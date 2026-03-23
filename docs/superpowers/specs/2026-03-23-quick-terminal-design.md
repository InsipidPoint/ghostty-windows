# Quick Terminal — Win32 Implementation Design

## Overview

Implement the `toggle_quick_terminal` action for the Win32 apprt. This is a borderless popup window that slides in/out from a screen edge with a global hotkey, providing instant terminal access from any application.

## Architecture

### New File: `src/apprt/win32/QuickTerminal.zig`

Owns a dedicated `Window` instance configured for quick terminal behavior. Managed by `App`, which holds an optional `?*QuickTerminal`.

**State:**
- `window: *Window` — the underlying window (borderless WS_POPUP)
- `visible: bool` — whether the quick terminal is currently shown
- `animating: bool` — whether an animation is in progress
- `animation_progress: f64` — 0.0 (hidden) to 1.0 (fully visible)
- `animation_direction: enum { in, out }` — current animation direction
- `animation_start_time: i64` — QueryPerformanceCounter timestamp
- `target_rect: RECT` — final position when fully visible
- `hidden_rect: RECT` — off-screen position when hidden
- `position: QuickTerminalPosition` — top/bottom/left/right/center from config

**Lifecycle:**
1. First `toggle_quick_terminal` → `QuickTerminal.init()` creates Window + Surface, animates in
2. Subsequent toggles → animate in/out, reuse existing window
3. Shell exit / surface close → destroy QuickTerminal, set `app.quick_terminal = null`, next toggle creates fresh
4. App shutdown → destroy if exists

### Separation from Normal Windows

- QuickTerminal is NOT added to `App.windows` list
- `App` holds `quick_terminal: ?*QuickTerminal` separately
- The QuickTerminal's Window uses `WS_POPUP` instead of `WS_OVERLAPPEDWINDOW`
- Tab bar is suppressed (single surface, no tabs)
- No splits support in quick terminal
- Quit timer check: `app.windows.items.len == 0 and app.quick_terminal == null` (must account for quick terminal when deciding whether to quit)

## Window Behavior

### Style
- Creation style: `WS_POPUP` only (no `WS_VISIBLE` — window is shown explicitly via `ShowWindow` during animation)
- Extended style: `WS_EX_TOOLWINDOW` to hide from taskbar and Alt+Tab

### Z-Order
- `HWND_TOPMOST` — quick terminal stays above other windows at all times (matches macOS `.floating` level)

### Screen Selection
- `main` (default): primary monitor via `MonitorFromPoint({0,0}, MONITOR_DEFAULTTOPRIMARY)`
- `mouse`: monitor under cursor via `MonitorFromPoint(cursor_pos, MONITOR_DEFAULTTONEAREST)`
- Recalculate target monitor on each `animateIn()` (handles monitor connect/disconnect)

### Size
- Respects `quick-terminal-size` config (DPI-scaled using `GetDpiForWindow`)
- Default: full monitor work area width, 400 DPI-scaled pixels height (for top/bottom positions)
- For left/right: 400 DPI-scaled pixels width, full monitor work area height

## Animation

### Mechanism
- Uses `QueryPerformanceCounter` / `QueryPerformanceFrequency` for precise timing
- `SetTimer()` with ~16ms interval (~60fps) drives the animation loop
- Timer ID: `QUICK_TERMINAL_ANIM_TIMER_ID = 3` (alongside existing QUIT_TIMER_ID=1, notification cleanup=2)
- Timer is set on `msg_hwnd`; `WM_TIMER` handled in `msgWndProc`
- Each `WM_TIMER` tick: calculate elapsed time, compute eased progress, `SetWindowPos()` to interpolate position

### Easing Function
Cubic ease-in-out:
```
if t < 0.5: 4 * t^3
else: 1 - (-2t + 2)^3 / 2
```

### Duration
- Reads `quick-terminal-animation-duration` config (default: 0.2 seconds)
- If duration is 0, snap instantly (no timer)

### Position Calculations

Given monitor work area `(mx, my, mw, mh)` and quick terminal size `(qw, qh)`:

| Position | Hidden Rect | Visible Rect |
|----------|------------|--------------|
| Top | `(mx, my - qh, qw, qh)` | `(mx, my, qw, qh)` |
| Bottom | `(mx, my + mh, qw, qh)` | `(mx, my + mh - qh, qw, qh)` |
| Left | `(mx - qw, my, qw, qh)` | `(mx, my, qw, qh)` |
| Right | `(mx + mw, my, qw, qh)` | `(mx + mw - qw, my, qw, qh)` |
| Center | `(mx + (mw-qw)/2, my - qh, qw, qh)` | `(mx + (mw-qw)/2, my + (mh-qh)/2, qw, qh)` |

Interpolation: `current = hidden + (visible - hidden) * eased_progress`

### Animation Flow
1. `animateIn()`: set `animation_direction = .in`, record start time, `ShowWindow(SW_SHOWNOACTIVATE)`, start timer
2. Timer tick: compute progress, `SetWindowPos()`, if progress >= 1.0 → kill timer, force foreground (see below)
3. `animateOut()`: set `animation_direction = .out`, record start time, start timer
4. Timer tick: compute progress, `SetWindowPos()`, if progress >= 1.0 → kill timer, `ShowWindow(SW_HIDE)`

### Forcing Foreground Focus

`SetForegroundWindow()` silently fails when called from a background process (flashes taskbar instead). When the quick terminal is toggled via global hotkey, Ghostty is in the background. Use the `AttachThreadInput` technique:

```
foreground_tid = GetWindowThreadProcessId(GetForegroundWindow(), null)
our_tid = GetCurrentThreadId()
AttachThreadInput(our_tid, foreground_tid, TRUE)
SetForegroundWindow(qt_hwnd)
AttachThreadInput(our_tid, foreground_tid, FALSE)
```

This is called after animation completes to give the quick terminal keyboard focus.

### Interruption
If toggle is called mid-animation, reverse direction from current progress (don't restart from 0).

## Global Hotkey

### Registration
- At `App.init()`, scan keybinds for entries with `global:` prefix bound to `toggle_quick_terminal`
- Call `RegisterHotKey(NULL, hotkey_id, modifiers, vk)` with NULL hwnd (thread-level)
- If `RegisterHotKey` fails (hotkey already taken by another app), log a warning
- Store the registration so it can be unregistered at cleanup
- Default binding (if none configured): none (user must opt-in via config)

### Message Handling
- `WM_HOTKEY` is posted to the thread's message queue (not to a specific window)
- Handle in the message loop in `App.run()` before `TranslateMessage`/`DispatchMessage`, similar to existing search key interception
- Dispatch: call `app.performAction(.app, .toggle_quick_terminal, {})`

### Unregistration
- `App.deinit()`: `UnregisterHotKey(NULL, hotkey_id)`

### Modifier Mapping
- `ctrl` → `MOD_CONTROL`
- `alt` → `MOD_ALT`
- `shift` → `MOD_SHIFT`
- `super` → `MOD_WIN`

## Autohide

- Handle `WM_ACTIVATE` with `WA_INACTIVE` in `windowWndProc` (guarded by `window.is_quick_terminal` check, consistent with existing `is_fullscreen` pattern)
- If `quick-terminal-autohide` config is true and window is visible and not animating out → animate out
- Ignore focus loss during animation (prevents flicker)
- Ignore focus loss to own child windows (e.g., if search bar is open)

## Shell Exit / Surface Close

When the quick terminal's shell exits:
1. `closeTabByIndex` is called (single tab, tab_count drops to 0)
2. Normally this posts `WM_CLOSE` → `Window.close()` → `Window.onDestroy()`
3. For quick terminal: `onDestroy()` detects `is_quick_terminal` flag
4. Instead of removing from `app.windows`, sets `app.quick_terminal = null` and frees the QuickTerminal
5. The quit timer check accounts for this: `app.windows.items.len == 0 and app.quick_terminal == null`

## Changes to Existing Files

### `App.zig`
- Add `quick_terminal: ?*QuickTerminal = null` field
- Add `global_hotkey_id: ?u32 = null` field
- Handle `.toggle_quick_terminal` in `performAction()` → delegate to `QuickTerminal.toggle()`
- Register global hotkey in `init()`
- Unregister in `deinit()`
- Handle `WM_HOTKEY` in message loop (`run()`) before `DispatchMessage`
- Handle `WM_TIMER` with `QUICK_TERMINAL_ANIM_TIMER_ID` in `msgWndProc()`
- Update quit timer check to account for quick terminal existence

### `Window.zig`
- Add `is_quick_terminal: bool = false` flag
- Skip tab bar rendering when `is_quick_terminal`
- Use `WS_POPUP` instead of `WS_OVERLAPPEDWINDOW` when `is_quick_terminal`
- Use `WS_EX_TOOLWINDOW` extended style when `is_quick_terminal`
- Handle `WM_ACTIVATE` with `WA_INACTIVE` for autohide (when `is_quick_terminal`)
- On destroy: route to `app.quick_terminal` cleanup instead of `app.windows` removal

### `win32.zig`
- Add API declarations: `RegisterHotKey`, `UnregisterHotKey`, `MonitorFromPoint`, `GetMonitorInfoW`, `MONITORINFO`, `SetTimer`, `KillTimer`, `QueryPerformanceCounter`, `QueryPerformanceFrequency`, `GetCurrentThreadId`, `AttachThreadInput`, `GetForegroundWindow`, `WM_HOTKEY`, `WM_TIMER`, `WM_ACTIVATE`, `WA_INACTIVE`, `HWND_TOPMOST`, `SWP_NOACTIVATE`, `MONITOR_DEFAULTTOPRIMARY`, `MONITOR_DEFAULTTONEAREST`, `MOD_CONTROL`, `MOD_ALT`, `MOD_SHIFT`, `MOD_WIN`, `SW_SHOWNOACTIVATE`

## Environment Variable

Set `GHOSTTY_QUICK_TERMINAL=1` on the surface's child process environment, matching macOS behavior. This lets shell scripts detect quick terminal context.

## Config Options Respected

| Config | Used For |
|--------|----------|
| `quick-terminal-position` | Slide direction and final position |
| `quick-terminal-size` | Window dimensions (DPI-scaled) |
| `quick-terminal-animation-duration` | Animation speed |
| `quick-terminal-autohide` | Hide on focus loss |
| `quick-terminal-screen` | Which monitor (`main` / `mouse`) |

## Not In Scope

- `quick-terminal-space-behavior` — macOS virtual desktop concept, no Windows equivalent
- `gtk-quick-terminal-layer` / `gtk-quick-terminal-namespace` — Wayland-specific
- `quick-terminal-keyboard-interactivity` — Wayland-specific
- Tab support in quick terminal (none on any platform)
- Split support in quick terminal (none on any platform)
- Config hot-reload of position/size while quick terminal is open (recalculates on next toggle)
