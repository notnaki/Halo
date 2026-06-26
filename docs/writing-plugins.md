# Writing Halo plugins

A Halo plugin is just a folder with an `init.lua`. No build step, no packaging.
This page is the full API reference; `examples/starter/` is a working plugin you
can copy and trim.

## Your first plugin

```
~/.config/halo/plugins/hello/
  init.lua
```

```lua
-- init.lua
halo.command("hello", function()
  halo.notify("hello from my plugin")
end)
halo.bind("cmd+shift+h", function() halo.notify("hi") end)
```

Reload (`halo reload`) and it's live. That's the whole contract: a folder under
`~/.config/halo/plugins/`, with an `init.lua` (or `plugin/init.lua`) that runs
with the `halo` global available.

## Installing & sharing

- **Drop-in:** put a folder in `~/.config/halo/plugins/`.
- **Declared:** in your own `~/.config/halo/init.lua`, call
  `halo.plugin("owner/repo")` — Halo clones it from GitHub into `plugins/` on
  first run. A full git URL or local path works too.
- **Pinning:** `halo.plugin("owner/repo", { ref = "v1.2.0", priority = 10 })`.
  `ref` is a tag/branch/commit; `priority` sets load order (higher first, ties by
  name). Resolved commits are written to `plugins.lock`.
- **Enable/disable:** `halo plugins`, `halo plugins disable <name>`,
  `halo plugins enable <name>` (or the Settings UI). Disabled names live in
  `~/.config/halo/plugins/disabled-plugins`.

A plugin is a git repo + `init.lua` — to share one, push it and hand over the
URL. (A discovery registry is planned but not built yet.)

### manifest.lua (optional)

```lua
return { version = "1.0.0", priority = 0 }
```

## API reference

### Building blocks

| Call | Description |
|------|-------------|
| `halo.command(name, fn)` | Register a named command (runnable from a keybind or CLI). |
| `halo.bind(chord, fn)` | Keybind, e.g. `"cmd+shift+p"`. |
| `halo.on(event, fn)` | Register an event handler (see Events). |
| `halo.timer(seconds, fn)` | Call `fn` every `seconds` (repeating). |
| `halo.set(key, value)` | Override a config value (Halo or ghostty key). |
| `halo.plugin(repo [, opts])` | Declare a plugin dependency (clone/pin). |

### Acting on the terminal

| Call | Description |
|------|-------------|
| `halo.send(text)` | Send text/keystrokes to the active pane. |
| `halo.active()` | `{ cwd, title, paneID }` of the focused pane, or `nil`. |
| `halo.capture([scrollback])` | Focused pane's text as a string. |
| `halo.state()` | The full project/session tree as a table. |
| `halo.split([horizontal])` | Split the focused pane. |
| `halo.tab([action])` | `"new"` / `"next"` / `"prev"`. |
| `halo.select(project, session)` | Jump to a session by index. |
| `halo.zoom()` | Toggle zoom on the focused pane. |
| `halo.open(path)` | Open a file. |
| `halo.browser([url])` | Open a browser pane. |
| `halo.focus([id])` | Focus a pane by id, or the active one. |
| `halo.cmd(verb, ...args)` | Low-level: run any control verb, returns a table. |

### UI

| Call | Description |
|------|-------------|
| `halo.notify(msg)` | Transient toast. |
| `halo.status(text)` | Set the chrome status text. |
| `halo.prompt(message [, default], fn)` | Free-text input; `fn(text)`. |
| `halo.confirm(message, fn)` | Yes/No; `fn(true\|false)`. |
| `halo.pick(items, fn)` | Single-select; `fn(label)`. Items are strings or `{ label, desc }`. |
| `halo.pickmulti(items, fn)` | Multi-select (Tab marks); `fn(table_of_labels)`. |
| `halo.menu(items)` | Action list; each item `{ text, desc, action = fn }` runs its own `action`. |
| `halo.panel(lines, opts)` | Create/update a floating panel → returns its `id`. |
| `halo.close(id)` | Close a panel. |

**Panels.** `lines` is an array; each line is one of:
- a string, or `{ text = , color = "#rrggbb" }` — a label,
- `{ text = , color = , click = fn }` — a clickable button,
- `{ input = true, placeholder = , action = fn }` — an editable field;
  `action(text)` fires on Enter.

`opts = { title, corner = "topright"|"topleft"|"bottomright"|"bottomleft",
bg = "#rrggbb", width, id, window = "active"|"all" }`. Pass a previous `id` to
update a panel in place. `window = "all"` renders it in every window; the default
follows the active window.

### Events

Register with `halo.on(name, fn)`. Handlers receive the relevant `paneID`
(except `config-reloaded`).

| Event | When |
|-------|------|
| `config-reloaded` | After init/plugins (re)load. |
| `dir-changed` | The focused pane's working dir changed. |
| `command-finished` | A foreground program returned to the shell. |
| `session-opened` | A new session was created. |
| `focus-changed` | The active session changed. |
| `session-closed` | The user closed a session. |
| `session-exited` | A shell exited on its own. |
| `pane-output` | Raw output bytes from any live pane: `fn(paneID, chunk)`. |

`pane-output` fires for **every** live pane and hands you raw bytes (binary-safe;
use `chunk:find(needle, 1, true)`). It's best-effort and coalesced under load, and
only works in persist mode (the default) where a daemon owns the PTY.

## Safety

Plugins can't crash Halo:
- Every callback is error-isolated; an error shows a toast.
- A plugin whose callback errors 5 times in a row is **auto-disabled** (re-enable
  with `halo plugins enable <name>`).
- A callback stuck in an infinite loop is **aborted** by an instruction-budget
  guard rather than freezing the UI.

Scrollback is persisted to disk by the daemon, so a pane's history survives a
daemon restart or reboot — nothing to do from a plugin.

See `examples/starter/init.lua` for all of the above in one runnable file.
