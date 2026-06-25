import Foundation
import AppKit
import CLua

// ── Swift⇄Lua bridge state ──────────────────────────────────────────────────
// All access is on the main thread (Lua is created and called only from the main run
// loop), so these globals need no locking. Lua C functions are bare C function pointers
// with no captured state, hence the file-level storage. nonisolated(unsafe) because the
// C callbacks are nonisolated; we uphold main-thread-only by construction.
nonisolated(unsafe) var luaState: OpaquePointer?
nonisolated(unsafe) var luaNotify: (String) -> Void = { FileHandle.standardError.write(Data("[halo.lua] \($0)\n".utf8)) }
nonisolated(unsafe) var luaCommands: [String: Int32] = [:]            // name → registry ref
nonisolated(unsafe) var luaEvents: [String: [Int32]] = [:]           // event → [registry refs]
nonisolated(unsafe) var luaBinds: [(spec: String, ref: Int32)] = []  // "cmd+shift+p" → registry ref
nonisolated(unsafe) var luaActiveInfo: () -> (cwd: String, title: String, paneID: String)? = { nil }
nonisolated(unsafe) var luaSendText: (String) -> Void = { _ in }

// Pop the function at stack slot 2 into the registry and return its ref (for on/command/bind).
private func refFunctionArg2(_ L: OpaquePointer?) -> Int32 {
    luaL_checktype(L, 2, halo_lua_tfunction())
    lua_pushvalue(L, 2)
    return luaL_ref(L, halo_lua_registryindex())
}

private func l_halo_notify(_ L: OpaquePointer?) -> Int32 {
    if let c = luaL_checklstring(L, 1, nil) { luaNotify(String(cString: c)) }
    return 0
}
private func l_halo_command(_ L: OpaquePointer?) -> Int32 {
    guard let c = luaL_checklstring(L, 1, nil) else { return 0 }
    luaCommands[String(cString: c)] = refFunctionArg2(L)
    return 0
}
private func l_halo_on(_ L: OpaquePointer?) -> Int32 {
    guard let c = luaL_checklstring(L, 1, nil) else { return 0 }
    luaEvents[String(cString: c), default: []].append(refFunctionArg2(L))
    return 0
}
private func l_halo_bind(_ L: OpaquePointer?) -> Int32 {
    guard let c = luaL_checklstring(L, 1, nil) else { return 0 }
    luaBinds.append((spec: String(cString: c), ref: refFunctionArg2(L)))
    return 0
}
private func l_halo_send(_ L: OpaquePointer?) -> Int32 {
    if let c = luaL_checklstring(L, 1, nil) { luaSendText(String(cString: c)) }
    return 0
}
private func l_halo_active(_ L: OpaquePointer?) -> Int32 {
    guard let info = luaActiveInfo() else { lua_pushnil(L); return 1 }
    lua_createtable(L, 0, 3)
    info.cwd.withCString    { _ = lua_pushstring(L, $0) }; lua_setfield(L, -2, "cwd")
    info.title.withCString  { _ = lua_pushstring(L, $0) }; lua_setfield(L, -2, "title")
    info.paneID.withCString { _ = lua_pushstring(L, $0) }; lua_setfield(L, -2, "paneID")
    return 1
}

// ── Calling Lua back from Swift (events, commands, binds) ────────────────────
/// Invoke a stored Lua function (registry ref) with an optional string arg. Errors are
/// reported via notify and never propagate. Main thread only.
func luaCall(ref: Int32, stringArg: String? = nil) {
    guard let L = luaState else { return }
    lua_rawgeti(L, halo_lua_registryindex(), lua_Integer(ref))   // push the function
    var nargs: Int32 = 0
    if let s = stringArg { s.withCString { _ = lua_pushstring(L, $0) }; nargs = 1 }
    if lua_pcallk(L, nargs, 0, 0, 0, nil) != 0 {
        let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "error"
        luaNotify("lua: \(err)")
        lua_settop(L, -2)   // pop the error
    }
}
/// Fire every handler registered for `event` via halo.on (with an optional string payload).
func luaFire(_ event: String, _ arg: String? = nil) {
    guard luaState != nil, let refs = luaEvents[event] else { return }
    for r in refs { luaCall(ref: r, stringArg: arg) }
}
/// Run a Lua command registered via halo.command. Returns false if no such command.
@discardableResult
func luaRunCommand(_ name: String) -> Bool {
    guard let r = luaCommands[name] else { return false }
    luaCall(ref: r); return true
}

/// Embedded Lua 5.4 runtime. Runs `~/.config/halo/init.lua` with a `halo` global:
/// `notify`, `command(name, fn)`, `on(event, fn)`, `bind(chord, fn)`, `send(text)`,
/// `active()`. The state is rebuilt on `halo reload`. A bad script reports via notify,
/// never crashes the app.
@MainActor
final class LuaRuntime {
    static let shared = LuaRuntime()
    static var initScriptPath: String { NSHomeDirectory() + "/.config/halo/init.lua" }

    func start() {
        if let old = luaState { lua_close(old); luaState = nil }
        // Drop refs from the previous load (reload re-registers everything fresh).
        luaCommands.removeAll(); luaEvents.removeAll(); luaBinds.removeAll()
        guard let L = luaL_newstate() else { return }
        luaState = L
        luaL_openlibs(L)
        lua_createtable(L, 0, 6)   // the `halo` table
        func reg(_ name: String, _ fn: lua_CFunction) {
            lua_pushcclosure(L, fn, 0); lua_setfield(L, -2, name)
        }
        reg("notify",  l_halo_notify)
        reg("command", l_halo_command)
        reg("on",      l_halo_on)
        reg("bind",    l_halo_bind)
        reg("send",    l_halo_send)
        reg("active",  l_halo_active)
        lua_setglobal(L, "halo")
        runInit()
        luaFire("config-reloaded")   // handlers registered in init.lua can react to (re)load
    }

    private func runInit() {
        guard let L = luaState else { return }
        let path = Self.initScriptPath
        guard FileManager.default.fileExists(atPath: path) else { return }   // no config → no-op
        let loaded = path.withCString { luaL_loadfilex(L, $0, nil) }
        if loaded != 0 || lua_pcallk(L, 0, 0, 0, 0, nil) != 0 {
            let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "unknown error"
            luaNotify("init.lua: \(err)")
            lua_settop(L, -2)
        }
    }
}
