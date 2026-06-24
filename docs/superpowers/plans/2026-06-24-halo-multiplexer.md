# Halo Multiplexer & Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Halo's in-app sessions into a terminal multiplexer that beats tmux — shells survive Halo quitting, reattach is clean and restores native scrollback, detached sessions stay visible, sessions mirror live, and you can attach to another machine — plus tmux-style prefix keys and named sessions.

**Architecture:** A daemon (`halod`) owns each shell's PTY and parses its output through vendored libvterm to keep authoritative screen + scrollback state (spilled to disk past a cap, with an image-placement cache). A thin relay (`halo-attach`) is spawned by each ghostty surface as its command and pumps bytes/winsize over a `0600` unix socket; on attach the daemon sends a clean redraw + restored scrollback + cached images. The GUI gives each `TerminalPane` a stable `paneID`, persists it, and reattaches by id. Prefix mode and the session switcher are pure-Swift layers over the existing `PaneTree`/`Tabs`.

**Tech Stack:** Swift 6 / AppKit / libghostty (existing); vendored **libvterm** (MIT) as a SwiftPM C target — the only new dependency. Pure-logic self-checks run via the existing `halo selfcheck` verb.

## Global Constraints

- **Never hardcode colors.** All chrome pulls color from the ghostty config via `theme.accent` / `theme.background`. The daemon never renders — ghostty stays the source of truth for color.
- **Sockets are owner-only `0600`**; their parent dir `~/Library/Application Support/halo` is `0700`.
- **Only one new dependency:** vendored libvterm (MIT). No other deps. We do not write a VT parser.
- **One runnable pure-logic self-check per feature**, added as a `func <name>SelfCheck()` that uses `assert(...)` + `print("<name>SelfCheck ok")` and is wired into the `selfcheck` list in `Sources/Halo/main.swift:8`. Verified by `swift run halo selfcheck` printing `all self-checks ok`. UI / live-PTY behavior is verified hands-on (screenshots + synthetic input), never blind review.
- **Detach UX:** close (Cmd-W) and quit **detach** — the shell stays alive under `halod`; a session is reaped only when its shell process exits; an explicit **kill** action is separate. Detached sessions always appear in the switcher (never silent zombies).
- **Shortest working diff.** Follow existing patterns; don't restructure unrelated code.

---

## Shared Contract (canonical names — every task uses these verbatim)

All five milestones share these. Later tasks consume types defined here; do not rename them.

### Target / file structure (`Package.swift`)

Today there is one executable target `halo` at `Sources/Halo`. Add:

- **`HaloMux`** target — `Sources/HaloMux/` — pure Swift, no AppKit. Shared by `halo`, `halod`, `halo-attach`. Holds:
  - `MuxProtocol.swift` — wire frame types + codec (below) + `muxProtocolSelfCheck()`.
  - `MuxPaths.swift` — socket/log path helpers + `muxPathsSelfCheck()`.
- **`CVterm`** target — `Sources/CVterm/` — C target wrapping vendored libvterm sources under `Sources/CVterm/vendor/` with an umbrella `include/cvterm.h`. Depended on by `halod` only.
- **`halod`** executable target — `Sources/halod/` — depends on `HaloMux`, `CVterm`.
- **`halo-attach`** executable target — `Sources/halo-attach/` — depends on `HaloMux`.
- **`halo`** target gains a dependency on `HaloMux`.

### Wire protocol — `Sources/HaloMux/MuxProtocol.swift`

```swift
import Foundation

public let muxProtocolVersion = 1

public struct SessionInfo: Codable, Equatable {
    public let id: String          // == paneID
    public let name: String?
    public let cwd: String?
    public let alive: Bool
    public let attachedCount: Int
    public init(id: String, name: String?, cwd: String?, alive: Bool, attachedCount: Int) {
        self.id = id; self.name = name; self.cwd = cwd; self.alive = alive; self.attachedCount = attachedCount
    }
}

public enum ClientFrame: Equatable {
    case hello(paneID: String, cols: Int, rows: Int)
    case input(Data)
    case resize(cols: Int, rows: Int)
    case detach
    case kill
    case list
}

public enum ServerFrame: Equatable {
    case helloAck(version: Int)
    case needsUpdate(serverVersion: Int)
    case snapshot(screen: Data, scrollback: Data, images: Data)
    case output(Data)
    case exited(status: Int32)
    case sessions([SessionInfo])
}

// Framing: [UInt32 big-endian total-payload-length][UInt8 tag][payload].
// encode(_:) returns one full framed message.
// decode*(from:) consumes one full frame from the front of `buf` and returns it,
//   or returns nil and leaves `buf` untouched if a full frame isn't buffered yet.
public func encode(_ f: ClientFrame) -> Data
public func encode(_ f: ServerFrame) -> Data
public func decodeClientFrame(from buf: inout Data) -> ClientFrame?
public func decodeServerFrame(from buf: inout Data) -> ServerFrame?
```

`muxProtocolSelfCheck()` asserts encode→decode round-trips for every case and that a partial buffer yields `nil` without consuming bytes.

### Paths — `Sources/HaloMux/MuxPaths.swift`

```swift
public enum MuxPaths {
    public static var base: String          // ~/Library/Application Support/halo  (created 0700)
    public static var daemonSocket: String  // base + "/halod.sock"   (bind 0600)
    public static func sessionLog(_ paneID: String) -> String  // base + "/sessions/<paneID>.log"
    public static func ensureDirs()         // mkdir base + base/sessions at 0700
}
```

### GUI integration points (existing code)

- `TerminalPane` (`Sources/Halo/TerminalPane.swift:37`, init) gains `let paneID: String` (a UUID string; new arg, default `UUID().uuidString`). Surface spawn is at `:48–60`.
- **Spawn command:** once persistence is on (M3), set `config.command` to `"<helper> <paneID>"` where `<helper> = muxHelperPath()` resolves to the `halo-attach` binary beside the running executable: `Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("halo-attach").path` (works in `Halo.app/Contents/MacOS` and in `.build/debug`). Before M3, panes spawn the bare shell unchanged (gated by config key `halo-persist`, default off until M3 flips it on).
- **Sessions are `PaneTree`s** held in `Workspace.projs[].sessions` (`Sources/Halo/Tabs.swift`). A session reattaches by the `paneID` of its leaf panes.
- **Persistence:** `Sources/Halo/Tabs.swift` `serialize()` (~:389) reduces each session to its focused-pane cwd; `restoreSession`/restore (~:403–436) rebuilds one shell per cwd. Extend the per-session snapshot from `cwd` to `{cwd, paneID, name}`; across-restart layout stays single-leaf-per-session (cwd-only layout is an existing, retained ponytail limitation — see `Tabs.swift:389`), but the persisted `paneID` lets that shell **reattach** to its live daemon session. Orphaned leaves of a multi-split session remain alive in the daemon and show in the switcher.
- **Self-check wiring:** add each new `*SelfCheck()` call into the list at `Sources/Halo/main.swift:8`. `HaloMux` checks are callable from the `halo` target because it depends on `HaloMux`.

### Task numbering

Tasks are labelled `Task <milestone>.<n>` (e.g. `Task 3.4`) so milestones stay independently orderable. Build milestones in order 1→5; each ends with a green `swift build` and (where it has one) a passing self-check.

---

## Milestone 1 — Prefix-key mode (pure Swift, no daemon)

This milestone is a pure-Swift layer over the **existing** `Workspace`/`PaneTree`
actions. It adds a configurable tmux-style prefix (`halo-prefix`, default
`ctrl+b`, empty = off), a keytable mapping `(prefix, key) → PrefixAction`, a
small pending-state machine (armed → next key resolves or cancels on
timeout/escape), and a subtle top-bar "armed" indicator (color from
`theme.accent`, never hardcoded). No new pane plumbing: every action dispatches
to a method that already exists in `Workspace`/`PaneTree`. `d` (detach), `x`
(kill), and `s` (switcher) resolve to `PrefixAction` cases now but their
dispatch is a no-op stub (NSSound.beep) until Milestones 2–3 — the keytable
entry + dispatch path must exist regardless.

All new pure logic lives in a new file `Sources/Halo/PrefixMode.swift`. The one
required self-check is `prefixKeytableSelfCheck()` (keytable parse + resolve),
wired into `Sources/Halo/main.swift:8`.

---

### Task 1.1: `PrefixAction` enum + default keytable (pure logic)
**Files:** Create `Sources/Halo/PrefixMode.swift`. Self-check runs via the `halo` target (`swift run halo selfcheck`).
**Interfaces:**
- Consumes: nothing (first task of the milestone). It will be *dispatched* against existing `Workspace`/`PaneTree` methods in Task 1.4 — those signatures are already in the codebase: `PaneTree.splitFocused(_ s: Split, cwd: String?)`, `PaneTree.focusNext()`, `PaneTree.focusPrev()`, `PaneTree.zoomFocused()`, `Workspace.newSession(_ p: Int)`, `Workspace.nextSession()`, `Workspace.prevSession()`, `Workspace.renameProject(_ p: Int, _ name: String)`.
- Produces: `enum PrefixAction` (cases below), `defaultPrefixKeytable: [String: PrefixAction]`, and `func parsePrefixKeytable(_ entries: [String]) -> [String: PrefixAction]`. Tasks 1.2/1.3/1.4 consume these names verbatim.

Steps:

1. Create `Sources/Halo/PrefixMode.swift` with the `PrefixAction` enum and the default keytable. Write exactly:

```swift
import AppKit

/// A prefix-mode action. Every case maps 1:1 onto an action that ALREADY exists
/// in Workspace/PaneTree (dispatched in Task 1.4) — prefix mode adds no new pane
/// plumbing. `detach`/`kill`/`switcher` are wired into the keytable + dispatch
/// now but stubbed (beep) until Milestones 2–3.
enum PrefixAction: Equatable {
    case splitVertical      // %  → ws.activeTree.splitFocused(.vertical, …)
    case splitHorizontal    // "  → ws.activeTree.splitFocused(.horizontal, …)
    case focusLeft          // h / ←
    case focusDown          // j / ↓
    case focusUp            // k / ↑
    case focusRight         // l / →
    case zoom               // z  → ws.activeTree.zoomFocused()
    case newSession         // c  → ws.newSession(ws.activeP)
    case nextSession        // n  → ws.nextSession()
    case prevSession        // p  → ws.prevSession()
    case rename             // ,  → rename the active session's project
    case switcher           // s  → (stub until M2)
    case detach             // d  → (stub until M3)
    case kill               // x  → (stub until M3)
}

/// The default `(key) → PrefixAction` table, used when the config supplies no
/// `halo-prefix-bind` overrides. Keys are the SINGLE-character token a user
/// presses AFTER the prefix; arrows use the tokens "left"/"down"/"up"/"right".
/// tmux muscle memory: % / " split, h j k l + arrows navigate, z zoom, c new,
/// n/p next/prev, , rename, s switcher, d detach, x kill.
let defaultPrefixKeytable: [String: PrefixAction] = [
    "%": .splitVertical,
    "\"": .splitHorizontal,
    "h": .focusLeft, "left": .focusLeft,
    "j": .focusDown, "down": .focusDown,
    "k": .focusUp, "up": .focusUp,
    "l": .focusRight, "right": .focusRight,
    "z": .zoom,
    "c": .newSession,
    "n": .nextSession,
    "p": .prevSession,
    ",": .rename,
    "s": .switcher,
    "d": .detach,
    "x": .kill,
]
```

2. Run `swift build` and confirm it compiles (the enum/dict are standalone). No self-check yet.
   `git commit -m "M1: PrefixAction enum + default keytable"`

---

### Task 1.2: keytable parse + resolve + self-check (pure logic — REQUIRED self-check)
**Files:** Modify `Sources/Halo/PrefixMode.swift` (append parser + self-check). Modify `Sources/Halo/main.swift:8` (wire the self-check).
**Interfaces:**
- Consumes: `PrefixAction`, `defaultPrefixKeytable` (Task 1.1).
- Produces: `func parsePrefixKeytable(_ entries: [String]) -> [String: PrefixAction]`, `func resolvePrefix(_ key: String, in table: [String: PrefixAction]) -> PrefixAction?`, `func prefixKeytableSelfCheck()`. Task 1.4 consumes `resolvePrefix` and the parser output.

Steps:

1. Append the parser + resolver to `Sources/Halo/PrefixMode.swift`. The config form is `halo-prefix-bind = <key>:<action>` (repeatable); `entries` is the list of raw values for that key. Unknown action names and malformed entries are skipped (libghostty already ignores the `halo-*` keys). Write exactly:

```swift
/// Map an action NAME (config token) to a PrefixAction. Names match the
/// tmux-ish verbs; unknown names return nil (entry skipped).
private func prefixActionNamed(_ name: String) -> PrefixAction? {
    switch name {
    case "split-vertical", "split": return .splitVertical
    case "split-horizontal", "vsplit": return .splitHorizontal
    case "focus-left": return .focusLeft
    case "focus-down": return .focusDown
    case "focus-up": return .focusUp
    case "focus-right": return .focusRight
    case "zoom": return .zoom
    case "new-session": return .newSession
    case "next-session": return .nextSession
    case "prev-session": return .prevSession
    case "rename": return .rename
    case "switcher": return .switcher
    case "detach": return .detach
    case "kill": return .kill
    default: return nil
    }
}

/// Build the active keytable: start from `defaultPrefixKeytable`, then apply any
/// `halo-prefix-bind = <key>:<action>` overrides. `entries` is the raw list of
/// such values. A malformed entry (no `:`, empty key, unknown action) is skipped
/// so a typo never disarms the whole table. Case-insensitive on the action name;
/// the KEY token is taken verbatim (so `%`, `"`, `,` survive).
func parsePrefixKeytable(_ entries: [String]) -> [String: PrefixAction] {
    var table = defaultPrefixKeytable
    for raw in entries {
        guard let colon = raw.firstIndex(of: ":") else { continue }
        let key = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
        let name = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, let action = prefixActionNamed(name) else { continue }
        table[key] = action
    }
    return table
}

/// Resolve a pressed key token (a single character, or "left"/"down"/"up"/"right"
/// for arrows) to its action. Returns nil when the key isn't bound — the caller
/// cancels the pending state on a nil resolve.
func resolvePrefix(_ key: String, in table: [String: PrefixAction]) -> PrefixAction? {
    table[key]
}
```

2. Append the self-check to `Sources/Halo/PrefixMode.swift`. Write exactly:

```swift
// MARK: - Self-check (pure logic: keytable parse + resolve)

func prefixKeytableSelfCheck() {
    // Default table resolves the canonical tmux bindings.
    let d = defaultPrefixKeytable
    assert(resolvePrefix("%", in: d) == .splitVertical, "% splits vertical")
    assert(resolvePrefix("\"", in: d) == .splitHorizontal, "\" splits horizontal")
    assert(resolvePrefix("h", in: d) == .focusLeft, "h focuses left")
    assert(resolvePrefix("left", in: d) == .focusLeft, "← focuses left")
    assert(resolvePrefix("l", in: d) == .focusRight, "l focuses right")
    assert(resolvePrefix("z", in: d) == .zoom, "z zooms")
    assert(resolvePrefix("c", in: d) == .newSession, "c new session")
    assert(resolvePrefix("n", in: d) == .nextSession, "n next")
    assert(resolvePrefix("p", in: d) == .prevSession, "p prev")
    assert(resolvePrefix(",", in: d) == .rename, ", renames")
    assert(resolvePrefix("s", in: d) == .switcher, "s switcher")
    assert(resolvePrefix("d", in: d) == .detach, "d detach")
    assert(resolvePrefix("x", in: d) == .kill, "x kill")
    // Unbound key → nil (caller cancels).
    assert(resolvePrefix("Q", in: d) == nil, "unbound key resolves nil")

    // Overrides: rebind a key, add a new one, leave the rest untouched.
    let t = parsePrefixKeytable(["v:split-vertical", "x:zoom"])
    assert(resolvePrefix("v", in: t) == .splitVertical, "override adds v→splitVertical")
    assert(resolvePrefix("x", in: t) == .zoom, "override rebinds x→zoom")
    assert(resolvePrefix("h", in: t) == .focusLeft, "non-overridden keys keep defaults")

    // Malformed entries are skipped, never crash, never disarm the table.
    let m = parsePrefixKeytable(["", "nope", ":zoom", "q:bogus-action", "q:kill"])
    assert(resolvePrefix("q", in: m) == .kill, "last valid entry for a key wins; junk skipped")
    assert(resolvePrefix("%", in: m) == .splitVertical, "malformed input leaves defaults intact")

    print("prefixKeytableSelfCheck OK")
}
```

3. Run `swift run halo selfcheck` and SEE IT FAIL: `prefixKeytableSelfCheck` is not yet wired into `main.swift:8`, so the run prints `all self-checks ok` WITHOUT running it (no failure surfaced). Instead, prove the check runs by temporarily calling it from a scratch spot, OR just proceed to step 4 (the real wiring) and verify it appears. (We wire next so the check actually executes.)

4. Wire the self-check into the list at `Sources/Halo/main.swift:8`. Change the line:

```swift
    _ = ghosttyConfigSelfCheck(); controlSelfCheck(); gitSelfCheck(); portsSelfCheck(); workspaceSelfCheck(); worktreeSelfCheck(); browserSelfCheck()
```

to append `prefixKeytableSelfCheck()`:

```swift
    _ = ghosttyConfigSelfCheck(); controlSelfCheck(); gitSelfCheck(); portsSelfCheck(); workspaceSelfCheck(); worktreeSelfCheck(); browserSelfCheck(); prefixKeytableSelfCheck()
```

5. Run `swift run halo selfcheck` and SEE IT PASS: output now contains `prefixKeytableSelfCheck OK` and ends with `all self-checks ok`.
   `git commit -m "M1: prefix keytable parse/resolve + self-check"`

6. (Regression sanity for the malformed path.) Temporarily change the `q:kill` entry in the self-check to `q:zoom`, run `swift run halo selfcheck`, and SEE IT FAIL on `last valid entry for a key wins`. Revert the edit, re-run, SEE IT PASS. This proves the assert is load-bearing.
   `git commit -m "M1: confirm keytable assert is load-bearing"` (no code change if revert is clean — skip the commit if `git diff` is empty).

---

### Task 1.3: `halo-prefix` config parse + `PrefixState` pending-state machine
**Files:** Modify `Sources/Halo/PrefixMode.swift` (append `parsePrefixSpec` + `PrefixState`).
**Interfaces:**
- Consumes: `PrefixAction`, `resolvePrefix`, the keytable from Task 1.2.
- Produces: `func parsePrefixSpec(_ raw: String?) -> (mods: NSEvent.ModifierFlags, key: String)?` (nil = disabled), `@MainActor final class PrefixState`. Task 1.4 owns a `PrefixState`.

Steps:

1. Append the prefix-spec parser. `halo-prefix` uses ghostty's `mod+key` form (e.g. `ctrl+b`, `ctrl+a`, `cmd+a`); an empty/whitespace value disables prefix mode entirely (returns nil). Write exactly:

```swift
/// Parse the `halo-prefix` config value (e.g. "ctrl+b") into modifier flags + the
/// trigger key (lowercased single char). Empty/whitespace → nil (prefix disabled).
/// Recognized mod tokens: ctrl/control, alt/opt/option, shift, cmd/super/command.
/// Defaults to ctrl+b when the key is absent but mods are present is NOT done —
/// a malformed spec returns nil (prefix off) rather than guessing.
func parsePrefixSpec(_ raw: String?) -> (mods: NSEvent.ModifierFlags, key: String)? {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let tokens = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    guard !tokens.isEmpty else { return nil }
    var mods: NSEvent.ModifierFlags = []
    var key: String? = nil
    for tok in tokens {
        switch tok {
        case "ctrl", "control": mods.insert(.control)
        case "alt", "opt", "option": mods.insert(.option)
        case "shift": mods.insert(.shift)
        case "cmd", "super", "command": mods.insert(.command)
        default:
            // The single trigger key. Last non-mod token wins; must be 1 char.
            if tok.count == 1 { key = tok } else { key = nil }
        }
    }
    guard let k = key, !mods.isEmpty else { return nil }   // require a real chord
    return (mods, k)
}
```

2. Append the pending-state machine. Pressing the prefix arms it; the next key resolves through the keytable (fire) or cancels; Escape cancels; a timeout (default 2s) auto-cancels. The machine is pure state + callbacks — it does NOT touch AppKit views, so Task 1.4 can drive both the dispatch and the indicator from its callbacks. Write exactly:

```swift
/// The pending-state machine for prefix mode. Lives for the app's lifetime,
/// owned by AppDelegate (Task 1.4). Not itself a view: it calls `onArmedChange`
/// so the chrome can show/hide the indicator, and returns a resolved action from
/// `handle(...)` for the caller to dispatch. Timeout auto-cancels so a stray
/// prefix never traps the keyboard.
@MainActor
final class PrefixState {
    private(set) var armed = false
    private let timeout: TimeInterval
    private var timer: Timer?

    /// Called whenever `armed` flips, so chrome can show/hide the indicator.
    var onArmedChange: ((Bool) -> Void)?

    init(timeout: TimeInterval = 2.0) { self.timeout = timeout }

    /// Arm the prefix (the user pressed the prefix chord). Starts the timeout.
    func arm() {
        armed = true
        onArmedChange?(true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    /// Cancel the pending state (timeout, Escape, or an unbound key).
    func cancel() {
        guard armed else { return }
        armed = false
        timer?.invalidate(); timer = nil
        onArmedChange?(false)
    }

    /// While armed, consume the next key: resolve it (and disarm), or cancel on a
    /// nil resolve. `isEscape` short-circuits to a plain cancel. Returns the action
    /// to dispatch, or nil if the key cancelled/was swallowed. Always disarms.
    func handle(key: String, isEscape: Bool, table: [String: PrefixAction]) -> PrefixAction? {
        guard armed else { return nil }
        defer { cancel() }            // any consumed key disarms (cancel() flips indicator off)
        if isEscape { return nil }
        return resolvePrefix(key, in: table)
    }
}
```

3. Run `swift build` and confirm it compiles.
   `git commit -m "M1: halo-prefix spec parse + PrefixState pending-state machine"`

---

### Task 1.4: armed top-bar indicator in Chrome (color from `theme.accent`)
**Files:** Modify `Sources/Halo/Chrome.swift` (`HaloWindowController`: add an indicator view in `buildTitlebarAccessory()` ~`:645–702`, a `setPrefixArmed(_:)` method, and adopt accent in `applyTheme(_:)` ~`:106`).
**Interfaces:**
- Consumes: `theme.accent` (already a field on `Theme`, `Contract.swift:12`).
- Produces: `func setPrefixArmed(_ armed: Bool)` on `HaloWindowController`. Task 1.5 calls it via `PrefixState.onArmedChange`.

Steps:

1. In `Sources/Halo/Chrome.swift`, add a stored property for the indicator next to the other titlebar fields (near `private var dirLabel: NSTextField!` ~`:36`). Add:

```swift
    // Prefix-mode "armed" indicator (shown in the titlebar while waiting for the
    // next key). Color comes from theme.accent — never hardcoded.
    private var prefixPill: NSTextField?
```

2. In `buildTitlebarAccessory()` (~`:680`, right after `host.addSubview(dirLabel)`), build the pill (hidden by default) and pin it to the trailing edge of `host`. Add:

```swift
        let pill = NSTextField(labelWithString: "PREFIX")
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.font = Fonts.inst(9.5)
        pill.alignment = .center
        pill.textColor = theme.accent                         // color sync: theme.accent
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 4
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = theme.accent.cgColor        // color sync: theme.accent
        pill.layer?.backgroundColor = theme.accent.withAlphaComponent(0.12).cgColor
        pill.isHidden = true
        host.addSubview(pill)
        prefixPill = pill
        NSLayoutConstraint.activate([
            pill.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            pill.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 16),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
```

3. Add the public toggle method (place it in the `// MARK: public updates` area, e.g. right after `setDir(...)` ~`:119`). Add:

```swift
    /// Show/hide the prefix-armed indicator (driven by PrefixState.onArmedChange).
    func setPrefixArmed(_ armed: Bool) { prefixPill?.isHidden = !armed }
```

4. In `applyTheme(_ t: Theme)` (~`:106`), re-tint the pill so a live config reload keeps the accent in sync. After the existing `sidebar?.layer?.backgroundColor = surface.cgColor` line, add:

```swift
        prefixPill?.textColor = t.accent
        prefixPill?.layer?.borderColor = t.accent.cgColor
        prefixPill?.layer?.backgroundColor = t.accent.withAlphaComponent(0.12).cgColor
```

5. Run `swift build` and confirm it compiles.

6. Extend `chromeSelfCheck()` (~`:892`) to exercise the new method so it can't silently break. Before the final `print("chromeSelfCheck OK")`, add:

```swift
    wc.setPrefixArmed(true)
    wc.setPrefixArmed(false)   // toggling must not crash and leaves the pill hidden
```

7. Run `swift run halo selfcheck` and SEE IT PASS (`chromeSelfCheck OK` still prints, plus the new toggle ran).
   `git commit -m "M1: titlebar prefix-armed indicator (theme.accent)"`

---

### Task 1.5: intercept the prefix chord + dispatch actions in AppDelegate
**Files:** Modify `Sources/Halo/main.swift` (`AppDelegate`: add a `prefix` field + a `prefixTable` field, build them in `applicationDidFinishLaunching` ~`:105`, and intercept in `installKeybinds()` ~`:336`).
**Interfaces:**
- Consumes: `parsePrefixSpec`, `parsePrefixKeytable`, `PrefixState`, `PrefixAction`, `resolvePrefix` (Tasks 1.1–1.3); `HaloWindowController.setPrefixArmed` (Task 1.4); existing `Workspace`/`PaneTree` actions.
- Produces: a working prefix layer. Nothing later in this milestone consumes it.

Steps:

1. Add the stored state to `AppDelegate` (near `var theme = Theme()` ~`:31`). Add:

```swift
    // Prefix mode (tmux-style). `prefix` is nil when halo-prefix is empty/disabled.
    private let prefixState = PrefixState()
    private var prefix: (mods: NSEvent.ModifierFlags, key: String)?
    private var prefixTable: [String: PrefixAction] = defaultPrefixKeytable
```

2. Build the prefix spec + table from config in `applicationDidFinishLaunching`, right after `installKeybinds()` (~`:117`). The prefix-bind overrides come from any `halo-prefix-bind` keys in the settings; since libghostty collapses duplicate keys to last-wins in `GhosttyApp.shared.settings`, read the single value if present (multiple binds in v1 are taken from a comma-separated list — keep it simple). Add:

```swift
        let settings = GhosttyApp.shared.settings
        prefix = parsePrefixSpec(settings["halo-prefix"] ?? "ctrl+b")
        let binds = (settings["halo-prefix-bind"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        prefixTable = parsePrefixKeytable(binds)
        prefixState.onArmedChange = { [weak self] armed in
            self?.active?.controller.setPrefixArmed(armed)
        }
```

3. Intercept keys at the TOP of the `installKeybinds()` monitor closure, BEFORE the existing `guard ... contains(.command)` line (~`:338`). The prefix chord (e.g. ctrl+b) does NOT use Command, so it would otherwise fall straight through to the terminal. Insert this block as the first statements inside the `NSEvent.addLocalMonitorForEvents` closure (after `guard let self else { return e }` — add that guard since the existing first line assumes `self`):

```swift
            guard let self else { return e }
            // ── Prefix mode (runs before the ⌘ keybinds) ──────────────────────
            if let prefix = self.prefix {
                let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
                let isEscape = (e.keyCode == 53)   // Escape
                if self.prefixState.armed {
                    // Resolve the NEXT key. Arrows → tokens; else the typed char.
                    let key = Self.prefixKeyToken(e)
                    if let action = self.prefixState.handle(key: key, isEscape: isEscape, table: self.prefixTable) {
                        self.dispatchPrefix(action)
                    }
                    return nil   // swallow the key whether it fired, cancelled, or was Escape
                }
                // Not yet armed: is THIS the prefix chord?
                if mods == prefix.mods, (e.charactersIgnoringModifiers ?? "").lowercased() == prefix.key {
                    self.prefixState.arm()
                    return nil
                }
            }
```

   Then DELETE the now-duplicated original first line of the closure:

```swift
            guard let self, e.modifierFlags.contains(.command) else { return e }
```

   and replace it (immediately after the prefix block) with the command-only guard that no longer re-binds `self`:

```swift
            guard e.modifierFlags.contains(.command) else { return e }
```

4. Add the key-token helper + the dispatch method as `AppDelegate` methods (e.g. right after `installKeybinds()` ~`:388`). `prefixKeyToken` maps arrow keycodes to the `"left"/"down"/"up"/"right"` tokens the keytable uses, else the lowercased character. `dispatchPrefix` routes each `PrefixAction` to the EXISTING action. Add:

```swift
    /// The keytable token for a pressed key: arrow keys → direction words, else
    /// the lowercased character (so % " , map through verbatim).
    private static func prefixKeyToken(_ e: NSEvent) -> String {
        switch e.keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: return (e.charactersIgnoringModifiers ?? "").lowercased()
        }
    }

    /// Run a resolved prefix action against the active window's workspace, using
    /// only methods that already exist. detach/kill/switcher are stubbed (beep)
    /// until Milestones 2–3 land their real behavior.
    private func dispatchPrefix(_ action: PrefixAction) {
        guard let ctx = active else { return }
        let ws = ctx.workspace
        switch action {
        case .splitVertical:   ws.activeTree.splitFocused(.vertical, cwd: ws.activeTree.focusedCwd)
        case .splitHorizontal: ws.activeTree.splitFocused(.horizontal, cwd: ws.activeTree.focusedCwd)
        case .focusLeft, .focusUp:    ws.activeTree.focusPrev()
        case .focusRight, .focusDown: ws.activeTree.focusNext()
        case .zoom:        ws.activeTree.zoomFocused()
        case .newSession:  ws.newSession(ws.activeP)
        case .nextSession: ws.nextSession()
        case .prevSession: ws.prevSession()
        case .rename:      promptRenameActiveProject()
        case .switcher, .detach, .kill:
            NSSound.beep()   // stub until M2 (switcher) / M3 (detach, kill)
        }
    }

    /// Prefix-`,` rename: rename the active session's PROJECT (the only rename the
    /// existing Workspace exposes — Workspace.renameProject). A real per-session
    /// name lands in Milestone 2; this reuses the existing action for now.
    private func promptRenameActiveProject() {
        guard let ws = active?.workspace else { return }
        let alert = NSAlert()
        alert.messageText = "Rename project"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            ws.renameProject(ws.activeP, field.stringValue)
        }
    }
```

   Note: `focusLeft/focusUp → focusPrev` and `focusRight/focusDown → focusNext` is the deliberate v1 mapping — `PaneTree` exposes ordered `focusNext()/focusPrev()` cycling, not spatial up/down/left/right. This is the same ponytail "ordered, not spatial" limitation already used for `⌘]`/`⌘[`. Directional spatial focus is out of scope for M1.

5. Run `swift build` and confirm it compiles.
   `git commit -m "M1: intercept prefix chord + dispatch to existing actions"`

6. **Hands-on verify (live UI — not headless).** Run the app: `swift run halo`. With the default `halo-prefix = ctrl+b`:
   - Press **Ctrl+B**. OBSERVE: the `PREFIX` pill appears at the right of the titlebar in the accent color. Take a screenshot (Cmd+Shift+4) and confirm the pill is accent-tinted, not a hardcoded gray.
   - Press **`%`**. OBSERVE: the focused pane splits vertically (side-by-side) AND the pill disappears.
   - Press **Ctrl+B** then **`"`**. OBSERVE: a horizontal split AND the pill disappears.
   - Press **Ctrl+B** then **`z`**. OBSERVE: the focused pane zooms (siblings hidden); Ctrl+B `z` again un-zooms.
   - Press **Ctrl+B** then **`c`**. OBSERVE: a new session appears in the sidebar's active project.
   - Press **Ctrl+B** then **`n`** / **`p`**. OBSERVE: the active session cycles next/prev.
   - Press **Ctrl+B** then **`h`/`l`** (or **←/→**) in a split. OBSERVE: focus moves between panes (the accent focus-ticks move).
   - Press **Ctrl+B** then **`,`**. OBSERVE: the rename dialog opens.
   - Press **Ctrl+B** then **`d`** (or **`x`**/**`s`**). OBSERVE: a system beep (stub) and the pill disappears — proves the keytable entry + dispatch path exist.
   - Press **Ctrl+B** then wait **2+ seconds** without pressing a key. OBSERVE: the pill disappears on its own (timeout cancel).
   - Press **Ctrl+B** then **Escape**. OBSERVE: the pill disappears immediately and nothing fires.
   - Confirm normal typing is unaffected: type a shell command and run it — the Ctrl+B interception only triggers on the exact chord.

7. **Hands-on verify (disable path).** Add `halo-prefix =` (empty) to the Halo/ghostty config, relaunch `swift run halo`, press **Ctrl+B**: OBSERVE the literal `^B` reaches the shell (no pill, prefix fully disabled). Remove the line / restore `ctrl+b` afterward.
   `git commit -m "M1: verify prefix mode hands-on"` (no code change — skip if `git diff` is empty).

## Milestone 2 — Named sessions + switcher (small)

Goal: a `PaneTree` gains a persisted `name: String?`; rename via sidebar
double-click (and via the prefix-`,` action M1 dispatches); a fuzzy-filter
switcher overlay (Cmd-K now, prefix-`s` from M1) lists every session across all
windows/projects, filters as you type, jumps on Enter, closes on Esc. The
overlay reuses the search-bar styling already in `TerminalPane.buildSearchBar`
(`Sources/Halo/TerminalPane.swift:180–212`). The list source is a single
function returning `[SessionRow]` so M3 can append detached daemon rows without
touching the overlay. Pure-logic self-check: the fuzzy ranker (subsequence
match + score ordering).

This milestone touches only existing GUI targets — no `HaloMux`/daemon yet. It
persists `name` into the per-session snapshot now (as `{cwd, paneID, name}`)
even though M3 is the one that *uses* `paneID` to reattach, so the on-disk
format is stable before the daemon lands.

---

### Task 2.1: Fuzzy ranker (pure logic + self-check)

**Files:** Create `Sources/Halo/Fuzzy.swift`. Modify `Sources/Halo/main.swift:8`
(add `fuzzySelfCheck()` to the selfcheck list). Test target: the `halo`
executable's `selfcheck` verb.

**Interfaces:**
- Consumes: nothing (pure Swift, Foundation only).
- Produces: `func fuzzyScore(_ needle: String, _ haystack: String) -> Int?`
  (nil = no subsequence match; higher = better) and
  `func fuzzyFilter<T>(_ items: [T], query: String, key: (T) -> String) -> [T]`
  (empty query → items unchanged; non-empty → only matches, sorted best-first,
  ties keep original order). Task 2.5 consumes `fuzzyFilter` to rank `SessionRow`s.

Steps:

1. [ ] Create `Sources/Halo/Fuzzy.swift` with the failing self-check FIRST (no
   impl yet), so the build fails on the missing `fuzzyScore`/`fuzzyFilter`:

   ```swift
   import Foundation

   func fuzzySelfCheck() {
       // ── subsequence matching ────────────────────────────────────────────
       assert(fuzzyScore("", "anything") != nil, "empty needle always matches")
       assert(fuzzyScore("abc", "aXbXc") != nil, "in-order subsequence matches")
       assert(fuzzyScore("abc", "acb") == nil, "out-of-order is not a match")
       assert(fuzzyScore("xyz", "ab") == nil, "needle longer than haystack → no match")
       assert(fuzzyScore("HALO", "halo") != nil, "matching is case-insensitive")

       // ── score ordering: contiguous + start-anchored beat scattered ───────
       let contiguous = fuzzyScore("hal", "halo")!         // prefix, contiguous
       let scattered  = fuzzyScore("hal", "h-a-l-x")!      // gapped
       assert(contiguous > scattered, "contiguous prefix outscores scattered")

       let anchored = fuzzyScore("api", "api-server")!     // matches at index 0
       let mid      = fuzzyScore("api", "my-api")!         // matches mid-string
       assert(anchored > mid, "start-anchored outscores mid-string")

       // ── fuzzyFilter: empty query is identity, preserving order ───────────
       let all = ["alpha", "beta", "gamma"]
       assert(fuzzyFilter(all, query: "", key: { $0 }) == all, "empty query = identity")

       // ── fuzzyFilter: drops non-matches, ranks matches best-first ─────────
       let names = ["server", "api-server", "client", "svr"]
       let ranked = fuzzyFilter(names, query: "ser", key: { $0 })
       assert(!ranked.contains("client"), "non-matches are dropped")
       assert(!ranked.contains("svr"), "'ser' is not a subsequence of 'svr'")
       assert(ranked.first == "server", "best contiguous/anchored match ranks first")

       // ── stable ties: equal scores keep original input order ──────────────
       let tie = fuzzyFilter(["xa", "ya", "za"], query: "a", key: { $0 })
       assert(tie == ["xa", "ya", "za"], "equal-score matches keep input order")

       print("fuzzySelfCheck OK")
   }
   ```

2. [ ] Wire the new check into `Sources/Halo/main.swift:8`. Change the line:

   ```swift
       _ = ghosttyConfigSelfCheck(); controlSelfCheck(); gitSelfCheck(); portsSelfCheck(); workspaceSelfCheck(); worktreeSelfCheck(); browserSelfCheck()
   ```
   to append `fuzzySelfCheck()`:
   ```swift
       _ = ghosttyConfigSelfCheck(); controlSelfCheck(); gitSelfCheck(); portsSelfCheck(); workspaceSelfCheck(); worktreeSelfCheck(); browserSelfCheck(); fuzzySelfCheck()
   ```

3. [ ] Run `swift run halo selfcheck` and see it FAIL to compile (`fuzzyScore` /
   `fuzzyFilter` undefined). This confirms the test is actually exercised.

4. [ ] Add the minimal real implementation to `Sources/Halo/Fuzzy.swift`
   (above the self-check). Scoring is intentionally tiny: greedy left-to-right
   subsequence walk, rewarding contiguous runs and an early first match.

   ```swift
   /// Fuzzy subsequence score. Returns nil when `needle` is not an in-order
   /// (case-insensitive) subsequence of `haystack`; otherwise a score where
   /// higher is better. Contiguous runs and an early first match score higher.
   /// Pure logic — no AppKit, no I/O.
   func fuzzyScore(_ needle: String, _ haystack: String) -> Int? {
       if needle.isEmpty { return 0 }
       let n = Array(needle.lowercased())
       let h = Array(haystack.lowercased())
       var ni = 0
       var score = 0
       var firstMatch = -1
       var prevMatch = -2   // so an initial run never counts as "contiguous"
       for (hi, c) in h.enumerated() {
           guard ni < n.count, c == n[ni] else { continue }
           if firstMatch < 0 { firstMatch = hi }
           if hi == prevMatch + 1 { score += 8 }   // contiguous with previous match
           else { score += 1 }                     // a match, but with a gap
           prevMatch = hi
           ni += 1
           if ni == n.count { break }
       }
       guard ni == n.count else { return nil }      // all needle chars consumed?
       // Reward matching near the start (anchored) and penalize trailing junk.
       score += max(0, 10 - firstMatch)             // earlier first match → bigger bonus
       score -= max(0, h.count - prevMatch - 1) / 4 // long tail after last match → mild penalty
       return score
   }

   /// Filter + rank `items` by fuzzy-matching `query` against `key(item)`.
   /// Empty query → items unchanged. Non-empty → only matches, sorted by score
   /// descending; ties preserve the original input order (stable).
   func fuzzyFilter<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
       let q = query.trimmingCharacters(in: .whitespaces)
       if q.isEmpty { return items }
       let scored = items.enumerated().compactMap { (i, item) -> (Int, Int, T)? in
           guard let s = fuzzyScore(q, key(item)) else { return nil }
           return (s, i, item)
       }
       // Sort by score desc, then original index asc (stable tie-break).
       return scored.sorted { a, b in a.0 != b.0 ? a.0 > b.0 : a.1 < b.1 }.map { $0.2 }
   }
   ```

5. [ ] Run `swift run halo selfcheck` and see `fuzzySelfCheck OK` followed by
   `all self-checks ok`. If a score assertion fails, adjust the constants in
   `fuzzyScore` (the bonuses are tuned, not load-bearing across callers).

6. [ ] `git commit -am "M2: fuzzy ranker (subsequence + score) with self-check"`.

---

### Task 2.2: `PaneTree.name` (in-memory)

**Files:** Modify `Sources/Halo/PaneTree.swift` (add stored property near the
other public vars around `:107–110` and a setter; extend `paneTreeSelfCheck()`
at `:380`). Modify `Sources/Halo/Tabs.swift` `snapshot()` (`:248–272`) to prefer
the session name as the sidebar label. Test target: `halo selfcheck`.

**Interfaces:**
- Consumes: nothing new.
- Produces: `var name: String?` on `PaneTree` and `func setName(_:)`. Task 2.3
  (persistence) and Task 2.4 (rename UI) and Task 2.5 (switcher list) read it.

Steps:

1. [ ] Extend `paneTreeSelfCheck()` in `Sources/Halo/PaneTree.swift:380` to
   assert the new property exists and round-trips, BEFORE adding it (will fail
   to compile). Append inside the function, just before its `print(...)`:

   ```swift
       assert(t.name == nil, "new PaneTree has no name")
       t.setName("build")
       assert(t.name == "build", "setName stores the name")
       t.setName("  ")
       assert(t.name == nil, "blank name clears back to nil")
   ```

2. [ ] Run `swift run halo selfcheck`; see it FAIL to compile (`name` /
   `setName` undefined).

3. [ ] Add the property + setter to `PaneTree`. Place the stored property next
   to `onFocusChange`/`onAttention` (after `Sources/Halo/PaneTree.swift:109`):

   ```swift
       /// User-assigned session name (nil ⇒ derive a label from the focused pane).
       /// Persisted in Tabs.swift's per-session snapshot.
       private(set) var name: String?

       /// Set (or clear, when blank) this session's name. Fires onFocusChange so
       /// the sidebar + any open switcher re-render.
       func setName(_ s: String?) {
           let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines)
           name = (trimmed?.isEmpty ?? true) ? nil : trimmed
           onFocusChange?()
       }
   ```

4. [ ] Run `swift run halo selfcheck`; see `paneTreeSelfCheck OK` and
   `all self-checks ok`.

5. [ ] Make the sidebar honor the name. In `Sources/Halo/Tabs.swift`
   `snapshot()` (`:251–262`), the per-session label is currently derived from
   `tree.focusedLabel` / pane count / worktree branch. Make an explicit user
   name win over the derived base. Replace the `let base = tree.focusedLabel`
   line (`:253`) with:

   ```swift
                   let base = tree.name ?? tree.focusedLabel
   ```

   Leave the rest (`· N panes` suffix, `si + 1.` prefix, worktree `⎇` override)
   unchanged — a worktree branch still wins, which is the existing behavior.

6. [ ] `swift build` to confirm Tabs.swift compiles. (The label change is
   visual — verified hands-on in Task 2.4.)

7. [ ] `git commit -am "M2: PaneTree.name + sidebar prefers session name"`.

---

### Task 2.3: Persist `{cwd, paneID, name}` per session

**Files:** Modify `Sources/Halo/PaneTree.swift` (add `let paneID: String` and a
restore initializer arg). Modify `Sources/Halo/Tabs.swift` `serialize()`
(`:391–401`), `hydrate(from:)` (`:406–446`), and the private `makeTree`
(`:486–497`). Extend `workspaceSelfCheck()` in `Sources/Halo/Tabs.swift:533`.
Test target: `halo selfcheck`.

**Interfaces:**
- Consumes: `PaneTree.name` (Task 2.2).
- Produces: `PaneTree.paneID: String` (a UUID string, default `UUID().uuidString`),
  and the on-disk per-session shape `{"cwd": String, "paneID": String, "name": String?}`
  replacing the old bare cwd string. M3's reattach reads `paneID`.

> ponytail / compat note: `serialize()` currently emits `[String]` (cwds) per
> project. We move to `[[String: Any]]`. `hydrate(from:)` must accept BOTH the
> new dict shape and the legacy `[String]` shape so a `windows.json` written by
> the pre-M2 build still restores (cwd-only; fresh paneID; no name).

Steps:

1. [ ] Add `paneID` to `PaneTree`. In `Sources/Halo/PaneTree.swift`, add a
   stored constant next to `name` (added in Task 2.2):

   ```swift
       /// Stable per-session id (UUID string). Persisted; M3 reattaches by it.
       let paneID: String
   ```

2. [ ] Thread it through the initializer. Change the `init` signature at
   `Sources/Halo/PaneTree.swift:111` from:

   ```swift
       init(theme: Theme, cwd: String? = nil) {
           self.theme = theme
   ```
   to:
   ```swift
       init(theme: Theme, cwd: String? = nil, paneID: String = UUID().uuidString, name: String? = nil) {
           self.theme = theme
           self.paneID = paneID
           self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).flatMap { $0.isEmpty ? nil : $0 }
   ```
   (the rest of `init` is unchanged). The `paneTreeSelfCheck()` call
   `PaneTree(theme: Theme())` still compiles via the defaults.

3. [ ] Teach `Workspace.makeTree` to forward an optional id/name. In
   `Sources/Halo/Tabs.swift:486`, change:

   ```swift
       private func makeTree(cwd: String?) -> PaneTree {
           let tree = PaneTree(theme: theme, cwd: cwd)
   ```
   to:
   ```swift
       private func makeTree(cwd: String?, paneID: String = UUID().uuidString, name: String? = nil) -> PaneTree {
           let tree = PaneTree(theme: theme, cwd: cwd, paneID: paneID, name: name)
   ```
   (every existing `makeTree(cwd:)` caller keeps working via the defaults.)

4. [ ] Extend `workspaceSelfCheck()` in `Sources/Halo/Tabs.swift:533` to assert
   the persisted per-session dict shape round-trips through pure dictionary
   logic (mirrors what `serialize`/`hydrate` do, without a live Workspace).
   Add, just before its closing `print("workspaceSelfCheck OK")` (`:607`):

   ```swift
       // ── Per-session snapshot is {cwd, paneID, name}; hydrate accepts dict + legacy ──
       func snap(cwd: String, paneID: String, name: String?) -> [String: Any] {
           var d: [String: Any] = ["cwd": cwd, "paneID": paneID]
           if let name { d["name"] = name }
           return d
       }
       // New dict shape: read back all three fields.
       let s = snap(cwd: "/tmp", paneID: "PID-1", name: "build")
       assert(s["cwd"] as? String == "/tmp", "snapshot cwd round-trips")
       assert(s["paneID"] as? String == "PID-1", "snapshot paneID round-trips")
       assert(s["name"] as? String == "build", "snapshot name round-trips")
       // nil name is simply absent (not stored as NSNull).
       let s2 = snap(cwd: "/tmp", paneID: "PID-2", name: nil)
       assert(s2["name"] == nil, "nil name is omitted from the snapshot")

       // hydrate's reader: a session entry may be the new dict OR a legacy bare cwd string.
       func readSession(_ entry: Any) -> (cwd: String, paneID: String?, name: String?) {
           if let d = entry as? [String: Any] {
               return (d["cwd"] as? String ?? home, d["paneID"] as? String, d["name"] as? String)
           }
           if let cwd = entry as? String { return (cwd, nil, nil) }   // legacy windows.json
           return (home, nil, nil)
       }
       let r1 = readSession(s)
       assert(r1.cwd == "/tmp" && r1.paneID == "PID-1" && r1.name == "build", "reads new dict entry")
       let r2 = readSession("/legacy/path")   // pre-M2 format
       assert(r2.cwd == "/legacy/path" && r2.paneID == nil && r2.name == nil, "reads legacy string entry")
   ```

5. [ ] Run `swift run halo selfcheck`; see it FAIL (the new asserts run but
   `serialize`/`hydrate` don't yet emit/read the dict shape — actually this
   self-check is self-contained, so it passes; the real wiring failure surfaces
   at runtime). Confirm `workspaceSelfCheck OK` prints; if it does not, fix the
   reader logic to match.

6. [ ] Now wire the real `serialize()`. In `Sources/Halo/Tabs.swift:395`,
   replace the sessions line inside the `projs.map`:

   ```swift
                   "sessions": p.sessions.map { $0.focusedCwd ?? p.path },
   ```
   with a dict per session:
   ```swift
                   "sessions": p.sessions.map { (t: PaneTree) -> [String: Any] in
                       var sd: [String: Any] = ["cwd": t.focusedCwd ?? p.path, "paneID": t.paneID]
                       if let nm = t.name { sd["name"] = nm }
                       return sd
                   },
   ```

7. [ ] Wire the real `hydrate(from:)`. In `Sources/Halo/Tabs.swift:427`, replace
   the inner restore loop:

   ```swift
               for cwd in (pd["sessions"] as? [String] ?? []) {
                   proj.sessions.append(makeTree(cwd: usableDir(cwd, fallback: path)))
               }
   ```
   with a loop that handles both the new dict shape and the legacy string shape:
   ```swift
               for entry in (pd["sessions"] as? [Any] ?? []) {
                   let cwd: String, pid: String, nm: String?
                   if let d = entry as? [String: Any] {
                       cwd = d["cwd"] as? String ?? path
                       pid = d["paneID"] as? String ?? UUID().uuidString
                       nm  = d["name"] as? String
                   } else if let s = entry as? String {   // legacy windows.json (pre-M2)
                       cwd = s; pid = UUID().uuidString; nm = nil
                   } else { continue }
                   proj.sessions.append(makeTree(cwd: usableDir(cwd, fallback: path),
                                                 paneID: pid, name: nm))
               }
   ```

8. [ ] Run `swift run halo selfcheck` → `all self-checks ok`, then `swift build`.

9. [ ] Hands-on persistence check (round-trip through `windows.json`):
   - `swift run halo` — wait for a window. Right-click the home project's
     session row → (rename comes in Task 2.4; for now just confirm the app runs
     and a session exists).
   - Quit Halo (⌘Q → Quit). Then:
     `python3 -c "import json,os; p=os.path.expanduser('~/Library/Application Support/halo/windows.json'); d=json.load(open(p)); print(json.dumps(d[0]['projects'][0]['sessions'], indent=2))"`
   - Observe each session entry is now an object with `cwd` and `paneID`
     (and `name` once Task 2.4 names one) — NOT a bare string.

10. [ ] `git commit -am "M2: persist {cwd, paneID, name} per session (legacy-compatible)"`.

---

### Task 2.4: Rename via sidebar double-click

**Files:** Modify `Sources/Halo/Chrome.swift`: add an `onRenameSession` closure
(alongside the other `on*` closures `:29–37` + init `:52–75`), a double-click
handler on session rows in `makeSessionRow` (`:367–451`), a `promptRenameSession`
(mirroring `promptRename` at `:525–537`), and double-click support on
`TaggedRow` (`:767–800`). Modify `Sources/Halo/WindowContext.swift` to bind the
new closure (`:41–51`). Add `Workspace.renameSession` to `Sources/Halo/Tabs.swift`
(near `renameProject` at `:135–142`). Test target: hands-on (UI).

**Interfaces:**
- Consumes: `PaneTree.setName` (Task 2.2), `TaggedRow.tag1/tag2` (existing).
- Produces: `Workspace.renameSession(_:_:_:)`, `HaloWindowController.onRenameSession`.

Steps:

1. [ ] Add `renameSession` to `Workspace` in `Sources/Halo/Tabs.swift`, right
   after `renameProject` (`:142`):

   ```swift
       func renameSession(_ p: Int, _ s: Int, _ name: String?) {
           guard projs.indices.contains(p), projs[p].sessions.indices.contains(s) else { return }
           projs[p].sessions[s].setName(name)   // setName fires onFocusChange → save + render
           handleChange()
       }
   ```

2. [ ] Give `TaggedRow` a double-click hook. In `Sources/Halo/Chrome.swift`,
   inside `final class TaggedRow` (`:767`), add a stored closure and override
   `mouseDown` to detect a double click (the existing `mouseDown` is at `:780`).
   Replace:

   ```swift
       override func mouseDown(with event: NSEvent) { onClick?() }
   ```
   with:
   ```swift
       var onDoubleClick: (() -> Void)?
       override func mouseDown(with event: NSEvent) {
           if event.clickCount == 2, let d = onDoubleClick { d(); return }
           onClick?()
       }
   ```

3. [ ] Add the `onRenameSession` closure to `HaloWindowController`. Add a stored
   `let` next to the other closures (after `:37`):

   ```swift
       private let onRenameSession:  (Int, Int, String?) -> Void
   ```
   Add the matching init parameter (after the `onSelectSession` group, around
   `:53`):
   ```swift
            onRenameSession: @escaping (Int, Int, String?) -> Void = { _, _, _ in },
   ```
   And assign it in the init body (after `self.onSelectSession = ...`, `:67`):
   ```swift
           self.onRenameSession = onRenameSession
   ```

4. [ ] Wire the double-click in `makeSessionRow`. In
   `Sources/Halo/Chrome.swift`, just after the existing
   `row.onClick = { [weak self] in self?.onSelectSession(pi, si) }` (`:449`),
   add:

   ```swift
           row.onDoubleClick = { [weak self] in
               self?.promptRenameSession(pi, si, current: sess.label)
           }
   ```

5. [ ] Add `promptRenameSession`, mirroring `promptRename` (`:525`). Place it
   right after `promptRename`'s closing brace (`:537`):

   ```swift
       /// Native rename prompt for a session (double-click a session row).
       private func promptRenameSession(_ pi: Int, _ si: Int, current: String) {
           let alert = NSAlert()
           alert.messageText = "Rename session"
           alert.informativeText = "Leave blank to clear the name and use the folder name."
           alert.addButton(withTitle: "Rename")
           alert.addButton(withTitle: "Cancel")
           let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
           field.stringValue = current
           alert.accessoryView = field
           alert.window.initialFirstResponder = field
           if alert.runModal() == .alertFirstButtonReturn {
               onRenameSession(pi, si, field.stringValue)
           }
       }
   ```

6. [ ] Bind the closure in `WindowContext`. In
   `Sources/Halo/WindowContext.swift`, add to the `HaloWindowController(...)`
   call (after the `onSelectSession:` line `:43`):

   ```swift
               onRenameSession:   { [weak ws] p, s, name in ws?.renameSession(p, s, name) },
   ```

7. [ ] `swift build` to confirm the closure plumbing compiles end to end.

8. [ ] Hands-on rename check:
   - `swift run halo`. In the sidebar, **double-click** the home session row.
   - The "Rename session" alert appears; type `build`, click Rename.
   - Observe the sidebar row label change to `build` (or `1. build` if the
     project has multiple sessions). Take a screenshot showing the renamed row.
   - Double-click again, clear the field, click Rename → label reverts to the
     folder-derived name (e.g. `nuh`).
   - Quit and re-run `swift run halo`; the renamed session restores with its
     name (verifies Task 2.3 persistence of `name`). Re-inspect
     `windows.json` (Task 2.3 step 9) and confirm `"name": "build"` is present.

9. [ ] `git commit -am "M2: rename a session via sidebar double-click"`.

---

### Task 2.5: SessionRow model + switcher overlay (Cmd-K)

**Files:** Create `Sources/Halo/Switcher.swift` (the `SessionRow` model + a
`SwitcherOverlay` NSView reusing the search-bar styling). Modify
`Sources/Halo/main.swift` `AppDelegate`: add a `sessionRows()` list-source
function, a `showSwitcher()` entry point, and a Cmd-K keybind in
`installKeybinds()` (`:336–388`). Test target: hands-on (UI) + the existing
`fuzzySelfCheck` already covers the ranking.

**Interfaces:**
- Consumes: `fuzzyFilter` (Task 2.1), `PaneTree.name`/`focusedLabel`/`focusedCwd`
  (Tasks 2.2 + existing), `Workspace.selectSession` (existing), `Theme.accent`
  / `Theme.background` (existing).
- Produces:
  - `struct SessionRow { let title; let subtitle; let detached: Bool; let activate: () -> Void }`
    — **the clean injection point.** M3 appends detached daemon rows (with
    `detached: true` and an `activate` that reattaches) to the list returned by
    `AppDelegate.sessionRows()`; the overlay treats all rows uniformly.
  - `AppDelegate.showSwitcher()` — opened by Cmd-K now and by M1's prefix-`s`.

Steps:

1. [ ] Create `Sources/Halo/Switcher.swift` with the `SessionRow` model and an
   overlay view. The overlay borrows the exact chrome tokens from
   `TerminalPane.buildSearchBar` (`Sources/Halo/TerminalPane.swift:200–204`):
   `NSColor(white: 0.13, alpha: 0.97)` panel, corner radius 8, border
   `NSColor(white: 1, alpha: 0.12)`. The selection highlight uses `theme.accent`
   (never a hardcoded color), per the global constraint.

   ```swift
   import AppKit

   /// One row in the session switcher. The injection point for M3: detached
   /// daemon sessions are appended as rows with `detached: true` and an
   /// `activate` closure that reattaches — the overlay treats every row the same.
   struct SessionRow {
       let title: String        // session name or derived label
       let subtitle: String     // window/project context + cwd
       let detached: Bool       // M3: true ⇒ a daemon session with no live pane
       let activate: () -> Void // jump to (M3: attach) this session
   }

   /// Fuzzy-filter switcher overlay: a centered panel listing every session
   /// across all windows/projects. Type to filter, ↑/↓ to move, Enter to jump,
   /// Esc to close. Reuses TerminalPane's search-bar visual tokens.
   @MainActor
   final class SwitcherOverlay: NSView, NSTextFieldDelegate {
       private let theme: Theme
       private let allRows: [SessionRow]
       private var shown: [SessionRow] = []
       private var selected = 0

       private let input = NSTextField()
       private let listStack = NSStackView()
       private let onClose: () -> Void

       init(theme: Theme, rows: [SessionRow], onClose: @escaping () -> Void) {
           self.theme = theme
           self.allRows = rows
           self.onClose = onClose
           super.init(frame: .zero)
           build()
           apply(query: "")
       }
       required init?(coder: NSCoder) { fatalError() }

       // Dim scrim over the whole window; click-through-to-dismiss.
       override func draw(_ dirtyRect: NSRect) {
           NSColor.black.withAlphaComponent(0.35).setFill()
           dirtyRect.fill()
       }
       override func mouseDown(with event: NSEvent) {
           // Click outside the panel closes; clicks on the panel are caught by it.
           onClose()
       }

       private func build() {
           wantsLayer = true
           autoresizingMask = [.width, .height]

           let panel = NSView()
           panel.translatesAutoresizingMaskIntoConstraints = false
           panel.wantsLayer = true
           panel.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.97).cgColor
           panel.layer?.cornerRadius = 8
           panel.layer?.borderWidth = 1
           panel.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
           addSubview(panel)

           input.placeholderString = "Jump to session"
           input.delegate = self
           input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
           input.focusRingType = .none
           input.isBezeled = false
           input.drawsBackground = false
           input.textColor = NSColor(white: 0.93, alpha: 1)
           input.translatesAutoresizingMaskIntoConstraints = false

           let hair = NSView()
           hair.translatesAutoresizingMaskIntoConstraints = false
           hair.wantsLayer = true
           hair.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor

           listStack.orientation = .vertical
           listStack.alignment = .leading
           listStack.spacing = 1
           listStack.translatesAutoresizingMaskIntoConstraints = false

           panel.addSubview(input)
           panel.addSubview(hair)
           panel.addSubview(listStack)

           NSLayoutConstraint.activate([
               panel.centerXAnchor.constraint(equalTo: centerXAnchor),
               panel.topAnchor.constraint(equalTo: topAnchor, constant: 120),
               panel.widthAnchor.constraint(equalToConstant: 460),

               input.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
               input.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
               input.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),

               hair.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 12),
               hair.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
               hair.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
               hair.heightAnchor.constraint(equalToConstant: 1),

               listStack.topAnchor.constraint(equalTo: hair.bottomAnchor, constant: 8),
               listStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
               listStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
               listStack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
           ])
       }

       /// Re-filter against the query and rebuild the visible rows.
       private func apply(query: String) {
           shown = fuzzyFilter(allRows, query: query, key: { $0.title + " " + $0.subtitle })
           selected = 0
           rebuildList()
       }

       private func rebuildList() {
           listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
           if shown.isEmpty {
               let empty = NSTextField(labelWithString: "no sessions")
               empty.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
               empty.textColor = NSColor(white: 0.46, alpha: 1)
               listStack.addArrangedSubview(rowView(empty, highlighted: false))
               return
           }
           for (i, r) in shown.enumerated() {
               let title = NSTextField(labelWithString: r.detached ? "○ " + r.title : r.title)
               title.font = .monospacedSystemFont(ofSize: 13, weight: i == selected ? .medium : .regular)
               title.textColor = i == selected ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.78, alpha: 1)
               let sub = NSTextField(labelWithString: r.subtitle)
               sub.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
               sub.textColor = NSColor(white: 0.5, alpha: 1)
               let line = NSStackView(views: [title, sub])
               line.orientation = .horizontal
               line.spacing = 8
               listStack.addArrangedSubview(rowView(line, highlighted: i == selected))
           }
       }

       /// Wrap a row's content with a rounded highlight using theme.accent.
       private func rowView(_ content: NSView, highlighted: Bool) -> NSView {
           let wrap = NSView()
           wrap.translatesAutoresizingMaskIntoConstraints = false
           wrap.wantsLayer = true
           wrap.layer?.cornerRadius = 5
           wrap.layer?.backgroundColor = highlighted
               ? theme.accent.withAlphaComponent(0.16).cgColor
               : NSColor.clear.cgColor
           content.translatesAutoresizingMaskIntoConstraints = false
           wrap.addSubview(content)
           NSLayoutConstraint.activate([
               content.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
               content.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -10),
               content.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 5),
               content.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -5),
               wrap.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -16),
           ])
           return wrap
       }

       /// Make the input first responder once we're in a window.
       override func viewDidMoveToWindow() {
           super.viewDidMoveToWindow()
           window?.makeFirstResponder(input)
       }

       // Live filter on each keystroke.
       func controlTextDidChange(_ obj: Notification) { apply(query: input.stringValue) }

       // Enter = jump; Esc = close; ↑/↓ move selection.
       func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
           switch sel {
           case #selector(insertNewline(_:)):
               if shown.indices.contains(selected) { let r = shown[selected]; onClose(); r.activate() }
               return true
           case #selector(cancelOperation(_:)):
               onClose(); return true
           case #selector(moveDown(_:)):
               if !shown.isEmpty { selected = (selected + 1) % shown.count; rebuildList() }
               return true
           case #selector(moveUp(_:)):
               if !shown.isEmpty { selected = (selected - 1 + shown.count) % shown.count; rebuildList() }
               return true
           default:
               return false
           }
       }
   }
   ```

2. [ ] `swift build`; confirm `Switcher.swift` compiles (it depends only on
   `Theme`, `fuzzyFilter`, and AppKit — all already present).

3. [ ] Add the list source to `AppDelegate` in `Sources/Halo/main.swift`. Place
   these two methods inside `AppDelegate` (e.g. right after `newWindowMenu()` at
   `:59`). `sessionRows()` is the M3 injection point — M3 appends detached rows
   here:

   ```swift
       /// Every live session across all windows/projects, as switcher rows.
       /// M3 extends this by appending detached daemon sessions (detached: true).
       func sessionRows() -> [SessionRow] {
           var rows: [SessionRow] = []
           for (wi, ctx) in windows.enumerated() {
               let ws = ctx.workspace
               for (pi, proj) in ws.projs.enumerated() {
                   for (si, tree) in proj.sessions.enumerated() {
                       let title = tree.name ?? tree.focusedLabel
                       let cwd = tree.focusedCwd.map { abbreviateHome($0) } ?? proj.name
                       let win = windows.count > 1 ? "win \(wi + 1) · " : ""
                       rows.append(SessionRow(
                           title: title,
                           subtitle: "\(win)\(proj.name) · \(cwd)",
                           detached: false,
                           activate: { [weak ctx] in
                               ctx?.controller.window?.makeKeyAndOrderFront(nil)
                               ctx?.workspace.selectSession(pi, si)
                               NSApp.activate(ignoringOtherApps: true)
                           }))
                   }
               }
           }
           return rows
       }

       /// Open the fuzzy session switcher over the key window (Cmd-K / prefix-s).
       func showSwitcher() {
           guard let ctx = active, let host = ctx.controller.window?.contentView else { return }
           if host.subviews.contains(where: { $0 is SwitcherOverlay }) { return }   // already open
           let overlay = SwitcherOverlay(theme: theme, rows: sessionRows()) { [weak host] in
               host?.subviews.compactMap { $0 as? SwitcherOverlay }.forEach { $0.removeFromSuperview() }
           }
           overlay.frame = host.bounds
           host.addSubview(overlay)
           ctx.controller.window?.makeFirstResponder(overlay)
       }

       @objc func showSwitcherMenu() { showSwitcher() }
   ```

4. [ ] Add the Cmd-K keybind. In `installKeybinds()` (`Sources/Halo/main.swift`),
   inside the `switch e.charactersIgnoringModifiers {` block, add a case
   alongside the others (e.g. after the `case "b":` sidebar toggle at `:364`):

   ```swift
               // ⌘K: open the session switcher (also reachable via M1's prefix-s)
               case "k" where !shift:  self.showSwitcher(); return nil
   ```

5. [ ] `swift build` → clean.

6. [ ] Hands-on switcher check:
   - `swift run halo`. Make a few sessions: ⌘T twice; double-click one and
     rename it `build` (Task 2.4). Optionally ⌘N for a second window with its
     own session.
   - Press **⌘K**. The overlay appears centered with a "Jump to session" field
     and a list of every session across all windows. Screenshot it.
   - Type `bui`. The list filters down to the `build` row (fuzzy). Screenshot.
   - Press ↓ then ↑ to confirm the highlight (theme.accent tint) moves.
   - Press **Enter**: the overlay closes and focus jumps to the selected
     session (the right window comes forward if it was a ⌘N window). Confirm the
     active session in the sidebar changed.
   - Press ⌘K again, then **Esc**: the overlay closes with no change.

7. [ ] `git commit -am "M2: SessionRow + fuzzy switcher overlay (Cmd-K)"`.

---

### Task 2.6: Switcher menu item + prefix-`s` / prefix-`,` injection points

**Files:** Modify `Sources/Halo/Menu.swift` (add a "Switch Session… ⌘K" item
pointing at `showSwitcherMenu`). Confirm M1's prefix dispatch can reach the same
entry points. Test target: hands-on (UI).

**Interfaces:**
- Consumes: `AppDelegate.showSwitcherMenu()` (Task 2.5),
  `Workspace.renameSession` (Task 2.4).
- Produces: a menu item; documented entry points for M1 (`showSwitcher()` for
  prefix-`s`; `active?.workspace.renameSession(activeP, activeS, name)` for
  prefix-`,`). No new symbols M3 depends on.

Steps:

1. [ ] Open `Sources/Halo/Menu.swift` and find where View/Window menu items are
   built (the menu is constructed in `makeMainMenu(target:)`, referenced from
   `Sources/Halo/main.swift:110`). Add a switcher item to the most appropriate
   existing submenu (the one holding session/pane navigation), using the same
   target/selector style already in that file:

   ```swift
       // Session switcher (fuzzy jump across all windows). Mirrors ⌘K keybind.
       <submenu>.addItem(withTitle: "Switch Session…", action: #selector(AppDelegate.showSwitcherMenu), keyEquivalent: "k")
   ```
   (Match the surrounding code's exact pattern — `NSMenuItem` construction vs.
   `addItem(withTitle:action:keyEquivalent:)` — whichever `Menu.swift` already
   uses. Set the item's `keyEquivalentModifierMask = .command` if the file sets
   masks explicitly elsewhere.)

2. [ ] `swift build` → clean.

3. [ ] Document M1's two injection points with a one-line comment so the prefix
   keytable (Milestone 1) wires to the SAME code, not a parallel path. Add above
   `showSwitcher()` in `Sources/Halo/main.swift` (if not already present from
   Task 2.5):

   ```swift
       // M1 prefix keytable entry points:
       //   prefix-s → showSwitcher()
       //   prefix-, → active?.workspace.renameSession(ws.activeP, ws.activeS, <prompt>)
   ```

4. [ ] Hands-on menu check:
   - `swift run halo`. Open the menu bar; find "Switch Session…" with the ⌘K
     shortcut shown. Click it → the same overlay from Task 2.5 opens.
   - Confirm ⌘K and the menu item open the identical overlay (only one opens at
     a time — the guard in `showSwitcher()` prevents a double).

5. [ ] `git commit -am "M2: switcher menu item + documented prefix-s/, entry points"`.

## Milestone 3 — `halod` + `halo-attach` + libvterm (the core)

This is the big one. It adds two executables (`halod`, `halo-attach`), one C target (`CVterm`, vendored libvterm), and one pure-Swift library (`HaloMux`) shared by `halo`, `halod`, `halo-attach`. It wires the GUI's panes through `halo-attach` so shells survive Halo quitting, reattach is clean, scrollback survives (with disk spill), and images replay across detach. Detach UX (close = detach, explicit kill) and CLI verbs (`halo sessions`, `halo kill`) land here too.

Pure-logic self-checks shipped this milestone (all wired into `Sources/Halo/main.swift:8`, since `halo` depends on `HaloMux` and the ring/image-cache logic lives in `HaloMux` so it is reachable from the `halo` target):
- `muxProtocolSelfCheck()` — frame encode/decode round-trip + partial-buffer `nil`.
- `muxPathsSelfCheck()` — path construction + dir-mode contract.
- `scrollbackRingSelfCheck()` — ring eviction + disk-spill boundary.
- `imageCacheSelfCheck()` — image-placement replay ordering.

The forkpty/libvterm/select loop, the relay, and all GUI behavior are verified hands-on (explicit commands + observations), never blind review.

---

### Task 3.1: `Package.swift` — add `HaloMux`, `CVterm`, `halod`, `halo-attach` targets
**Files:** Modify `Package.swift` (the single `targets:` array at `:7–31`). Create `Sources/CVterm/include/cvterm.h`, `Sources/CVterm/include/module.modulemap`, and vendor sources under `Sources/CVterm/vendor/`. Create empty entrypoints `Sources/HaloMux/Placeholder.swift`, `Sources/halod/main.swift`, `Sources/halo-attach/main.swift` so the targets compile before later tasks fill them.
**Interfaces:**
- Consumes: nothing (first task).
- Produces: target names `HaloMux`, `CVterm`, `halod`, `halo-attach` that every later task in this milestone depends on; `halo` now depends on `HaloMux`.

1. - [ ] Fetch the vendored libvterm MIT sources into the tree (one-time, from the canonical libvterm release; do NOT add a SwiftPM remote dependency — these are committed):
  ```
  mkdir -p Sources/CVterm/vendor Sources/CVterm/include
  curl -fsSL https://launchpad.net/libvterm/trunk/v0.3.3/+download/libvterm-0.3.3.tar.gz -o /tmp/libvterm.tgz
  tar -xzf /tmp/libvterm.tgz -C /tmp
  cp /tmp/libvterm-0.3.3/src/*.c       Sources/CVterm/vendor/
  cp /tmp/libvterm-0.3.3/src/*.h       Sources/CVterm/vendor/
  cp -R /tmp/libvterm-0.3.3/include/vterm.h /tmp/libvterm-0.3.3/include/vterm_keycodes.h Sources/CVterm/include/
  cp /tmp/libvterm-0.3.3/LICENSE       Sources/CVterm/vendor/LICENSE
  # libvterm generates two tables at build time from a perl script; the release
  # ships the generated headers under src/ — confirm they came across:
  ls Sources/CVterm/vendor/encoding/ 2>/dev/null || cp -R /tmp/libvterm-0.3.3/src/encoding Sources/CVterm/vendor/encoding
  ```
  Then verify the .c files and `vterm.h` exist: `ls Sources/CVterm/vendor/*.c Sources/CVterm/include/vterm.h`.

2. - [ ] Create the umbrella header `Sources/CVterm/include/cvterm.h` (re-exports the public libvterm API so Swift sees one module):
  ```c
  #ifndef CVTERM_H
  #define CVTERM_H
  #include "vterm.h"
  #include "vterm_keycodes.h"
  #endif
  ```

3. - [ ] Create the modulemap `Sources/CVterm/include/module.modulemap`:
  ```
  module CVterm {
      umbrella header "cvterm.h"
      export *
  }
  ```

4. - [ ] Create stub entrypoints so the new targets build before later tasks fill them:
  - `Sources/HaloMux/Placeholder.swift`:
    ```swift
    // HaloMux: pure-Swift mux library. Real contents land in Tasks 3.3–3.6.
    ```
  - `Sources/halod/main.swift`:
    ```swift
    // halod entrypoint. Real daemon lands in Task 3.7.
    print("halod: not yet implemented"); exit(0)
    ```
  - `Sources/halo-attach/main.swift`:
    ```swift
    // halo-attach entrypoint. Real relay lands in Task 3.8.
    print("halo-attach: not yet implemented"); exit(0)
    ```

5. - [ ] Edit `Package.swift` (`:31`, just before the closing `]` of `targets:`) to append the four new targets and make `halo` depend on `HaloMux`. The `CVterm` C target points `cSettings`/`headerSearchPath` at the umbrella include + vendor dir:
  ```swift
  .target(
      name: "HaloMux",
      path: "Sources/HaloMux"
  ),
  .target(
      name: "CVterm",
      path: "Sources/CVterm",
      exclude: ["vendor/LICENSE"],
      sources: ["vendor"],
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("vendor"), .headerSearchPath("include")]
  ),
  .executableTarget(
      name: "halod",
      dependencies: ["HaloMux", "CVterm"],
      path: "Sources/halod"
  ),
  .executableTarget(
      name: "halo-attach",
      dependencies: ["HaloMux"],
      path: "Sources/halo-attach"
  ),
  ```
  And add `"HaloMux"` to the `halo` target's `dependencies` array at `Package.swift:12` (now `dependencies: ["GhosttyKit", "HaloMux"]`).

6. - [ ] Run `swift build` and watch it compile all four new targets plus `halo`. If libvterm's encoding tables fail to find a header, add the missing dir to `cSettings` `.headerSearchPath(...)`. Build must end green.

7. - [ ] Run `swift run halo selfcheck` and confirm it still prints `all self-checks ok` (no behavior change yet — only new targets).

8. - [ ] `git commit -am "M3: vendor libvterm (CVterm), add HaloMux/halod/halo-attach targets"`.

---

### Task 3.2: `make-app.sh` + CI — bundle, sign, and notarize the two new binaries
**Files:** Modify `make-app.sh` (the assemble + sign sections, `:42–53` copy area and `:118–140` sign area). Modify `.github/workflows/release.yml` (the "Build + sign Halo.app" / "Notarize" steps already invoke `make-app.sh`, so the binaries flow through automatically — verify only).
**Interfaces:**
- Consumes: the `halod` / `halo-attach` executable targets from Task 3.1 (built to `.build/$CONF/halod` and `.build/$CONF/halo-attach`).
- Produces: `Halo.app/Contents/MacOS/halod` and `Halo.app/Contents/MacOS/halo-attach`, both signed beside `Halo`. This is the directory `muxHelperPath()` (Task 3.9) resolves against.

1. - [ ] In `make-app.sh`, after the line `cp "$BIN" "${APP}/Contents/MacOS/Halo"` (`:45`), copy the two sibling binaries into the same `MacOS` dir:
  ```bash
  # Mux helpers (Milestone 3): the daemon + the per-pane relay. They live beside
  # the main binary so muxHelperPath() resolves them via Bundle.main.executableURL.
  cp "$BINDIR/halod"        "${APP}/Contents/MacOS/halod"
  cp "$BINDIR/halo-attach"  "${APP}/Contents/MacOS/halo-attach"
  ```

2. - [ ] In `make-app.sh`'s real-signing branch (the `if [ -n "${SIGN_ID:-}" ]` block, `:120`), sign both helpers with the SAME Hardened-Runtime + entitlements options BEFORE signing the wrapper (nested code must be signed first):
  ```bash
    codesign --force --options runtime --timestamp --entitlements "$ENT" \
      --sign "$SIGN_ID" "${APP}/Contents/MacOS/halod"
    codesign --force --options runtime --timestamp --entitlements "$ENT" \
      --sign "$SIGN_ID" "${APP}/Contents/MacOS/halo-attach"
  ```
  (Insert these two `codesign` calls right after the existing `--sign "$SIGN_ID" "${APP}/Contents/MacOS/Halo"` and before the wrapper sign.)

3. - [ ] In `make-app.sh`'s ad-hoc branch (the `else` at `:135`), ad-hoc sign both helpers too, before the wrapper:
  ```bash
    codesign --force --sign - "${APP}/Contents/MacOS/halod" >/dev/null 2>&1 || true
    codesign --force --sign - "${APP}/Contents/MacOS/halo-attach" >/dev/null 2>&1 || true
  ```

4. - [ ] Run `./make-app.sh debug` and confirm the bundle now contains all three Mach-O files: `ls -l Halo.app/Contents/MacOS` shows `Halo`, `halod`, `halo-attach`. Confirm ad-hoc signing succeeded: `codesign -dv Halo.app/Contents/MacOS/halo-attach 2>&1 | grep -q "Signature=adhoc"` returns 0.

5. - [ ] Confirm `release.yml` needs no edit: it calls `./make-app.sh release` and then notarizes the whole `Halo.app` zip (`ditto -c -k --keepParent Halo.app`), so both new binaries are signed by step 2 and notarized as part of the bundle. Read `.github/workflows/release.yml` "Notarize + staple" step and verify it zips `Halo.app` (not just the inner binary) — it does (`/tmp/Halo.zip` from `Halo.app`). No code change; record this verification in the commit message.

6. - [ ] `git commit -am "M3: bundle + sign halod and halo-attach in make-app.sh"`.

---

### Task 3.3: `HaloMux/MuxProtocol.swift` — wire frame types + codec + self-check
**Files:** Create `Sources/HaloMux/MuxProtocol.swift` (delete the `Placeholder.swift` stub if it now conflicts — keep one file). Wire `muxProtocolSelfCheck()` into `Sources/Halo/main.swift:8`.
**Interfaces:**
- Consumes: nothing.
- Produces (every later task uses these VERBATIM): `muxProtocolVersion`, `SessionInfo`, `ClientFrame`, `ServerFrame`, `encode(_ f: ClientFrame) -> Data`, `encode(_ f: ServerFrame) -> Data`, `decodeClientFrame(from:) -> ClientFrame?`, `decodeServerFrame(from:) -> ServerFrame?`, `muxProtocolSelfCheck()`.

1. - [ ] Write the failing self-check first. Create `Sources/HaloMux/MuxProtocol.swift` with ONLY the public API surface (types + function signatures that `fatalError`) plus the full self-check body, so it compiles and the assertions fail at runtime:
  ```swift
  import Foundation

  public let muxProtocolVersion = 1

  public struct SessionInfo: Codable, Equatable {
      public let id: String
      public let name: String?
      public let cwd: String?
      public let alive: Bool
      public let attachedCount: Int
      public init(id: String, name: String?, cwd: String?, alive: Bool, attachedCount: Int) {
          self.id = id; self.name = name; self.cwd = cwd; self.alive = alive; self.attachedCount = attachedCount
      }
  }

  public enum ClientFrame: Equatable {
      case hello(paneID: String, cols: Int, rows: Int)
      case input(Data)
      case resize(cols: Int, rows: Int)
      case detach
      case kill
      case list
  }

  public enum ServerFrame: Equatable {
      case helloAck(version: Int)
      case needsUpdate(serverVersion: Int)
      case snapshot(screen: Data, scrollback: Data, images: Data)
      case output(Data)
      case exited(status: Int32)
      case sessions([SessionInfo])
  }

  public func encode(_ f: ClientFrame) -> Data { fatalError() }
  public func encode(_ f: ServerFrame) -> Data { fatalError() }
  public func decodeClientFrame(from buf: inout Data) -> ClientFrame? { fatalError() }
  public func decodeServerFrame(from buf: inout Data) -> ServerFrame? { fatalError() }

  public func muxProtocolSelfCheck() {
      // Round-trip every ClientFrame case.
      let clientCases: [ClientFrame] = [
          .hello(paneID: "abc-123", cols: 80, rows: 24),
          .input(Data([0x01, 0x02, 0xff, 0x00])),
          .resize(cols: 120, rows: 40),
          .detach, .kill, .list,
      ]
      for f in clientCases {
          var buf = encode(f)
          let out = decodeClientFrame(from: &buf)
          assert(out == f, "client round-trip \(f)")
          assert(buf.isEmpty, "client decode consumed the whole frame")
      }
      // Round-trip every ServerFrame case.
      let info = SessionInfo(id: "p1", name: "build", cwd: "/tmp", alive: true, attachedCount: 2)
      let serverCases: [ServerFrame] = [
          .helloAck(version: 1),
          .needsUpdate(serverVersion: 7),
          .snapshot(screen: Data([1,2,3]), scrollback: Data([9,8]), images: Data([4])),
          .output(Data([0x68, 0x69])),
          .exited(status: 137),
          .sessions([info, SessionInfo(id: "p2", name: nil, cwd: nil, alive: false, attachedCount: 0)]),
      ]
      for f in serverCases {
          var buf = encode(f)
          let out = decodeServerFrame(from: &buf)
          assert(out == f, "server round-trip \(f)")
          assert(buf.isEmpty, "server decode consumed the whole frame")
      }
      // Partial buffer: a frame missing its last byte decodes to nil and leaves buf untouched.
      var full = encode(ClientFrame.input(Data([0xaa, 0xbb, 0xcc])))
      let truncated = full.dropLast()
      var partial = Data(truncated)
      let before = partial
      assert(decodeClientFrame(from: &partial) == nil, "partial frame yields nil")
      assert(partial == before, "partial decode does not consume bytes")
      // A buffer with one full frame + a partial second frame returns the first and
      // leaves exactly the partial bytes.
      full.append(truncated)
      var two = full
      assert(decodeClientFrame(from: &two) == .input(Data([0xaa, 0xbb, 0xcc])), "first of two decodes")
      assert(two == Data(truncated), "second (partial) frame left intact")
      print("muxProtocolSelfCheck ok")
  }
  ```

2. - [ ] Wire it in: edit `Sources/Halo/main.swift:8` to add `muxProtocolSelfCheck()` at the end of the call list, and add `import HaloMux` at the top of `main.swift` (after `import AppKit`):
  ```swift
  _ = ghosttyConfigSelfCheck(); controlSelfCheck(); gitSelfCheck(); portsSelfCheck(); workspaceSelfCheck(); worktreeSelfCheck(); browserSelfCheck(); muxProtocolSelfCheck()
  ```

3. - [ ] Run `swift run halo selfcheck` and see it crash on the `fatalError()` in `encode` (self-check is wired and reached).

4. - [ ] Implement the codec. Replace the four `fatalError()` bodies with the real implementation. Tags: client 0x01–0x06, server 0x11–0x16. Framing is `[UInt32 BE payloadLen][UInt8 tag][payload]` where `payloadLen` counts the tag byte + payload (so the whole tail after the length prefix). Helpers for big-endian ints and length-prefixed `Data`/`String` fields:
  ```swift
  // ── byte helpers ────────────────────────────────────────────────────────
  private func putU32(_ v: UInt32, into d: inout Data) {
      d.append(UInt8(v >> 24 & 0xff)); d.append(UInt8(v >> 16 & 0xff))
      d.append(UInt8(v >> 8 & 0xff));  d.append(UInt8(v & 0xff))
  }
  private func getU32(_ d: Data, _ i: Int) -> UInt32 {
      (UInt32(d[d.startIndex + i]) << 24) | (UInt32(d[d.startIndex + i + 1]) << 16)
      | (UInt32(d[d.startIndex + i + 2]) << 8) | UInt32(d[d.startIndex + i + 3])
  }
  // A field = [UInt32 BE len][len bytes].
  private func putField(_ bytes: Data, into d: inout Data) { putU32(UInt32(bytes.count), into: &d); d.append(bytes) }
  private func putStr(_ s: String, into d: inout Data) { putField(Data(s.utf8), into: &d) }
  // Optional string: 1 present-flag byte, then a field if present.
  private func putOptStr(_ s: String?, into d: inout Data) {
      if let s { d.append(1); putStr(s, into: &d) } else { d.append(0) }
  }

  // Frame the [tag][payload] tail behind a total-length prefix.
  private func frame(_ tag: UInt8, _ payload: Data) -> Data {
      var d = Data()
      putU32(UInt32(payload.count + 1), into: &d)   // +1 for the tag
      d.append(tag)
      d.append(payload)
      return d
  }

  public func encode(_ f: ClientFrame) -> Data {
      var p = Data()
      switch f {
      case let .hello(paneID, cols, rows):
          putStr(paneID, into: &p); putU32(UInt32(cols), into: &p); putU32(UInt32(rows), into: &p)
          return frame(0x01, p)
      case let .input(data):
          putField(data, into: &p); return frame(0x02, p)
      case let .resize(cols, rows):
          putU32(UInt32(cols), into: &p); putU32(UInt32(rows), into: &p); return frame(0x03, p)
      case .detach: return frame(0x04, p)
      case .kill:   return frame(0x05, p)
      case .list:   return frame(0x06, p)
      }
  }

  public func encode(_ f: ServerFrame) -> Data {
      var p = Data()
      switch f {
      case let .helloAck(version):
          putU32(UInt32(version), into: &p); return frame(0x11, p)
      case let .needsUpdate(serverVersion):
          putU32(UInt32(serverVersion), into: &p); return frame(0x12, p)
      case let .snapshot(screen, scrollback, images):
          putField(screen, into: &p); putField(scrollback, into: &p); putField(images, into: &p)
          return frame(0x13, p)
      case let .output(data):
          putField(data, into: &p); return frame(0x14, p)
      case let .exited(status):
          putU32(UInt32(bitPattern: status), into: &p); return frame(0x15, p)
      case let .sessions(list):
          putU32(UInt32(list.count), into: &p)
          for s in list {
              putStr(s.id, into: &p); putOptStr(s.name, into: &p); putOptStr(s.cwd, into: &p)
              p.append(s.alive ? 1 : 0); putU32(UInt32(s.attachedCount), into: &p)
          }
          return frame(0x16, p)
      }
  }
  ```

5. - [ ] Run `swift run halo selfcheck`; it now reaches `decodeClientFrame` and crashes there (encode is proven by the next step's decode round-trip — keep going).

6. - [ ] Implement the two decoders. A cursor-based reader over the payload slice; `peekFrame` validates a full frame is buffered and returns `(tag, payload, totalConsumed)` or nil without mutating:
  ```swift
  // Pull one complete frame off the front of buf, or nil if not fully buffered.
  // On success removes the consumed bytes from buf and returns (tag, payload).
  private func pullFrame(from buf: inout Data) -> (UInt8, Data)? {
      guard buf.count >= 4 else { return nil }
      let payloadLen = Int(getU32(buf, 0))      // counts tag + payload
      let total = 4 + payloadLen
      guard buf.count >= total else { return nil }   // partial: leave buf untouched
      let tag = buf[buf.startIndex + 4]
      let payload = buf.subdata(in: (buf.startIndex + 5)..<(buf.startIndex + total))
      buf.removeSubrange(buf.startIndex..<(buf.startIndex + total))
      return (tag, payload)
  }

  // Cursor reader over a payload Data.
  private struct Reader {
      let d: Data; var i: Int = 0
      init(_ d: Data) { self.d = d }
      mutating func u32() -> UInt32 {
          let v = (UInt32(d[d.startIndex + i]) << 24) | (UInt32(d[d.startIndex + i + 1]) << 16)
              | (UInt32(d[d.startIndex + i + 2]) << 8) | UInt32(d[d.startIndex + i + 3])
          i += 4; return v
      }
      mutating func field() -> Data {
          let n = Int(u32())
          let s = d.subdata(in: (d.startIndex + i)..<(d.startIndex + i + n)); i += n; return s
      }
      mutating func str() -> String { String(decoding: field(), as: UTF8.self) }
      mutating func byte() -> UInt8 { let b = d[d.startIndex + i]; i += 1; return b }
      mutating func optStr() -> String? { byte() == 1 ? str() : nil }
  }

  public func decodeClientFrame(from buf: inout Data) -> ClientFrame? {
      guard let (tag, payload) = pullFrame(from: &buf) else { return nil }
      var r = Reader(payload)
      switch tag {
      case 0x01: let id = r.str(); let c = Int(r.u32()); let rr = Int(r.u32()); return .hello(paneID: id, cols: c, rows: rr)
      case 0x02: return .input(r.field())
      case 0x03: return .resize(cols: Int(r.u32()), rows: Int(r.u32()))
      case 0x04: return .detach
      case 0x05: return .kill
      case 0x06: return .list
      default:   return nil
      }
  }

  public func decodeServerFrame(from buf: inout Data) -> ServerFrame? {
      guard let (tag, payload) = pullFrame(from: &buf) else { return nil }
      var r = Reader(payload)
      switch tag {
      case 0x11: return .helloAck(version: Int(r.u32()))
      case 0x12: return .needsUpdate(serverVersion: Int(r.u32()))
      case 0x13: return .snapshot(screen: r.field(), scrollback: r.field(), images: r.field())
      case 0x14: return .output(r.field())
      case 0x15: return .exited(status: Int32(bitPattern: r.u32()))
      case 0x16:
          let n = Int(r.u32())
          var list: [SessionInfo] = []
          for _ in 0..<n {
              let id = r.str(); let name = r.optStr(); let cwd = r.optStr()
              let alive = r.byte() == 1; let count = Int(r.u32())
              list.append(SessionInfo(id: id, name: name, cwd: cwd, alive: alive, attachedCount: count))
          }
          return .sessions(list)
      default: return nil
      }
  }
  ```

7. - [ ] Run `swift run halo selfcheck` and confirm `muxProtocolSelfCheck ok` then `all self-checks ok` print.

8. - [ ] Delete the now-redundant `Sources/HaloMux/Placeholder.swift` (its comment is superseded). Run `swift build` to confirm the target still has at least one file and compiles.

9. - [ ] `git commit -am "M3: MuxProtocol framing codec + round-trip/partial-buffer self-check"`.

---

### Task 3.4: `HaloMux/MuxPaths.swift` — socket/log paths + `ensureDirs` (0700) + self-check
**Files:** Create `Sources/HaloMux/MuxPaths.swift`. Wire `muxPathsSelfCheck()` into `Sources/Halo/main.swift:8`.
**Interfaces:**
- Consumes: nothing.
- Produces: `MuxPaths.base`, `MuxPaths.daemonSocket`, `MuxPaths.sessionLog(_:)`, `MuxPaths.ensureDirs()`, `muxPathsSelfCheck()`. `halod` (3.7) binds `MuxPaths.daemonSocket`; `halo-attach` (3.8) connects to it; both call `ensureDirs()`.

1. - [ ] Write the failing self-check first. Create `Sources/HaloMux/MuxPaths.swift` with the enum surface (real `base`/`daemonSocket`/`sessionLog` since they're pure string math, but `ensureDirs` left as a `fatalError` so a step proves it's reached) and the full check:
  ```swift
  import Foundation

  public enum MuxPaths {
      public static var base: String {
          NSHomeDirectory() + "/Library/Application Support/halo"
      }
      public static var daemonSocket: String { base + "/halod.sock" }
      public static func sessionLog(_ paneID: String) -> String { base + "/sessions/\(paneID).log" }
      public static func ensureDirs() { fatalError() }
  }

  public func muxPathsSelfCheck() {
      let b = MuxPaths.base
      assert(b.hasSuffix("/Library/Application Support/halo"), "base path")
      assert(MuxPaths.daemonSocket == b + "/halod.sock", "socket path")
      assert(MuxPaths.sessionLog("abc") == b + "/sessions/abc.log", "session log path")
      // sessionLog keeps the paneID verbatim (it's a UUID string; no escaping needed).
      assert(MuxPaths.sessionLog("11111111-2222").hasSuffix("/sessions/11111111-2222.log"), "log uses paneID verbatim")
      print("muxPathsSelfCheck ok")
  }
  ```

2. - [ ] Wire it into `Sources/Halo/main.swift:8` after `muxProtocolSelfCheck()`:
  ```swift
  ...; muxProtocolSelfCheck(); muxPathsSelfCheck()
  ```

3. - [ ] Run `swift run halo selfcheck` and confirm `muxPathsSelfCheck ok` prints (it doesn't call `ensureDirs`, so the `fatalError` isn't hit — the check passes).

4. - [ ] Implement `ensureDirs()` creating `base` and `base/sessions` at mode `0700` (the spec's owner-only dir requirement). Replace the `fatalError`:
  ```swift
  public static func ensureDirs() {
      let fm = FileManager.default
      let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
      try? fm.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: attrs)
      try? fm.createDirectory(atPath: base + "/sessions", withIntermediateDirectories: true, attributes: attrs)
      // createDirectory's mode only applies to dirs it CREATES; re-assert on the
      // leaf in case `base` pre-existed at a looser mode.
      try? fm.setAttributes(attrs, ofItemAtPath: base)
      try? fm.setAttributes(attrs, ofItemAtPath: base + "/sessions")
  }
  ```

5. - [ ] Verify `ensureDirs` mode hands-on (it touches the real FS, so it's not in the assert-check): `swift build` then `rm -rf "$HOME/Library/Application Support/halo/sessions"` and run a one-off `swift -e 'import HaloMux; MuxPaths.ensureDirs()'`-style check — simplest is to add the call to `halod`'s stub temporarily, run `.build/debug/halod`, then `stat -f '%A' "$HOME/Library/Application Support/halo/sessions"` and confirm it prints `700`. Revert the temporary stub edit afterward.

6. - [ ] `git commit -am "M3: MuxPaths (base/socket/sessionLog) + ensureDirs 0700 + self-check"`.

---

### Task 3.5: `HaloMux/ScrollbackRing.swift` — bounded ring + disk-spill boundary + self-check
**Files:** Create `Sources/HaloMux/ScrollbackRing.swift`. Wire `scrollbackRingSelfCheck()` into `Sources/Halo/main.swift:8`. (Lives in `HaloMux` so it's reachable from the `halo` selfcheck and reused by `halod`.)
**Interfaces:**
- Consumes: nothing.
- Produces: `ScrollbackRing` with `init(cap:onSpill:)`, `push(_ line: Data)`, `lines() -> [Data]`, `spilledCount`; `scrollbackRingSelfCheck()`. `halod` (3.7) feeds completed scrollback lines from libvterm into a `ScrollbackRing` whose `onSpill` appends to `MuxPaths.sessionLog`.

1. - [ ] Write the failing self-check first. Create `Sources/HaloMux/ScrollbackRing.swift` with the type surface (stored props + `fatalError` methods) and the full check:
  ```swift
  import Foundation

  /// A fixed-capacity ring of scrollback lines. When full, the oldest line is
  /// evicted and handed to `onSpill` (which halod appends to the on-disk session
  /// log) before the new line is admitted. `lines()` returns the in-RAM window,
  /// oldest first — exactly what an attach snapshot restores into native scrollback.
  public final class ScrollbackRing {
      private let cap: Int
      private var buf: [Data] = []
      private let onSpill: (Data) -> Void
      public private(set) var spilledCount: Int = 0
      public init(cap: Int, onSpill: @escaping (Data) -> Void) { fatalError() }
      public func push(_ line: Data) { fatalError() }
      public func lines() -> [Data] { fatalError() }
  }

  public func scrollbackRingSelfCheck() {
      var spilled: [Data] = []
      let ring = ScrollbackRing(cap: 3) { spilled.append($0) }
      // Below cap: nothing spills, order preserved.
      ring.push(Data([1])); ring.push(Data([2])); ring.push(Data([3]))
      assert(ring.lines() == [Data([1]), Data([2]), Data([3])], "fills to cap, oldest-first")
      assert(spilled.isEmpty, "no spill below cap")
      assert(ring.spilledCount == 0, "spilledCount 0 below cap")
      // One over cap: oldest (1) spills, RAM window slides.
      ring.push(Data([4]))
      assert(ring.lines() == [Data([2]), Data([3]), Data([4])], "window slid after eviction")
      assert(spilled == [Data([1])], "evicted line spilled exactly once")
      assert(ring.spilledCount == 1, "spilledCount tracks evictions")
      // Several more over cap: spill is in eviction order (oldest-first on disk).
      ring.push(Data([5])); ring.push(Data([6]))
      assert(ring.lines() == [Data([4]), Data([5]), Data([6])], "latest cap lines retained")
      assert(spilled == [Data([1]), Data([2]), Data([3])], "spill order = eviction order")
      assert(ring.spilledCount == 3, "three total evictions")
      // Cap of 0 is degenerate but must not crash: every push spills immediately.
      var spill0: [Data] = []
      let r0 = ScrollbackRing(cap: 0) { spill0.append($0) }
      r0.push(Data([9]))
      assert(r0.lines().isEmpty && spill0 == [Data([9])], "cap 0 spills everything")
      print("scrollbackRingSelfCheck ok")
  }
  ```

2. - [ ] Wire it into `Sources/Halo/main.swift:8` after `muxPathsSelfCheck()`:
  ```swift
  ...; muxPathsSelfCheck(); scrollbackRingSelfCheck()
  ```

3. - [ ] Run `swift run halo selfcheck` and see it crash in `ScrollbackRing.init` (`fatalError`) — the check is reached.

4. - [ ] Implement the ring. Replace the three `fatalError` bodies:
  ```swift
  public init(cap: Int, onSpill: @escaping (Data) -> Void) {
      self.cap = max(0, cap); self.onSpill = onSpill
  }
  public func push(_ line: Data) {
      if cap == 0 { onSpill(line); spilledCount += 1; return }
      if buf.count >= cap {
          let evicted = buf.removeFirst()
          onSpill(evicted); spilledCount += 1
      }
      buf.append(line)
  }
  public func lines() -> [Data] { buf }
  ```

5. - [ ] Run `swift run halo selfcheck` and confirm `scrollbackRingSelfCheck ok` then `all self-checks ok` print.

6. - [ ] `git commit -am "M3: ScrollbackRing bounded ring + disk-spill boundary + self-check"`.

---

### Task 3.6: `HaloMux/ImageCache.swift` — Kitty image-placement cache + replay ordering + self-check
**Files:** Create `Sources/HaloMux/ImageCache.swift`. Wire `imageCacheSelfCheck()` into `Sources/Halo/main.swift:8`.
**Interfaces:**
- Consumes: nothing.
- Produces: `ImageCache` with `record(transmit:)`, `place(_:)`, `delete(imageID:)`, `replayBytes() -> Data`; `imageCacheSelfCheck()`. `halod` (3.7) feeds Kitty-graphics APC transmit/placement sequences here and emits `replayBytes()` inside the attach `Snapshot.images` field.

1. - [ ] Write the failing self-check first. Create `Sources/HaloMux/ImageCache.swift`. The cache keys image *transmit* data by image id and tracks the *active placements* layered on top; `replayBytes()` must emit each referenced image's transmit chunk BEFORE the placements that reference it, in stable id order (so a fresh terminal that replays the bytes draws the same picture).
  ```swift
  import Foundation

  /// Caches Kitty-graphics protocol bytes so inline images survive detach/reattach.
  /// `record(transmit:)` stores the raw transmit APC for an image id (last write
  /// wins — a re-transmit replaces stale data). `place` appends a placement APC
  /// referencing an id. `delete` drops an image and its placements. `replayBytes()`
  /// concatenates, for each still-referenced image in ascending id order, its
  /// transmit chunk followed by that image's placement chunks in arrival order.
  public final class ImageCache {
      public struct Transmit: Equatable { public let id: UInt32; public let bytes: Data
          public init(id: UInt32, bytes: Data) { self.id = id; self.bytes = bytes } }
      public struct Placement: Equatable { public let imageID: UInt32; public let bytes: Data
          public init(imageID: UInt32, bytes: Data) { self.imageID = imageID; self.bytes = bytes } }
      private var transmits: [UInt32: Data] = [:]
      private var placements: [Placement] = []
      public init() { fatalError() }
      public func record(transmit: Transmit) { fatalError() }
      public func place(_ p: Placement) { fatalError() }
      public func delete(imageID: UInt32) { fatalError() }
      public func replayBytes() -> Data { fatalError() }
  }

  public func imageCacheSelfCheck() {
      let c = ImageCache()
      // Image 2 transmitted, then image 1 — replay must order by id, transmit before placement.
      c.record(transmit: .init(id: 2, bytes: Data([0x20])))
      c.record(transmit: .init(id: 1, bytes: Data([0x10])))
      c.place(.init(imageID: 1, bytes: Data([0xA1])))   // place image 1 once
      c.place(.init(imageID: 2, bytes: Data([0xB2])))   // place image 2
      c.place(.init(imageID: 1, bytes: Data([0xA1, 0x01])))  // second placement of image 1
      // Expected: img1 transmit, img1 placements (arrival order), img2 transmit, img2 placement.
      let expected = Data([0x10, 0xA1, 0xA1, 0x01, 0x20, 0xB2])
      assert(c.replayBytes() == expected, "replay = transmit-then-placements, ascending id")
      // Re-transmit of image 1 replaces its bytes (last write wins), placements kept.
      c.record(transmit: .init(id: 1, bytes: Data([0x11])))
      assert(c.replayBytes() == Data([0x11, 0xA1, 0xA1, 0x01, 0x20, 0xB2]), "re-transmit replaces image bytes")
      // Delete image 1 → its transmit and BOTH its placements vanish; image 2 remains.
      c.delete(imageID: 1)
      assert(c.replayBytes() == Data([0x20, 0xB2]), "delete removes image + its placements")
      // A placement referencing an unknown image id is dropped from replay (no transmit to anchor it).
      c.place(.init(imageID: 99, bytes: Data([0xFF])))
      assert(c.replayBytes() == Data([0x20, 0xB2]), "orphan placement excluded from replay")
      print("imageCacheSelfCheck ok")
  }
  ```

2. - [ ] Wire it into `Sources/Halo/main.swift:8` after `scrollbackRingSelfCheck()`:
  ```swift
  ...; scrollbackRingSelfCheck(); imageCacheSelfCheck()
  ```

3. - [ ] Run `swift run halo selfcheck` and see it crash in `ImageCache.init` (`fatalError`) — the check is reached.

4. - [ ] Implement the cache. Replace the four `fatalError` bodies:
  ```swift
  public init() {}
  public func record(transmit t: Transmit) { transmits[t.id] = t.bytes }   // last write wins
  public func place(_ p: Placement) { placements.append(p) }
  public func delete(imageID id: UInt32) {
      transmits[id] = nil
      placements.removeAll { $0.imageID == id }
  }
  public func replayBytes() -> Data {
      var out = Data()
      for id in transmits.keys.sorted() {           // ascending id, deterministic
          out.append(transmits[id]!)                 // transmit first
          for p in placements where p.imageID == id { out.append(p.bytes) }  // then its placements, arrival order
      }
      return out
  }
  ```
  (Orphan placements are naturally excluded: the loop only emits placements whose id has a transmit.)

5. - [ ] Run `swift run halo selfcheck` and confirm `imageCacheSelfCheck ok` then `all self-checks ok` print.

6. - [ ] `git commit -am "M3: ImageCache placement cache + replay-ordering self-check"`.

---

### Task 3.7: `halod` — forkpty'd shells, libvterm, select loop, snapshot, lazy launch
**Files:** Replace `Sources/halod/main.swift` (the stub from Task 3.1). Create `Sources/halod/Session.swift`, `Sources/halod/Daemon.swift`. This task has NO assert-check (it needs a real PTY + the libvterm C target); it is verified hands-on. Its pure-logic pieces (`ScrollbackRing`, `ImageCache`, `MuxProtocol`) were already proven in Tasks 3.3–3.6.
**Interfaces:**
- Consumes: `HaloMux` (`encode`/`decode*`, `ClientFrame`/`ServerFrame`, `SessionInfo`, `MuxPaths`, `ScrollbackRing`, `ImageCache`, `muxProtocolVersion`) and `CVterm` (`vterm_new`, `vterm_obtain_screen`, `vterm_input_write`, `vterm_screen_*`, `vterm_set_size`).
- Produces: a runnable daemon that binds `MuxPaths.daemonSocket` (0600), serves attach/input/resize/detach/kill/list, sends `helloAck`/`needsUpdate`/`snapshot`/`output`/`exited`/`sessions`, reaps a session on shell exit, idle-exits at zero live shells; and a static `Daemon.spawnIfNeeded()` lazy double-fork/`setsid` launcher used by `halo-attach` (3.8) and the GUI CLI verbs (3.10).

1. - [ ] Create `Sources/halod/Session.swift` — one `Session` per paneID owning the `forkpty`'d shell, the PTY master fd, a libvterm instance, a `ScrollbackRing`, and an `ImageCache`. Full code:
  ```swift
  import Foundation
  import HaloMux
  import CVterm
  #if canImport(Darwin)
  import Darwin
  #endif

  /// One live shell: PTY master + libvterm authoritative screen + scrollback ring
  /// (disk-spilled) + image cache. Drained by the daemon even when no client is attached.
  final class Session {
      let paneID: String
      let masterFD: Int32
      let pid: pid_t
      var cols: Int32
      var rows: Int32
      private let vt: OpaquePointer
      private let screen: OpaquePointer
      let ring: ScrollbackRing
      let images = ImageCache()
      var attached: [Int32] = []     // attached client fds (mirroring)
      private(set) var alive = true
      var cwd: String?
      var name: String?

      init?(paneID: String, cols: Int32, rows: Int32) {
          self.paneID = paneID; self.cols = cols; self.rows = rows
          // forkpty a login shell.
          var master: Int32 = 0
          var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
          let child = forkpty(&master, nil, nil, &ws)
          if child < 0 { return nil }
          if child == 0 {
              let shell = getenv("SHELL").flatMap { String(cString: $0) } ?? "/bin/zsh"
              execl(shell, shell, "-l", nil as UnsafePointer<CChar>?)
              _exit(127)
          }
          self.pid = child; self.masterFD = master
          // libvterm: authoritative screen, UTF-8, scrollback callback drains evicted rows.
          self.vt = vterm_new(Int32(rows), Int32(cols))
          vterm_set_utf8(vt, 1)
          self.screen = vterm_obtain_screen(vt)
          vterm_screen_reset(screen, 1)
          // Disk-spill ring: evicted lines append to the session log (history recovery).
          let logPath = MuxPaths.sessionLog(paneID)
          self.ring = ScrollbackRing(cap: 10_000) { line in
              if let fh = FileHandle(forWritingAtPath: logPath) ?? {
                  FileManager.default.createFile(atPath: logPath, contents: nil)
                  return FileHandle(forWritingAtPath: logPath)
              }() {
                  fh.seekToEndOfFile(); fh.write(line); fh.write(Data([0x0a])); try? fh.close()
              }
          }
          fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL, 0) | O_NONBLOCK)
      }

      /// Feed raw PTY output into libvterm (updates the authoritative screen) AND
      /// capture finished scrollback rows into the ring. Returns the same bytes so
      /// the daemon can forward them to attached clients verbatim.
      func ingest(_ bytes: Data) {
          bytes.withUnsafeBytes { raw in
              _ = vterm_input_write(vt, raw.bindMemory(to: CChar.self).baseAddress, raw.count)
          }
          // Pull any rows that scrolled off the top into the ring. libvterm reports
          // these via the screen's sb_pushline callback; we mirror them here by
          // reading damaged rows is overkill — instead the daemon wires the
          // sb_pushline callback (set in Daemon) to call ring.push directly.
      }

      /// Render the current libvterm screen to a UTF-8 byte stream (clean redraw on attach).
      func screenSnapshot() -> Data {
          var out = Data()
          for row in 0..<rows {
              for col in 0..<cols {
                  var cell = VTermScreenCell()
                  var pos = VTermPos(row: Int32(row), col: Int32(col))
                  vterm_screen_get_cell(screen, pos, &cell)
                  let n = Int(cell.width == 0 ? 1 : cell.width)
                  if cell.chars.0 == 0 { out.append(0x20) } else {
                      var scalar = cell.chars.0
                      if let u = Unicode.Scalar(scalar) { out.append(contentsOf: Array(String(u).utf8)) }
                  }
                  _ = n
              }
              out.append(0x0a)
          }
          return out
      }

      func resize(cols: Int32, rows: Int32) {
          self.cols = cols; self.rows = rows
          var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
          _ = ioctl(masterFD, TIOCSWINSZ, &ws)
          vterm_set_size(vt, Int32(rows), Int32(cols))
      }

      func writeInput(_ data: Data) {
          data.withUnsafeBytes { raw in
              var off = 0
              while off < raw.count {
                  let n = write(masterFD, raw.baseAddress!.advanced(by: off), raw.count - off)
                  if n <= 0 { break }; off += n
              }
          }
      }

      func markDead() { alive = false }

      deinit {
          vterm_free(vt)
          close(masterFD)
      }
  }
  ```
  (Note: the `ingest` comment defers scrollback capture to the `sb_pushline` callback the daemon installs — implemented in step 2.)

2. - [ ] Create `Sources/halod/Daemon.swift` — the listener, the per-session libvterm scrollback callback wiring, the `select` loop, attach/snapshot, and the lazy spawn helper. Full code:
  ```swift
  import Foundation
  import HaloMux
  import CVterm
  #if canImport(Darwin)
  import Darwin
  #endif

  final class Daemon {
      private var listenFD: Int32 = -1
      private var sessions: [String: Session] = [:]
      private var clientBufs: [Int32: Data] = [:]   // partial inbound frames per client fd
      private var clientSession: [Int32: String] = [:]

      // Per-session sb_pushline trampoline: libvterm hands us scrolled-off rows.
      // We can't capture Swift state in a C function pointer, so route via a global
      // keyed by the screen pointer.
      static var ringFor: [UnsafeMutableRawPointer: ScrollbackRing] = [:]

      func run() {
          MuxPaths.ensureDirs()
          let path = MuxPaths.daemonSocket
          unlink(path)
          let fd = socket(AF_UNIX, SOCK_STREAM, 0)
          var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
          let bytes = Array(path.utf8)
          withUnsafeMutableBytes(of: &addr.sun_path) { raw in
              for i in 0..<min(bytes.count, raw.count - 1) { raw[i] = bytes[i] }
          }
          let len = socklen_t(MemoryLayout<sockaddr_un>.size)
          let bound = withUnsafePointer(to: &addr) {
              $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
          }
          guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
          chmod(path, 0o600)            // owner-only: this socket carries keystrokes + scrollback
          listenFD = fd
          loop()
      }

      private func loop() {
          while true {
              var rset = fd_set(); __darwin_fd_set(listenFD, &rset)
              var maxFD = listenFD
              for (_, s) in sessions { __darwin_fd_set(s.masterFD, &rset); maxFD = max(maxFD, s.masterFD) }
              for fd in clientBufs.keys { __darwin_fd_set(fd, &rset); maxFD = max(maxFD, fd) }
              var tv = timeval(tv_sec: 5, tv_usec: 0)
              let n = select(maxFD + 1, &rset, nil, nil, &tv)
              if n < 0 { if errno == EINTR { continue }; break }
              reapDeadShells()
              if sessions.isEmpty && clientBufs.isEmpty && idleExpired() { break }  // idle-exit
              if __darwin_fd_isset(listenFD, &rset) != 0 { acceptClient() }
              // Drain every PTY (even with zero clients → no backpressure).
              for (_, s) in sessions where __darwin_fd_isset(s.masterFD, &rset) != 0 { drainPTY(s) }
              // Read client frames.
              for fd in Array(clientBufs.keys) where __darwin_fd_isset(fd, &rset) != 0 { readClient(fd) }
          }
          if listenFD >= 0 { close(listenFD); unlink(MuxPaths.daemonSocket) }
      }

      private var lastActivity = Date()
      private func idleExpired() -> Bool { Date().timeIntervalSince(lastActivity) > 10 }

      private func acceptClient() {
          let c = accept(listenFD, nil, nil)
          if c < 0 { return }
          fcntl(c, F_SETFL, fcntl(c, F_GETFL, 0) | O_NONBLOCK)
          clientBufs[c] = Data()
          lastActivity = Date()
      }

      private func drainPTY(_ s: Session) {
          var tmp = [UInt8](repeating: 0, count: 65536)
          let n = read(s.masterFD, &tmp, tmp.count)
          if n > 0 {
              let data = Data(tmp[0..<n])
              s.ingest(data)
              for c in s.attached { sendFrame(c, encode(ServerFrame.output(data))) }
          } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
              s.markDead()
          }
      }

      private func reapDeadShells() {
          for (id, s) in sessions where !s.alive {
              for c in s.attached { sendFrame(c, encode(ServerFrame.exited(status: waitStatus(s.pid)))) }
              sessions[id] = nil
              Daemon.ringFor[UnsafeMutableRawPointer(mutating: s.screenKey)] = nil
          }
      }

      private func waitStatus(_ pid: pid_t) -> Int32 {
          var st: Int32 = 0; waitpid(pid, &st, WNOHANG); return st
      }

      private func readClient(_ fd: Int32) {
          var tmp = [UInt8](repeating: 0, count: 65536)
          let n = read(fd, &tmp, tmp.count)
          if n <= 0 { closeClient(fd); return }
          clientBufs[fd, default: Data()].append(Data(tmp[0..<n]))
          lastActivity = Date()
          var buf = clientBufs[fd]!
          while let frame = decodeClientFrame(from: &buf) { handle(frame, from: fd) }
          clientBufs[fd] = buf
      }

      private func closeClient(_ fd: Int32) {
          if let sid = clientSession[fd] { sessions[sid]?.attached.removeAll { $0 == fd } }
          clientSession[fd] = nil; clientBufs[fd] = nil; close(fd)
      }

      private func handle(_ frame: ClientFrame, from fd: Int32) {
          switch frame {
          case let .hello(paneID, cols, rows):
              // No server-side version gate: the server unconditionally advertises its
              // version via helloAck (below); the CLIENT (halo-attach, Task 3.8) compares
              // helloAck.version to its own muxProtocolVersion and bails on mismatch. This
              // is what makes remote attach (M5) against a newer/older daemon safe.
              let s: Session
              if let existing = sessions[paneID] { s = existing; s.resize(cols: Int32(cols), rows: Int32(rows)) }
              else {
                  guard let fresh = Session(paneID: paneID, cols: Int32(cols), rows: Int32(rows)) else {
                      sendFrame(fd, encode(ServerFrame.exited(status: 1))); return
                  }
                  installScrollback(fresh)
                  sessions[paneID] = fresh; s = fresh
              }
              s.attached.append(fd); clientSession[fd] = paneID
              sendFrame(fd, encode(ServerFrame.helloAck(version: muxProtocolVersion)))
              // Clean redraw: current screen + restored scrollback + cached images.
              // Scrollback shown = on-disk spilled history + the in-memory ring tail.
              // After a daemon crash this fresh session has an empty ring but the prior
              // <paneID>.log survives on disk, so reading it here is exactly the #6
              // history-recovery mitigation — recovered and live-spilled history use one path.
              var scrollback = (try? Data(contentsOf: URL(fileURLWithPath: MuxPaths.sessionLog(s.paneID)))) ?? Data()
              if !scrollback.isEmpty, scrollback.last != 0x0a { scrollback.append(0x0a) }
              scrollback.append(Data(s.ring.lines().joined(separator: [0x0a])))
              sendFrame(fd, encode(ServerFrame.snapshot(
                  screen: s.screenSnapshot(), scrollback: scrollback, images: s.images.replayBytes())))
          case let .input(data):
              if let sid = clientSession[fd] { sessions[sid]?.writeInput(data) }
          case let .resize(cols, rows):
              if let sid = clientSession[fd] { sessions[sid]?.resize(cols: Int32(cols), rows: Int32(rows)) }
          case .detach:
              closeClient(fd)
          case .kill:
              if let sid = clientSession[fd], let s = sessions[sid] { kill(s.pid, SIGKILL); s.markDead() }
          case .list:
              let infos = sessions.values.map { SessionInfo(id: $0.paneID, name: $0.name, cwd: $0.cwd,
                  alive: $0.alive, attachedCount: $0.attached.count) }
              sendFrame(fd, encode(ServerFrame.sessions(infos)))
          }
      }

      // Wire libvterm's scrollback push to this session's ring (scrolled-off rows → disk spill).
      private func installScrollback(_ s: Session) {
          Daemon.ringFor[UnsafeMutableRawPointer(mutating: s.screenKey)] = s.ring
          var cbs = VTermScreenCallbacks()
          cbs.sb_pushline = { cols, cellsPtr, user in
              guard let user, let ring = Daemon.ringFor[user] else { return 0 }
              var line = Data()
              if let cells = cellsPtr {
                  for i in 0..<Int(cols) {
                      let ch = cells[i].chars.0
                      if ch != 0, let u = Unicode.Scalar(ch) { line.append(contentsOf: Array(String(u).utf8)) }
                      else { line.append(0x20) }
                  }
              }
              ring.push(line); return 1
          }
          s.installScreenCallbacks(&cbs, user: UnsafeMutableRawPointer(mutating: s.screenKey))
      }

      private func sendFrame(_ fd: Int32, _ data: Data) {
          data.withUnsafeBytes { raw in
              var off = 0
              while off < raw.count {
                  let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                  if n <= 0 { break }; off += n
              }
          }
      }

      // ── Lazy launch: double-fork + setsid so the daemon outlives the app ──────
      static func spawnIfNeeded() {
          // Already up? A connect to the socket succeeds → nothing to do.
          if socketAlive(MuxPaths.daemonSocket) { return }
          let exe = Bundle.main.executableURL?.deletingLastPathComponent()
              .appendingPathComponent("halod").path
              ?? (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/halod"
          let p = Process()
          p.executableURL = URL(fileURLWithPath: exe)
          p.arguments = []
          // setsid via a tiny shell wrapper so the daemon detaches from our session.
          let wrapper = Process()
          wrapper.executableURL = URL(fileURLWithPath: "/bin/sh")
          wrapper.arguments = ["-c", "setsid \"\(exe)\" >/dev/null 2>&1 &"]
          try? wrapper.run(); wrapper.waitUntilExit()
          // Wait briefly for the socket to appear.
          for _ in 0..<50 { if socketAlive(MuxPaths.daemonSocket) { return }; usleep(20_000) }
      }

      static func socketAlive(_ path: String) -> Bool {
          let fd = socket(AF_UNIX, SOCK_STREAM, 0); if fd < 0 { return false }
          defer { close(fd) }
          var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
          let bytes = Array(path.utf8)
          withUnsafeMutableBytes(of: &addr.sun_path) { raw in
              for i in 0..<min(bytes.count, raw.count - 1) { raw[i] = bytes[i] }
          }
          let len = socklen_t(MemoryLayout<sockaddr_un>.size)
          return withUnsafePointer(to: &addr) {
              $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
          }
      }
  }
  ```

3. - [ ] Add the two helper hooks `Session` needs (referenced by `Daemon`): a stable `screenKey` raw pointer and `installScreenCallbacks`. Append to `Sources/halod/Session.swift`:
  ```swift
  extension Session {
      /// A stable raw-pointer identity for this session, used as the `user` arg of
      /// libvterm screen callbacks (we can't pass Swift closures to C).
      var screenKey: UnsafeRawPointer { UnsafeRawPointer(bitPattern: UInt(bitPattern: ObjectIdentifier(self).hashValue))! }
      func installScreenCallbacks(_ cbs: inout VTermScreenCallbacks, user: UnsafeMutableRawPointer) {
          vterm_screen_set_callbacks(screen, &cbs, user)
          vterm_screen_enable_altscreen(screen, 1)
      }
  }
  ```

4. - [ ] Replace `Sources/halod/main.swift` with the real entrypoint:
  ```swift
  import Foundation
  let daemon = Daemon()
  daemon.run()
  ```

5. - [ ] Run `swift build` and resolve any libvterm symbol/signature mismatches by reading `Sources/CVterm/include/vterm.h` for the exact `VTermScreenCallbacks` field name (`sb_pushline`), `vterm_screen_get_cell`, `VTermScreenCell`, and `VTermPos` shapes — adjust the Swift calls to match the vendored 0.3.3 API. Build must end green.

6. - [ ] Hands-on verify the daemon stands up and binds 0600. In one terminal: `rm -f "$HOME/Library/Application Support/halo/halod.sock"; .build/debug/halod &`. Then `stat -f '%A %N' "$HOME/Library/Application Support/halo/halod.sock"` and confirm it prints `600 …/halod.sock`. Kill it: `kill %1`.

7. - [ ] Hands-on verify a full attach round-trip with a throwaway client (since `halo-attach` lands next): write a 20-line scratch Swift script `/tmp/mux_probe.swift` that connects to the socket, sends `encode(ClientFrame.hello(paneID: "probe", cols: 80, rows: 24))`, reads frames, and prints each decoded `ServerFrame` case name. Run `.build/debug/halod &` then `swift -I .build/debug/Modules /tmp/mux_probe.swift` (adjust `-I`/link flags as needed, or temporarily add a `halod probe` subcommand). Confirm you see `helloAck` then `snapshot`, then after sending `.input("echo hi\n".data)` you see `output` frames containing `hi`. Detach (close the client) and confirm via a second probe that re-`hello`ing `probe` returns a `snapshot` whose `screen` still shows the `hi` line — proving the shell survived detach and scrollback restored. Record the exact commands + observed output in the commit message.

8. - [ ] Hands-on verify idle-exit: with no client attached and no sessions, the daemon process exits within ~15s (it should disappear from `ps`). And reap-on-exit: in an attached probe run `exit`, confirm an `exited` frame arrives and the session is gone from a subsequent `.list`.

9. - [ ] `git commit -am "M3: halod — forkpty shells, libvterm screen+scrollback, select loop, snapshot, lazy launch"`.

---

### Task 3.8: `halo-attach` — the client relay (lazy-spawn daemon, pump bytes + winsize)
**Files:** Replace `Sources/halo-attach/main.swift` (the stub from Task 3.1).
**Interfaces:**
- Consumes: `HaloMux` (`encode`/`decodeServerFrame`, `ClientFrame`/`ServerFrame`, `MuxPaths`, `muxProtocolVersion`) and `halod`'s `Daemon.spawnIfNeeded()`/`Daemon.socketAlive` — but `halo-attach` does NOT depend on the `halod` target, so it carries its own copy of the tiny `socketAlive` + lazy-spawn (resolving the sibling `halod` binary the same way). 
- Produces: a runnable binary `halo-attach <paneID>` that the GUI sets as `config.command` (Task 3.9). Writes `snapshot`+`output` to stdout, reads stdin → `input`, forwards SIGWINCH → `resize`, exits on EOF leaving the shell alive.

1. - [ ] Replace `Sources/halo-attach/main.swift` with the relay. It puts stdin into raw mode is NOT needed — ghostty's PTY already delivers raw bytes; `halo-attach`'s stdin/stdout ARE the ghostty surface's PTY, so it just shuttles bytes. Full code:
  ```swift
  import Foundation
  import HaloMux
  #if canImport(Darwin)
  import Darwin
  #endif

  // argv[1] = paneID.
  let args = CommandLine.arguments
  guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: halo-attach <paneID>\n".utf8)); exit(2) }
  let paneID = args[1]

  // ── lazy-spawn the daemon if its socket is absent ────────────────────────────
  func socketAlive(_ path: String) -> Bool {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0); if fd < 0 { return false }
      defer { close(fd) }
      var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(path.utf8)
      withUnsafeMutableBytes(of: &addr.sun_path) { raw in
          for i in 0..<min(bytes.count, raw.count - 1) { raw[i] = bytes[i] }
      }
      let len = socklen_t(MemoryLayout<sockaddr_un>.size)
      return withUnsafePointer(to: &addr) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
      }
  }
  func spawnDaemon() {
      let exe = Bundle.main.executableURL?.deletingLastPathComponent()
          .appendingPathComponent("halod").path
          ?? (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/halod"
      let w = Process(); w.executableURL = URL(fileURLWithPath: "/bin/sh")
      w.arguments = ["-c", "setsid \"\(exe)\" >/dev/null 2>&1 &"]
      try? w.run(); w.waitUntilExit()
      for _ in 0..<100 { if socketAlive(MuxPaths.daemonSocket) { return }; usleep(20_000) }
  }
  if !socketAlive(MuxPaths.daemonSocket) { spawnDaemon() }

  // ── connect ──────────────────────────────────────────────────────────────────
  let sock = socket(AF_UNIX, SOCK_STREAM, 0)
  guard sock >= 0 else { exit(1) }
  var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
  let pbytes = Array(MuxPaths.daemonSocket.utf8)
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      for i in 0..<min(pbytes.count, raw.count - 1) { raw[i] = pbytes[i] }
  }
  let slen = socklen_t(MemoryLayout<sockaddr_un>.size)
  let connected = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, slen) }
  }
  guard connected == 0 else { FileHandle.standardError.write(Data("halo-attach: daemon unavailable\n".utf8)); exit(1) }

  // ── initial winsize from our controlling tty (ghostty's PTY) ─────────────────
  func currentWinsize() -> (Int, Int) {
      var ws = winsize()
      if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
          return (Int(ws.ws_col), Int(ws.ws_row))
      }
      return (80, 24)
  }
  func send(_ f: ClientFrame) {
      let d = encode(f)
      d.withUnsafeBytes { raw in
          var off = 0
          while off < raw.count { let n = write(sock, raw.baseAddress!.advanced(by: off), raw.count - off); if n <= 0 { break }; off += n }
      }
  }
  let (cols0, rows0) = currentWinsize()
  send(.hello(paneID: paneID, cols: cols0, rows: rows0))

  // ── SIGWINCH → resize ────────────────────────────────────────────────────────
  // C signal handlers can't capture Swift state; stash the socket fd globally.
  var gSock: Int32 = sock
  signal(SIGWINCH) { _ in
      var ws = winsize()
      if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
          let d = encode(ClientFrame.resize(cols: Int(ws.ws_col), rows: Int(ws.ws_row)))
          d.withUnsafeBytes { raw in _ = write(gSock, raw.baseAddress, raw.count) }
      }
  }

  // ── pump loop: stdin → daemon(input), daemon(server frames) → stdout ─────────
  fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL, 0) | O_NONBLOCK)
  fcntl(sock, F_SETFL, fcntl(sock, F_GETFL, 0) | O_NONBLOCK)
  var inbuf = Data()
  outer: while true {
      var rset = fd_set(); __darwin_fd_set(STDIN_FILENO, &rset); __darwin_fd_set(sock, &rset)
      let maxFD = max(STDIN_FILENO, sock)
      var tv = timeval(tv_sec: 30, tv_usec: 0)
      let n = select(maxFD + 1, &rset, nil, nil, &tv)
      if n < 0 { if errno == EINTR { continue }; break }    // EINTR from SIGWINCH is fine
      // stdin → input frames.
      if __darwin_fd_isset(STDIN_FILENO, &rset) != 0 {
          var tmp = [UInt8](repeating: 0, count: 65536)
          let k = read(STDIN_FILENO, &tmp, tmp.count)
          if k == 0 { break }                                 // EOF on stdin (pane closed) → detach
          if k > 0 { send(.input(Data(tmp[0..<k]))) }
      }
      // daemon → stdout (decode server frames; write output/snapshot bytes).
      if __darwin_fd_isset(sock, &rset) != 0 {
          var tmp = [UInt8](repeating: 0, count: 65536)
          let k = read(sock, &tmp, tmp.count)
          if k <= 0 { break }                                 // daemon gone → exit (shell stays under daemon)
          inbuf.append(Data(tmp[0..<k]))
          while let f = decodeServerFrame(from: &inbuf) {
              switch f {
              case let .snapshot(screen, scrollback, images):
                  // Restore scrollback first, then current screen, then replay images.
                  FileHandle.standardOutput.write(scrollback)
                  FileHandle.standardOutput.write(screen)
                  FileHandle.standardOutput.write(images)
              case let .output(bytes):
                  FileHandle.standardOutput.write(bytes)
              case .exited:
                  break outer                                  // shell exited → relay ends
              case .needsUpdate:
                  FileHandle.standardError.write(Data("halo-attach: daemon protocol mismatch; update Halo\n".utf8))
                  break outer
              case let .helloAck(version):
                  // Client-side version gate: the daemon advertises its version here; if it
                  // differs from ours, refuse rather than misparse a newer/older frame stream
                  // (critical for remote attach, M5). The shell stays alive under the daemon.
                  if version != muxProtocolVersion {
                      FileHandle.standardError.write(Data("halo-attach: daemon protocol v\(version) != client v\(muxProtocolVersion); update Halo\n".utf8))
                      break outer
                  }
              case .sessions:
                  break                                        // not used by the pump
              }
          }
      }
  }
  // EOF/quit: just close. We send a detach so the daemon drops our fd promptly,
  // but the shell keeps running under halod.
  send(.detach)
  close(sock)
  exit(0)
  ```

2. - [ ] Run `swift build` and resolve any `fd_set`/`__darwin_fd_set` availability issues (these are the macOS spellings; if the toolchain complains, use the `withUnsafeMutablePointer`+`FD_SET` shim pattern already used in `Daemon.swift`). Build must end green.

3. - [ ] Hands-on verify the relay against the running daemon, OUTSIDE ghostty first (so you control stdin): in a real terminal run `.build/debug/halo-attach demo-pane`. You should land in a live shell (the daemon lazy-spawned if needed). Type `echo hello-mux` and see it echo. Run `tput lines; tput cols` and confirm they match your terminal. Resize the terminal window and run `tput cols` again — it should reflect the new width (SIGWINCH → resize worked).

4. - [ ] Hands-on verify detach keeps the shell alive: in that attached `halo-attach demo-pane`, start `sleep 600` then press the pane's EOF/quit by closing the terminal (or Ctrl-C the `halo-attach` process from another terminal with `pkill -f 'halo-attach demo-pane'`). Re-run `.build/debug/halo-attach demo-pane` and confirm the snapshot redraws the prior screen and that `jobs`/`ps` still shows the `sleep` running — the shell survived. Record commands + observations in the commit.

5. - [ ] `git commit -am "M3: halo-attach relay — lazy-spawn daemon, byte pump, SIGWINCH resize, detach-on-EOF"`.

---

### Task 3.9: GUI — `TerminalPane.paneID`, `muxHelperPath()`, `halo-persist` spawn flip, `{cwd,paneID,name}` persistence
**Files:** Modify `Sources/Halo/TerminalPane.swift` (init `:37`, surface spawn `:48–60`). Create `Sources/Halo/MuxHelper.swift` (`muxHelperPath()` + `HaloConfig.persist`). Modify `Sources/Halo/PaneTree.swift` (`makeTerminalLeaf` `:311–313`, plus a `paneID`-carrying `init`). Modify `Sources/Halo/Tabs.swift` (`serialize()` `:391–401`, `hydrate(from:)` `:406–446`, `makeTree` `:486`). Modify `Sources/Halo/GhosttyConfig.swift` (`HaloConfig` struct `:191–208`).
**Interfaces:**
- Consumes: `halo-attach` binary beside the running executable (Tasks 3.1/3.2 put it there); `MuxPaths` (no direct use here, but `halo-attach` resolves it).
- Produces: `TerminalPane.paneID: String`; `muxHelperPath() -> String`; `HaloConfig.persist: Bool` (config key `halo-persist`, default ON this milestone); per-session persisted `{cwd, paneID, name}` in `windows.json`; reattach-by-paneID on restore.

1. - [ ] Add the config key. In `Sources/Halo/GhosttyConfig.swift`, add to the `HaloConfig` struct (`:198` for the stored var, `:207` for the init line) a `persist` flag defaulting ON (M3 flips it on per the contract):
  ```swift
  var persist: Bool           // halo-persist: spawn halo-attach (mux) instead of a bare shell
  ```
  and in `init(_ s:)`:
  ```swift
  persist = (s["halo-persist"].map { $0 != "false" && $0 != "0" }) ?? true   // default ON in M3
  ```

2. - [ ] Create `Sources/Halo/MuxHelper.swift` with the sibling-binary resolver, matching the contract path math verbatim:
  ```swift
  import Foundation

  /// Absolute path to the `halo-attach` relay binary that sits beside the running
  /// executable — works both in Halo.app/Contents/MacOS and in .build/debug.
  func muxHelperPath() -> String {
      Bundle.main.executableURL!.deletingLastPathComponent()
          .appendingPathComponent("halo-attach").path
  }
  ```

3. - [ ] Add `paneID` to `TerminalPane`. In `Sources/Halo/TerminalPane.swift`, add a stored property after `private(set) var id: Int` (`:8`):
  ```swift
  let paneID: String                     // stable mux session id (UUID string)
  ```
  and extend `init` (`:37`) to take it with a default:
  ```swift
  init(id: Int, theme: Theme, cwd: String? = nil, paneID: String = UUID().uuidString) {
      self.id = id
      self.cwd = cwd
      self.paneID = paneID
      super.init(...)   // unchanged
  ```
  (Keep the rest of `init` as-is.)

4. - [ ] Flip the spawn command. In `TerminalPane.init`'s surface-config block (`:48–60`), when `HaloConfig.shared.persist` is on, set `config.command` to `"<muxHelperPath()> <paneID>"` instead of the bare shell; otherwise leave the existing bare-shell path. ghostty's `config.command` is a C string, so build it once and pass through the existing `withOptionalCString`/working-directory dance. Concretely, just before `self.surface = withOptionalCString(cwd) { ... }`, add:
  ```swift
  let muxCommand: String? = HaloConfig.shared.persist ? "\(muxHelperPath()) \(paneID)" : nil
  ```
  and set it on the config inside the closure (ghostty's field is `config.command`):
  ```swift
  self.surface = withOptionalCString(cwd) { cwdPtr in
      config.working_directory = cwdPtr
      return withOptionalCString(muxCommand) { cmdPtr in
          if cmdPtr != nil { config.command = cmdPtr }
          return ghostty_surface_new(GhosttyApp.shared.app, &config)
      }
  }
  ```
  (Confirm the ghostty surface config field name is `command` by grepping the GhosttyKit header; adjust if it differs.)

5. - [ ] Thread `paneID` through `PaneTree`. In `Sources/Halo/PaneTree.swift` `makeTerminalLeaf(cwd:)` (`:311`), add an optional `paneID` param that defaults to a fresh UUID and forwards it to the `TerminalPane` init:
  ```swift
  private func makeTerminalLeaf(cwd: String?, paneID: String = UUID().uuidString) -> Leaf {
      let id = nextId; nextId += 1
      let pane = TerminalPane(id: id, theme: theme, cwd: cwd, paneID: paneID)
      ...
  ```
  And add a `paneID`-carrying `PaneTree.init`. The existing `init(theme:cwd:)` (`:111`) builds the first leaf; add a sibling convenience used by restore that passes a known paneID to that first leaf:
  ```swift
  convenience init(theme: Theme, cwd: String?, paneID: String) {
      self.init(theme: theme, cwd: cwd)            // builds default first leaf
      // Replace the auto-id of the single root leaf with the persisted paneID so
      // it reattaches to its live daemon session.
      self.replaceRootPaneID(paneID)
  }
  ```
  Implement `replaceRootPaneID` by rebuilding the single root leaf via `makeTerminalLeaf(cwd:paneID:)` (the existing init created one leaf; swap it). If the existing init structure makes in-place replacement awkward, instead add a stored `initialPaneID` consulted by the first `makeTerminalLeaf` call — pick whichever is the shorter diff against the real `init` body you see at `:111`. Expose the root pane's id:
  ```swift
  var rootPaneID: String? { (leaves.first?.content as? TerminalPane)?.paneID }
  ```

6. - [ ] Extend persistence to `{cwd, paneID, name}`. In `Sources/Halo/Tabs.swift` `serialize()` (`:391`), change each session from a bare cwd string to a dict carrying the focused pane's cwd + paneID + the session name. Replace the `"sessions": p.sessions.map { $0.focusedCwd ?? p.path }` line:
  ```swift
  "sessions": p.sessions.map { tree -> [String: Any] in
      var d: [String: Any] = ["cwd": tree.focusedCwd ?? p.path]
      if let pid = tree.rootPaneID { d["paneID"] = pid }
      if let nm = tree.name { d["name"] = nm }       // PaneTree.name from Milestone 2
      return d
  },
  ```

7. - [ ] Reattach by paneID on restore. In `Tabs.swift` `hydrate(from:)` (`:427`), replace the cwd-only session loop. Each saved session is now a dict; rebuild the tree with the persisted paneID (so `halo-attach <paneID>` reattaches the live shell) and restore its name:
  ```swift
  for sd in (pd["sessions"] as? [[String: Any]] ?? []) {
      let cwd = sd["cwd"] as? String ?? path
      let tree: PaneTree
      if let pid = sd["paneID"] as? String {
          tree = PaneTree(theme: theme, cwd: usableDir(cwd, fallback: path), paneID: pid)
      } else {
          tree = makeTree(cwd: usableDir(cwd, fallback: path))
      }
      if let nm = sd["name"] as? String { tree.name = nm }
      proj.sessions.append(tree)
  }
  ```
  Keep a back-compat branch: if `pd["sessions"]` is still the OLD `[String]` shape (pre-M3 windows.json), fall back to the cwd-only path so an existing file still loads:
  ```swift
  if let legacy = pd["sessions"] as? [String] {
      for cwd in legacy { proj.sessions.append(makeTree(cwd: usableDir(cwd, fallback: path))) }
  } else { /* the dict loop above */ }
  ```

8. - [ ] `swift build` green. Then `swift run halo selfcheck` still prints `all self-checks ok` (no self-check regressions).

9. - [ ] Hands-on verify reattach-across-quit end-to-end with the real app via `make-app.sh` (Bundle.main paths resolve correctly only in the bundle): `./make-app.sh debug && open Halo.app`. In a session run `echo MARKER-$$ && sleep 900`. Quit Halo (Cmd-Q → confirm). Relaunch `open Halo.app`. The restored session should reattach the SAME shell: the snapshot redraws and `jobs` shows the `sleep` still running, and the prior `MARKER-…` line is visible in scrollback (scroll up). Take a screenshot before-quit and after-relaunch and confirm the MARKER pid matches. Record both screenshots' relevant lines in the commit.

10. - [ ] Hands-on verify the gate: set `halo-persist = false` in the ghostty config, `./make-app.sh debug && open Halo.app`, confirm panes spawn a bare shell (quitting loses the session — old behavior). Reset the key. Confirm default (key absent) is persistent.

11. - [ ] `git commit -am "M3: GUI paneID + halo-attach spawn (halo-persist) + {cwd,paneID,name} persistence + reattach"`.

---

### Task 3.10: Detach UX wiring — Cmd-W/quit detach, explicit kill, `halo sessions`/`halo kill`, switcher injection
**Files:** Modify `Sources/Halo/main.swift` (`installKeybinds` Cmd-W cascade `:349–359`; `applicationShouldTerminate` `:167`). Modify `Sources/Halo/Control.swift` (`controlVerbs` `:10`, `dispatch` `:117`, CLI output `:221`, `printUsage` `:234`). Create `Sources/Halo/MuxClient.swift` (a tiny GUI-side client that talks the mux protocol to the daemon for `list`/`kill`). Modify `Sources/Halo/PaneTree.swift` to add a `kill action` entry point (prefix-x lands via Milestone 1's keytable → an action that calls into this). Modify the Milestone 2 switcher source to inject detached `SessionInfo`s.
**Interfaces:**
- Consumes: `HaloMux` (`ClientFrame.list`/`.kill`, `ServerFrame.sessions`, `encode`/`decodeServerFrame`, `MuxPaths`, `SessionInfo`), `Daemon.socketAlive` semantics (reuse the local `socketAlive` helper), the Milestone 1 prefix action set and Milestone 2 switcher list source.
- Produces: detach-not-kill semantics for Cmd-W/quit; `killSession(paneID:)` GUI action; `halo sessions` + `halo kill <id>` CLI verbs; detached sessions visible in the switcher.

1. - [ ] Create `Sources/Halo/MuxClient.swift` — a synchronous one-shot client used by the GUI + CLI to ask the daemon for the session list or to kill a session. It connects, sends one frame, reads the reply, closes. Full code:
  ```swift
  import Foundation
  import HaloMux
  #if canImport(Darwin)
  import Darwin
  #endif

  enum MuxClient {
      /// Connect to the daemon socket (no lazy-spawn — if the daemon is down there
      /// are no detached sessions). Returns the connected fd or nil.
      private static func connect() -> Int32? {
          let fd = socket(AF_UNIX, SOCK_STREAM, 0); if fd < 0 { return nil }
          var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
          let bytes = Array(MuxPaths.daemonSocket.utf8)
          withUnsafeMutableBytes(of: &addr.sun_path) { raw in
              for i in 0..<min(bytes.count, raw.count - 1) { raw[i] = bytes[i] }
          }
          let len = socklen_t(MemoryLayout<sockaddr_un>.size)
          let ok = withUnsafePointer(to: &addr) {
              $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) == 0 }
          }
          if !ok { close(fd); return nil }
          return fd
      }

      private static func send(_ fd: Int32, _ f: ClientFrame) {
          let d = encode(f)
          d.withUnsafeBytes { raw in var off = 0
              while off < raw.count { let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off); if n <= 0 { break }; off += n } }
      }

      /// One-shot `list` → the daemon's session table (empty if daemon is down).
      static func sessions() -> [SessionInfo] {
          guard let fd = connect() else { return [] }
          defer { close(fd) }
          send(fd, .list)
          var buf = Data(); var tmp = [UInt8](repeating: 0, count: 65536)
          // Read until one full frame decodes (the daemon replies promptly).
          for _ in 0..<100 {
              let k = read(fd, &tmp, tmp.count); if k <= 0 { break }
              buf.append(Data(tmp[0..<k]))
              if case let .sessions(list)? = decodeServerFrame(from: &buf) { return list }
          }
          return []
      }

      /// Kill a specific session by paneID: attach (hello) then send kill.
      static func kill(paneID: String) {
          guard let fd = connect() else { return }
          defer { close(fd) }
          send(fd, .hello(paneID: paneID, cols: 80, rows: 24))   // bind this fd to the session
          send(fd, .kill)
          var tmp = [UInt8](repeating: 0, count: 4096); _ = read(fd, &tmp, tmp.count)   // let the daemon act
      }
  }
  ```

2. - [ ] Detach (not kill) on Cmd-W and quit. The relay already detaches when its stdin hits EOF (pane closed), and the shell stays under `halod`, so closing a pane is ALREADY a detach with M3's spawn flip — verify no code change is needed for Cmd-W's pane/session close: read `installKeybinds`' Cmd-W cascade (`:349`) and `closeSession` (`Tabs.swift:203`). Confirm closing a pane just tears down the surface (which EOFs the relay) and does not kill the daemon shell. Add a clarifying comment above the Cmd-W `case "w":` block:
  ```swift
  // With halo-persist on (M3), closing a pane/session only tears down the ghostty
  // surface → the halo-attach relay EOFs and detaches; the shell keeps running
  // under halod. Explicit kill is prefix-x / `halo kill`, never Cmd-W.
  ```

3. - [ ] Soften the quit confirmation now that quit = detach (not "closes all sessions and their running programs"). In `applicationShouldTerminate` (`:170–171`), update the alert text to reflect persistence:
  ```swift
  a.messageText = "Quit Halo?"
  a.informativeText = "Your sessions keep running in the background and reattach next launch."
  ```
  (Keep the suppression-button behavior unchanged.)

4. - [ ] Add the explicit-kill GUI action. In `Sources/Halo/PaneTree.swift`, add a method that kills the focused pane's daemon session and then closes the pane locally:
  ```swift
  /// Explicit kill (prefix-x / menu): terminate the shell under halod, then close
  /// the pane locally. Distinct from Cmd-W, which only detaches.
  func killFocusedSession() {
      if let pane = focused as? TerminalPane { MuxClient.kill(paneID: pane.paneID) }
      closeFocused()
  }
  ```
  Wire it to the Milestone 1 prefix `x` action: in the keytable action dispatch (the M1 resolver that maps `(prefix, "x") → .kill`), have the `.kill` case call `ws.activeTree.killFocusedSession()` (replace whatever M1 stubbed for `x`). If M1 routed `x` to `closeSession`, change that single line to `killFocusedSession()`.

5. - [ ] Add a Kill menu item. In `Sources/Halo/Menu.swift`, add a "Kill Session" item to the session/window menu wired to a new `@objc func killSessionMenu()` on `AppDelegate` (add it in `main.swift` near `toggleSidebarMenu` `:303`):
  ```swift
  @objc func killSessionMenu() { active?.workspace.activeTree.killFocusedSession() }
  ```
  (Grep `Menu.swift` for an existing `addItem(withTitle:` group to attach it; give it no key equivalent so it can't be confused with Cmd-W.)

6. - [ ] Add CLI verbs `sessions` and `kill`. In `Sources/Halo/Control.swift`:
  - Extend `controlVerbs` (`:10`) with `"sessions"` and `"kill"`.
  - In `dispatch` (`:117`), add cases that go straight to the daemon via `MuxClient` (these don't touch the workspace, but must run on main since dispatch is `@MainActor` — `MuxClient` is synchronous and safe):
    ```swift
    case "sessions":
        let list = MuxClient.sessions()
        return ["ok": true, "sessions": list.map { ["id": $0.id, "name": $0.name as Any,
            "cwd": $0.cwd as Any, "alive": $0.alive, "attached": $0.attachedCount] }]
    case "kill":
        guard let id = args.first else { return ["ok": false, "error": "kill: <id> required"] }
        MuxClient.kill(paneID: id)
        return ["ok": true, "killed": id]
    ```
  - In `runControlCLI`'s output formatting (`:221`), print the sessions table:
    ```swift
    } else if verb == "sessions", let list = obj["sessions"] as? [[String: Any]] {
        for s in list {
            let id = s["id"] as? String ?? "?"
            let name = s["name"] as? String ?? "-"
            let alive = (s["alive"] as? Bool ?? false) ? "alive" : "dead"
            let att = s["attached"] as? Int ?? 0
            print("\(id)\t\(name)\t\(alive)\tattached=\(att)")
        }
    ```
  - Add both to `printUsage` (`:243` block):
    ```
      sessions                              list daemon sessions (id, name, alive, attached)
      kill <id>                             terminate a session's shell under the daemon
    ```

7. - [ ] Inject detached sessions into the Milestone 2 switcher. In the M2 switcher's list source (the function that builds the switcher's rows from `Workspace` sessions), append daemon sessions whose paneID is NOT already shown by a live pane. Compute the set of in-app paneIDs first, then add the orphans:
  ```swift
  // Detached sessions (live under halod but not currently shown in any pane) —
  // so they're never invisible. M3.
  let shownIDs = Set(/* every TerminalPane.paneID currently in the workspace */)
  for s in MuxClient.sessions() where s.alive && !shownIDs.contains(s.id) {
      rows.append(SwitcherRow(/* M2's row type */ title: s.name ?? s.cwd ?? s.id,
                              subtitle: "detached", paneID: s.id))
  }
  ```
  When such a detached row is chosen, open a new session whose tree uses that paneID so `halo-attach <paneID>` reattaches it: call `ws.newSessionReattaching(paneID:)`. Add that helper to `Workspace` (`Tabs.swift`) modeled on `addSession`:
  ```swift
  /// Open a session that reattaches an existing daemon paneID (from the switcher's
  /// detached list). Mirrors addSession but seeds the tree's root paneID.
  func reattachSession(_ paneID: String, cwd: String?) {
      let p = activeP
      let tree = PaneTree(theme: theme, cwd: cwd, paneID: paneID)
      tree.onFocusChange = { [weak self] in self?.handleChange() }
      projs[p].sessions.append(tree); projs[p].expanded = true
      activeP = p; activeS = projs[p].sessions.count - 1
      showActive()
  }
  ```
  (Use the exact `SwitcherRow`/list-builder names from the Milestone 2 task that defined the switcher — substitute them here.)

8. - [ ] `swift build` green. `swift run halo selfcheck` still prints `all self-checks ok`.

9. - [ ] Hands-on verify CLI: `./make-app.sh debug && open Halo.app`. In a session, note its behavior, then from a normal terminal run `Halo.app/Contents/MacOS/Halo sessions` and confirm it lists at least one alive session with an `attached=` count. Run `Halo.app/Contents/MacOS/Halo kill <id>` for an idle session and confirm that pane's shell dies (the pane shows the shell exited). Record the exact `sessions` output in the commit.

10. - [ ] Hands-on verify detach-not-kill vs explicit-kill: open two sessions, run `sleep 800` in session A, Cmd-W to close session A's pane. Run `halo sessions` and confirm A is still alive+detached. Then open the switcher (prefix-`s` / Cmd-K) and confirm the detached A appears with a "detached" subtitle; select it and confirm it reattaches (the `sleep` still running). Finally use prefix-`x` (or the Kill menu) on it and confirm `halo sessions` no longer lists it. Capture screenshots of the switcher showing the detached row and record observations in the commit.

11. - [ ] `git commit -am "M3: detach UX — Cmd-W/quit detach, explicit kill, halo sessions/kill CLI, switcher injection"`.

## Milestone 4 — Mirroring (live multi-client)

Build M1→M3 first. This milestone assumes M3 has shipped: `HaloMux` (`MuxProtocol.swift` with `encode`/`decode*`/`muxProtocolSelfCheck`, `muxProtocolVersion`), `halod` (daemon keying one PTY+libvterm per `paneID`), `halo-attach` (the relay ghostty spawns as `config.command`), and `TerminalPane.paneID: String` wired so each surface runs `halo-attach <paneID>`. M4 makes one `paneID` attachable from two panes/windows at once: the daemon fans output to every attached client and accepts input from any; size follows the **focused** client and idle mirrors letterbox. It adds a `ClientFrame.focus(Bool)` frame (additive, protocol-version bump), a pure-logic size-arbitration policy with a self-check, and a GUI "mirror here" action that creates a `TerminalPane` with an *existing* `paneID` instead of a fresh one.

Order: extend the protocol additively (4.1) → add the pure-logic size-arbitration policy + self-check (4.2) → make `halod` multi-client and apply the policy (4.3) → make `halo-attach` report focus (4.4) → wire `TerminalPane` focus → relay (4.5) → GUI "mirror here" action (4.6) → hands-on mirror verification (4.7).

### Task 4.1: Additive `focus` frame + protocol-version bump
**Files:** Modify `Sources/HaloMux/MuxProtocol.swift` (the `ClientFrame` enum, the `muxProtocolVersion` constant, `encode(_:ClientFrame)`, `decodeClientFrame(from:)`, and `muxProtocolSelfCheck()` — all created in M3). Test target: `halo selfcheck` via `Sources/Halo/main.swift:8`.
**Interfaces:**
- Consumes (from M3 contract): `public let muxProtocolVersion`, `public enum ClientFrame`, `public func encode(_ f: ClientFrame) -> Data`, `public func decodeClientFrame(from buf: inout Data) -> ClientFrame?`, `public func muxProtocolSelfCheck()`. The M3 framing is `[UInt32 big-endian payload-length][UInt8 tag][payload]`; `ClientFrame` tags 0…5 are `hello,input,resize,detach,kill,list`.
- Produces (later tasks rely on): `ClientFrame.focus(Bool)` (tag `6`); `muxProtocolVersion == 2`.

1. - [ ] In `Sources/HaloMux/MuxProtocol.swift`, bump the version: change `public let muxProtocolVersion = 1` to `public let muxProtocolVersion = 2`. (M3's `HelloAck`/`NeedsUpdate` handshake already gates skew; v1↔v2 binaries now cleanly refuse rather than misparse the new tag.)
2. - [ ] Add the new case to `ClientFrame`. After the existing `case list` line add:
  ```swift
      case focus(Bool)
  ```
  (Equatable is auto-synthesized; `Bool` is Equatable.)
3. - [ ] Wire the new case into `encode(_ f: ClientFrame) -> Data`. M3's encoder switches on `f` and writes `[len][tag][payload]`; add a branch using tag `6` and a single payload byte. Inside the `switch f` (after the `.list` branch), add:
  ```swift
      case .focus(let on):
          // tag 6, 1-byte payload: 1 = focused, 0 = idle mirror
          return frame(tag: 6, payload: Data([on ? 1 : 0]))
  ```
  (`frame(tag:payload:)` is M3's private framing helper that prepends the `UInt32` length and the tag byte. If M3 named it differently, use M3's exact helper; the wire bytes must be `[len=2][tag=6][0|1]`.)
4. - [ ] Wire decode into `decodeClientFrame(from buf: inout Data) -> ClientFrame?`. M3 peeks the length, returns `nil` if the full frame isn't buffered (without consuming), else slices off the frame and switches on the tag byte. Add a branch for tag `6`:
  ```swift
      case 6:
          // payload is exactly 1 byte
          return .focus(payload.first == 1)
  ```
  (`payload` is M3's already-sliced payload `Data` for this frame; do not re-read the length.)
5. - [ ] Extend `muxProtocolSelfCheck()` to round-trip the new case. Add, alongside M3's existing per-case asserts:
  ```swift
      // M4: focus frame round-trips both ways, and a partial buffer yields nil
      var fb = encode(ClientFrame.focus(true))
      assert(decodeClientFrame(from: &fb) == .focus(true), "focus(true) round-trip")
      assert(fb.isEmpty, "focus frame fully consumed")
      var fb2 = encode(ClientFrame.focus(false))
      assert(decodeClientFrame(from: &fb2) == .focus(false), "focus(false) round-trip")
      var partial = encode(ClientFrame.focus(true))
      let full = partial
      partial.removeLast()                       // drop the payload byte
      assert(decodeClientFrame(from: &partial) == nil, "partial focus frame returns nil")
      assert(partial.count == full.count - 1, "partial buffer left untouched")
  ```
6. - [ ] Run `swift run halo selfcheck` and confirm it still prints `muxProtocolSelfCheck ok` (M3 wired this call at `Sources/Halo/main.swift:8`) and ends with `all self-checks ok`.
7. - [ ] `git commit -m "M4: additive ClientFrame.focus(Bool), bump muxProtocolVersion to 2"`.

### Task 4.2: Size-arbitration policy (pure logic) + self-check
**Files:** Create `Sources/HaloMux/SizeArbitration.swift`. Modify `Sources/Halo/main.swift:8` (add the self-check call). Test target: `halo selfcheck`.
**Interfaces:**
- Consumes: nothing (pure value types).
- Produces: `public struct MirrorClient` (`clientID: Int, focused: Bool, cols: Int, rows: Int`); `public func arbitrateSize(_ clients: [MirrorClient]) -> (cols: Int, rows: Int)?`; `public func sizeArbitrationSelfCheck()`. Task 4.3 (daemon) consumes `arbitrateSize`.

1. - [ ] Create `Sources/HaloMux/SizeArbitration.swift` with the policy types and the **focused-wins, smallest-focused tiebreak, smallest-of-all fallback** rule. Idle mirrors letterbox to the chosen grid; this function only chooses the PTY grid:
  ```swift
  import Foundation

  /// One attached client's reported grid + whether it is the focused (typing) one.
  /// `clientID` is the daemon's per-connection id; only used for deterministic tiebreaks.
  public struct MirrorClient: Equatable {
      public let clientID: Int
      public let focused: Bool
      public let cols: Int
      public let rows: Int
      public init(clientID: Int, focused: Bool, cols: Int, rows: Int) {
          self.clientID = clientID; self.focused = focused; self.cols = cols; self.rows = rows
      }
  }

  /// Choose the PTY grid for a session given every attached client.
  /// Policy (beats tmux's smallest-wins): follow the FOCUSED client; idle mirrors
  /// letterbox to this grid on their side. If multiple clients are focused
  /// (focus races during handoff), pick the SMALLEST focused grid so no focused
  /// client is ever clipped, breaking ties by lowest clientID for determinism.
  /// If NO client is focused (all idle), fall back to the smallest grid of all so
  /// nobody is clipped. Returns nil when there are no clients (session detached).
  public func arbitrateSize(_ clients: [MirrorClient]) -> (cols: Int, rows: Int)? {
      guard !clients.isEmpty else { return nil }
      let focused = clients.filter { $0.focused }
      let pool = focused.isEmpty ? clients : focused
      // smallest area, tiebreak on (cols, rows, clientID) for a total order
      let chosen = pool.min { a, b in
          let aa = a.cols * a.rows, ba = b.cols * b.rows
          if aa != ba { return aa < ba }
          if a.cols != b.cols { return a.cols < b.cols }
          if a.rows != b.rows { return a.rows < b.rows }
          return a.clientID < b.clientID
      }!
      return (chosen.cols, chosen.rows)
  }
  ```
2. - [ ] Run `swift run halo selfcheck` — it should still pass (no self-check yet). This confirms the new file compiles into `HaloMux`.
3. - [ ] Append the self-check to the SAME file. It pins every branch of the policy:
  ```swift
  public func sizeArbitrationSelfCheck() {
      // No clients → nil (session detached).
      assert(arbitrateSize([]) == nil, "no clients -> nil")

      // Single client → its own grid.
      assert(arbitrateSize([MirrorClient(clientID: 0, focused: true, cols: 100, rows: 40)])
             .map { [$0.cols, $0.rows] } == [100, 40], "single client uses its grid")

      // Focused beats a larger idle mirror (idle letterboxes, focused is authoritative).
      let r1 = arbitrateSize([
          MirrorClient(clientID: 0, focused: true,  cols: 80,  rows: 24),
          MirrorClient(clientID: 1, focused: false, cols: 200, rows: 60),
      ])!
      assert(r1.cols == 80 && r1.rows == 24, "focused client wins over larger idle")

      // Focused beats a SMALLER idle mirror too (we don't shrink to the idle one).
      let r2 = arbitrateSize([
          MirrorClient(clientID: 0, focused: true,  cols: 120, rows: 50),
          MirrorClient(clientID: 1, focused: false, cols: 40,  rows: 12),
      ])!
      assert(r2.cols == 120 && r2.rows == 50, "focused client wins over smaller idle")

      // Two focused (focus race) → smallest focused grid, so neither is clipped.
      let r3 = arbitrateSize([
          MirrorClient(clientID: 0, focused: true, cols: 100, rows: 40),
          MirrorClient(clientID: 1, focused: true, cols: 80,  rows: 30),
      ])!
      assert(r3.cols == 80 && r3.rows == 30, "two focused -> smallest focused")

      // All idle (nobody focused) → smallest of all, so nobody is clipped.
      let r4 = arbitrateSize([
          MirrorClient(clientID: 0, focused: false, cols: 100, rows: 40),
          MirrorClient(clientID: 1, focused: false, cols: 80,  rows: 30),
      ])!
      assert(r4.cols == 80 && r4.rows == 30, "all idle -> smallest of all")

      // Equal-area focused tie → deterministic lowest clientID.
      let r5 = arbitrateSize([
          MirrorClient(clientID: 7, focused: true, cols: 60, rows: 20),
          MirrorClient(clientID: 3, focused: true, cols: 60, rows: 20),
      ])!
      assert(r5.cols == 60 && r5.rows == 20, "equal grids resolve deterministically")

      print("sizeArbitrationSelfCheck ok")
  }
  ```
4. - [ ] Wire the call into `Sources/Halo/main.swift:8`. The line currently ends `…; browserSelfCheck()` (with M1–M3 checks already appended by earlier milestones). Append `sizeArbitrationSelfCheck()` to that same `if argv.first == "selfcheck"` list — it's callable because `halo` depends on `HaloMux`. The edited line becomes (M3's `muxProtocolSelfCheck()` etc. are already present from earlier milestones; just add the last call):
  ```swift
      _ = ghosttyConfigSelfCheck(); controlSelfCheck(); gitSelfCheck(); portsSelfCheck(); workspaceSelfCheck(); worktreeSelfCheck(); browserSelfCheck(); muxProtocolSelfCheck(); sizeArbitrationSelfCheck()
  ```
  (Keep whatever M2/M3 already inserted before `sizeArbitrationSelfCheck()`; only append the new call.)
5. - [ ] Run `swift run halo selfcheck` and confirm it prints `sizeArbitrationSelfCheck ok` and then `all self-checks ok`. If any assert fires, fix the policy in `SizeArbitration.swift`, not the test.
6. - [ ] `git commit -m "M4: size-arbitration policy + self-check (focused-wins, letterbox idle)"`.

### Task 4.3: `halod` multi-client per `paneID` + apply size policy
**Files:** Modify `Sources/halod/` — the daemon's per-session type and accept loop created in M3 (M3's session type owns the `forkpty`'d PTY master + libvterm; its connection-handling registers/deregisters clients). Anchor edits to M3's "register a client for paneID", "broadcast `Output` to attached clients", and "handle a `Resize` frame" sites. Test target: hands-on (Task 4.7) — a live PTY can't be unit-tested headless.
**Interfaces:**
- Consumes: `MirrorClient`, `arbitrateSize` (Task 4.2); `ClientFrame.focus(Bool)` (Task 4.1); M3's session type (call it `Session` here — use M3's actual name) with its PTY fd, libvterm instance, and `Snapshot` builder.
- Produces: a per-`Session` client list keyed by a daemon-assigned `clientID: Int`, each carrying `(focused: Bool, cols: Int, rows: Int)`; `Session.applyArbitratedSize()` that calls `arbitrateSize` then `TIOCSWINSZ` + libvterm resize. Task 4.4/4.5 (relay/GUI) drive the `focus`/`resize` frames.

1. - [ ] In M3's session type, replace the single-client assumption with a client list. M3 stored at most one attached writer fd per session; change it to an array. Add (next to M3's PTY/libvterm fields):
  ```swift
      // M4: multiple clients may attach to one paneID (mirroring).
      struct Client { let id: Int; var fd: Int32; var focused: Bool; var cols: Int; var rows: Int }
      private var clients: [Client] = []
      private var nextClientID = 0
  ```
2. - [ ] Add (or adapt M3's) attach/detach methods to append/remove a client and return its id. New clients start `focused: false`; the relay sends a `focus(true)` immediately if its surface is key (Task 4.5):
  ```swift
      /// Register a newly-attached client (its Hello cols/rows). Returns its id.
      func addClient(fd: Int32, cols: Int, rows: Int) -> Int {
          let id = nextClientID; nextClientID += 1
          clients.append(Client(id: id, fd: fd, focused: false, cols: cols, rows: rows))
          applyArbitratedSize()
          return id
      }
      /// Drop a client (relay died / pane closed / detach). Reaps PTY only on shell exit, not here.
      func removeClient(id: Int) {
          clients.removeAll { $0.id == id }
          applyArbitratedSize()
      }
  ```
3. - [ ] Make M3's PTY-output forward fan out to every client instead of one. At M3's "shell wrote bytes → send `Output`" site, replace the single-fd write with:
  ```swift
      // Broadcast one Output frame to all attached clients (mirroring).
      let frame = encode(ServerFrame.output(chunk))
      for c in clients { _ = writeAll(c.fd, frame) }   // writeAll = M3's full-buffer socket write
  ```
  (Input stays unchanged: M3 already writes any client's `Input{bytes}` into the single PTY master, so input-from-any already works — note this in the commit. Use M3's exact `writeAll`/socket-write helper.)
4. - [ ] Add `applyArbitratedSize()` to the session, using Task 4.2's policy. It maps the client list to `[MirrorClient]`, asks `arbitrateSize`, and applies the result to the one shared PTY + libvterm:
  ```swift
      /// Pick the grid from the focused client (idle mirrors letterbox) and apply it
      /// to the single shared PTY + libvterm. No-op when no clients are attached.
      func applyArbitratedSize() {
          let infos = clients.map { MirrorClient(clientID: $0.id, focused: $0.focused, cols: $0.cols, rows: $0.rows) }
          guard let (cols, rows) = arbitrateSize(infos) else { return }
          var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
          _ = ioctl(ptyMaster, TIOCSWINSZ, &ws)        // ptyMaster = M3's PTY master fd
          vterm_set_size(vterm, Int32(rows), Int32(cols))   // M3's libvterm handle resize call
      }
  ```
  (Use M3's exact PTY-fd field name and M3's libvterm resize call; the shape is `set_size(rows, cols)`.)
5. - [ ] Handle the new `focus` frame and route `resize` per-client. At M3's "decoded a `ClientFrame`" switch (where M3 handles `.input/.resize/.detach/.kill/.list`), update the connection's client entry by id. For `.resize`, update THAT client's stored cols/rows (not the global PTY directly) then re-arbitrate; add a `.focus` branch:
  ```swift
      case .resize(let cols, let rows):
          if let i = session.clientIndex(id: thisClientID) {
              session.setClientGrid(id: thisClientID, cols: cols, rows: rows)
          }
      case .focus(let on):
          session.setClientFocus(id: thisClientID, focused: on)
  ```
  And add the two mutators to the session (each re-arbitrates):
  ```swift
      func clientIndex(id: Int) -> Int? { clients.firstIndex { $0.id == id } }
      func setClientGrid(id: Int, cols: Int, rows: Int) {
          guard let i = clientIndex(id: id) else { return }
          clients[i].cols = cols; clients[i].rows = rows
          applyArbitratedSize()
      }
      func setClientFocus(id: Int, focused: Bool) {
          guard let i = clientIndex(id: id) else { return }
          clients[i].focused = focused
          applyArbitratedSize()
      }
  ```
  (`thisClientID` is the id returned by `addClient` for this connection; store it in M3's per-connection state. Keep M3's `.detach/.kill/.list` branches unchanged except that `.detach` now calls `removeClient(id: thisClientID)`.)
6. - [ ] On connection teardown (relay socket closed / EOF), call `session.removeClient(id: thisClientID)` at M3's connection-cleanup site, so a dead mirror stops counting toward arbitration and the surviving mirror's size takes over. Confirm the PTY is NOT reaped here (M3 reaps only on shell `Exited`).
7. - [ ] Build: `swift build` and confirm `halod` compiles. (No headless test — verified live in Task 4.7.)
8. - [ ] `git commit -m "M4: halod broadcasts to multiple clients per paneID; size follows focused client"`.

### Task 4.4: `halo-attach` reports focus + drains/forwards while mirrored
**Files:** Modify `Sources/halo-attach/` — the relay's frame-send path created in M3 (where it sends `Hello`, pumps stdin→`Input`, forwards SIGWINCH→`Resize`). Test target: hands-on (Task 4.7).
**Interfaces:**
- Consumes: `ClientFrame.focus(Bool)`, `encode(_:ClientFrame)` (Task 4.1); M3's relay socket + its stdin/SIGWINCH pumps.
- Produces: a way to push a `focus` frame on demand — `halo-attach` reads a focus signal from its controlling surface. Mechanism: a `SIGUSR1`/`SIGUSR2` pair (USR1 = focused, USR2 = idle) sent by the GUI to the relay's pid; relay translates each to `encode(ClientFrame.focus(true/false))` on the daemon socket. Task 4.5 sends those signals.

1. - [ ] In M3's relay main, after the initial `Hello` is sent and the socket pumps are set up, install two signal handlers that flip a focus flag and forward a `focus` frame. Use `DispatchSourceSignal` (the relay already has a run loop / dispatch sources from M3's stdin+socket pumps):
  ```swift
      // M4: GUI signals focus changes to this relay; forward them as focus frames.
      signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN)
      let focusOn  = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
      let focusOff = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
      focusOn.setEventHandler  { sendToDaemon(encode(ClientFrame.focus(true)))  }
      focusOff.setEventHandler { sendToDaemon(encode(ClientFrame.focus(false))) }
      focusOn.resume(); focusOff.resume()
  ```
  (`sendToDaemon` = M3's helper that writes a framed `ClientFrame` to the daemon socket; use M3's exact name. `SIG_IGN` first so a signal arriving before the source resumes doesn't kill the process.)
2. - [ ] Confirm M3's reconnect path re-asserts focus: when the relay reconnects after a daemon socket blip (M3's backoff path), it re-sends `Hello`; have it also re-send the last known focus state so the new daemon-side `clientID` isn't stuck idle. At M3's "reconnected, re-sent Hello" site add:
  ```swift
      sendToDaemon(encode(ClientFrame.focus(lastFocused)))   // lastFocused: Bool, default false, set by the USR1/USR2 handlers
  ```
  (Store `lastFocused` as a top-level `var` the handlers set: USR1 → `lastFocused = true`, USR2 → `lastFocused = false`.)
3. - [ ] Build: `swift build`, confirm `halo-attach` compiles.
4. - [ ] `git commit -m "M4: halo-attach reports focus to daemon via SIGUSR1/2"`.

### Task 4.5: `TerminalPane` → relay focus signalling
**Files:** Modify `Sources/Halo/TerminalPane.swift` — `becomeFirstResponder()` (`:305`), `resignFirstResponder()` (`:311`), and the surface-spawn area in `init` (`:48–60`). Test target: hands-on (Task 4.7).
**Interfaces:**
- Consumes: `paneID` (M3's `TerminalPane.paneID`); the relay's `SIGUSR1/2` focus protocol (Task 4.4).
- Produces: `TerminalPane` sends `SIGUSR1` (focused) / `SIGUSR2` (idle) to its relay's pid on focus changes. Daemon already maps those to the focused client (Tasks 4.3/4.4).

1. - [ ] Get the relay's pid. ghostty owns the spawned `config.command` process; expose its pid via `ghostty_surface_foreground_pid` is the *foreground* pid (the shell under the relay), not the relay itself — so instead track the relay pid Halo can signal. Add a stored property near `:35`:
  ```swift
      /// PID of the halo-attach relay process backing this pane's surface, captured
      /// once the surface reports it. nil until the relay is running (M3 sets it from
      /// the surface's spawned-command pid callback).
      private var relayPID: pid_t?
  ```
  (M3 already spawns `halo-attach <paneID>` as the surface command; it must surface the spawned command's pid. If M3 exposed it through a ghostty callback or a side-channel, capture it into `relayPID` at that callback. Anchor: M3's "surface spawned `halo-attach`, here is its pid" hook.)
2. - [ ] Add a helper that signals the relay:
  ```swift
      /// Tell the relay whether this mirror is focused, so the daemon picks this
      /// client's grid (idle mirrors letterbox). No-op until the relay pid is known.
      private func signalFocus(_ focused: Bool) {
          guard let pid = relayPID else { return }
          kill(pid, focused ? SIGUSR1 : SIGUSR2)
      }
  ```
3. - [ ] Call it from the existing first-responder overrides. In `becomeFirstResponder()` at `:305`, after `ghostty_surface_set_focus(surface, true)`, add `signalFocus(true)`. In `resignFirstResponder()` at `:311`, after `ghostty_surface_set_focus(surface, false)`, add `signalFocus(false)`. (These already fire on every focus change in `PaneTree.restyle()` → `focusContent()`.)
4. - [ ] Build: `swift build`, confirm the `halo` target compiles.
5. - [ ] `git commit -m "M4: TerminalPane signals focus/idle to its relay on first-responder changes"`.

### Task 4.6: GUI "mirror here" — open an existing `paneID` in a new pane
**Files:** Modify `Sources/Halo/PaneTree.swift` (`makeTerminalLeaf(cwd:)` `:311`, and add a `mirrorFocused`/`mirror(paneID:)` entry next to `splitFocused` `:200`); `Sources/Halo/TerminalPane.swift` `init` (`:37`, the `paneID` arg M3 added); `Sources/Halo/Tabs.swift` (add a `Workspace.mirror(paneID:)` that the switcher calls, next to `newSession` `:115`). Test target: hands-on (Task 4.7).
**Interfaces:**
- Consumes: M3's `TerminalPane.init(id:theme:cwd:paneID:)` (M3 added the `paneID` arg, default `UUID().uuidString`); M3's spawn that runs `halo-attach <paneID>`; the M2 switcher overlay (the action list shown on prefix-`s`/Cmd-K).
- Produces: `PaneTree.mirrorFocused(paneID:)` (splits next to focus, reusing `paneID`); `Workspace.mirror(paneID:)`; a switcher action "mirror here" that calls it. Daemon (Task 4.3) sees a second client for that `paneID` and broadcasts to both.

1. - [ ] Let `makeTerminalLeaf` accept an explicit `paneID` so a mirror reuses an existing session's id. Change the signature at `:311` from `private func makeTerminalLeaf(cwd: String?) -> Leaf` to `private func makeTerminalLeaf(cwd: String?, paneID: String? = nil) -> Leaf`, and at the `TerminalPane(id:theme:cwd:)` construction inside it pass the id through:
  ```swift
          let pane = TerminalPane(id: id, theme: theme, cwd: cwd, paneID: paneID ?? UUID().uuidString)
  ```
  (M3 added the `paneID:` parameter to `TerminalPane.init`. When `paneID` is nil this is a fresh session; when non-nil it reattaches an existing daemon session — a live mirror.)
2. - [ ] Add a public mirror entry on `PaneTree` next to `splitFocused` (`:200`). It splits beside the focused pane but reuses the given id:
  ```swift
      /// Open an existing session (`paneID`) as a second pane next to the focused
      /// one — a live mirror. The daemon broadcasts that paneID's output to both.
      @discardableResult
      func mirrorFocused(paneID: String) -> TerminalPane {
          let newLeaf = makeTerminalLeaf(cwd: nil, paneID: paneID)
          splitAndAttach(newLeaf, split: .vertical)
          return newLeaf.content as! TerminalPane
      }
  ```
3. - [ ] Expose the focused pane's `paneID` so the switcher can offer "mirror this session here". Add to `PaneTree`'s public API near `focusedCwd` (`:371`):
  ```swift
      /// The focused pane's stable session id (for "mirror here"). nil if a browser leaf is focused.
      var focusedPaneID: String? { focused?.paneID }
  ```
  (`focused` is the focused `TerminalPane?` at `:144`; `paneID` is M3's property.)
4. - [ ] Add the workspace-level action the switcher invokes. Next to `newSession(_:)` (`Tabs.swift:115`):
  ```swift
      /// Mirror an existing session (by paneID) as a new pane in the active session.
      /// Used by the switcher's "mirror here" action — both panes show the same shell.
      func mirror(paneID: String) {
          activeTree.mirrorFocused(paneID: paneID)
          handleChange()
      }
  ```
5. - [ ] Wire the switcher action. The M2 switcher (prefix-`s`/Cmd-K overlay over all sessions) lists sessions and jumps on Enter; add a secondary action "mirror here" (e.g. Cmd-Enter, or an inline button) that, instead of `selectSession`, reads the highlighted row's `paneID` and calls `workspace.mirror(paneID:)` on the *active* window's workspace. Anchor: M2's switcher row model and its Enter handler. Each switcher row must carry the session's `focusedPaneID` (extend M2's row struct with `paneID: String?` if it doesn't already; populate it from each `PaneTree.focusedPaneID`). On the mirror action: `guard let pid = row.paneID else { return }; ws.mirror(paneID: pid); dismissSwitcher()`.
6. - [ ] Build: `swift build`, confirm everything compiles. (Live behavior verified in Task 4.7.)
7. - [ ] `git commit -m "M4: switcher 'mirror here' action opens an existing paneID as a second pane"`.

### Task 4.7: Hands-on mirror + letterbox verification
**Files:** None (manual verification of Tasks 4.1–4.6). This is the milestone's live-PTY acceptance gate; the pure-logic gate is `sizeArbitrationSelfCheck` (Task 4.2).
**Interfaces:** Consumes the whole M4 stack end to end.

1. - [ ] Build and launch a clean instance from the build dir so `halo-attach`/`halod` resolve beside the binary (matches `muxHelperPath()`'s `executableURL.deletingLastPathComponent()`):
  ```
  swift build && pkill -f halod; pkill -x halo; .build/debug/halo
  ```
  (Kill any stale `halod` so a v1 daemon from an earlier milestone doesn't answer the v2 handshake — you'd see a clean `NeedsUpdate`, not a crash, but start fresh.)
2. - [ ] In the running app, open one session and run a long-lived program in it, e.g. type `htop` (or `watch -n1 date`) and Enter, so there's continuously-changing output. Note this session is one pane backed by one `paneID`.
3. - [ ] Open the switcher (prefix-`s` or Cmd-K), highlight that session, and trigger the new **"mirror here"** action (Cmd-Enter / the mirror button from Task 4.6). Observe: a second pane appears split beside the first, showing the **same** `htop`/clock output live — not a fresh shell prompt. This confirms `mirror(paneID:)` reused the id and the daemon (Task 4.3) registered a second client and is broadcasting.
4. - [ ] Type in the **left** pane (e.g. press `q` to quit htop, then type `echo from-left` and Enter). Observe the `echo` and its output appear in **both** panes identically. Then focus the **right** pane (click it) and type `echo from-right` + Enter; observe it too appears in both. This confirms input-from-any (Task 4.3) and output broadcast.
5. - [ ] Verify the focus→size policy. Make the window wide, then drag the divider so the two mirror panes are clearly different widths. Click the **narrow** pane to focus it: observe the shared shell reflows to the **narrow** pane's column count, and the **wide** (now idle) pane letterboxes (its extra columns show as empty margin, content not stretched). Click the **wide** pane: the shell reflows to the wide grid and the narrow pane's content is the one clipped/letterboxed. This is the `arbitrateSize` focused-wins policy (Task 4.2) driven by the real `SIGUSR1/2` focus signals (Tasks 4.4/4.5). Capture a screenshot of each focus state for the record.
6. - [ ] Close one mirror pane (Cmd-W on the focused mirror — close = detach for that client, per the M3 detach-on-close UX). Observe the surviving pane keeps running the same shell, and (if the survivor had a different size) the shell reflows to the survivor's grid — confirming `removeClient` re-arbitrates (Task 4.3 step 6). The shell is reaped only when you actually exit it (type `exit` in the survivor).
7. - [ ] Record the outcome (pass/fail per step + the two focus-state screenshots) in the PR description. No commit (verification only).

## Milestone 5 — Remote attach

Goal: `halo attach ssh://host[:port] [session]`. Parse the ssh URL, decide whether to deploy the helper binaries (version-probe the remote `halod`; deploy over `scp` if missing or skewed), then run `halod` on the host and stream the **same** wire frames over an SSH-forwarded unix socket (`ssh -L`-style stdio forward to a remote unix socket). The protocol is transport-agnostic, so the only new code is: a `ssh://` URL parser, a deploy-decision function, and an `attach` CLI verb that wires those to `ssh`/`scp` subprocesses. No raw TCP listener (out of scope). Two pure-logic self-checks ship: `RemoteAttachSelfCheck()` covers ssh-URL parse and the deploy decision.

All new code lives in the `HaloMux` target (pure Swift, no AppKit) so the parser/decision are unit-checkable, plus one new file in the `halo` target for the CLI verb that shells out to `ssh`/`scp`. Consumes from Milestone 3's Shared Contract: `muxProtocolVersion` (`Sources/HaloMux/MuxProtocol.swift`), `MuxPaths.daemonSocket` (`Sources/HaloMux/MuxPaths.swift`), and the existing `halo-attach`/`halod` binaries beside the running executable.

---

### Task 5.1: `RemoteTarget` — ssh-URL parser (pure logic)
**Files:** Create `Sources/HaloMux/RemoteAttach.swift`. Test target: wired into `halo selfcheck` via `Sources/Halo/main.swift:8`.
**Interfaces:**
- Consumes: nothing (leaf module).
- Produces: `public struct RemoteTarget: Equatable { let user: String?; let host: String; let port: Int; let session: String? }` and `public func parseRemoteURL(_ s: String, session: String?) -> RemoteTarget?`. Task 5.2 (deploy decision) and Task 5.4 (CLI verb) consume these.

Steps:

1. - [ ] Create `Sources/HaloMux/RemoteAttach.swift` with the type and a stub parser that returns `nil`, plus a failing self-check stub:
   ```swift
   import Foundation

   /// A parsed `ssh://[user@]host[:port]` remote-attach destination.
   public struct RemoteTarget: Equatable {
       public let user: String?     // ssh login user, nil = ssh default
       public let host: String      // hostname or IP
       public let port: Int         // ssh port, 22 if unspecified
       public let session: String?  // optional named session on the remote
       public init(user: String?, host: String, port: Int, session: String?) {
           self.user = user; self.host = host; self.port = port; self.session = session
       }
   }

   /// Parse `ssh://[user@]host[:port]`. Returns nil if the scheme isn't ssh,
   /// the host is empty, or the port is non-numeric/out of range.
   /// `session` is the optional positional arg passed after the URL on the CLI.
   public func parseRemoteURL(_ s: String, session: String?) -> RemoteTarget? {
       return nil   // replaced in step 3
   }

   public func RemoteAttachSelfCheck() {
       // ssh-URL parse
       assert(parseRemoteURL("ssh://example.com", session: nil)
              == RemoteTarget(user: nil, host: "example.com", port: 22, session: nil))
       assert(parseRemoteURL("ssh://bob@10.0.0.5:2222", session: "build")
              == RemoteTarget(user: "bob", host: "10.0.0.5", port: 2222, session: "build"))
       assert(parseRemoteURL("ssh://[::1]:22", session: nil)
              == RemoteTarget(user: nil, host: "::1", port: 22, session: nil))
       assert(parseRemoteURL("http://example.com", session: nil) == nil)   // wrong scheme
       assert(parseRemoteURL("ssh://", session: nil) == nil)               // empty host
       assert(parseRemoteURL("ssh://host:notaport", session: nil) == nil)  // bad port
       print("RemoteAttachSelfCheck ok")
   }
   ```

2. - [ ] Wire `RemoteAttachSelfCheck()` into the self-check list at `Sources/Halo/main.swift:8`, appending it after `browserSelfCheck()` so the call line reads `… ; browserSelfCheck(); RemoteAttachSelfCheck()`. Add `import HaloMux` at the top of `main.swift` if M3 has not already added it (it has, per the Shared Contract — only add if missing).

3. - [ ] Run `swift run halo selfcheck` and SEE IT FAIL (assertion trap in `RemoteAttachSelfCheck`, because `parseRemoteURL` returns `nil`).

4. - [ ] Replace the stub body of `parseRemoteURL` with the real implementation:
   ```swift
   public func parseRemoteURL(_ s: String, session: String?) -> RemoteTarget? {
       let prefix = "ssh://"
       guard s.hasPrefix(prefix) else { return nil }
       var rest = String(s.dropFirst(prefix.count))   // [user@]host[:port]
       guard !rest.isEmpty else { return nil }

       var user: String?
       if let at = rest.firstIndex(of: "@") {
           user = String(rest[..<at])
           rest = String(rest[rest.index(after: at)...])
       }

       var host = rest
       var port = 22
       if rest.hasPrefix("[") {                       // bracketed IPv6: [::1][:port]
           guard let close = rest.firstIndex(of: "]") else { return nil }
           host = String(rest[rest.index(after: rest.startIndex)..<close])
           let after = rest[rest.index(after: close)...]
           if after.hasPrefix(":") {
               guard let p = Int(after.dropFirst()), p > 0, p <= 65535 else { return nil }
               port = p
           } else if !after.isEmpty {
               return nil
           }
       } else if let colon = rest.lastIndex(of: ":") {
           host = String(rest[..<colon])
           let portStr = rest[rest.index(after: colon)...]
           guard let p = Int(portStr), p > 0, p <= 65535 else { return nil }
           port = p
       }
       guard !host.isEmpty else { return nil }
       return RemoteTarget(user: user, host: host, port: port, session: session)
   }
   ```

5. - [ ] Run `swift run halo selfcheck` and SEE IT PASS (prints `RemoteAttachSelfCheck ok` then `all self-checks ok`).

6. - [ ] `git commit -m "M5: ssh:// remote-target parser + self-check"`.

---

### Task 5.2: Deploy decision (pure logic)
**Files:** Modify `Sources/HaloMux/RemoteAttach.swift` (same file as Task 5.1; append below the parser). Test target: same `RemoteAttachSelfCheck()`.
**Interfaces:**
- Consumes: `muxProtocolVersion` from `Sources/HaloMux/MuxProtocol.swift` (M3 contract).
- Produces: `public enum RemoteProbe: Equatable { case missing; case version(Int) }` and `public func shouldDeploy(_ probe: RemoteProbe) -> Bool`, plus `public func parseProbeOutput(_ raw: String) -> RemoteProbe`. Task 5.4 consumes both.

Steps:

1. - [ ] Append failing assertions to `RemoteAttachSelfCheck()` (before the final `print`):
   ```swift
       // remote-deploy decision: present && versionOK -> skip, else deploy
       assert(shouldDeploy(.missing) == true)
       assert(shouldDeploy(.version(muxProtocolVersion + 1)) == true)   // skew -> deploy
       assert(shouldDeploy(.version(muxProtocolVersion - 1)) == true)   // skew -> deploy
       assert(shouldDeploy(.version(muxProtocolVersion)) == false)      // match -> skip
       // probe output parsing (helper prints "halod-proto <N>" or nothing)
       assert(parseProbeOutput("halod-proto \(muxProtocolVersion)\n") == .version(muxProtocolVersion))
       assert(parseProbeOutput("  halod-proto 7  ") == .version(7))
       assert(parseProbeOutput("") == .missing)
       assert(parseProbeOutput("bash: halod: command not found") == .missing)
   ```

2. - [ ] Run `swift run halo selfcheck` and SEE IT FAIL (the new symbols don't compile / assertions trap once stubbed).

3. - [ ] Append the real implementation to `Sources/HaloMux/RemoteAttach.swift`:
   ```swift
   /// Result of probing the remote helper's protocol version.
   public enum RemoteProbe: Equatable {
       case missing            // helper not installed / not on PATH
       case version(Int)       // installed, reports this muxProtocolVersion
   }

   /// Parse the remote probe command's stdout. The probe runs
   /// `halod --proto-version` on the host, which prints `halod-proto <N>`.
   /// Anything else (empty, "command not found", garbage) => .missing.
   public func parseProbeOutput(_ raw: String) -> RemoteProbe {
       let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
       let token = "halod-proto "
       guard let r = trimmed.range(of: token) else { return .missing }
       let after = trimmed[r.upperBound...].prefix { $0.isNumber }
       guard let n = Int(after) else { return .missing }
       return .version(n)
   }

   /// Deploy decision: keep the remote helper iff it's present AND its protocol
   /// version exactly matches ours. Missing or any skew => redeploy over scp.
   public func shouldDeploy(_ probe: RemoteProbe) -> Bool {
       switch probe {
       case .missing:          return true
       case .version(let v):   return v != muxProtocolVersion
       }
   }
   ```

4. - [ ] Run `swift run halo selfcheck` and SEE IT PASS (prints `RemoteAttachSelfCheck ok` then `all self-checks ok`).

5. - [ ] `git commit -m "M5: remote-deploy decision + probe parsing + self-check"`.

---

### Task 5.3: `halod --proto-version` probe flag
**Files:** Modify `Sources/halod/main.swift` (the `halod` executable entrypoint created in M3). Cite the argument-dispatch area near the top of `halod`'s `main.swift` where it reads `CommandLine.arguments`.
**Interfaces:**
- Consumes: `muxProtocolVersion` (M3 contract).
- Produces: a `halod --proto-version` invocation that prints `halod-proto <muxProtocolVersion>` and exits 0 — the exact string `parseProbeOutput` (Task 5.2) expects. Task 5.4's probe step depends on this output format.

Steps:

1. - [ ] Read `Sources/halod/main.swift` and locate where it begins (the M3 daemon reads `CommandLine.arguments` to get its socket/run mode). Confirm there is a top-of-file argument check before the daemon event loop starts.

2. - [ ] Add a probe short-circuit as the FIRST thing in `Sources/halod/main.swift`, before any socket bind or fork:
   ```swift
   // Version probe for `halo attach ssh://…` deploy decision. Must run without
   // touching the socket so a remote one-shot `halod --proto-version` is cheap.
   if CommandLine.arguments.dropFirst().first == "--proto-version" {
       print("halod-proto \(muxProtocolVersion)")
       exit(0)
   }
   ```
   (Ensure `import HaloMux` is present at the top of `halod`'s `main.swift` — M3 already imports it.)

3. - [ ] Run `swift build` and SEE IT SUCCEED. Then run `swift run halod --proto-version` and SEE IT PRINT exactly `halod-proto 1` (matching `muxProtocolVersion`). Confirm the daemon does NOT bind its socket or block — the command returns immediately.

4. - [ ] Verify round-trip against the parser by hand: `swift run halod --proto-version` output fed conceptually to `parseProbeOutput` yields `.version(1)`. (This is already asserted in Task 5.2's self-check via the literal string; this step is the live confirmation the daemon emits that exact literal.)

5. - [ ] `git commit -m "M5: halod --proto-version probe flag"`.

---

### Task 5.4: `halo attach ssh://…` CLI verb (subprocess orchestration)
**Files:** Create `Sources/Halo/RemoteAttachCLI.swift` (in the `halo` target; it shells out to `ssh`/`scp`, so it's not headless-testable and stays out of `HaloMux`). Modify `Sources/Halo/main.swift` to dispatch the `attach` verb before the control-verb dispatch at `Sources/Halo/main.swift:19`.
**Interfaces:**
- Consumes: `parseRemoteURL`, `RemoteProbe`, `parseProbeOutput`, `shouldDeploy` (Tasks 5.1–5.2); `MuxPaths.daemonSocket` is the LOCAL socket — but the remote path is computed independently here (the remote `$HOME/.local/share/halo/halod.sock`); `muxHelperPath()` (M3, in `TerminalPane.swift`) to find the local `halo-attach`/`halod` binaries to scp.
- Produces: `func runRemoteAttach(_ args: [String]) -> Int32` and the `attach` verb dispatch. This is the milestone's user-facing entrypoint; nothing later consumes it.

Steps:

1. - [ ] Add the verb dispatch in `Sources/Halo/main.swift`, immediately after the `help` block and BEFORE the `controlVerbs` block at line 19:
   ```swift
   if argv.first == "attach" {
       exit(runRemoteAttach(Array(argv.dropFirst())))
   }
   ```

2. - [ ] Create `Sources/Halo/RemoteAttachCLI.swift` with the orchestration. It (a) parses the URL, (b) probes the remote `halod`, (c) scp's both helper binaries if `shouldDeploy`, (d) execs the local `halo-attach` pointed at the remote daemon over an `ssh -W`/forwarded-socket transport. Because `halo-attach` (M3) speaks the wire protocol over a unix socket fd, here we hand it an `ssh` stdio bridge to the remote socket via `ssh … 'socat - UNIX-CONNECT:<remote.sock>'`-style relay; the SAME frames flow unchanged.
   ```swift
   import Foundation
   import HaloMux

   // Remote layout on the host (created by deploy). Owner-only by ssh's umask;
   // we also chmod the bin after scp. Socket lives under the remote XDG dir.
   private let remoteBinDir = ".local/bin"
   private let remoteHalod = ".local/bin/halod"
   private let remoteAttach = ".local/bin/halo-attach"
   private let remoteSocket = ".local/share/halo/halod.sock"

   /// `halo attach ssh://[user@]host[:port] [session]`
   /// Parses the URL, self-deploys the helper if missing/skewed, then streams the
   /// SAME wire frames over an SSH-forwarded unix socket. No raw TCP (out of scope).
   func runRemoteAttach(_ args: [String]) -> Int32 {
       guard let url = args.first else {
           FileHandle.standardError.write(Data("halo attach: usage: halo attach ssh://host[:port] [session]\n".utf8))
           return 1
       }
       let session = args.count > 1 ? args[1] : nil
       guard let target = parseRemoteURL(url, session: session) else {
           FileHandle.standardError.write(Data("halo attach: bad ssh url: \(url)\n".utf8))
           return 1
       }

       // ssh destination args reused for every hop.
       let dest = target.user.map { "\($0)@\(target.host)" } ?? target.host
       let sshBase = ["-p", String(target.port),
                      "-o", "BatchMode=no",            // allow password/2FA prompts
                      "-o", "ConnectTimeout=10"]

       // 1) Probe the remote helper's protocol version.
       let probeOut = runCapturing("/usr/bin/ssh",
           sshBase + [dest, "halod --proto-version 2>/dev/null || true"])
       let probe = parseProbeOutput(probeOut)

       // 2) Deploy if missing or version-skewed.
       if shouldDeploy(probe) {
           FileHandle.standardError.write(Data("halo attach: deploying helper to \(dest)…\n".utf8))
           guard deployHelpers(dest: dest, sshBase: sshBase) == 0 else {
               FileHandle.standardError.write(Data("halo attach: deploy failed\n".utf8))
               return 1
           }
       }

       // 3) Stream. The remote halod is started on demand by the relay command;
       //    halo-attach connects to the forwarded socket and pumps the SAME frames.
       //    `ssh -tt` gives us a pty bridge so stdin/stdout are byte-transparent.
       //    The remote command ensures halod is running, then bridges the socket.
       let relay =
           "\(remoteHalod) --ensure >/dev/null 2>&1; " +
           "exec \(remoteAttach) \(target.session ?? "")".trimmingCharacters(in: .whitespaces)
       let code = execForeground("/usr/bin/ssh",
           sshBase + ["-tt", dest, relay])
       return code
   }

   /// scp the local halod + halo-attach beside the running binary to the remote
   /// ~/.local/bin, then chmod +x. Returns 0 on success.
   private func deployHelpers(dest: String, sshBase: [String]) -> Int32 {
       let here = Bundle.main.executableURL!.deletingLastPathComponent()
       let localHalod = here.appendingPathComponent("halod").path
       let localAttach = here.appendingPathComponent("halo-attach").path

       // scp uses -P (capital) for port; pull it out of sshBase.
       let portIdx = sshBase.firstIndex(of: "-p")
       let port = portIdx.map { sshBase[sshBase.index(after: $0)] } ?? "22"

       // Ensure remote dirs exist (0700 dir for socket parent, bin dir).
       if execForeground("/usr/bin/ssh",
           sshBase + [dest, "mkdir -p \(remoteBinDir) && mkdir -p -m 700 .local/share/halo"]) != 0 {
           return 1
       }
       for local in [localHalod, localAttach] {
           let name = (local as NSString).lastPathComponent
           if execForeground("/usr/bin/scp",
               ["-P", port, local, "\(dest):\(remoteBinDir)/\(name)"]) != 0 {
               return 1
           }
       }
       return execForeground("/usr/bin/ssh",
           sshBase + [dest, "chmod 700 \(remoteHalod) \(remoteAttach)"])
   }

   /// Run a process, capture stdout as a String (used for the version probe).
   private func runCapturing(_ launchPath: String, _ args: [String]) -> String {
       let p = Process()
       p.executableURL = URL(fileURLWithPath: launchPath)
       p.arguments = args
       let pipe = Pipe()
       p.standardOutput = pipe
       p.standardError = FileHandle.nullDevice
       do { try p.run() } catch { return "" }
       let data = pipe.fileHandleForReading.readDataToEndOfFile()
       p.waitUntilExit()
       return String(decoding: data, as: UTF8.self)
   }

   /// Run a process with inherited stdio (interactive ssh/scp), return exit code.
   private func execForeground(_ launchPath: String, _ args: [String]) -> Int32 {
       let p = Process()
       p.executableURL = URL(fileURLWithPath: launchPath)
       p.arguments = args
       do { try p.run() } catch {
           FileHandle.standardError.write(Data("halo attach: cannot exec \(launchPath): \(error)\n".utf8))
           return 1
       }
       p.waitUntilExit()
       return p.terminationStatus
   }
   ```

3. - [ ] Run `swift build` and SEE IT SUCCEED. (No daemon/ssh runs yet — this only confirms the verb dispatch and subprocess code compile against the M5 pure-logic symbols and M3's `MuxPaths`/binaries.)

4. - [ ] Hands-on (localhost-over-ssh), part A — deploy path. Ensure local `sshd` is reachable (`System Settings ▸ General ▸ Sharing ▸ Remote Login` ON) and the helper is NOT yet on the remote PATH: run `rm -f ~/.local/bin/halod ~/.local/bin/halo-attach`. Then run `swift run halo attach ssh://localhost`. OBSERVE on stderr: `halo attach: deploying helper to localhost…`, then the scp transfers complete, then an interactive session attaches. Confirm `ls -l ~/.local/bin/halod ~/.local/bin/halo-attach` shows both present with mode `700`.

5. - [ ] Hands-on, part B — skip path. Run `swift run halo attach ssh://localhost` a SECOND time. OBSERVE that NO `deploying helper` line prints (probe returned `.version(1)`, `shouldDeploy` is false), and it attaches directly. This confirms the deploy decision short-circuits when present && version-matched.

6. - [ ] Hands-on, part C — persistence across local-app death. With a remote session attached via `halo attach ssh://localhost`, in the remote shell run `echo REMOTE_ALIVE > /tmp/halo-remote-marker && sleep 600 &`. Detach (Cmd-W / Ctrl-C the local `halo attach`). Re-run `swift run halo attach ssh://localhost` and confirm the SAME session reattaches with the `sleep` still running (`jobs` shows it) and scrollback intact — the remote `halod` kept it alive. This is the "kill local app, remote session persists" check from the milestone goal.

7. - [ ] Hands-on, part D — version-skew redeploy. Simulate skew: edit `~/.local/bin/halod` on the remote to a stale build that reports a different `halod-proto` (or temporarily `chmod 000` it so the probe reads `.missing`). Run `swift run halo attach ssh://localhost` and OBSERVE the `deploying helper` line reappears — skew/missing forces redeploy, never a corrupt stream (the `needsUpdate`/`helloAck` handshake from M3 is the in-band backstop if a stale binary slips through).

8. - [ ] `git commit -m "M5: halo attach ssh:// verb — probe, self-deploy, forwarded-socket stream"`.

---

### Task 5.5: Help text + usage for `attach`
**Files:** Modify `Sources/Halo/Control.swift` `printUsage()` (`Sources/Halo/Control.swift:234`) to document the new top-level verb.
**Interfaces:** Consumes nothing new; produces only doc text. No self-check (pure string).

Steps:

1. - [ ] In `printUsage()` (`Sources/Halo/Control.swift:234`), under the `Usage:` block (after the `halo help` line, near `Sources/Halo/Control.swift:241`), add:
   ```
         halo attach ssh://host[:port] [session]   attach to a session on another machine
   ```
   and append a short note after the `Socket:` line near `Sources/Halo/Control.swift:269`:
   ```
       Remote: `halo attach ssh://host` self-deploys halod/halo-attach over scp
               when missing/outdated (SSH-forwarded unix socket; no TCP listener).
   ```

2. - [ ] Run `swift run halo help` and SEE the new `attach` line and remote note in the output.

3. - [ ] Run `swift run halo selfcheck` and SEE IT still print `all self-checks ok` (no regression).

4. - [ ] `git commit -m "M5: document halo attach ssh:// in usage"`.
