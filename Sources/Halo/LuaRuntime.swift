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
nonisolated(unsafe) var luaPluginSpecs: [String] = []                 // declared via halo.plugin(...)
nonisolated(unsafe) var luaControl: (String, [String]) -> [String: Any] = { _, _ in [:] }  // halo.cmd → control dispatch
nonisolated(unsafe) var luaScheduleTimer: (Double, Int32) -> Void = { _, _ in }            // halo.timer
nonisolated(unsafe) var luaClearTimers: () -> Void = {}                                     // reset on reload
nonisolated(unsafe) var luaShowPicker: ([String], Int32) -> Void = { _, _ in }             // halo.pick
nonisolated(unsafe) var luaSetStatus: (String) -> Void = { _ in }                          // halo.status
nonisolated(unsafe) var luaPanel: ([PanelLine], PanelOpts) -> Int = { _, _ in 0 }           // halo.panel → id
nonisolated(unsafe) var luaClosePanel: (Int) -> Void = { _ in }                            // halo.close
nonisolated(unsafe) var luaClearPanels: () -> Void = {}                                     // reset on reload
nonisolated(unsafe) var luaShowPrompt: (String, Int32) -> Void = { _, _ in }               // halo.prompt
nonisolated(unsafe) var luaConfigOverrides: [String: String] = [:]                         // halo.set (Lua wins)

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
private func l_halo_status(_ L: OpaquePointer?) -> Int32 {
    luaSetStatus(luaL_checklstring(L, 1, nil).map { String(cString: $0) } ?? "")
    return 0
}
/// halo.set(key, value) — override a config key (Lua wins over the file/UI). Chrome
/// aliases (accent/surface/…) get the `halo-` prefix; any other key is treated as a raw
/// ghostty key (e.g. `background`) and reaches libghostty. Value coerced to a string.
/// Short names that map to Halo's own chrome knobs (everything else is a raw ghostty key).
private let haloConfigAliases: Set<String> = [
    "accent", "surface", "font-family", "sidebar-width", "font-size", "divider-width"]

private func l_halo_set(_ L: OpaquePointer?) -> Int32 {
    guard let kc = luaL_checklstring(L, 1, nil) else { return 0 }
    var key = String(cString: kc)
    if haloConfigAliases.contains(key) { key = "halo-" + key }   // chrome knob; else a ghostty key
    let val: String
    if let vc = lua_tolstring(L, 2, nil) { val = String(cString: vc) }   // string / number
    else { val = lua_toboolean(L, 2) != 0 ? "true" : "false" }            // boolean
    luaConfigOverrides[key] = val
    return 0
}
private func l_halo_plugin(_ L: OpaquePointer?) -> Int32 {
    if let c = luaL_checklstring(L, 1, nil) { luaPluginSpecs.append(String(cString: c)) }
    return 0
}

/// Push a Swift value as a Lua value (recursively for arrays/dicts) — used to hand
/// `halo.cmd(...)` results (e.g. capture text, the full state tree) back to Lua.
private func pushLuaValue(_ L: OpaquePointer?, _ v: Any) {
    switch v {
    case let s as String:  s.withCString { _ = lua_pushstring(L, $0) }
    case let b as Bool:    lua_pushboolean(L, b ? 1 : 0)
    case let i as Int:     lua_pushinteger(L, lua_Integer(i))
    case let d as Double:  lua_pushnumber(L, d)
    case let arr as [Any]:
        lua_createtable(L, Int32(arr.count), 0)
        for (i, e) in arr.enumerated() { pushLuaValue(L, e); lua_rawseti(L, -2, lua_Integer(i + 1)) }
    case let dict as [String: Any]:
        lua_createtable(L, 0, Int32(dict.count))
        for (k, val) in dict { pushLuaValue(L, val); lua_setfield(L, -2, k) }
    default: lua_pushnil(L)
    }
}

/// halo.cmd(verb, ...string args) → runs a control verb (same as the CLI) and returns
/// its result as a Lua table. Gives plugins capture/state/split/tab/select/open/zoom/…
private func l_halo_cmd(_ L: OpaquePointer?) -> Int32 {
    guard let c = luaL_checklstring(L, 1, nil) else { return 0 }
    let verb = String(cString: c)
    var args: [String] = []
    let n = lua_gettop(L)
    if n >= 2 { for i in 2...n { if let a = lua_tolstring(L, i, nil) { args.append(String(cString: a)) } } }
    pushLuaValue(L, luaControl(verb, args))
    return 1
}

/// halo.timer(seconds, fn) — call fn every `seconds` (repeating). Cleared on reload.
private func l_halo_timer(_ L: OpaquePointer?) -> Int32 {
    let secs = lua_tonumberx(L, 1, nil)
    luaL_checktype(L, 2, halo_lua_tfunction())
    lua_pushvalue(L, 2)
    let ref = luaL_ref(L, halo_lua_registryindex())
    luaScheduleTimer(secs, ref)
    return 0
}

/// halo.pick(items, fn) — show a filterable picker; fn(chosen) runs on selection. The
/// fn ref is one-shot (freed after choose/cancel via luaUnref).
private func l_halo_pick(_ L: OpaquePointer?) -> Int32 {
    luaL_checktype(L, 1, halo_lua_ttable())
    let len = Int(lua_rawlen(L, 1))
    var items: [String] = []
    if len > 0 {
        for i in 1...len {
            lua_rawgeti(L, 1, lua_Integer(i))
            if let c = lua_tolstring(L, -1, nil) { items.append(String(cString: c)) }
            lua_settop(L, -2)
        }
    }
    luaL_checktype(L, 2, halo_lua_tfunction())
    lua_pushvalue(L, 2)
    let ref = luaL_ref(L, halo_lua_registryindex())
    luaShowPicker(items, ref)
    return 0
}

/// Free a one-shot registry ref (halo.pick callbacks after they fire/cancel).
func luaUnref(_ ref: Int32) {
    if let L = luaState { luaL_unref(L, halo_lua_registryindex(), ref) }
}

/// Read a Lua array (table) of strings at stack `idx`.
private func luaStringArray(_ L: OpaquePointer?, _ idx: Int32) -> [String] {
    luaL_checktype(L, idx, halo_lua_ttable())
    let len = Int(lua_rawlen(L, idx))
    var out: [String] = []
    if len > 0 {
        for i in 1...len {
            lua_rawgeti(L, idx, lua_Integer(i))
            if let c = lua_tolstring(L, -1, nil) { out.append(String(cString: c)) }
            lua_settop(L, -2)
        }
    }
    return out
}

/// Read the panel `lines` array: each element is a string OR a table {text, color, click}.
private func panelLines(_ L: OpaquePointer?, _ idx: Int32) -> [PanelLine] {
    luaL_checktype(L, idx, halo_lua_ttable())
    let len = Int(lua_rawlen(L, idx))
    var out: [PanelLine] = []
    guard len > 0 else { return out }
    for i in 1...len {
        lua_rawgeti(L, idx, lua_Integer(i))                 // push element (-1)
        if lua_isstring(L, -1) != 0 {
            out.append(PanelLine(text: lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? ""))
            lua_settop(L, -2)
        } else {
            var line = PanelLine(text: "")
            lua_getfield(L, -1, "text");  line.text = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? ""; lua_settop(L, -2)
            lua_getfield(L, -1, "color"); line.colorHex = lua_tolstring(L, -1, nil).map { String(cString: $0) }; lua_settop(L, -2)
            lua_getfield(L, -1, "click")
            if lua_type(L, -1) == halo_lua_tfunction() { line.clickRef = luaL_ref(L, halo_lua_registryindex()) }  // pops fn
            else { lua_settop(L, -2) }
            out.append(line)
            lua_settop(L, -2)                               // pop element table
        }
    }
    return out
}

/// halo.panel(lines [, opts]) → id. opts = {title, corner, bg, width, id}. With an existing
/// id it updates that panel in place; otherwise it creates one. The custom-UI workhorse.
private func l_halo_panel(_ L: OpaquePointer?) -> Int32 {
    let lines = panelLines(L, 1)
    var o = PanelOpts()
    if lua_type(L, 2) == halo_lua_ttable() {
        func str(_ k: String) -> String? { lua_getfield(L, 2, k); defer { lua_settop(L, -2) }; return lua_tolstring(L, -1, nil).map { String(cString: $0) } }
        if let t = str("title") { o.title = t }
        if let c = str("corner") { o.corner = c }
        o.bgHex = str("bg")
        o.allWindows = (str("window") == "all")   // "all" → every window; default "active"
        lua_getfield(L, 2, "id");    o.id = Int(lua_tointegerx(L, -1, nil)); lua_settop(L, -2)
        lua_getfield(L, 2, "width"); o.width = lua_tonumberx(L, -1, nil);    lua_settop(L, -2)
    }
    lua_pushinteger(L, lua_Integer(luaPanel(lines, o)))
    return 1
}
/// halo.close(id) — remove a panel created by halo.panel.
private func l_halo_close(_ L: OpaquePointer?) -> Int32 {
    luaClosePanel(Int(luaL_checkinteger(L, 1)))
    return 0
}
/// halo.prompt(message, fn) — ask for a line of text; fn(text) runs on Enter (one-shot).
private func l_halo_prompt(_ L: OpaquePointer?) -> Int32 {
    let msg = luaL_checklstring(L, 1, nil).map { String(cString: $0) } ?? ""
    luaL_checktype(L, 2, halo_lua_tfunction())
    lua_pushvalue(L, 2)
    let ref = luaL_ref(L, halo_lua_registryindex())
    luaShowPrompt(msg, ref)
    return 0
}

/// git-clone a plugin (run off-main). `spec` is "owner/repo" (→ GitHub) or a full URL.
func gitClonePlugin(_ spec: String, to dir: String) -> Bool {
    let url = (spec.hasPrefix("http") || spec.hasPrefix("git@")) ? spec : "https://github.com/\(spec).git"
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["clone", "--depth", "1", url, dir]
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
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
    static var configDir: String { NSHomeDirectory() + "/.config/halo" }
    static var initScriptPath: String { configDir + "/init.lua" }
    static var pluginsDir: String { configDir + "/plugins" }

    func start() {
        if let old = luaState { lua_close(old); luaState = nil }
        // Drop refs/timers from the previous load (reload re-registers everything fresh).
        luaCommands.removeAll(); luaEvents.removeAll(); luaBinds.removeAll(); luaPluginSpecs.removeAll()
        luaConfigOverrides.removeAll()
        luaClearTimers(); luaClearPanels()
        guard let L = luaL_newstate() else { return }
        luaState = L
        luaL_openlibs(L)
        lua_createtable(L, 0, 10)   // the `halo` table
        func reg(_ name: String, _ fn: lua_CFunction) {
            lua_pushcclosure(L, fn, 0); lua_setfield(L, -2, name)
        }
        reg("notify",  l_halo_notify)
        reg("command", l_halo_command)
        reg("on",      l_halo_on)
        reg("bind",    l_halo_bind)
        reg("send",    l_halo_send)
        reg("active",  l_halo_active)
        reg("plugin",  l_halo_plugin)
        reg("cmd",     l_halo_cmd)
        reg("timer",   l_halo_timer)
        reg("pick",    l_halo_pick)
        reg("status",  l_halo_status)
        reg("panel",   l_halo_panel)
        reg("close",   l_halo_close)
        reg("prompt",  l_halo_prompt)
        reg("set",     l_halo_set)
        lua_setglobal(L, "halo")
        runPrelude()   // convenience wrappers over halo.cmd
        runInit()
        loadPlugins()                // declared (halo.plugin) + drop-in plugins/*/
        luaFire("config-reloaded")   // handlers registered in init.lua/plugins react to (re)load
    }

    /// Load plugins: declared via `halo.plugin("owner/repo")` (cloned to plugins/ if
    /// missing) plus any drop-in `plugins/*/` folder. Each plugin's `init.lua` (or
    /// `plugin/init.lua`) runs with the same `halo` global, so it registers commands /
    /// events / binds like init.lua does.
    private func loadPlugins() {
        let base = Self.pluginsDir
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let disabled = disabledPlugins()
        var handled = Set<String>()
        for spec in luaPluginSpecs {
            let name = ((spec as NSString).lastPathComponent as NSString)
                .deletingPathExtension   // strip a trailing .git
            let dir = base + "/" + name
            handled.insert(dir)
            if disabled.contains(name) { continue }
            if FileManager.default.fileExists(atPath: dir) {
                loadPluginEntry(dir)
            } else {
                luaNotify("installing plugin \(spec)…")
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = gitClonePlugin(spec, to: dir)
                    DispatchQueue.main.async {
                        if ok { self.loadPluginEntry(dir); luaNotify("plugin \(name) installed") }
                        else  { luaNotify("plugin \(spec): clone failed") }
                    }
                }
            }
        }
        // Drop-in: any plugins/*/ folder not already declared.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        for e in entries.sorted() {
            let dir = base + "/" + e
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                  !handled.contains(dir), !disabled.contains(e) else { continue }
            loadPluginEntry(dir)
        }
    }

    static var disabledPath: String { configDir + "/disabled-plugins" }

    /// Names of plugins the user has turned off (skipped at load). One name per line.
    func disabledPlugins() -> Set<String> {
        guard let t = try? String(contentsOfFile: Self.disabledPath, encoding: .utf8) else { return [] }
        return Set(t.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Persist a plugin's enabled state. The caller triggers the full reload (config + chrome).
    func setPluginEnabled(_ name: String, _ enabled: Bool) {
        var d = disabledPlugins()
        if enabled { d.remove(name) } else { d.insert(name) }
        try? d.sorted().joined(separator: "\n").write(toFile: Self.disabledPath, atomically: true, encoding: .utf8)
    }

    /// Run a plugin's entry script (`<dir>/init.lua` or `<dir>/plugin/init.lua`).
    private func loadPluginEntry(_ dir: String) {
        guard let L = luaState else { return }
        let entry = [dir + "/init.lua", dir + "/plugin/init.lua"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let entry else { return }
        let loaded = entry.withCString { luaL_loadfilex(L, $0, nil) }
        if loaded != 0 || lua_pcallk(L, 0, 0, 0, 0, nil) != 0 {
            let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "error"
            luaNotify("plugin \((dir as NSString).lastPathComponent): \(err)")
            lua_settop(L, -2)
        }
    }

    /// Names of installed plugin folders (for `halo plugins`).
    func installedPlugins() -> [String] {
        let base = Self.pluginsDir
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return entries.filter { e in
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: base + "/" + e, isDirectory: &d) && d.boolValue
        }.sorted()
    }

    /// `git pull` every installed plugin, then reload so updates take effect.
    @discardableResult
    func syncPlugins() -> [String] {
        let base = Self.pluginsDir
        let names = installedPlugins()
        for n in names {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", base + "/" + n, "pull", "--ff-only", "--quiet"]
            try? p.run(); p.waitUntilExit()
        }
        start()
        return names
    }

    /// Convenience wrappers over halo.cmd, defined in Lua so plugins get ergonomic helpers
    /// (halo.capture/state/split/tab/select/open/zoom/browser/focus) without shelling out.
    private func runPrelude() {
        guard let L = luaState else { return }
        let prelude = """
        function halo.capture(scrollback)
          local r = scrollback and halo.cmd("capture","focused","--scrollback") or halo.cmd("capture","focused")
          return r and r.text or ""
        end
        function halo.state() return halo.cmd("state") end
        function halo.split(h) if h then halo.cmd("split","-h") else halo.cmd("split") end end
        function halo.open(p) halo.cmd("open", p) end
        function halo.tab(a) halo.cmd("tab", a or "new") end
        function halo.select(p,s) halo.cmd("select", tostring(p), tostring(s)) end
        function halo.zoom() halo.cmd("zoom") end
        function halo.browser(u) halo.cmd("browser", u or "about:blank") end
        function halo.focus(id) if id then halo.cmd("focus", tostring(id)) else halo.cmd("focus") end end
        """
        if prelude.withCString({ luaL_loadstring(L, $0) }) != 0 || lua_pcallk(L, 0, 0, 0, 0, nil) != 0 {
            let err = lua_tolstring(L, -1, nil).map { String(cString: $0) } ?? "error"
            luaNotify("prelude: \(err)"); lua_settop(L, -2)
        }
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
