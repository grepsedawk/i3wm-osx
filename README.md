# i3wm-osx

A tiling window manager for macOS that reads i3 config files and behaves like i3wm.

## Status

**Early prototype.** Targets the [grepsedawk i3 config](https://github.com/grepsedawk/.dotfiles/blob/master/.i3/config) as its compatibility benchmark.

What works:

- Tree-based tiling (splith, splitv, tabbed, stacking) with i3 layout semantics
- Numbered workspaces with `workspace_auto_back_and_forth`
- Multi-monitor "outputs"
- i3 config parser: `set $var`, `bindsym`, `exec[_always]`, `for_window`, `mode`, gaps, colors, `floating_modifier`, bar block
- i3 command parser/executor for: `focus`, `move`, `split`, `layout`, `workspace`, `kill`, `exec`, `fullscreen`, `floating`, `gaps`, `mode`, `resize`, `reload`, `restart`, `exit`
- Global hotkeys via `CGEventTap` (Mod4 → Command, Mod1 → Option)
- i3 IPC over UNIX socket with `i3-msg` companion CLI (`RUN_COMMAND`, `GET_WORKSPACES`, `GET_OUTPUTS`, `GET_TREE`, `GET_VERSION`)
- Status bar across the top of every monitor with workspace pills + status command output (Dracula theme)
- Floating windows toggle, smart gaps, inner/outer gaps

What doesn't work yet:

- Scratchpad
- Marks / `[con_mark=…]` criteria
- Stacking layout titlebars are minimal
- Window borders (we set `default_border none`, which matches the target config)
- `move scratchpad`, `sticky`, `urgent` hint
- Spaces (macOS Spaces) integration — windows are placed on the current macOS Space; we don't move them across Spaces
- `restart` does not preserve in-place state; it re-execs from scratch

## Setup (do these once, in order)

```bash
# 1. One-time: create a self-signed code-signing identity so macOS TCC
#    remembers your Accessibility / Input Monitoring grant across rebuilds.
#    Without this, every `swift build` changes the binary's cdhash and macOS
#    re-prompts you to grant access. macOS will ask for your login keychain
#    password during this step.
./setup-signing.sh

# 2. Build & package as a proper .app so TCC has a stable identity to grant.
./build-app.sh                  # produces build/i3wm-osx.app

# 3. Drop a config file (i3 syntax). This file is intentionally separate
#    from ~/.i3/config — modifier defaults, available exec commands, and
#    special keys differ on macOS.
mkdir -p ~/.config/i3wm-osx
cp examples/config-macos ~/.config/i3wm-osx/config
```

Now grant permissions to **the app bundle** (not your terminal):

1. **Accessibility**: System Settings → Privacy & Security → Accessibility → click `+` → navigate to `~/Code/i3wm-osx/build/i3wm-osx.app` → enable. **Remove any stale `Alacritty` / `Terminal` entry that was added by mistake** — TCC does not auto-clean those, and a wrongly-granted terminal will make the prompt name *that* app every time you run from it.
2. **Input Monitoring**: same thing for the global hotkey tap.

## Running

```bash
open build/i3wm-osx.app           # detaches from your shell, no terminal in TCC chain
# or, with stderr visible:
build/i3wm-osx.app/Contents/MacOS/i3wm-osx
```

The first thing the daemon prints to stderr is a diagnostic block telling you what's working:

```
[i3wm-osx] Accessibility trust: GRANTED
[i3wm-osx] screens: 2 — Built-in Retina Display, Studio Display
[i3wm-osx] scanned: 17 windows across 2 output(s)
[i3wm-osx] hotkey tap: INSTALLED
[i3wm-osx] bar windows: 2
[i3wm-osx] IPC listening on /tmp/i3wm-osx-alex.sock
```

If trust is DENIED and you grant it after launch, the daemon polls every 2 seconds and re-bootstraps automatically — you don't need to restart it.

## Notes on the config

i3 conventions are preserved as written:

| i3 keyword       | macOS modifier (default)                      |
|------------------|-----------------------------------------------|
| `Mod4` / `super` | ⌥ Option (override via `I3WM_OSX_MOD4=command`) |
| `Mod1`           | ⌥ Option (override via `I3WM_OSX_MOD1=command`) |
| `cmd` / `command`| ⌘ Command                                     |
| `option` / `alt` | ⌥ Option                                      |
| `Control`        | ⌃ Control                                     |
| `Shift`          | ⇧ Shift                                       |

Valid override values: `command`, `option`, `control`, `shift`. Set via env var when launching, e.g. `I3WM_OSX_MOD4=command open build/i3wm-osx.app`.

Linux-only commands like `pactl`, `rofi`, `xmodmap` will simply fail to exec; replace them with macOS equivalents in your config (e.g. `osascript`, `choose`, etc.).

## Scripts

- `setup-signing.sh` — one-time. Mints a self-signed code-signing identity so the `.app` keeps a stable cdhash across rebuilds. Without it, every rebuild invalidates your TCC grants.
- `build-app.sh` — main build path. Compiles via SwiftPM, assembles `build/i3wm-osx.app`, codesigns with the identity from `setup-signing.sh` (or ad-hoc with a warning).
- `scripts/dev-run.sh` — dev convenience. `swift build -c release` + execs the bare binary against `~/.i3/config` (or the bundled example). Skips the `.app` bundle, so it does **not** get TCC permissions — useful only when iterating on code that doesn't need AX.
- `scripts/macos-tune-animations.sh on|off` — disables (or restores) macOS-wide window/Dock animations so workspace switches feel like i3 on Linux. Affects every app, not just i3wm-osx.

## Architecture

- `App.swift` — top-level coordinator
- `AX.swift` / `Window.swift` — Accessibility API wrappers
- `Tree.swift` — i3-style container tree with layout computation
- `WindowManager.swift` — observes new windows, places them in the tree, applies layouts
- `Workspace.swift` — workspaces and outputs (monitors)
- `Config.swift` — i3 config parser
- `Commands.swift` — i3 command parser and executor
- `Hotkey.swift` — CGEventTap-based global hotkey daemon
- `IPC.swift` — i3 IPC server
- `Bar.swift` — top-of-screen status bar
