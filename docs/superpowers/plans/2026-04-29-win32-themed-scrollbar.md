# Win32 Themed Scrollbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the native Win32 scrollbar in Ghostty with a layered-popup scrollbar painted in terminal theme colors, honoring the OS "Always show scrollbars" accessibility setting.

**Architecture:** A `Scrollbar` module owns a `WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_POPUP` window per Surface. Painting uses `UpdateLayeredWindow` with a per-pixel-alpha BGRA bitmap — DWM composites it above the OpenGL surface. Mode (overlay vs always-visible) is read from `HKCU\Control Panel\Accessibility\DynamicScrollbars` and re-read on `WM_SETTINGCHANGE`. All scrollbar work runs on the main app thread; no synchronization with the renderer thread is needed.

**Tech Stack:** Zig, Win32 GDI (BGRA bitmap, `UpdateLayeredWindow`), Win32 USER (`WS_EX_LAYERED`, `WS_POPUP`, `TrackMouseEvent`, registry).

**Spec:** `docs/superpowers/specs/2026-04-29-win32-themed-scrollbar-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `src/apprt/win32/Scrollbar.zig` (new) | Owns popup HWND, paints, handles mouse, runs visibility state machine, reads registry. Pure-math helpers in same file but as separate `pub` functions for unit-testability. |
| `src/apprt/win32/Surface.zig` (modify) | Owns `?*Scrollbar`. Removes legacy `WS_VSCROLL`/`SetScrollInfo`/`WM_VSCROLL` code. Forwards lifecycle and message events. Adds `scrollToOffset`. |
| `src/apprt/win32/win32.zig` (modify) | Adds Win32 API bindings the new module needs. |
| `test/win32/test_scrollbar.ps1` (new) | PowerShell integration test. |
| `test/win32/run_tests.ps1` (modify) | Add new test to harness. |

---

## Task 1: Add Win32 API bindings to win32.zig

**Files:**
- Modify: `src/apprt/win32/win32.zig`

- [ ] **Step 1: Add bindings**

Add the following at the end of `src/apprt/win32/win32.zig` (or grouped with related existing bindings — match local style):

```zig
// --- Layered window painting ---

pub const ULW_ALPHA: u32 = 0x00000002;
pub const AC_SRC_OVER: u8 = 0x00;
pub const AC_SRC_ALPHA: u8 = 0x01;
pub const WS_EX_LAYERED: u32 = 0x00080000;
pub const WS_EX_TRANSPARENT: u32 = 0x00000020;
pub const WS_EX_NOACTIVATE: u32 = 0x08000000;

pub const BLENDFUNCTION = extern struct {
    BlendOp: u8 = AC_SRC_OVER,
    BlendFlags: u8 = 0,
    SourceConstantAlpha: u8 = 255,
    AlphaFormat: u8 = AC_SRC_ALPHA,
};

pub const POINT = extern struct { x: i32, y: i32 };
pub const SIZE = extern struct { cx: i32, cy: i32 };

pub extern "user32" fn UpdateLayeredWindow(
    hwnd: HWND,
    hdcDst: ?HDC,
    pptDst: ?*const POINT,
    psize: ?*const SIZE,
    hdcSrc: ?HDC,
    pptSrc: ?*const POINT,
    crKey: u32,
    pblend: ?*const BLENDFUNCTION,
    dwFlags: u32,
) callconv(.winapi) c_int;

// --- DIB section ---

pub const BI_RGB: u32 = 0;
pub const DIB_RGB_COLORS: u32 = 0;

pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = BI_RGB,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};

pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn CreateDIBSection(
    hdc: ?HDC,
    pbmi: *const BITMAPINFO,
    usage: u32,
    ppvBits: *?*anyopaque,
    hSection: ?HANDLE,
    offset: u32,
) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: HANDLE) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) c_int;
pub extern "gdi32" fn DeleteObject(h: HANDLE) callconv(.winapi) c_int;

// --- Mouse tracking ---

pub const TME_LEAVE: u32 = 0x00000002;

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32 = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: u32,
    hwndTrack: HWND,
    dwHoverTime: u32 = 0,
};

pub extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(.winapi) c_int;
pub extern "user32" fn ClientToScreen(hwnd: HWND, lpPoint: *POINT) callconv(.winapi) c_int;

// --- Mouse activate ---

pub const WM_MOUSEACTIVATE: u32 = 0x0021;
pub const MA_NOACTIVATE: isize = 3;

// --- Registry ---

pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const KEY_READ: u32 = 0x00020019;
pub const REG_DWORD: u32 = 4;
pub const ERROR_SUCCESS: u32 = 0;

pub const HKEY = *opaque {};

pub extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const u16,
    ulOptions: u32,
    samDesired: u32,
    phkResult: *HKEY,
) callconv(.winapi) u32;

pub extern "advapi32" fn RegQueryValueExW(
    hKey: HKEY,
    lpValueName: [*:0]const u16,
    lpReserved: ?*u32,
    lpType: ?*u32,
    lpData: ?[*]u8,
    lpcbData: *u32,
) callconv(.winapi) u32;

pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) u32;

// --- Settings change broadcast ---

pub const WM_SETTINGCHANGE: u32 = 0x001A;
pub const WM_SHOWWINDOW: u32 = 0x0018;
```

Note: Some of these (e.g., `HANDLE`, `HDC`, `HWND`, `WM_USER`, `WM_TIMER`) already exist in `win32.zig` — do not duplicate. Reuse existing aliases.

- [ ] **Step 2: Verify the build still compiles**

Run: `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=Debug 2>&1 | tail -20`
Expected: build succeeds (these are unused declarations at this point, which Zig allows).

- [ ] **Step 3: Commit**

```bash
git add src/apprt/win32/win32.zig
git commit -m "feat(win32): add API bindings for layered scrollbar

Bindings for UpdateLayeredWindow, BLENDFUNCTION, DIB section creation,
TrackMouseEvent, registry access, and the WS_EX_/WM_ constants needed
by the upcoming Scrollbar module."
```

---

## Task 2: Pure-math helpers with unit tests (TDD)

**Files:**
- Create: `src/apprt/win32/Scrollbar.zig`

This task creates the file with **only** pure functions and their tests. No Win32 calls. No struct yet. We get the math right under unit tests before touching the OS.

- [ ] **Step 1: Write failing tests**

Create `src/apprt/win32/Scrollbar.zig` with the following content (only — no implementation yet):

```zig
//! Themed scrollbar for the Win32 apprt. See
//! docs/superpowers/specs/2026-04-29-win32-themed-scrollbar-design.md

const std = @import("std");
const testing = std.testing;

/// Computed thumb rectangle within the track.
pub const ThumbRect = struct { y: i32, h: i32 };

/// Compute thumb_y and thumb_h given scrollback state and track height.
/// Enforces a 20-px minimum (DPI-scaled by caller via min_h).
pub fn thumbRect(
    total: usize,
    offset: usize,
    len: usize,
    track_h: i32,
    min_h: i32,
) ThumbRect {
    @compileError("unimplemented");
}

/// Compute new scroll offset from a thumb position during a drag.
/// Returns null if there's nothing to scroll (track_range <= 0 or total <= len).
pub fn dragOffset(
    mouse_y: i32,
    drag_anchor: i32,
    track_h: i32,
    thumb_h: i32,
    total: usize,
    len: usize,
) ?usize {
    @compileError("unimplemented");
}

/// Effective alpha = base_alpha * fade / 255, saturating at 255.
pub fn effectiveAlpha(base_alpha: u8, fade: u8) u8 {
    @compileError("unimplemented");
}

pub const Mode = enum { overlay, always_visible };

/// Parse the registry DynamicScrollbars value into a Mode.
/// `value == null` means the value didn't exist.
pub fn parseMode(value: ?u32) Mode {
    @compileError("unimplemented");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "thumbRect: thumb at top when offset is 0" {
    const r = thumbRect(1000, 0, 50, 400, 20);
    try testing.expectEqual(@as(i32, 0), r.y);
    try testing.expectEqual(@as(i32, 20), r.h); // 50/1000 * 400 = 20
}

test "thumbRect: thumb at bottom when offset = total - len" {
    const r = thumbRect(1000, 950, 50, 400, 20);
    // (950/1000) * 400 = 380; thumb_h = 20; bottom = 400. OK.
    try testing.expectEqual(@as(i32, 380), r.y);
    try testing.expectEqual(@as(i32, 20), r.h);
}

test "thumbRect: enforces minimum height" {
    // len/total = 1/10000, computed_h = 0; floor of min is 20.
    const r = thumbRect(10000, 0, 1, 400, 20);
    try testing.expectEqual(@as(i32, 20), r.h);
}

test "thumbRect: total == 0 returns full track" {
    const r = thumbRect(0, 0, 0, 400, 20);
    try testing.expectEqual(@as(i32, 0), r.y);
    try testing.expectEqual(@as(i32, 400), r.h);
}

test "dragOffset: top of track" {
    const off = dragOffset(0, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 0), off);
}

test "dragOffset: bottom of track" {
    // mouse_y = 380 (track_range = 400 - 20 = 380); should land at total - len = 950.
    const off = dragOffset(380, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 950), off);
}

test "dragOffset: middle of track" {
    const off = dragOffset(190, 0, 400, 20, 1000, 50).?;
    // 190/380 * 950 ≈ 475
    try testing.expectEqual(@as(usize, 475), off);
}

test "dragOffset: clamped above" {
    const off = dragOffset(-100, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 0), off);
}

test "dragOffset: clamped below" {
    const off = dragOffset(99999, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 950), off);
}

test "dragOffset: returns null when total <= len" {
    try testing.expectEqual(@as(?usize, null), dragOffset(50, 0, 400, 20, 50, 100));
    try testing.expectEqual(@as(?usize, null), dragOffset(50, 0, 400, 20, 50, 50));
}

test "dragOffset: returns null when thumb fills track" {
    // thumb_h == track_h → track_range == 0
    try testing.expectEqual(@as(?usize, null), dragOffset(0, 0, 400, 400, 1000, 50));
}

test "effectiveAlpha: full fade" {
    try testing.expectEqual(@as(u8, 80), effectiveAlpha(80, 255));
}

test "effectiveAlpha: half fade" {
    try testing.expectEqual(@as(u8, 40), effectiveAlpha(80, 128));
}

test "effectiveAlpha: zero fade" {
    try testing.expectEqual(@as(u8, 0), effectiveAlpha(80, 0));
}

test "parseMode: missing value defaults to overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(null));
}

test "parseMode: 1 is overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(1));
}

test "parseMode: 0 is always_visible" {
    try testing.expectEqual(Mode.always_visible, parseMode(0));
}
```

- [ ] **Step 2: Verify tests fail to compile**

Run: `zig test src/apprt/win32/Scrollbar.zig 2>&1 | tail -10`
Expected: error containing "unimplemented" — the `@compileError` markers fire before the tests can run.

- [ ] **Step 3: Replace `@compileError` markers with implementations**

Replace each function body:

```zig
pub fn thumbRect(
    total: usize,
    offset: usize,
    len: usize,
    track_h: i32,
    min_h: i32,
) ThumbRect {
    if (total == 0 or len >= total) {
        return .{ .y = 0, .h = track_h };
    }
    const total_f: f32 = @floatFromInt(total);
    const offset_f: f32 = @floatFromInt(offset);
    const len_f: f32 = @floatFromInt(len);
    const track_f: f32 = @floatFromInt(track_h);

    const computed_h_f = (len_f / total_f) * track_f;
    const computed_h: i32 = @intFromFloat(@round(computed_h_f));
    const h = @max(min_h, computed_h);

    const computed_y_f = (offset_f / total_f) * track_f;
    var y: i32 = @intFromFloat(@round(computed_y_f));
    // Clamp so the thumb never extends past the track.
    if (y + h > track_h) y = track_h - h;
    if (y < 0) y = 0;

    return .{ .y = y, .h = h };
}

pub fn dragOffset(
    mouse_y: i32,
    drag_anchor: i32,
    track_h: i32,
    thumb_h: i32,
    total: usize,
    len: usize,
) ?usize {
    if (total <= len) return null;
    const track_range = track_h - thumb_h;
    if (track_range <= 0) return null;

    const new_thumb_y = std.math.clamp(mouse_y - drag_anchor, 0, track_range);
    const range_f: f32 = @floatFromInt(track_range);
    const thumb_y_f: f32 = @floatFromInt(new_thumb_y);
    const max_off_f: f32 = @floatFromInt(total - len);

    return @intFromFloat(@round(thumb_y_f / range_f * max_off_f));
}

pub fn effectiveAlpha(base_alpha: u8, fade: u8) u8 {
    const product: u16 = @as(u16, base_alpha) * @as(u16, fade) / 255;
    return @intCast(@min(product, 255));
}

pub fn parseMode(value: ?u32) Mode {
    if (value) |v| {
        return if (v == 0) .always_visible else .overlay;
    }
    return .overlay;
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `zig test src/apprt/win32/Scrollbar.zig 2>&1 | tail -10`
Expected: `All N tests passed.`

- [ ] **Step 5: Commit**

```bash
git add src/apprt/win32/Scrollbar.zig
git commit -m "feat(win32): add scrollbar geometry/drag/alpha math (TDD)

Pure functions with full unit test coverage. No Win32 dependencies yet —
this is the math substrate the rest of the module will build on.

Tests verify thumb position at top/middle/bottom, minimum height
enforcement, drag clamping at both ends, drag no-op when total<=len or
thumb fills track, alpha multiplication, and registry mode parsing
(missing/0/1)."
```

---

## Task 3: Window class registration + struct skeleton

**Files:**
- Modify: `src/apprt/win32/Scrollbar.zig`

This task adds the `Scrollbar` struct, registers the `GhosttyScrollbar` window class once per process, and creates the layered popup. The popup paints nothing yet (alpha=0 everywhere) and handles no mouse — just exists.

- [ ] **Step 1: Append struct + registration logic**

Add the following imports at the top of `Scrollbar.zig` (after the existing `const std`):

```zig
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const terminal = @import("../../terminal/main.zig");

const log = std.log.scoped(.win32_scrollbar);
```

Forward-declare `Surface` to avoid circular import at file top:

```zig
const Surface = @import("Surface.zig");
```

Add the struct (append below the math helpers):

```zig
pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyScrollbar");

/// Test-only message: SendMessage(hwnd, WM_GHOSTTY_SCROLLBAR_QUERY, 0, 0)
/// returns the current visibility state as an LRESULT.
/// 0=hidden, 1=fading_in, 2=shown, 3=fading_out.
pub const WM_GHOSTTY_SCROLLBAR_QUERY: u32 = w32.WM_USER + 1;

pub const Visibility = enum(isize) {
    hidden = 0,
    fading_in = 1,
    shown = 2,
    fading_out = 3,
};

pub const Scrollbar = struct {
    alloc: std.mem.Allocator,
    surface: *Surface,
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// Latest scroll state from the core. Initially zero.
    state: terminal.Scrollbar = .zero,
    /// True until the first update() call — used to suppress fade-in on startup.
    first_update: bool = true,

    /// Current mode; re-read on WM_SETTINGCHANGE.
    mode: Mode = .overlay,

    /// Cached theme colors. Updated via setTheme.
    bg: terminal.color.RGB = .{ .r = 0, .g = 0, .b = 0 },
    fg: terminal.color.RGB = .{ .r = 255, .g = 255, .b = 255 },

    /// DPI scale (1.0 at 96 DPI).
    scale: f32 = 1.0,

    /// Visibility state (overlay mode only).
    visibility: Visibility = .hidden,
    /// Fade alpha [0..255]. Multiplied into base_alpha at paint time.
    fade: u8 = 0,

    /// Hover tracking.
    hover: bool = false,
    /// Drag tracking.
    dragging: bool = false,
    drag_anchor: i32 = 0,

    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        surface: *Surface,
    ) !*Scrollbar {
        try registerClassOnce(surface.app.hinstance);

        const self = try alloc.create(Scrollbar);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .surface = surface,
            .owner = owner,
            .hwnd = undefined,
        };

        // WS_EX_LAYERED — DWM-composited above OpenGL.
        // WS_EX_NOACTIVATE — clicking us does not steal focus from the terminal.
        // WS_EX_TOOLWINDOW — keep us out of the taskbar / Alt-Tab list.
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;
        // WS_POPUP — owned popup, follows the surface in z-order.
        const style: u32 = w32.WS_POPUP;

        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            style,
            0, 0, 1, 1, // placeholder rect — repositionAndResize() sets the real one
            owner, // owner (popup, not parent)
            null,
            surface.app.hinstance,
            null,
        ) orelse return error.Win32Error;
        errdefer _ = w32.DestroyWindow(hwnd);

        // Stash self pointer in GWLP_USERDATA so the WndProc can find us.
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *Scrollbar) void {
        _ = w32.DestroyWindow(self.hwnd);
        self.alloc.destroy(self);
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = scrollbarWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, @ptrFromInt(@intFromEnum(w32.IDC_ARROW))),
        .hbrBackground = null, // we paint via UpdateLayeredWindow
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn scrollbarWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    // Stub for now. Forwards everything to DefWindowProc until subsequent
    // tasks add real handlers.
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
```

(If any of `LoadCursorW`, `IDC_ARROW`, `WNDCLASSEXW`, `RegisterClassExW`, `DefWindowProcW`, `CreateWindowExW`, `GWLP_USERDATA`, `SetWindowLongPtrW`, `DestroyWindow`, `HINSTANCE`, `WS_POPUP`, `WS_EX_TOOLWINDOW` is missing from `win32.zig`, add bindings — they are standard.)

- [ ] **Step 2: Verify build compiles**

Run: `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=Debug 2>&1 | tail -20`
Expected: build succeeds.

- [ ] **Step 3: Verify unit tests still pass**

Run: `zig test src/apprt/win32/Scrollbar.zig 2>&1 | tail -10`
Expected: all tests still pass (we only added new declarations, didn't change math).

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/Scrollbar.zig src/apprt/win32/win32.zig
git commit -m "feat(win32): add Scrollbar struct and class registration

Registers GhosttyScrollbar window class once per process. create()
spawns a WS_EX_LAYERED|WS_EX_NOACTIVATE|WS_POPUP owned by the Surface
HWND. Popup paints nothing yet (subsequent task) — the create/destroy
lifecycle is the focus here."
```

---

## Task 4: Wire Scrollbar into Surface (no painting yet)

**Files:**
- Modify: `src/apprt/win32/Surface.zig`

This task replaces the native `WS_VSCROLL` plumbing with calls into `Scrollbar`. After this task the terminal will have **no visible scrollbar** until painting lands — which is fine, because the scrollback can still be reached via mouse wheel / keyboard.

- [ ] **Step 1: Add the Scrollbar field**

Find the `scrollbar_total/offset/len` fields (Surface.zig:92-96) and replace them with:

```zig
/// Themed scrollbar (custom layered-popup overlay).
/// Created lazily after the surface HWND exists.
scrollbar: ?*Scrollbar = null,
```

Also add the import at the top of `Surface.zig` (near the other `@import` lines):

```zig
const Scrollbar = @import("Scrollbar.zig").Scrollbar;
```

- [ ] **Step 2: Initialize the scrollbar after HWND creation**

Find `Surface.init` — there's an HWND creation site followed by various setup. Right after `applyChromeTheme(hwnd, ...)` or the `SetWindowTheme` call (whichever comes last in init), add:

```zig
self.scrollbar = try Scrollbar.create(app.alloc, hwnd, self);
errdefer if (self.scrollbar) |sb| {
    sb.destroy();
    self.scrollbar = null;
};
```

Use `Read` on `Surface.zig` around line 220-280 to find the exact location matching the existing `errdefer` pattern.

- [ ] **Step 3: Destroy the scrollbar in deinit**

Find `Surface.deinit` (around line 290+). Before any `DestroyWindow(hwnd)` call on the surface HWND, add:

```zig
if (self.scrollbar) |sb| {
    sb.destroy();
    self.scrollbar = null;
}
```

The order matters: scrollbar HWND must be destroyed while its owner still exists.

- [ ] **Step 4: Replace `setScrollbar` body**

Find `pub fn setScrollbar(self: *Surface, scrollbar: terminal.Scrollbar) void` (Surface.zig:1372). Replace the entire function body with:

```zig
pub fn setScrollbar(self: *Surface, scrollbar: terminal.Scrollbar) void {
    if (self.scrollbar) |sb| sb.update(scrollbar);
}
```

- [ ] **Step 5: Remove `handleVScroll`**

Find `pub fn handleVScroll` (Surface.zig:1405) and delete the entire function (and its `WM_VSCROLL` dispatch case in the WndProc — search for `WM_VSCROLL` to find it).

- [ ] **Step 6: Add `scrollToOffset` method**

Add a new method to `Surface` (place it near `setScrollbar`):

```zig
/// Called by Scrollbar when the user drags or page-clicks. Forwards to
/// the core surface's scroll_viewport action.
pub fn scrollToOffset(self: *Surface, offset: usize) void {
    if (!self.core_surface_ready) return;
    self.core_surface.io.queueMessage(.{ .scroll_viewport = .{
        .delta = .{ .row = .{ .top = offset } },
    } }, .unlocked);
    self.core_surface.renderer_thread.wakeup.notify() catch {};
}
```

(Verify the exact `scroll_viewport` shape against the existing `handleVScroll` — copy what it does for `SB_THUMBTRACK`. The point is to reuse the existing path, not invent a new one.)

- [ ] **Step 7: Forward WM_SIZE / WM_MOVE / WM_SHOWWINDOW / WM_DPICHANGED / WM_SETTINGCHANGE**

In `handleResize` (Surface.zig:1455) — add at the end (after the `core_surface.sizeCallback` call):

```zig
if (self.scrollbar) |sb| _ = sb.repositionAndResize();
```

In `handleDpiChange` (Surface.zig:1502) — add:

```zig
if (self.scrollbar) |sb| sb.onDpiChanged(@intFromFloat(self.scale * 96.0));
```

In the WndProc, find the message dispatch table. Add cases (or extend existing ones):

```zig
.WM_MOVE => {
    if (surface.scrollbar) |sb| _ = sb.repositionAndResize();
    return 0;
},
.WM_SHOWWINDOW => {
    if (surface.scrollbar) |sb| sb.setOwnerVisible(wparam != 0);
    return 0;
},
.WM_SETTINGCHANGE => {
    if (surface.scrollbar) |sb| {
        if (sb.onSettingsChange()) {
            // Mode flipped; re-flow grid via WM_SIZE.
            const lp: isize = @bitCast(
                (@as(usize, surface.height) << 16) | @as(usize, surface.width),
            );
            _ = w32.PostMessageW(hwnd, w32.WM_SIZE, 0, lp);
        }
    }
    return 0;
},
```

(Match the existing dispatch style — Surface.zig may use a switch or if/else chain. Use the same form.)

- [ ] **Step 8: Add stub methods on Scrollbar**

Add these stubs to `Scrollbar` in `Scrollbar.zig` so Step 7 compiles:

```zig
pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void {
    self.state = state;
    self.first_update = false;
    // Painting/state-machine integration in later tasks.
}

pub fn repositionAndResize(self: *Scrollbar) i32 {
    // Stub — full positioning logic in Task 5.
    return 0;
}

pub fn setOwnerVisible(self: *Scrollbar, visible: bool) void {
    _ = w32.ShowWindow(self.hwnd, if (visible) w32.SW_SHOWNOACTIVATE else w32.SW_HIDE);
}

pub fn setTheme(self: *Scrollbar, bg: terminal.color.RGB, fg: terminal.color.RGB) void {
    self.bg = bg;
    self.fg = fg;
}

pub fn onSettingsChange(self: *Scrollbar) bool {
    _ = self;
    return false; // No-op until Task 8.
}

pub fn onDpiChanged(self: *Scrollbar, dpi: u32) void {
    self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
}
```

- [ ] **Step 9: Verify build**

Run: `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=Debug 2>&1 | tail -20`
Expected: build succeeds.

- [ ] **Step 10: Verify all existing tests still pass**

Run: `zig test src/apprt/win32/Scrollbar.zig 2>&1 | tail -10`
Expected: pass.

Run the existing apprt test suite if defined; otherwise build and skip.

- [ ] **Step 11: Manual smoke test**

Build a release exe and run:
```bash
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
# copy zig-out/bin/ghostty.exe to Desktop, launch, type a few commands
```

Expected: terminal opens, no visible scrollbar (yet), wheel-scroll still works. No crash. (If it crashes on startup, the lifecycle ordering between Scrollbar and Surface HWND is wrong — debug before continuing.)

- [ ] **Step 12: Commit**

```bash
git add src/apprt/win32/Surface.zig src/apprt/win32/Scrollbar.zig
git commit -m "feat(win32): replace native scrollbar with Scrollbar module wiring

Surface now owns ?*Scrollbar, creates it after HWND init, destroys it
before deinit, and routes setScrollbar / WM_SIZE / WM_MOVE /
WM_SHOWWINDOW / WM_DPICHANGED / WM_SETTINGCHANGE through it.

Removes the legacy ShowScrollBar/SetScrollInfo/handleVScroll path. The
new module's painting and mouse handling come in subsequent commits —
right now the surface has no visible scrollbar but scroll-by-wheel and
scroll-by-keyboard continue to work."
```

---

## Task 5: Position tracking + painting (always-visible mode)

**Files:**
- Modify: `src/apprt/win32/Scrollbar.zig`

This task implements `repositionAndResize` and the BGRA-bitmap paint path. We start with **always-visible mode** semantics (track + thumb fully opaque, no fade) so we can verify painting works before layering on the state machine. The mode field stays `.overlay` — we just hard-code `.always_visible` for this task and switch to dynamic detection in Task 8.

- [ ] **Step 1: Add geometry + paint scaffolding**

Append to `Scrollbar.zig`:

```zig
const SCROLLBAR_WIDTH_BASE: i32 = 14;
const SCROLLBAR_WIDTH_OVERLAY_COLLAPSED: i32 = 8;
const THUMB_MIN_HEIGHT_BASE: i32 = 20;

const ALPHA_IDLE: u8 = 80;
const ALPHA_HOVER: u8 = 140;
const ALPHA_DRAG: u8 = 200;

fn dpiScaled(self: *const Scrollbar, base: i32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(base)) * self.scale));
}

fn currentWidth(self: *const Scrollbar) i32 {
    // Hard-coded for Task 5; Task 8 makes this mode-aware.
    return self.dpiScaled(SCROLLBAR_WIDTH_BASE);
}
```

- [ ] **Step 2: Implement `repositionAndResize`**

Replace the stub:

```zig
pub fn repositionAndResize(self: *Scrollbar) i32 {
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(self.owner, &rect) == 0) return 0;

    const client_h = rect.bottom - rect.top;
    const width = self.currentWidth();

    // Convert top-right corner of client area to screen coords.
    var top_right = w32.POINT{ .x = rect.right - width, .y = rect.top };
    _ = w32.ClientToScreen(self.owner, &top_right);

    _ = w32.SetWindowPos(
        self.hwnd,
        null,
        top_right.x,
        top_right.y,
        width,
        client_h,
        w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
    );

    self.repaint();

    // Hard-coded always-visible width-to-subtract for Task 5; Task 8 makes
    // this mode-aware (returns 0 in overlay mode).
    return width;
}
```

(`GetClientRect`, `RECT`, `SetWindowPos`, `SWP_NOACTIVATE`, `SWP_NOZORDER`, `SWP_SHOWWINDOW` should already be in `win32.zig`. If not, add them.)

- [ ] **Step 3: Implement `repaint`**

```zig
fn repaint(self: *Scrollbar) void {
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &client) == 0) return;
    const w = client.right - client.left;
    const h = client.bottom - client.top;
    if (w <= 0 or h <= 0) return;

    // Allocate a temp BGRA buffer, fill it, blit via UpdateLayeredWindow.
    const screen_dc = w32.GetDC(null) orelse return;
    defer _ = w32.ReleaseDC(null, screen_dc);

    const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);

    var bits: ?*anyopaque = null;
    const bmi = w32.BITMAPINFO{
        .bmiHeader = .{
            .biWidth = w,
            // Negative for top-down DIB so row 0 is the top row.
            .biHeight = -h,
        },
    };

    const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0)
        orelse return;
    defer _ = w32.DeleteObject(bitmap);

    const old = w32.SelectObject(mem_dc, bitmap);
    defer _ = w32.SelectObject(mem_dc, old.?);

    self.drawBitmap(@ptrCast(@alignCast(bits.?)), w, h);

    var window_rect: w32.RECT = undefined;
    _ = w32.GetWindowRect(self.hwnd, &window_rect);
    const dst_pt = w32.POINT{ .x = window_rect.left, .y = window_rect.top };
    const dst_size = w32.SIZE{ .cx = w, .cy = h };
    const src_pt = w32.POINT{ .x = 0, .y = 0 };
    const blend = w32.BLENDFUNCTION{
        .SourceConstantAlpha = 255, // per-pixel alpha only
    };

    _ = w32.UpdateLayeredWindow(
        self.hwnd,
        screen_dc,
        &dst_pt,
        &dst_size,
        mem_dc,
        &src_pt,
        0,
        &blend,
        w32.ULW_ALPHA,
    );
}

fn drawBitmap(self: *Scrollbar, pixels: [*]u32, w: i32, h: i32) void {
    // Premultiplied BGRA. Layout per pixel: 0xAARRGGBB.
    // For Task 5 (always-visible only): paint full track + opaque thumb.

    const bg = packBGRA(self.bg, 255);
    const total = w * h;
    var i: i32 = 0;
    while (i < total) : (i += 1) {
        pixels[@intCast(i)] = bg;
    }

    const min_h = self.dpiScaled(THUMB_MIN_HEIGHT_BASE);
    const r = thumbRect(self.state.total, self.state.offset, self.state.len, h, min_h);

    const thumb_alpha = self.thumbAlpha();
    const thumb_color = packBGRA(self.fg, thumb_alpha);

    var y: i32 = r.y;
    while (y < r.y + r.h and y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            pixels[@intCast(y * w + x)] = thumb_color;
        }
    }
}

fn thumbAlpha(self: *const Scrollbar) u8 {
    const base = if (self.dragging) ALPHA_DRAG
        else if (self.hover) ALPHA_HOVER
        else ALPHA_IDLE;
    // Task 5: no fade. Task 7 multiplies by self.fade.
    return base;
}

/// Pack RGB + alpha into premultiplied BGRA (UpdateLayeredWindow expects
/// premultiplied per-pixel alpha).
fn packBGRA(c: terminal.color.RGB, a: u8) u32 {
    // Premultiply: each channel *= a / 255.
    const af: f32 = @as(f32, @floatFromInt(a)) / 255.0;
    const r: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.r)) * af));
    const g: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.g)) * af));
    const b: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.b)) * af));
    return (@as(u32, a) << 24) | (r << 16) | (g << 8) | b;
}
```

(`GetDC`, `ReleaseDC`, `GetWindowRect`, `RECT` should be in `win32.zig`. Add if missing.)

- [ ] **Step 4: Wire `update` to repaint**

Replace the `update` stub with:

```zig
pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void {
    const changed = !self.first_update and !std.meta.eql(self.state, state);
    self.state = state;
    self.first_update = false;
    if (changed) self.repaint();
}
```

If `terminal.Scrollbar` doesn't implement `eql`/Zig equality, compare fields manually.

- [ ] **Step 5: Wire `setTheme` to repaint**

```zig
pub fn setTheme(self: *Scrollbar, bg: terminal.color.RGB, fg: terminal.color.RGB) void {
    if (std.meta.eql(self.bg, bg) and std.meta.eql(self.fg, fg)) return;
    self.bg = bg;
    self.fg = fg;
    self.repaint();
}
```

- [ ] **Step 6: Wire setTheme call site in Surface**

Find where Surface receives the terminal palette / theme. Look for `palette` or `setPaletteColor` or similar. Add a call:

```zig
if (self.scrollbar) |sb| sb.setTheme(
    self.core_surface.config.background.toTerminalRGB(),
    self.core_surface.config.foreground.toTerminalRGB(),
);
```

(Adjust to match the actual config field names — `Read` `Surface.zig` and `App.zig` for how the existing code reads bg/fg config.)

Call this once at scrollbar creation in `Surface.init` (after `Scrollbar.create`) so the initial colors are right.

- [ ] **Step 7: Build + manual visual test**

Build, copy to Desktop, run:
```bash
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

Expected: Open a tab, fill 200 lines with `for ($i=0; $i -lt 200; $i++) { echo "line $i" }`. The scrollbar should be visible at the right edge, painted in the theme colors. Resize the window — scrollbar should track the right edge.

Known limitation: there's no interaction yet. Wheel-scroll updates the thumb (because update fires repaint), but mouse drag does nothing.

- [ ] **Step 8: Commit**

```bash
git add src/apprt/win32/Scrollbar.zig src/apprt/win32/Surface.zig src/apprt/win32/win32.zig
git commit -m "feat(win32): paint themed scrollbar via UpdateLayeredWindow

Always-visible mode for now (mode dispatch lands in Task 8). Each
update() call repaints the BGRA bitmap and blits to the layered popup
via UpdateLayeredWindow with per-pixel alpha. Thumb position computed
by thumbRect() from Task 2; colors come from the terminal palette
plumbed through setTheme().

The scrollbar is now visible and tracks scroll position. Mouse
interaction (Task 6), fade animation (Task 7), and OS-mode dispatch
(Task 8) follow."
```

---

## Task 6: Mouse handling — hover, click, drag

**Files:**
- Modify: `src/apprt/win32/Scrollbar.zig`

- [ ] **Step 1: Implement WndProc handlers**

Replace `scrollbarWndProc` body:

```zig
fn scrollbarWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*Scrollbar = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
            self.onMouseMove(x, y);
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            self.onMouseLeave();
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
            self.onLeftDown(y);
            return 0;
        },

        w32.WM_LBUTTONUP => {
            self.onLeftUp();
            return 0;
        },

        WM_GHOSTTY_SCROLLBAR_QUERY => return @intFromEnum(self.visibility),

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
```

- [ ] **Step 2: Implement mouse callbacks**

Append:

```zig
fn ensureLeaveTracking(self: *Scrollbar) void {
    var tme = w32.TRACKMOUSEEVENT{
        .dwFlags = w32.TME_LEAVE,
        .hwndTrack = self.hwnd,
    };
    _ = w32.TrackMouseEvent(&tme);
}

fn trackHeight(self: *const Scrollbar) i32 {
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &rect) == 0) return 0;
    return rect.bottom - rect.top;
}

fn currentThumbRect(self: *const Scrollbar) ThumbRect {
    return thumbRect(
        self.state.total,
        self.state.offset,
        self.state.len,
        self.trackHeight(),
        self.dpiScaled(THUMB_MIN_HEIGHT_BASE),
    );
}

fn onMouseMove(self: *Scrollbar, x: i32, y: i32) void {
    _ = x;
    self.ensureLeaveTracking();

    if (self.dragging) {
        if (dragOffset(
            y,
            self.drag_anchor,
            self.trackHeight(),
            self.currentThumbRect().h,
            self.state.total,
            self.state.len,
        )) |off| {
            self.state.offset = off;
            self.surface.scrollToOffset(off);
            self.repaint();
        }
        return;
    }

    if (!self.hover) {
        self.hover = true;
        self.repaint();
    }
}

fn onMouseLeave(self: *Scrollbar) void {
    if (self.hover) {
        self.hover = false;
        self.repaint();
    }
}

fn onLeftDown(self: *Scrollbar, y: i32) void {
    const r = self.currentThumbRect();
    if (y >= r.y and y < r.y + r.h) {
        // Drag.
        _ = w32.SetCapture(self.hwnd);
        self.drag_anchor = y - r.y;
        self.dragging = true;
    } else {
        // Page click.
        const total = self.state.total;
        const len = self.state.len;
        if (total <= len) return;
        const max = total - len;
        const new_off = if (y < r.y)
            (if (self.state.offset > len) self.state.offset - len else 0)
        else
            @min(self.state.offset + len, max);
        self.state.offset = new_off;
        self.surface.scrollToOffset(new_off);
        self.repaint();
    }
}

fn onLeftUp(self: *Scrollbar) void {
    if (self.dragging) {
        _ = w32.ReleaseCapture();
        self.dragging = false;
        self.repaint();
    }
}
```

(`SetCapture`, `ReleaseCapture`, `GetWindowLongPtrW`, `WM_MOUSEMOVE`, `WM_LBUTTONDOWN`, `WM_LBUTTONUP`, `WM_MOUSELEAVE` should be in `win32.zig`. Add if missing.)

- [ ] **Step 3: Build + manual test**

Build, run, fill scrollback. Expected:
- Hover → thumb gets brighter (hover color).
- Click + drag thumb → terminal scrolls smoothly.
- Click track above/below thumb → page jump.

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/Scrollbar.zig src/apprt/win32/win32.zig
git commit -m "feat(win32): scrollbar mouse interaction (hover, drag, page-click)

Drag uses dragOffset() from Task 2. Page-click jumps by len rows.
TrackMouseEvent re-armed on every WM_MOUSEMOVE so we always get
WM_MOUSELEAVE. WM_MOUSEACTIVATE returns MA_NOACTIVATE so the popup
never steals focus from the terminal."
```

---

## Task 7: Visibility state machine + fade animation (overlay mode)

**Files:**
- Modify: `src/apprt/win32/Scrollbar.zig`

This task adds the auto-hide overlay behavior. Mode is still hard-coded to overlay-style behavior here; we'll dispatch on actual mode in Task 8.

- [ ] **Step 1: Add fade timer logic**

Append:

```zig
const FADE_TIMER_ID: usize = 1;
const IDLE_TIMER_ID: usize = 2;
const FADE_INTERVAL_MS: u32 = 16; // ~60Hz
const FADE_STEP: u8 = 32;
const IDLE_DELAY_MS: u32 = 1000;

fn startFadeIn(self: *Scrollbar) void {
    self.visibility = .fading_in;
    _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, FADE_INTERVAL_MS, null);
    self.clearTransparent();
    self.repaint();
}

fn startFadeOut(self: *Scrollbar) void {
    self.visibility = .fading_out;
    _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, FADE_INTERVAL_MS, null);
    self.repaint();
}

fn restartIdleTimer(self: *Scrollbar) void {
    _ = w32.SetTimer(self.hwnd, IDLE_TIMER_ID, IDLE_DELAY_MS, null);
}

fn onFadeTick(self: *Scrollbar) void {
    switch (self.visibility) {
        .fading_in => {
            const new_fade = @min(@as(u16, self.fade) + FADE_STEP, 255);
            self.fade = @intCast(new_fade);
            if (self.fade == 255) {
                self.visibility = .shown;
                _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
            }
            self.repaint();
        },
        .fading_out => {
            const new_fade = if (self.fade > FADE_STEP) self.fade - FADE_STEP else 0;
            self.fade = new_fade;
            if (self.fade == 0) {
                self.visibility = .hidden;
                _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
                self.setTransparent();
            }
            self.repaint();
        },
        else => _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID),
    }
}

fn onIdleTick(self: *Scrollbar) void {
    _ = w32.KillTimer(self.hwnd, IDLE_TIMER_ID);
    if (self.dragging or self.hover) return;
    self.startFadeOut();
}

fn setTransparent(self: *Scrollbar) void {
    const cur = w32.GetWindowLongW(self.hwnd, w32.GWL_EXSTYLE);
    _ = w32.SetWindowLongW(self.hwnd, w32.GWL_EXSTYLE, cur | @as(i32, @bitCast(w32.WS_EX_TRANSPARENT)));
}

fn clearTransparent(self: *Scrollbar) void {
    const cur = w32.GetWindowLongW(self.hwnd, w32.GWL_EXSTYLE);
    _ = w32.SetWindowLongW(self.hwnd, w32.GWL_EXSTYLE, cur & ~@as(i32, @bitCast(w32.WS_EX_TRANSPARENT)));
}
```

- [ ] **Step 2: Wire `WM_TIMER` in WndProc**

Add to the `switch (msg)` in `scrollbarWndProc`:

```zig
w32.WM_TIMER => {
    switch (wparam) {
        FADE_TIMER_ID => self.onFadeTick(),
        IDLE_TIMER_ID => self.onIdleTick(),
        else => {},
    }
    return 0;
},
```

- [ ] **Step 3: Update `update()` to trigger fade-in**

Replace the existing `update`:

```zig
pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void {
    const was_first = self.first_update;
    const changed = !std.meta.eql(self.state, state);
    self.state = state;
    self.first_update = false;

    if (was_first) {
        // Initial state — silent. In overlay mode start hidden + transparent.
        self.visibility = .hidden;
        self.fade = 0;
        self.setTransparent();
        return;
    }

    if (changed) {
        if (self.visibility == .hidden or self.visibility == .fading_out) {
            self.startFadeIn();
        }
        self.restartIdleTimer();
        self.repaint();
    }
}
```

- [ ] **Step 4: Update `onMouseMove` and `onMouseLeave`**

In `onMouseMove`, before the existing hover assignment:

```zig
if (self.visibility == .hidden or self.visibility == .fading_out) {
    self.startFadeIn();
}
```

In `onMouseLeave`, after clearing hover (if not dragging):

```zig
if (!self.dragging) self.restartIdleTimer();
```

- [ ] **Step 5: Update `thumbAlpha` to incorporate fade**

```zig
fn thumbAlpha(self: *const Scrollbar) u8 {
    const base = if (self.dragging) ALPHA_DRAG
        else if (self.hover) ALPHA_HOVER
        else ALPHA_IDLE;
    return effectiveAlpha(base, self.fade);
}
```

- [ ] **Step 6: Update `drawBitmap` to skip the track**

Track is fully transparent in overlay. Replace the `bg` fill loop with zero-fill (alpha=0):

```zig
const total = w * h;
var i: i32 = 0;
while (i < total) : (i += 1) {
    pixels[@intCast(i)] = 0; // fully transparent
}
```

- [ ] **Step 7: Build + manual test**

Build and run. Expected:
- On open, no scrollbar visible.
- Scroll with wheel → scrollbar fades in over ~133ms.
- After 1s idle → scrollbar fades out.
- Hover near right edge → fades back in.
- Click while hidden → falls through to terminal (because WS_EX_TRANSPARENT).

- [ ] **Step 8: Commit**

```bash
git add src/apprt/win32/Scrollbar.zig
git commit -m "feat(win32): scrollbar fade-in/out + auto-hide

WS_EX_TRANSPARENT toggled on hidden state so clicks fall through to
the terminal beneath. Fade timer drives ~133ms transitions; idle
timer fires fade-out 1s after last scroll/hover. Initial first
update() is silent (no startup flash)."
```

---

## Task 8: Mode detection (registry + WM_SETTINGCHANGE)

**Files:**
- Modify: `src/apprt/win32/Scrollbar.zig`

- [ ] **Step 1: Implement registry read**

Append:

```zig
fn readDynamicScrollbars() ?u32 {
    const key_name = std.unicode.utf8ToUtf16LeStringLiteral("Control Panel\\Accessibility");
    var key: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, key_name, 0, w32.KEY_READ, &key) != w32.ERROR_SUCCESS) {
        return null;
    }
    defer _ = w32.RegCloseKey(key);

    var value: u32 = 0;
    var size: u32 = @sizeOf(u32);
    var ty: u32 = 0;
    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("DynamicScrollbars");
    if (w32.RegQueryValueExW(
        key,
        value_name,
        null,
        &ty,
        @ptrCast(&value),
        &size,
    ) != w32.ERROR_SUCCESS) {
        return null;
    }
    if (ty != w32.REG_DWORD) return null;
    return value;
}

fn readMode() Mode {
    return parseMode(readDynamicScrollbars());
}
```

- [ ] **Step 2: Use `readMode` at creation**

In `Scrollbar.create`, after the struct init but before returning, set the mode:

```zig
self.mode = readMode();
```

- [ ] **Step 3: Mode-aware width**

Replace `currentWidth`:

```zig
fn currentWidth(self: *const Scrollbar) i32 {
    return switch (self.mode) {
        .always_visible => self.dpiScaled(SCROLLBAR_WIDTH_BASE),
        .overlay => self.dpiScaled(if (self.hover or self.dragging)
            SCROLLBAR_WIDTH_BASE
        else
            SCROLLBAR_WIDTH_OVERLAY_COLLAPSED),
    };
}
```

- [ ] **Step 4: Mode-aware paint**

Replace `drawBitmap`:

```zig
fn drawBitmap(self: *Scrollbar, pixels: [*]u32, w: i32, h: i32) void {
    const total_px = w * h;

    // Track fill.
    const track_pixel: u32 = switch (self.mode) {
        .always_visible => packBGRA(self.bg, 255),
        .overlay => 0, // fully transparent
    };
    var i: i32 = 0;
    while (i < total_px) : (i += 1) pixels[@intCast(i)] = track_pixel;

    // Thumb.
    const min_h = self.dpiScaled(THUMB_MIN_HEIGHT_BASE);
    const r = thumbRect(self.state.total, self.state.offset, self.state.len, h, min_h);

    const thumb_color = packBGRA(self.fg, self.thumbAlpha());

    var y: i32 = r.y;
    while (y < r.y + r.h and y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            pixels[@intCast(y * w + x)] = thumb_color;
        }
    }
}
```

- [ ] **Step 5: Mode-aware `thumbAlpha`**

```zig
fn thumbAlpha(self: *const Scrollbar) u8 {
    const base = if (self.dragging) ALPHA_DRAG
        else if (self.hover) ALPHA_HOVER
        else ALPHA_IDLE;
    return switch (self.mode) {
        .always_visible => base,
        .overlay => effectiveAlpha(base, self.fade),
    };
}
```

- [ ] **Step 6: Mode-aware `update`**

Update the `update` so always-visible mode doesn't fade:

```zig
pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void {
    const was_first = self.first_update;
    const changed = !std.meta.eql(self.state, state);
    self.state = state;
    self.first_update = false;

    if (was_first) {
        switch (self.mode) {
            .overlay => {
                self.visibility = .hidden;
                self.fade = 0;
                self.setTransparent();
            },
            .always_visible => {
                self.visibility = .shown;
                self.fade = 255;
                self.clearTransparent();
            },
        }
        self.repaint();
        return;
    }

    if (changed) {
        if (self.mode == .overlay) {
            if (self.visibility == .hidden or self.visibility == .fading_out) {
                self.startFadeIn();
            }
            self.restartIdleTimer();
        }
        self.repaint();
    }
}
```

- [ ] **Step 7: Implement `onSettingsChange`**

```zig
pub fn onSettingsChange(self: *Scrollbar) bool {
    const new_mode = readMode();
    if (new_mode == self.mode) return false;
    self.mode = new_mode;
    switch (self.mode) {
        .overlay => {
            self.visibility = .hidden;
            self.fade = 0;
            self.setTransparent();
        },
        .always_visible => {
            _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
            _ = w32.KillTimer(self.hwnd, IDLE_TIMER_ID);
            self.visibility = .shown;
            self.fade = 255;
            self.clearTransparent();
        },
    }
    self.repaint();
    return true;
}
```

- [ ] **Step 8: Mode-aware width-to-subtract**

In `repositionAndResize`, change the return:

```zig
return switch (self.mode) {
    .always_visible => width,
    .overlay => 0,
};
```

- [ ] **Step 9: Plumb width-to-subtract through Surface.handleResize**

In `Surface.handleResize`, before calling `core_surface.sizeCallback`, subtract the scrollbar's width:

```zig
var grid_width = width;
if (self.scrollbar) |sb| {
    const sub = sb.repositionAndResize();
    if (sub > 0 and grid_width > sub) {
        grid_width -= @intCast(sub);
    }
}
```

And pass `grid_width` to `sizeCallback` instead of `width`. Also pass `grid_width` to `self.width` (so clients downstream see the corrected width).

This is subtle — read the existing `handleResize` carefully. The scrollbar repositions based on the **owner's** client rect (full width), but the grid uses `width - scrollbar_width` columns.

- [ ] **Step 10: Verify with `Read`**

Re-read `Surface.zig:1455-1500` to confirm the changes are in the right place.

- [ ] **Step 11: Manual test**

Build, run. Default Win11 setup → overlay mode (auto-hide). Toggle Settings → Accessibility → Visual effects → "Always show scrollbars" ON. Without restarting Ghostty:

Expected: scrollbar becomes always-visible immediately, terminal grid loses one column. Toggle off: returns to overlay, grid recovers column.

- [ ] **Step 12: Commit**

```bash
git add src/apprt/win32/Scrollbar.zig src/apprt/win32/Surface.zig
git commit -m "feat(win32): scrollbar honors OS DynamicScrollbars setting

Reads HKCU\\Control Panel\\Accessibility\\DynamicScrollbars at create
and on WM_SETTINGCHANGE. Overlay mode (the Win11 default) auto-hides;
always-visible mode paints an opaque widget that steals one column of
grid space. Mode flip triggers a re-flow via WM_SIZE."
```

---

## Task 9: Integration test

**Files:**
- Create: `test/win32/test_scrollbar.ps1`
- Modify: `test/win32/run_tests.ps1`

- [ ] **Step 1: Write the test**

Create `test/win32/test_scrollbar.ps1`:

```powershell
# test_scrollbar.ps1 — verifies the themed scrollbar overlay
#
# Tested behavior:
#   1. Filling scrollback causes the scrollbar popup to exist as an
#      owned popup of the surface HWND.
#   2. Within ~150ms of the scroll event, the popup's visibility state
#      is fading_in or shown.
#   3. After 1.5s of idle, the visibility state has transitioned to
#      hidden.

param(
    [string]$ExePath = "$env:USERPROFILE\Desktop\ghostty.exe"
)

. "$PSScriptRoot\test_harness.ps1"

$WM_GHOSTTY_SCROLLBAR_QUERY = 0x0400 + 1  # WM_USER + 1

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class ScrollbarHelpers {
    public delegate bool EnumThreadDelegate(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumThreadWindows(int dwThreadId, EnumThreadDelegate lpfn, IntPtr lParam);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern int GetClassName(IntPtr hwnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hwnd, uint uCmd);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hwnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@

function Find-ScrollbarPopup($surfaceHwnd, $tid) {
    $found = [IntPtr]::Zero
    $cb = [ScrollbarHelpers+EnumThreadDelegate] {
        param($hwnd, $lp)
        $cls = New-Object System.Text.StringBuilder 64
        [void][ScrollbarHelpers]::GetClassName($hwnd, $cls, 64)
        if ($cls.ToString() -eq "GhosttyScrollbar") {
            $owner = [ScrollbarHelpers]::GetWindow($hwnd, 4)  # GW_OWNER
            if ($owner -eq $surfaceHwnd) {
                $script:found = $hwnd
                return $false
            }
        }
        return $true
    }
    [void][ScrollbarHelpers]::EnumThreadWindows($tid, $cb, [IntPtr]::Zero)
    return $found
}

$ctx = Start-Ghostty $ExePath
try {
    Wait-ForReady $ctx

    # Fill 200 lines of scrollback.
    Send-KeysToGhostty $ctx 'for ($i=0; $i -lt 200; $i++) { Write-Host "line $i" }'
    Send-KeysToGhostty $ctx '{ENTER}'
    Start-Sleep -Milliseconds 500

    # Scroll to top — triggers scrollbar fade-in.
    Send-KeysToGhostty $ctx '^{HOME}'
    Start-Sleep -Milliseconds 200

    # Locate the scrollbar popup.
    $tid = [ScrollbarHelpers]::GetWindowThreadProcessId($ctx.MainHwnd, [ref]([uint32]0))
    $sb = Find-ScrollbarPopup $ctx.SurfaceHwnd $tid
    if ($sb -eq [IntPtr]::Zero) {
        throw "scrollbar popup not found"
    }

    # Visibility should be fading_in (1) or shown (2) immediately after scroll.
    $state = [ScrollbarHelpers]::SendMessage($sb, $WM_GHOSTTY_SCROLLBAR_QUERY, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
    if ($state -lt 1 -or $state -gt 2) {
        throw "expected visibility fading_in/shown, got $state"
    }
    Write-Host "PASS: scrollbar visible after scroll (state=$state)"

    # Wait 1.5s for idle fade-out.
    Start-Sleep -Milliseconds 1500
    $state = [ScrollbarHelpers]::SendMessage($sb, $WM_GHOSTTY_SCROLLBAR_QUERY, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
    if ($state -ne 0) {
        throw "expected visibility hidden after idle, got $state"
    }
    Write-Host "PASS: scrollbar auto-hides after idle"

    Write-Host "ALL PASS"
    exit 0
}
finally {
    Stop-Ghostty $ctx
}
```

(`Start-Ghostty`, `Wait-ForReady`, `Send-KeysToGhostty`, `Stop-Ghostty`, the `$ctx.SurfaceHwnd` field, etc., are defined in `test_harness.ps1`. If `SurfaceHwnd` doesn't already exist in the harness, add it — most other tests reference the surface HWND already.)

- [ ] **Step 2: Add to run_tests.ps1**

Read `test/win32/run_tests.ps1` to find the test list and append:

```powershell
"test_scrollbar.ps1",
```

(Position it next to the other UI integration tests.)

- [ ] **Step 3: Build a fresh exe**

```bash
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

Copy `zig-out/bin/ghostty.exe` to Desktop.

- [ ] **Step 4: Run the test from PowerShell**

```powershell
pwsh -File test/win32/test_scrollbar.ps1
```

Expected: `PASS: scrollbar visible after scroll`, `PASS: scrollbar auto-hides after idle`, `ALL PASS`.

- [ ] **Step 5: Run the full harness**

```powershell
pwsh -File test/win32/run_tests.ps1
```

Expected: every test passes (the new test plus the existing 30).

- [ ] **Step 6: Commit**

```bash
git add test/win32/test_scrollbar.ps1 test/win32/run_tests.ps1
git commit -m "test(win32): integration test for themed scrollbar overlay

Asserts the scrollbar popup exists as an owned popup of the surface
HWND, fades in within 200ms of a scroll event, and fades out after
1.5s of idle. Uses WM_GHOSTTY_SCROLLBAR_QUERY rather than
IsWindowVisible because layered windows with alpha=0 are still
'visible' from Win32's perspective."
```

---

## Task 10: Manual visual verification + release notes

**Files:**
- Modify: `CHANGELOG.md` (or wherever release notes live in this repo)

- [ ] **Step 1: Visual sanity check**

Build:
```bash
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

Copy `zig-out/bin/ghostty.exe` and `zig-out/share/` to Desktop. Launch and verify:

- Default theme (dark): thumb is a subtle off-white translucent rectangle.
- `theme = gruvbox-dark`: thumb is gruvbox foreground (cream / tan).
- `theme = github-light`: thumb is dark grey on light background, clearly visible.
- Toggle Settings → Accessibility → Visual effects → "Always show scrollbars" ON: scrollbar becomes solid, terminal loses one column, no auto-hide. Toggle OFF: returns to overlay.
- Resize window: scrollbar tracks the right edge with at most one frame of lag.
- Drag the thumb: terminal scrolls smoothly.
- Click above/below the thumb: page jump.

- [ ] **Step 2: Update changelog**

Find the project's changelog file (likely `CHANGELOG.md` at the repo root). Add an entry under the current unreleased / next-version section:

```markdown
- **Themed scrollbar (Win32)**: replaced the native white WS_VSCROLL
  with a custom layered-popup scrollbar painted in terminal theme
  colors. Honors the OS "Always show scrollbars" accessibility setting:
  overlay (auto-hide) by default, always-visible when the OS prefers it.
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog entry for win32 themed scrollbar"
```

---

## Self-Review Notes

Spec coverage check (each spec section → task):

- **Architecture / why layered popup** → Tasks 3 (creation), 5 (painting).
- **Painting via UpdateLayeredWindow** → Task 5.
- **Position tracking (WM_MOVE/WM_SIZE/WM_SHOWWINDOW)** → Tasks 4 (forwarding), 5 (repositionAndResize).
- **Removal of native scrollbar** → Task 4.
- **Public interface** → Tasks 3 (skeleton), 4 (stubs), 5/6/7/8 (real implementations).
- **Memory ownership** → Task 3 (`alloc.create`), Task 4 (Surface init/deinit).
- **Threading** → Implicit; no locks added in any task.
- **Split panes / tabs** → Task 4 wires WM_SHOWWINDOW; per-Surface ownership inherently handles splits.
- **Scroll action callback** → Task 4 (`scrollToOffset`).
- **Mode detection** → Task 8.
- **Geometry (widths, hover/visibility axes)** → Task 5 (always-visible width), Task 6 (hover), Task 7 (visibility), Task 8 (mode-aware width).
- **Painting (colors, alpha)** → Task 5 (BGRA), Task 7 (fade multiplier), Task 8 (mode-aware track).
- **Visibility state machine** → Task 7.
- **Mouse handling** → Task 6.
- **Focus / activation** → Task 3 (`WS_EX_NOACTIVATE`), Task 6 (`WM_MOUSEACTIVATE`).
- **Click-through when hidden** → Task 7 (`setTransparent`/`clearTransparent`).
- **Drag math** → Task 2 (`dragOffset`), Task 6 (call site).
- **Unit tests** → Task 2.
- **Integration test** → Task 9.
- **Manual visual verification** → Task 10.
- **Files changed** → Tasks 1-9 cover all listed files.
- **Risks** — DynamicScrollbars semantics verified empirically in Task 8 step 11; grid off-by-one caught by manual test in Task 10; drag-during-fade-out is implicit in `onIdleTick` checking `self.dragging`; popup position lag during resize is acceptable per spec; multi-monitor DPI handled by `onDpiChanged` (Task 4 stub, no changes needed since all widths are computed from `self.scale` at paint time).

No placeholders. Method names checked for consistency across tasks (`update`, `repositionAndResize`, `setOwnerVisible`, `setTheme`, `onSettingsChange`, `onDpiChanged`, `scrollToOffset` all match the spec).
