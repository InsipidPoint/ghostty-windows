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

Replace the native scrollbar with a custom child-window scrollbar painted using
the terminal's own theme background and foreground colors, with behavior that
honors the OS "Always show scrollbars" accessibility setting:

- **Auto-hide (overlay) mode** when the OS prefers dynamic scrollbars (the
  Win11 default). Mac-style: invisible until the user scrolls, fades out after
  ~1s idle, expands on hover.
- **Always-visible mode** when the OS prefers always-shown scrollbars. The
  scrollbar steals one column of grid space and is always painted.

## Non-goals

- Does not replicate the macOS NSScroller blur/vibrancy effect. We simulate
  translucency by pre-mixing colors against the terminal background.
- Does not add horizontal scrollbar support (terminal grid is fixed-width).
- Does not add a config knob for forcing a mode — the OS setting is the source
  of truth, matching what every other Win32 app does.

## Architecture

A new module `src/apprt/win32/Scrollbar.zig` owns one scrollbar instance per
`Surface`. It registers a custom window class `GhosttyScrollbar` (once per
process) and creates a `WS_CHILD` window parented to the Surface HWND, anchored
to the right edge of the client area.

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
    pub fn create(parent: HWND, surface: *Surface) !*Scrollbar;
    pub fn destroy(self: *Scrollbar) void;

    /// Surface forwards new scroll state here (called from
    /// performAction(.scrollbar)).
    pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void;

    /// Surface forwards client area resize here (called from WM_SIZE).
    /// Returns the width to subtract from the grid client area
    /// (0 in overlay mode, scrollbar_width_dpi in always-visible mode).
    pub fn resize(self: *Scrollbar, client_width: i32, client_height: i32) i32;

    /// Surface forwards theme/config changes here (palette load, config reload).
    pub fn setTheme(self: *Scrollbar, bg: terminal.color.RGB, fg: terminal.color.RGB) void;

    /// Surface forwards WM_SETTINGCHANGE here so we re-read the registry.
    pub fn onSettingsChange(self: *Scrollbar) void;
};
```

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
`scrollbar.resize()`, gets the updated width-to-subtract, and re-flows the
grid). This keeps mode-change handling on the same code path as ordinary
window resizes — no duplicate logic.

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

GDI double-buffered paint in `WM_PAINT` (memory DC + BitBlt to avoid flicker).
No layered window. Translucency is simulated by pre-mixing colors against the
known terminal background:

```zig
fn lerp(a: RGB, b: RGB, t: f32) RGB { ... }

const track_color      = bg;                       // skipped in overlay mode
const thumb_color_idle = lerp(bg, fg, 0.30);       // subtle
const thumb_color_hover = lerp(bg, fg, 0.55);
const thumb_color_drag  = lerp(bg, fg, 0.75);
```

### Visibility state machine (overlay mode only)

States: `hidden / fading_in / shown / fading_out`.

Driven by a 60Hz `SetTimer` while animating. Alpha steps of 32/frame → ~133ms
fade. Alpha is applied at paint time by lerping the thumb color against the
background a second time:

```zig
const visible_color = lerp(bg, base_color, alpha / 255.0);
```

Triggers:

- `update(state)` called with a different state → start fade-in, restart idle
  timer.
- Mouse enters → start fade-in.
- Mouse leaves AND not dragging → start 1000ms idle timer; on fire, fade out.
- Drag in progress → stay shown regardless of timer.

Always-visible mode skips the state machine entirely; thumb is always painted
at `thumb_color_idle` (or hover/drag color when applicable).

## Mouse handling

All handled on the scrollbar HWND. Mouse wheel is **not** intercepted — it
continues to fall through to the parent Surface's existing `WM_MOUSEWHEEL`
handler.

| Event | Action |
|---|---|
| `WM_MOUSEMOVE` | Update `hover`; `TrackMouseEvent(TME_LEAVE)`; if dragging, compute new offset and call `surface.scrollToRow`; repaint. |
| `WM_MOUSELEAVE` | Clear `hover`; in overlay mode, restart 1s idle timer; repaint. |
| `WM_LBUTTONDOWN` on thumb rect | `SetCapture`; `drag_anchor = mouse_y - thumb_y`; `dragging = true`. |
| `WM_LBUTTONDOWN` on track (not thumb) | Page up/down: `offset ± len`, clamped to `[0, total - len]`. |
| `WM_LBUTTONUP` | `ReleaseCapture`; clear `dragging`; restart idle timer if overlay & not hovered. |

### Drag math

```zig
const new_thumb_y = std.math.clamp(
    mouse_y - drag_anchor,
    0,
    track_height - thumb_h,
);
const new_offset = @as(usize, @intFromFloat(
    @round(@as(f32, @floatFromInt(new_thumb_y)) /
           @as(f32, @floatFromInt(track_height - thumb_h)) *
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
4. Use `FindWindowEx` to locate the `GhosttyScrollbar` child of the surface
   HWND; assert it exists and `IsWindowVisible` is true.
5. Sleep 1.5s; assert the window is still present but the visibility state has
   transitioned to `hidden` (we expose this via a `WM_USER+1` query message
   that returns the state, used only by tests).
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
- `src/apprt/win32/win32.zig` — add the few extra Win32 bindings we need
  (`TrackMouseEvent`, `TRACKMOUSEEVENT`, `RegOpenKeyExW`, `RegQueryValueExW`,
  registry constants).
- `test/win32/test_scrollbar.ps1` (new).
- `test/win32/run_tests.ps1` — add the new test to the harness.

## Risks

- **`DynamicScrollbars` registry semantics may differ from documented.**
  Verified empirically during implementation; flip the check if needed.
- **Layered child window flicker** — mitigated by double-buffered paint with
  a memory DC. Standard pattern.
- **Surface grid size off-by-one when always-visible mode is active.** Caught
  by existing surface resize tests once we plumb the scrollbar width
  subtraction through `WM_SIZE`.
- **Drag during fade-out** — handled explicitly: dragging pins state to
  `shown` until `WM_LBUTTONUP`.
