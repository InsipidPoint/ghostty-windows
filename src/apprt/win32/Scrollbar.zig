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
