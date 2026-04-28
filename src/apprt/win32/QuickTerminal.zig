//! Quick Terminal: a borderless popup window that slides in/out from a
//! screen edge. Owned by App, separate from the normal windows list.
const QuickTerminal = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_quick_terminal);

/// Animation timer ID (must not collide with QUIT_TIMER_ID=1 or notification=2).
pub const ANIM_TIMER_ID: usize = 3;

/// Animation tick interval in milliseconds (~60fps).
const ANIM_TICK_MS: u32 = 16;

app: *App,
window: *Window,
visible: bool = false,
animating: bool = false,
animation_direction: enum { in, out } = .in,
animation_start_time: i64 = 0,
animation_duration: f64 = 0.2,
perf_freq: i64 = 1, // avoid division by zero

// Cached rects for animation interpolation.
target_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
hidden_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

pub fn init(app: *App) !*QuickTerminal {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(QuickTerminal);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .window = undefined,
    };

    // Query performance counter frequency for animation timing.
    _ = w32.QueryPerformanceFrequency(&self.perf_freq);

    // Read animation duration from config.
    self.animation_duration = app.config.@"quick-terminal-animation-duration";

    // Create the window in quick terminal mode.
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(app, .{ .is_quick_terminal = true });
    self.window = window;

    // Add a single tab (surface) to the window.
    _ = try window.addTab();

    return self;
}

pub fn deinit(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;

    // Kill animation timer if running.
    if (self.animating) {
        _ = w32.KillTimer(app.msg_hwnd, ANIM_TIMER_ID);
        self.animating = false;
    }

    // Prevent onDestroy from calling onWindowDestroyed (we're cleaning up ourselves).
    app.quick_terminal = null;

    // Clean up the window.
    self.window.close();
    alloc.destroy(self.window);
    alloc.destroy(self);
}

/// Toggle the quick terminal in or out. Called from App.performAction.
pub fn toggle(self: *QuickTerminal) void {
    if (self.animating) {
        // Mid-animation: reverse direction from current position.
        self.animation_direction = if (self.animation_direction == .in) .out else .in;
        // Adjust start time so progress continues smoothly from current position.
        const elapsed_ticks = self.now() - self.animation_start_time;
        const elapsed = @as(f64, @floatFromInt(elapsed_ticks)) / @as(f64, @floatFromInt(self.perf_freq));
        const progress = @min(elapsed / self.animation_duration, 1.0);
        const remaining = (1.0 - progress) * self.animation_duration;
        self.animation_start_time = self.now() - @as(i64, @intFromFloat(remaining * @as(f64, @floatFromInt(self.perf_freq))));
        return;
    }

    if (self.visible) {
        self.animateOut();
    } else {
        self.animateIn();
    }
}

fn animateIn(self: *QuickTerminal) void {
    // Recalculate position each time (handles monitor changes, config reload).
    self.calculateRects();

    const hwnd = self.window.hwnd orelse return;

    // Position at hidden rect before showing.
    _ = w32.SetWindowPos(
        hwnd,
        w32.HWND_TOPMOST,
        self.hidden_rect.left,
        self.hidden_rect.top,
        self.hidden_rect.right - self.hidden_rect.left,
        self.hidden_rect.bottom - self.hidden_rect.top,
        w32.SWP_NOACTIVATE,
    );

    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);

    if (self.animation_duration <= 0) {
        // Instant: jump to target.
        _ = w32.SetWindowPos(
            hwnd,
            w32.HWND_TOPMOST,
            self.target_rect.left,
            self.target_rect.top,
            self.target_rect.right - self.target_rect.left,
            self.target_rect.bottom - self.target_rect.top,
            w32.SWP_NOACTIVATE,
        );
        self.visible = true;
        self.forceForeground();
        return;
    }

    self.animation_direction = .in;
    self.animation_start_time = self.now();
    self.animating = true;
    _ = w32.SetTimer(self.app.msg_hwnd, ANIM_TIMER_ID, ANIM_TICK_MS, null);
}

fn animateOut(self: *QuickTerminal) void {
    if (self.animation_duration <= 0) {
        // Instant hide.
        if (self.window.hwnd) |hwnd| {
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        }
        self.visible = false;
        return;
    }

    self.animation_direction = .out;
    self.animation_start_time = self.now();
    self.animating = true;
    _ = w32.SetTimer(self.app.msg_hwnd, ANIM_TIMER_ID, ANIM_TICK_MS, null);
}

/// Called from App's WM_TIMER handler on each animation tick.
pub fn onAnimationTick(self: *QuickTerminal) void {
    if (!self.animating) return;

    const elapsed_ticks = self.now() - self.animation_start_time;
    const elapsed = @as(f64, @floatFromInt(elapsed_ticks)) / @as(f64, @floatFromInt(self.perf_freq));
    const progress = @min(elapsed / self.animation_duration, 1.0);

    // For animate-out, invert progress so interpolation goes from visible→hidden.
    const t = if (self.animation_direction == .in) easeInOutCubic(progress) else 1.0 - easeInOutCubic(progress);

    const hwnd = self.window.hwnd orelse return;

    // Interpolate position.
    const x = lerp(self.hidden_rect.left, self.target_rect.left, t);
    const y = lerp(self.hidden_rect.top, self.target_rect.top, t);
    const w = self.target_rect.right - self.target_rect.left;
    const h = self.target_rect.bottom - self.target_rect.top;

    _ = w32.SetWindowPos(hwnd, w32.HWND_TOPMOST, x, y, w, h, w32.SWP_NOACTIVATE);

    if (progress >= 1.0) {
        // Animation complete.
        _ = w32.KillTimer(self.app.msg_hwnd, ANIM_TIMER_ID);
        self.animating = false;

        if (self.animation_direction == .in) {
            self.visible = true;
            self.forceForeground();
        } else {
            self.visible = false;
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        }
    }
}

/// Called when the quick terminal window loses focus.
pub fn onFocusLost(self: *QuickTerminal) void {
    if (!self.visible) return;
    if (self.animating and self.animation_direction == .out) return;
    if (!self.app.config.@"quick-terminal-autohide") return;

    self.animateOut();
}

/// Called when the quick terminal's window is destroyed (shell exited).
/// At this point Window.onDestroy has already cleaned up font/hwnd.
pub fn onWindowDestroyed(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;

    // Kill the animation timer unconditionally — `self.animating` may
    // be false but a stray WM_TIMER could already be queued. Once `self`
    // is freed below, dispatching that timer would touch freed memory.
    _ = w32.KillTimer(app.msg_hwnd, ANIM_TIMER_ID);

    alloc.destroy(self.window);
    app.quick_terminal = null;
    alloc.destroy(self);

    // Check if we should start the quit timer (after self is freed).
    if (app.windows.items.len == 0) {
        app.startQuitTimer();
    }
}

/// Update cached config values after a config reload.
pub fn onConfigChange(self: *QuickTerminal, config: *const configpkg.Config) void {
    self.animation_duration = config.@"quick-terminal-animation-duration";
}

// -----------------------------------------------------------------------
// Position calculation
// -----------------------------------------------------------------------

/// Compute the target (visible) and hidden (off-screen) rects based on
/// the current monitor and config.
fn calculateRects(self: *QuickTerminal) void {
    const config = &self.app.config;
    const position = config.@"quick-terminal-position";

    // Get monitor work area.
    const monitor = self.getMonitor() orelse return;
    var mi = w32.MONITORINFO{
        .cbSize = @sizeOf(w32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    if (w32.GetMonitorInfoW(monitor, &mi) == 0) return;

    const work = mi.rcWork;
    const mw: u32 = @intCast(work.right - work.left);
    const mh: u32 = @intCast(work.bottom - work.top);

    // Use the config's calculate() method for size.
    const size = config.@"quick-terminal-size".calculate(position, .{
        .width = mw,
        .height = mh,
    });

    // Apply DPI scaling to default pixel values (calculate() returns
    // unscaled defaults like 400px).
    const scale = self.window.scale;
    var qw: i32 = if (config.@"quick-terminal-size".primary != null or config.@"quick-terminal-size".secondary != null)
        @intCast(size.width)
    else
        @intFromFloat(@round(@as(f32, @floatFromInt(size.width)) * scale));
    var qh: i32 = if (config.@"quick-terminal-size".primary != null or config.@"quick-terminal-size".secondary != null)
        @intCast(size.height)
    else
        @intFromFloat(@round(@as(f32, @floatFromInt(size.height)) * scale));

    // Clamp to work area.
    if (qw > @as(i32, @intCast(mw))) qw = @intCast(mw);
    if (qh > @as(i32, @intCast(mh))) qh = @intCast(mh);

    switch (position) {
        .top => {
            self.target_rect = .{ .left = work.left, .top = work.top, .right = work.left + qw, .bottom = work.top + qh };
            self.hidden_rect = .{ .left = work.left, .top = work.top - qh, .right = work.left + qw, .bottom = work.top };
        },
        .bottom => {
            self.target_rect = .{ .left = work.left, .top = work.bottom - qh, .right = work.left + qw, .bottom = work.bottom };
            self.hidden_rect = .{ .left = work.left, .top = work.bottom, .right = work.left + qw, .bottom = work.bottom + qh };
        },
        .left => {
            self.target_rect = .{ .left = work.left, .top = work.top, .right = work.left + qw, .bottom = work.top + qh };
            self.hidden_rect = .{ .left = work.left - qw, .top = work.top, .right = work.left, .bottom = work.top + qh };
        },
        .right => {
            self.target_rect = .{ .left = work.right - qw, .top = work.top, .right = work.right, .bottom = work.top + qh };
            self.hidden_rect = .{ .left = work.right, .top = work.top, .right = work.right + qw, .bottom = work.top + qh };
        },
        .center => {
            const cx = work.left + @divTrunc(@as(i32, @intCast(mw)) - qw, 2);
            const cy = work.top + @divTrunc(@as(i32, @intCast(mh)) - qh, 2);
            self.target_rect = .{ .left = cx, .top = cy, .right = cx + qw, .bottom = cy + qh };
            self.hidden_rect = .{ .left = cx, .top = work.top - qh, .right = cx + qw, .bottom = work.top };
        },
    }
}

fn getMonitor(self: *QuickTerminal) ?w32.HMONITOR {
    const screen = self.app.config.@"quick-terminal-screen";
    switch (screen) {
        .main, .@"macos-menu-bar" => {
            return w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY);
        },
        .mouse => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                return w32.MonitorFromPoint(pt, w32.MONITOR_DEFAULTTONEAREST);
            }
            return w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY);
        },
    }
}

// -----------------------------------------------------------------------
// Animation helpers
// -----------------------------------------------------------------------

/// Force the quick terminal to the foreground, even when Ghostty is a
/// background process. Uses AttachThreadInput to work around the Win32
/// SetForegroundWindow restriction.
fn forceForeground(self: *QuickTerminal) void {
    const hwnd = self.window.hwnd orelse return;
    const fg = w32.GetForegroundWindow();
    if (fg) |fg_hwnd| {
        const fg_tid = w32.GetWindowThreadProcessId(fg_hwnd, null);
        const our_tid = w32.GetCurrentThreadId();
        if (fg_tid != our_tid) {
            _ = w32.AttachThreadInput(our_tid, fg_tid, 1);
            _ = w32.SetForegroundWindow(hwnd);
            _ = w32.AttachThreadInput(our_tid, fg_tid, 0);
        } else {
            _ = w32.SetForegroundWindow(hwnd);
        }
    } else {
        _ = w32.SetForegroundWindow(hwnd);
    }
    // Focus the terminal surface inside the window.
    if (self.window.getActiveSurface()) |s| {
        if (s.hwnd) |sh| _ = w32.SetFocus(sh);
    }
}

fn now(_: *QuickTerminal) i64 {
    var count: i64 = 0;
    _ = w32.QueryPerformanceCounter(&count);
    return count;
}

/// Cubic ease-in-out: smooth acceleration and deceleration.
fn easeInOutCubic(t: f64) f64 {
    if (t < 0.5) {
        return 4.0 * t * t * t;
    } else {
        const f = -2.0 * t + 2.0;
        return 1.0 - (f * f * f) / 2.0;
    }
}

/// Interpolate between two values using eased progress.
fn lerp(a: i32, b: i32, t: f64) i32 {
    return a + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(b - a)) * t)));
}
