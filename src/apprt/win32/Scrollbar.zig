//! Themed scrollbar for the Win32 apprt. See
//! docs/superpowers/specs/2026-04-29-win32-themed-scrollbar-design.md

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");
const testing = std.testing;

const log = std.log.scoped(.win32_scrollbar);

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
    if (total == 0 or len >= total) {
        return .{ .y = 0, .h = track_h };
    }
    const total_f: f32 = @floatFromInt(total);
    const offset_f: f32 = @floatFromInt(offset);
    const len_f: f32 = @floatFromInt(len);
    const track_f: f32 = @floatFromInt(track_h);

    const computed_h_f = (len_f / total_f) * track_f;
    const computed_h: i32 = @intFromFloat(@round(computed_h_f));
    const h = @min(track_h, @max(min_h, computed_h));

    const computed_y_f = (offset_f / total_f) * track_f;
    var y: i32 = @intFromFloat(@round(computed_y_f));
    // Clamp so the thumb never extends past the track.
    if (y + h > track_h) y = track_h - h;
    if (y < 0) y = 0;

    return .{ .y = y, .h = h };
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
    if (total <= len) return null;
    const track_range = track_h - thumb_h;
    if (track_range <= 0) return null;

    const new_thumb_y = std.math.clamp(mouse_y - drag_anchor, 0, track_range);
    const range_f: f32 = @floatFromInt(track_range);
    const thumb_y_f: f32 = @floatFromInt(new_thumb_y);
    const max_off_f: f32 = @floatFromInt(total - len);

    return @intFromFloat(@round(thumb_y_f / range_f * max_off_f));
}

/// Effective alpha = base_alpha * fade / 255, saturating at 255.
pub fn effectiveAlpha(base_alpha: u8, fade: u8) u8 {
    const product: u16 = @as(u16, base_alpha) * @as(u16, fade) / 255;
    return @intCast(@min(product, 255));
}

pub const Mode = enum { overlay, always_visible };

/// Parse the registry DynamicScrollbars value into a Mode.
/// `value == null` means the value didn't exist.
pub fn parseMode(value: ?u32) Mode {
    if (value) |v| {
        return if (v == 0) .always_visible else .overlay;
    }
    return .overlay;
}

// ---------------------------------------------------------------------------
// Scrollbar window class + struct
// ---------------------------------------------------------------------------

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

    /// Update the cached scroll state. Painting / state-machine
    /// integration comes in later tasks.
    pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void {
        self.state = state;
        self.first_update = false;
    }

    /// Reposition and resize the popup to stay glued to the surface.
    /// Returns the new scrollbar width (stub returns 0 until Task 5).
    pub fn repositionAndResize(self: *Scrollbar) i32 {
        _ = self;
        return 0;
    }

    /// Show or hide the popup when the owner surface is shown/hidden.
    pub fn setOwnerVisible(self: *Scrollbar, visible: bool) void {
        _ = w32.ShowWindow(self.hwnd, if (visible) w32.SW_SHOWNOACTIVATE else w32.SW_HIDE);
    }

    /// Update cached theme colors (used by the painter in later tasks).
    pub fn setTheme(self: *Scrollbar, bg: terminal.color.RGB, fg: terminal.color.RGB) void {
        self.bg = bg;
        self.fg = fg;
    }

    /// Called on WM_SETTINGCHANGE. Returns true if a mode change
    /// requires the terminal grid to be re-flowed.
    pub fn onSettingsChange(self: *Scrollbar) bool {
        _ = self;
        return false; // No-op until Task 8.
    }

    /// Update the DPI scale factor.
    pub fn onDpiChanged(self: *Scrollbar, dpi: u32) void {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
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
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
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

test "thumbRect: clamps when min_h exceeds track_h" {
    // Tiny track + normal min_h: h should not exceed track_h.
    const r = thumbRect(1000, 0, 50, 10, 20);
    try testing.expect(r.h <= 10);
    try testing.expect(r.y + r.h <= 10);
}

test "thumbRect: clamps when offset would push thumb past bottom" {
    // offset=999 → naive y = round(999/1000 * 400) = 400; with h=20 the
    // thumb would extend to 420. Clamp must pull y back to track_h - h = 380.
    const r = thumbRect(1000, 999, 50, 400, 20);
    try testing.expectEqual(@as(i32, 380), r.y);
    try testing.expectEqual(@as(i32, 20), r.h);
    try testing.expect(r.y + r.h <= 400);
}

test "dragOffset: applies drag_anchor" {
    // drag_anchor=100 should be equivalent to mouse_y shifted by -100.
    const a = dragOffset(190, 100, 400, 20, 1000, 50).?;
    const b = dragOffset(90, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(b, a);
}

test "dragOffset: rounds half to nearest" {
    // mouse_y=191, drag_anchor=0 → 191/380 * 950 = 477.5 → 478 (round-half-to-even rounds .5 up here).
    const off = dragOffset(191, 0, 400, 20, 1000, 50).?;
    try testing.expect(off == 477 or off == 478);
}

test "parseMode: non-{0,1} value treated as overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(2));
    try testing.expectEqual(Mode.overlay, parseMode(99));
}
