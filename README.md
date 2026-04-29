<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty for Windows
</h1>
  <p align="center">
    Native Windows port of the Ghostty terminal emulator.
    <br />
    <a href="#status">Status</a>
    ·
    <a href="#building">Building</a>
    ·
    <a href="#keyboard-shortcuts">Shortcuts</a>
    ·
    <a href="#configuration">Configuration</a>
    ·
    <a href="https://ghostty.org/docs">Upstream Docs</a>
  </p>
</p>

## About

This is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds **native Windows support** via a Win32 application runtime. It runs as a standalone `.exe` — no WSL, no Cygwin, no compatibility layers.

The goal is to track the upstream main branch while maintaining a native Windows port that leverages Ghostty's cross-platform core (terminal emulation, renderer, font system).

> **Upstream Ghostty** supports Linux (GTK) and macOS natively. This fork adds a `win32` application runtime alongside those existing backends. See the [upstream repository](https://github.com/ghostty-org/ghostty) for the original project.

## Status

**Feature-complete** — 100% apprt action coverage (65/65 actions handled). The terminal is ready for daily use.

### Features

**Terminal**
- Full VT sequence support with OpenGL 4.6 rendering (WGL)
- FreeType + HarfBuzz fonts with DirectWrite system font discovery
- ConPTY shell spawning (cmd.exe, PowerShell, WSL)
- Win32 Input Mode (mode 9001) for full Unicode through ConPTY
- IME support for CJK input (Japanese, Chinese, Korean)
- Per-monitor DPI awareness, window resize with grid reflow
- 463 built-in color themes (same as macOS)

**Windows & Tabs**
- Multiple windows, tabbed interface with custom GDI tab bar
- Tab drag-and-drop reorder, inline rename (double-click), right-click context menu
- Close tab modes: current, all others, all to the right

**Split Panes**
- Split right/down/left/up, navigate between panes
- Mouse drag to resize dividers, double-click to equalize
- Toggle split zoom, equalize all splits
- Independent split tree per tab

**Extras**
- Command palette with filterable actions and keybinding hints
- Quick terminal (slide-in/out from screen edge with global hotkey)
- Find-in-terminal search bar
- URL detection with Ctrl+click to open in browser
- Desktop notifications (OSC 9, OSC 777)
- Background opacity, fullscreen, window decorations toggle
- Font size zoom with inheritance to new tabs/splits
- Config hot-reload, scrollbar
- DWM dark/light chrome and Win11 22H2+ caption color matching the
  configured background
- Shell integration for PowerShell (prompt marking, CWD, title)
- Drag a file from Explorer onto the terminal to paste its path
- Visual bell (taskbar flash) when BEL fires on an unfocused window
- Taskbar flash when a command exits non-zero in an unfocused window
- Confirm-close dialog when a programmatic close hits a tab with a
  running command
- Auto-update check against GitHub releases (rate-limited to once per
  hour); clicking the "Update available" balloon opens the releases
  page in your browser
- Horizontal scroll wheels / trackpad gestures (`WM_MOUSEHWHEEL`)

### Platform-Specific Notes

- Inspector (debug overlay) — acknowledged but no Win32 UI yet
- `undo`/`redo` — macOS NSUndoManager only, no Win32 equivalent
- `secure_input` — macOS EnableSecureEventInput only
- Release build + installer (MSI/MSIX) — not yet packaged

## Building

Requires [Zig](https://ziglang.org/download/) 0.15.2 or newer.

### Cross-compile from Linux/WSL2

```bash
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows
```

The executable is at `zig-out/bin/ghostty.exe`. Copy it to a Windows path and run it.

### Release build

```bash
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

To debug a release build with stderr visible, add `-Dwindows-console=true`
— it links against `/SUBSYSTEM:CONSOLE` instead of the default Windows
GUI subsystem so the process gets a console attached.

## Keyboard Shortcuts

All keybindings are configurable via the `keybind` config option. These are the defaults:

### General

| Action | Shortcut |
|--------|----------|
| New window | `Ctrl+Shift+N` |
| Close surface (tab/pane) | `Ctrl+Shift+W` |
| Close window | `Ctrl+Shift+Q` |
| Toggle fullscreen | `Ctrl+Enter` |
| Command palette | `Ctrl+Shift+P` |
| Open config file | `Ctrl+,` |
| Reload config | `Ctrl+Shift+,` |
| Quit | `Ctrl+Shift+Q` |

### Tabs

| Action | Shortcut |
|--------|----------|
| New tab | `Ctrl+Shift+T` |
| Next tab | `Ctrl+Page Down` |
| Previous tab | `Ctrl+Page Up` |
| Go to tab 1–8 | `Ctrl+1` – `Ctrl+8` |
| Go to last tab | `Ctrl+9` |
| Move tab left | `Ctrl+Shift+Page Up` |
| Move tab right | `Ctrl+Shift+Page Down` |
| Drag reorder | Mouse drag on tab |
| Rename tab | Double-click tab |
| Tab context menu | Right-click tab |

### Split Panes

| Action | Shortcut |
|--------|----------|
| Split right | `Ctrl+Shift+O` |
| Split down | `Ctrl+Shift+E` |
| Focus next pane | `Ctrl+Shift+]` |
| Focus previous pane | `Ctrl+Shift+[` |
| Equalize splits | Configurable (`equalize_splits`) |
| Toggle split zoom | Configurable (`toggle_split_zoom`) |
| Resize split | Mouse drag on divider |
| Equalize split | Double-click divider |

### Text & Clipboard

| Action | Shortcut |
|--------|----------|
| Copy | `Ctrl+Shift+C` |
| Paste | `Ctrl+Shift+V` |
| Select all | `Ctrl+Shift+A` |
| Find | `Ctrl+Shift+F` |
| Find next | `Enter` (in search bar) |
| Find previous | `Shift+Enter` (in search bar) |
| Close search | `Escape` |

### Font Size

| Action | Shortcut |
|--------|----------|
| Increase font size | `Ctrl+=` |
| Decrease font size | `Ctrl+-` |
| Reset font size | `Ctrl+0` |

### Mouse

| Action | Gesture |
|--------|---------|
| Vertical scroll | Mouse wheel |
| Horizontal scroll | Trackpad swipe / horizontal wheel |
| Drag-select | Left-click drag |
| Open URL | `Ctrl+Click` on a detected URL |
| Middle-click paste | Middle button (configurable via `middle-click-action`) |
| Drop file | Drag a file from Explorer onto the terminal — its path is pasted |

### Quick Terminal

The quick terminal requires a keybinding in your config:

```
keybind = global:ctrl+grave_accent=toggle_quick_terminal
```

The `global:` prefix makes it work system-wide, even when Ghostty isn't focused.

## Configuration

Ghostty reads its config file from `%LOCALAPPDATA%\ghostty\config` (or `%XDG_CONFIG_HOME%\ghostty\config` if set). Example:

```
# Font
font-family = JetBrains Mono
font-size = 14

# Colors
background = #1e1e2e
foreground = #cdd6f4

# Shell
command = powershell.exe

# Behavior
quit-after-last-window-closed = true

# Quick terminal (global hotkey)
keybind = global:ctrl+grave_accent=toggle_quick_terminal
```

See the [upstream documentation](https://ghostty.org/docs/config) for the full list of config options. Most settings work on Windows — the exceptions are platform-specific options (GTK, macOS).

## Architecture

The Windows port adds a `win32` application runtime (`src/apprt/win32/`) alongside the existing GTK (Linux) and AppKit (macOS) runtimes. It reuses Ghostty's cross-platform core:

- **Terminal emulation**: Shared VT parser, screen, scrollback (`src/terminal/`)
- **Rendering**: OpenGL 4.3+ with WGL context management (`src/renderer/`)
- **Fonts**: FreeType rasterization + HarfBuzz shaping + DirectWrite discovery (`src/font/`)
- **PTY**: Windows ConPTY via `CreatePseudoConsole` (`src/pty.zig`)
- **I/O**: libxev with IOCP backend (`src/termio/`)

### Key files

```
src/apprt/win32/
  App.zig             — Win32 message loop, window classes, action dispatch
  Window.zig          — Top-level container HWND, tab bar, splits, tab lifecycle
  Surface.zig         — WS_CHILD HWND, WGL context, input, clipboard, search, command palette
  QuickTerminal.zig   — Quick terminal popup with slide animation
  win32.zig           — Win32 API type definitions and extern declarations

src/shell-integration/powershell/
  ghostty-shell-integration.ps1  — PowerShell prompt marking, CWD, title
```

## Testing

A test harness runs from WSL2 using PowerShell automation:

```bash
bash test/win32/ghostty_test.sh all
```

25+ automated tests cover: launch/close, window properties, keyboard input, multiple windows, clipboard, config loading, scrollbar, close confirmation, URL detection, notifications, window sizing, window resize (real assertion), search bar, config reload, tabs (new/switch/close), opacity, command palette, tab drag reorder, inline tab rename, split panes, font zoom, fullscreen toggle, open config, and quick terminal.

Tab and split tests run in PowerShell sessions:

```bash
powershell.exe -ExecutionPolicy Bypass -File test/win32/test_tabs.ps1 -ExePath path\to\ghostty.exe
powershell.exe -ExecutionPolicy Bypass -File test/win32/test_splits.ps1 -ExePath path\to\ghostty.exe
```

## Syncing with Upstream

This fork tracks `ghostty-org/ghostty` main branch. To sync:

```bash
git remote add upstream https://github.com/ghostty-org/ghostty.git
git fetch upstream
git merge upstream/main
```

`git rerere` is enabled in the local repo so previously-resolved
conflict resolutions get re-applied automatically on subsequent merges.

When resolving conflicts, default to **keep upstream** for any file
outside `src/apprt/win32/`, `dist/windows/`, or `test/win32/`. The
`.win32` switch arms (`.none, .win32 => void` and similar) need to be
preserved in upstream switches that handle apprt variants.

Files most likely to conflict on upstream merges:
- `src/Surface.zig`, `src/config/Config.zig`, `src/font/discovery.zig`,
  `src/font/DeferredFace.zig`, `src/font/backend.zig`
- Switch-arm files: `src/apprt/runtime.zig`, `src/apprt.zig`,
  `src/datastruct/split_tree.zig`, `src/input/Binding.zig`,
  `src/font/face.zig`, `src/terminal/mouse.zig`

## License

Same as upstream Ghostty — see [LICENSE](LICENSE).
