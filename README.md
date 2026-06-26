<p align="center">
  <img src="assets/halo-logo.svg" width="120" alt="Halo logo">
</p>

<h1 align="center">Halo</h1>

<p align="center">A native macOS terminal for running AI coding agents in parallel —<br>built on real <a href="https://ghostty.org">libghostty</a>, driven by a scriptable CLI.</p>

---

Halo is a Swift/AppKit terminal that links **GhosttyKit.xcframework** (it is not
a Ghostty fork). It renders with Ghostty's Metal engine, reads your existing
`~/.config/ghostty/config` as-is, and adds a project sidebar, tmux-style splits,
and an agent-control CLI on top.

## Highlights

- **Real libghostty** — Ghostty 1.3.2 Metal renderer, your ghostty config and
  theme, zero reimplemented terminal logic.
- **Persistent sessions (tmux-style)** — shells survive Halo quitting and
  reattach cleanly. A small daemon (`halod`) holds the PTYs; panes connect
  through a relay (`halo-attach`). Prefix-key mode + a fuzzy session switcher.
- **Projects → sessions sidebar** — vertical, drag-resizable. Each project owns
  sessions; rename / recolor / remove from the right-click menu.
- **Native splits** — `⌘D` / `⌘⇧D`, click-to-focus, zoom, drag dividers.
- **Scriptable** — the `halo` CLI drives and reads the live UI over a Unix
  socket, so agents can orchestrate it.
- **Everything from your config** — colors, fonts, sidebar width, divider width
  are all `halo-*` keys in the same ghostty config file. Empty config = sane
  defaults.

## Build & run

```sh
swift build
.build/arm64-apple-macosx/debug/halo            # run the app (dev)
swift run halo selfcheck                          # pure-logic checks
./install.sh                                      # symlink `halo` → /usr/local/bin (CLI)

./make-app.sh                                     # build Halo.app (double-clickable, logo icon)
open Halo.app                                     # launch the bundle
```

> The raw debug binary is bundle-less and dies if its launching shell exits (use
> `nohup .build/.../halo & disown`). **`./make-app.sh`** packages a proper
> `Halo.app` — logo dock icon, "Halo" menu, double-click launch, detached
> lifetime. The binary is self-contained (ghostty is statically linked).

## The `halo` CLI

Drives the running app over `~/Library/Application Support/halo/control.sock`.
`halo help` is authoritative; the common verbs:

```sh
halo help                       # list every verb + config key
halo open <path>                # new session at <path>
halo split -v | -h              # split the focused pane (side-by-side / stacked)
halo new-pane --cwd <path>      # new pane in a dir
halo focus <id> | halo focus next
halo zoom                       # toggle zoom on the focused pane
halo close                      # close the focused pane
halo send-keys <target> <text>  # type into a pane (target = pane id or "focused")
halo capture                    # dump the focused pane's screen
halo list                       # JSON: sessions + panes + focus
halo tab new|next|prev|<n>      # session control
halo sessions                   # list daemon-held sessions (incl. detached)
halo kill <id>                  # end a session's shell (by paneID)
```

## Multiplexer & sessions

Shells run under a small daemon (`halod`), not the app, so they **survive Halo
quitting** and **reattach cleanly**. The daemon owns one `forkpty`'d shell per
pane and keeps the last ~256 KB of its raw output; on attach it replays those
bytes and ghostty re-renders them — colors, cursor, full-screen apps and all
(no separate screen model, so nothing to garble). On by default; set
`halo-persist = false` for plain non-persistent shells.

What you get:

- **Survive quit** — `⌘Q`, reopen Halo: panes come back with their shells and
  recent output.
- **Detach, don't kill** — `⌘W` (pane) / `⌘⇧W` (session) detaches; the shell
  keeps running under `halod`. Reopen it from the switcher.
- **Switcher** — `⌘K` (or prefix-`s`): fuzzy-filter every session across
  windows/projects, including detached ones. Enter to jump.
- **Prefix mode** — tmux muscle memory. Press the prefix (`ctrl+b` by default,
  `halo-prefix`), then a key (table below). Empty `halo-prefix` disables it.
- **Explicit kill** — prefix-`x`, or `halo kill <id>` — when you actually mean
  to end the shell.

### Verify it works

```sh
# 1. survive quit
#    in a pane:   echo i-was-here && date
#    ⌘Q, reopen Halo.app → the pane shows that output again.

# 2. detach / reattach
#    ⌘W the pane (shell keeps running), ⌘K → pick it → output replays.

# 3. from the CLI, watch the daemon hold sessions
halo sessions            # lists live + detached sessions with attach counts
halo kill <id>           # ends one for real
```

If a pane ever says "daemon protocol … update Halo", an **old `halod` from a
previous build** is still running (`pkill -f halod`, then relaunch) — the
daemon is single-instance per user.

### Prefix keytable (after `ctrl+b`)

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| `%` | split vertical | `c` | new session |
| `"` | split horizontal | `n` / `p` | next / prev session |
| `h j k l` / arrows | focus pane | `,` | rename session |
| `z` | zoom pane | `s` | switcher |
| `d` | detach pane | `x` | kill shell |

Override bindings with `halo-prefix-bind = key=action, …` in your ghostty config.

## Configuration

Halo reads `halo-*` keys from your ghostty config (libghostty ignores them).
Standard ghostty keys (`theme`, `background`, `foreground`, `cursor-color`,
`palette = N=#hex`) apply live. Every `halo-*` default matches the built-in
look, so an untouched config changes nothing.

| Key | Default | Meaning |
|-----|---------|---------|
| `halo-accent` | theme accent | accent color (rings, dots, focus ticks) |
| `halo-surface` | theme background | base surface color |
| `halo-sidebar-width` | 240 | sidebar open width (px) |
| `halo-font-family` | Geist Mono | chrome label font |
| `halo-font-mono` | Martian Mono | mono font |
| `halo-font-size` | 13 | chrome font size |
| `halo-divider-width` | 8 | split divider grab width (1px hairline drawn) |
| `halo-projects` | — | comma-separated project paths to preload |
| `halo-persist` | true | run shells under `halod` (survive quit); `false` = plain shells |
| `halo-persist-scrollback` | false | mirror scrollback to disk so it survives a daemon restart. **Off by default** — terminal output can contain secrets (see [SECURITY.md](SECURITY.md)) |
| `halo-prefix` | ctrl+b | prefix key for tmux-style mode; empty = disabled |
| `halo-prefix-bind` | — | override prefix bindings: `key=action, …` |

## Keybindings

| Keys | Action |
|------|--------|
| `⌘D` / `⌘⇧D` | split vertical / horizontal |
| `⌘W` / `⌘⇧W` | close pane / close session |
| `⌘T` | new session in active project (cwd `~`) |
| `⌘]` | focus next pane |
| `⌘{` / `⌘}` | previous / next session |
| `⌘1`–`⌘9` | select session N |
| `⌘B` | toggle sidebar |
| `⌘K` | session switcher (fuzzy, incl. detached) |
| `ctrl+b` then a key | prefix mode (see Multiplexer & sessions) |

Click a pane to focus it; click a project to expand it; right-click a project
to rename / recolor / remove it. `⌘W` / `⌘⇧W` **detach** (the shell lives on
under `halod`) rather than killing — see Multiplexer & sessions.

## Architecture

- `Sources/Halo/Ghostty/` — libghostty init, config sync, runtime callbacks.
- `TerminalPane.swift` — a ghostty surface (input / IME / mouse / resize / cwd / title).
- `PaneTree.swift` — tmux-style splits as nested `NSSplitView`s.
- `Tabs.swift` — the `Workspace` model: projects own sessions.
- `Chrome.swift` — window, titlebar, sidebar rendering.
- `Control.swift` — the `halo` CLI + socket server.
- `GhosttyConfig.swift` — `Theme` + `HaloConfig` (the `halo-*` keys).
- `Git.swift` — branch / status, shelled out off-main.
- `PrefixMode.swift` / `Switcher.swift` — tmux-style prefix mode + fuzzy session switcher.
- `Sources/halod/` — the session daemon: one `forkpty`'d shell per pane + a raw
  output ring, replayed on attach. No terminal parsing (ghostty does that).
- `Sources/halo-attach/` — the per-pane relay ghostty spawns as its command;
  a dumb byte pump between the pane and the daemon over a `0600` unix socket.
- `Sources/HaloMux/` — shared wire protocol (`MuxProtocol`) + paths (`MuxPaths`).

## Roadmap

Designs live in `docs/superpowers/specs/`. Shipped: **persistent sessions**
(`2026-06-25-mux-rawring-rewrite.md`) — `halod`/`halo-attach` raw-ring
multiplexer, prefix mode, switcher. Deferred there: mirroring (one session in
two panes), remote attach (`halo attach ssh://`), disk-spill scrollback, and
inline-image replay across detach. Also in flight: **cmux parity**
(`2026-06-22-cmux-parity-design.md`) — worktree-isolated sessions, attention
rings, richer sidebar, embedded browser pane.

## Self-checks

```sh
.build/arm64-apple-macosx/debug/halo selfcheck   # config, control, git, workspace, chrome
```
