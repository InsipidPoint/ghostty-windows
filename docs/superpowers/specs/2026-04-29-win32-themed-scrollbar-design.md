# Win32 Themed Scrollbar — Design

**Status:** Design approved, ready for implementation plan
**Date:** 2026-04-29
**Author:** Shiwei Song (with Claude)

## Problem

The Windows port currently uses the native non-client `WS_VSCROLL` scrollbar
(`Surface.zig:1390`). It renders white/light grey regardless of the terminal
theme because:

1. The standard non-client scrollbar drawn by `user32.dll` is not affected by
   `SetWindowTheme(hwnd, "DarkMode_Explorer")` — that theme only re-skins
   scrollbars *inside* Explorer-style controls (ListView, TreeView).
2. Even if the app called `uxtheme!SetPreferredAppMode(AllowDark)` (ordinal
   #135) to force system-dark scrollbars, that only produces "system dark"
   (~#2B2B2B) — it cannot track arbitrary terminal theme background/foreground
   colors (gruvbox-tan, solarized-cream, etc.).

macOS Ghostty avoids this by wrapping the surface in `NSScrollView` and using
overlay `NSScroller`s, which are translucent and auto-hide on idle. There is no
Win32 equivalent of `NSScroller` that picks up our theme colors.

## Goal

Replace the native scrollbar with a custom layered-popup scrollbar painted
using the terminal's own theme colors, with behavior that honors the OS
"Always show scrollbars" accessibility setting:

- **Auto-hide (overlay) mode** when the OS prefers dynamic scrollbars (the
  Win11 default). Mac-style: invisible until the user scrolls, fades out after
  ~1s idle, expands on hover.
- **Always-visible mode** when the OS prefers always-shown scrollbars. The
  scrollbar steals one column of grid space and is always painted.

## Non-goals

- Does not replicate the macOS NSScroller blur/vibrancy effect. We use
  per-pixel alpha for translucency, but no Gaussian blur of the underlying
  content.
- Does not add horizontal scrollbar support (terminal grid is fixed-width).
- Does not add a config knob for forcing a mode — the OS setting is the source
  of truth, matching what every other Win32 app does.

## Architecture

A new module `src/apprt/win32/Scrollbar.zig` owns one scrollbar instance per
`Surface`. It registers a custom window class `GhosttyScrollbar` (once per
process) and creates a `WS_EX_LAYERED | WS_POPUP` window **owned by** the
Surface HWND (not a child of it). The scrollbar is positioned at the right
edge of the surface's client area in screen coordinates.

### Why a layered popup, not a child window

Surface.zig:231 creates the OpenGL context on the surface HWND
(`wglCreateContext(self.hdc)`). Every frame, `SwapBuffers` presents the GL
backbuffer to the entire client area — Win32's child-window clipping
(`WS_CLIPCHILDREN`) does not affect `SwapBuffers`, so a `WS_CHILD` scrollbar
would be overpainted every frame.

Layered top-level windows are composited *above* accelerated content by DWM,
so an `WS_EX_LAYERED | WS_POPUP` overlay survives. This is the standard Win32
pattern for drawing controls over OpenGL/D3D surfaces (Steam, Spotify, NVIDIA
overlay all use it).

Owned popups follow their owner: when the Surface HWND is hidden, minimized,
moved, or activated, the popup follows automatically — except for position,
which we update manually on `WM_MOVE`/`WM_SIZE` (see below). Z-order is
correct: another Ghostty window on top obscures both the surface and its
scrollbar.

### Painting via UpdateLayeredWindow

Layered windows do not use the normal `WM_PAINT` flow. Instead, paint by
constructing a 32-bit BGRA bitmap and calling `UpdateLayeredWindow` with
`ULW_ALPHA`. Per-pixel alpha lets us draw:

- A fully transparent track (alpha=0 everywhere outside the thumb).
- A translucent thumb (theme foreground at chosen alpha — e.g., 80/255 idle,
  140/255 hover, 200/255 drag).

Bitmap size for a typical surface: 14 × ~600 px = ~33 KB. Rebuilt only when
state changes, not every frame.

### Position tracking

The popup is in screen coordinates, so the Surface must keep it positioned:

- On `WM_MOVE` / `WM_SIZE` of the Surface HWND, call
  `scrollbar.repositionAndResize()` which calls `ClientToScreen` to compute
  the right-edge rect and `SetWindowPos` (with `SWP_NOACTIVATE | SWP_NOZORDER`).
- On `WM_SHOWWINDOW(false)` of the Surface, hide the popup; on
  `WM_SHOWWINDOW(true)`, reposition and re-show (subject to mode and
  visibility state).
- On surface destroy, destroy the popup first.

### Removal of existing native scrollbar

In `src/apprt/win32/Surface.zig`:

- Remove `ShowScrollBar(SB_VERT, ...)` calls in `setScrollbar()`.
- Remove the `SetScrollInfo` call.
- Remove the `WM_VSCROLL` handler (`handleVScroll`).
- Remove the cached `scrollbar_total/offset/len` fields — those move into the
  new `Scrollbar` struct.
- Add a new `scrollbar: ?*Scrollbar` field; initialize in `Surface.init` after
  the surface HWND exists.
- `setScrollbar(scrollbar)` becomes a one-liner forwarding to
  `self.scrollbar.?.update(scrollbar)`.

### Public interface of `Scrollbar`

```zig
pub const Scrollbar = struct {
    /// Allocated with surface.app.alloc; freed in destroy().
    pub fn create(alloc: Allocator, owner: HWND, surface: *Surface) !*Scrollbar;
    pub fn destroy(self: *Scrollbar) void;

    /// Surface forwards new scroll state here (called from
    /// performAction(.scrollbar)). The very first call after create()
    /// sets state silently — no fade-in. Subsequent calls trigger fade-in
    /// in overlay mode.
    pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void;

    /// Surface forwards WM_MOVE/WM_SIZE here so the popup tracks the
    /// surface's right edge. Returns the width to subtract from the grid
    /// client area (0 in overlay mode, scrollbar_width_dpi in
    /// always-visible mode).
    pub fn repositionAndResize(self: *Scrollbar) i32;

    /// Surface forwards WM_SHOWWINDOW here so the popup follows
    /// hide/show of the owner.
    pub fn setOwnerVisible(self: *Scrollbar, visible: bool) void;

    /// Surface forwards theme/config changes here.
    pub fn setTheme(self: *Scrollbar, bg: terminal.color.RGB, fg: terminal.color.RGB) void;

    /// Surface forwards WM_SETTINGCHANGE. Returns true if the mode flipped,
    /// in which case Surface should post WM_SIZE to re-flow the grid.
    pub fn onSettingsChange(self: *Scrollbar) bool;

    /// Surface forwards WM_DPICHANGED so we can recompute widths.
    pub fn onDpiChanged(self: *Scrollbar, dpi: u32) void;
};
```

### Memory ownership

The `Scrollbar` struct is heap-allocated with `surface.app.alloc` (the same
allocator used by all other Win32 apprt resources). `Surface` holds it as
`scrollbar: ?*Scrollbar`. Lifecycle:

- Created in `Surface.init` after the surface HWND exists and OpenGL is set up.
- Destroyed in `Surface.deinit` before the surface HWND is destroyed (so
  `DestroyWindow` on the popup runs while its owner still exists).

### Threading

All operations on `Scrollbar` (including `update`) run on the **main app
thread**:

- `setScrollbar` is invoked from `App.performAction(.scrollbar)`
  (`App.zig:548`), which runs on the main thread.
- `WM_PAINT`-equivalent (UpdateLayeredWindow refresh) and `WM_TIMER` for fade
  animation are dispatched by the main thread's message loop.
- The renderer thread never touches `Scrollbar`.

No synchronization needed. The spec calls this out explicitly so future
maintainers don't add locks reflexively.

### Split panes and tabs

Each `Surface` is an independent HWND with its own OpenGL context and its own
`Scrollbar` instance. Splits and tabs work for free:

- Splitting a pane creates a new Surface → new Scrollbar.
- Switching tabs: the old Surface gets `WM_SHOWWINDOW(false)`, hiding its
  scrollbar; the new Surface gets `WM_SHOWWINDOW(true)`, showing its
  scrollbar (subject to overlay visibility state).
- Resizing a split pane fires `WM_SIZE` on each affected Surface, which calls
  `repositionAndResize()` on its scrollbar.

### Scroll action callback

When the user drags the thumb or page-clicks, the scrollbar calls
`surface.scrollToRow(new_offset)` — a new tiny method on `Surface` that wraps
the same core action used by the existing `WM_VSCROLL` `SB_THUMBTRACK` handler
(`scroll_viewport` with a row offset). This preserves the existing scroll path;
we are only changing the *source* of the user input.

## Mode detection

Read `HKCU\Control Panel\Accessibility\DynamicScrollbars` (REG_DWORD) once at
scrollbar creation:

| Value | Mode |
|---|---|
| Missing or `1` | Overlay (Win11 default) |
| `0` | Always-visible |

The exact semantics will be verified empirically during implementation by
toggling Settings → Accessibility → Visual effects → "Always show scrollbars"
and reading the registry. If the mapping is reversed, the check is flipped —
no other code changes.

Re-read on `WM_SETTINGCHANGE` (forwarded from Surface) so toggling the OS
setting takes effect without restart. `onSettingsChange` returns `true` when
the mode changed; Surface responds by posting `WM_SIZE` to itself with the
current client dimensions so the standard resize path runs (which calls
`scrollbar.repositionAndResize()`, gets the updated width-to-subtract, and
re-flows the grid). This keeps mode-change handling on the same code path
as ordinary window resizes — no duplicate logic.

## Geometry

Width (DPI-scaled, base widths at 96 DPI):

- **Overlay collapsed:** 8px
- **Overlay expanded (hover/drag):** 14px
- **Always-visible:** 14px

Hover and visibility are **independent axes** in overlay mode:

- **Visibility** (hidden/fading_in/shown/fading_out) is driven by scroll
  events and the idle timer — controls the alpha of the thumb.
- **Hover** (true/false) is driven by `WM_MOUSEMOVE`/`WM_MOUSELEAVE` —
  controls the width (8px ↔ 14px) and the base color (idle ↔ hover).

A scrollbar that is hovered while fading out, for example, paints a
14px-wide hover-colored thumb at decreasing alpha. Both axes are evaluated
at every paint.

Anchored to right edge, full client height. In always-visible mode, the
Surface subtracts `scrollbar_width` from the reported client width before
passing it to the grid layout — so the terminal grid loses one column. In
overlay mode, the scrollbar floats over the rightmost column (same as Mac
overlay scrollers) and the grid uses the full client width.

Thumb geometry:

```
thumb_y = (offset / total) * track_height
thumb_h = max(20_px_dpi, (len / total) * track_height)
```

(`len` is the visible-rows field of `terminal.Scrollbar` — i.e., the page
size. Field names match the existing `terminal.Scrollbar` struct used by the
core renderer.)

The 20px minimum keeps the thumb grabbable on very long scrollbacks.

## Painting

`UpdateLayeredWindow` with `ULW_ALPHA` and a 32-bit BGRA bitmap built in a
GDI memory DC. Per-pixel alpha lets the thumb be genuinely translucent over
the OpenGL terminal content, while the rest of the popup is fully transparent
(alpha=0).

Color and alpha (`Scrollbar.zig` helpers, all from `terminal.color.RGB`):

```zig
const thumb_rgb = fg;  // theme foreground

// Base alpha tied to interaction state.
const alpha_idle:  u8 = 80;   // ~31% — subtle in overlay mode
const alpha_hover: u8 = 140;  // ~55%
const alpha_drag:  u8 = 200;  // ~78%
```

In **always-visible mode** the track is also painted (theme background, full
alpha) so the scrollbar reads as a solid, opaque widget like every other
always-visible Win32 app. In **overlay mode** the track is fully transparent;
only the thumb is drawn.

The bitmap is rebuilt only when state changes (mode, theme, scroll position,
hover, dragging, fade alpha). Steady-state idle costs zero paints.

### Visibility state machine (overlay mode only)

States: `hidden / fading_in / shown / fading_out`.

Driven by a 60Hz `SetTimer` while animating. Effective alpha multiplies the
base alpha by `current_fade / 255`:

```zig
const final_alpha: u8 = @intCast(@as(u16, base_alpha) * fade / 255);
```

Fade steps: 32/frame → ~133ms fade in or out.

Triggers:

- **First `update()` after create()** → set state silently to `hidden`. No
  fade-in on startup.
- **Subsequent `update()` with changed state** → fade-in if hidden; restart
  1s idle timer.
- **Mouse enters popup** → fade-in.
- **Mouse leaves AND not dragging** → restart 1s idle timer; on fire, fade
  out.
- **Drag in progress** → state pinned to `shown`; idle timer suspended.

Always-visible mode skips the state machine entirely. `final_alpha = base_alpha`
always, with `base_alpha` switching among idle/hover/drag.

## Mouse handling

All handled on the scrollbar HWND (the layered popup). Mouse wheel is **not**
intercepted — `WM_MOUSEWHEEL` arrives at whichever window has focus, which is
the Surface, so the existing wheel handler keeps working unchanged.

### Click-through when hidden

In overlay mode with `visibility = hidden`, the popup is invisible (alpha=0
everywhere). A user clicking in that 8px right-edge strip should hit the
terminal underneath, not a phantom invisible window. We achieve this by
toggling `WS_EX_TRANSPARENT` on the popup:

- `visibility = hidden` → set `WS_EX_TRANSPARENT` (clicks fall through to
  Surface).
- Any other visibility state → clear `WS_EX_TRANSPARENT` (popup captures
  clicks).

Toggling done with `SetWindowLongW(GWL_EXSTYLE, ...)`. Cheap.

In always-visible mode the popup never has `WS_EX_TRANSPARENT` — it's a real
control, like every other Win32 scrollbar.

| Event | Action |
|---|---|
| `WM_MOUSEMOVE` | Update `hover`; `TrackMouseEvent(TME_LEAVE)`; if dragging, compute new offset and call `surface.scrollToRow`; repaint. |
| `WM_MOUSELEAVE` | Clear `hover`; in overlay mode, restart 1s idle timer; repaint. |
| `WM_LBUTTONDOWN` on thumb rect | `SetCapture`; `drag_anchor = mouse_y - thumb_y`; `dragging = true`. |
| `WM_LBUTTONDOWN` on track (not thumb) | Page up/down: `offset ± len`, clamped to `[0, total - len]`. |
| `WM_LBUTTONUP` | `ReleaseCapture`; clear `dragging`; restart idle timer if overlay & not hovered. |

### Drag math

```zig
// Track range: distance the thumb top-edge can travel.
const track_range = track_height - thumb_h;

// Edge case: if track_range == 0 (thumb fills track), there's nothing to
// scroll — drag is a no-op. Same if total <= len.
if (track_range <= 0 or total <= len) return;

const new_thumb_y = std.math.clamp(mouse_y - drag_anchor, 0, track_range);
const new_offset = @as(usize, @intFromFloat(
    @round(@as(f32, @floatFromInt(new_thumb_y)) /
           @as(f32, @floatFromInt(track_range)) *
           @as(f32, @floatFromInt(total - len))),
));
```

## Testing

### Unit tests (in `Scrollbar.zig` test blocks)

- Thumb geometry at top, middle, bottom of scrollback.
- Thumb minimum height enforcement (20px) when page/total ratio is tiny.
- Drag math correctness and clamp at both ends.
- Color lerp correctness (e.g., `lerp(#000, #fff, 0.5) == #808080`).
- Registry mode parsing: `0` → always-visible, `1` → overlay, missing →
  overlay.

### Integration test (`test/win32/test_scrollbar.ps1`)

1. Launch ghostty.
2. Send commands to fill 200 lines of scrollback.
3. Send `Ctrl+Home` to scroll to top.
4. Locate the scrollbar popup. Since it's an owned popup (not a child), use
   `EnumThreadWindows` filtered by class name `GhosttyScrollbar` and
   `GetWindow(hwnd, GW_OWNER)` matching the surface HWND. Assert it exists
   and `IsWindowVisible` is true.
5. Sleep 1.5s; assert the window is still present but the visibility state has
   transitioned to `hidden`. State is exposed via a named test-only message:
   ```zig
   pub const WM_GHOSTTY_SCROLLBAR_QUERY = w32.WM_USER + 1;
   ```
   The popup's WndProc returns the current state as an `LRESULT` (0=hidden,
   1=fading_in, 2=shown, 3=fading_out). The PowerShell test sends this via
   `SendMessage` and asserts on the return value.
6. Drag the thumb (synthesized `WM_LBUTTONDOWN` / `WM_MOUSEMOVE` /
   `WM_LBUTTONUP`); assert the visible cursor row changed.

The mode-switching test (toggling the OS setting at runtime) is deferred to
manual testing — synthesizing `WM_SETTINGCHANGE` requires modifying real
registry state and is fragile in CI.

### Manual visual verification

Documented in the implementation commit message:

- Build with `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast`.
- Copy to Desktop, run with default theme.
- Run with `theme = gruvbox-dark`, confirm thumb color tracks the foreground.
- Run with a light theme (e.g., `theme = github-light`), confirm thumb is
  visible against the light background.
- Toggle Settings → Accessibility → Visual effects → "Always show scrollbars",
  confirm the mode switches without restart.

## Files changed

- `src/apprt/win32/Scrollbar.zig` (new) — ~400 lines including tests.
- `src/apprt/win32/Surface.zig` — remove ~50 lines of native scrollbar code,
  add `scrollbar: ?*Scrollbar` field, route theme/resize/settings-change
  through to it, add `scrollToRow` helper.
- `src/apprt/win32/win32.zig` — add the Win32 bindings we need:
  `TrackMouseEvent`, `TRACKMOUSEEVENT`, `RegOpenKeyExW`, `RegQueryValueExW`,
  registry constants, `UpdateLayeredWindow`, `BLENDFUNCTION`, `ULW_ALPHA`,
  `AC_SRC_OVER`, `AC_SRC_ALPHA`, `WS_EX_LAYERED`, `WS_EX_TRANSPARENT`,
  `CreateCompatibleDC`, `CreateDIBSection`, `BITMAPINFO`, `SelectObject`,
  `DeleteDC`, `DeleteObject`, `ClientToScreen`.
- `test/win32/test_scrollbar.ps1` (new).
- `test/win32/run_tests.ps1` — add the new test to the harness.

## Risks

- **`DynamicScrollbars` registry semantics may differ from documented.**
  Verified empirically during implementation; flip the check if needed.
- **Surface grid size off-by-one when always-visible mode is active.** Caught
  by existing surface resize tests once we plumb the scrollbar width
  subtraction through `WM_SIZE`.
- **Drag during fade-out** — handled explicitly: dragging pins state to
  `shown` until `WM_LBUTTONUP`.
- **Layered popup position lag during fast surface resize** — `SetWindowPos`
  on the popup happens after `WM_SIZE` returns, so during a live drag-resize
  the popup can briefly trail the right edge by a frame. Acceptable; matches
  how every other layered overlay (Steam, Discord) behaves.
- **Multi-monitor DPI changes** — popup must be resized when the surface
  moves to a different DPI. Handled by `WM_DPICHANGED` already received by
  Surface (it forwards to the scrollbar to recompute widths).
