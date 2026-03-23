# Quick Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a slide-in/out borderless terminal window toggled via global hotkey for the Win32 apprt.

**Architecture:** New `QuickTerminal.zig` owns a `Window` configured with `WS_POPUP` style and `is_quick_terminal=true`. `App` holds `?*QuickTerminal`, registers a system-wide hotkey via `RegisterHotKey`, handles `WM_HOTKEY` in the message loop, and delegates animation ticks via `WM_TIMER`. The quick terminal slides to/from a screen edge using timer-driven `SetWindowPos` with cubic ease-in-out interpolation.

**Tech Stack:** Zig, Win32 API (RegisterHotKey, SetTimer, SetWindowPos, MonitorFromPoint, AttachThreadInput, QueryPerformanceCounter)

**Spec:** `docs/superpowers/specs/2026-03-23-quick-terminal-design.md`

---

### Task 1: Win32 API Declarations

**Files:**
- Modify: `src/apprt/win32/win32.zig` (append after popup menu section, ~line 1036)

- [ ] **Step 1: Add timer API**

```zig
// -----------------------------------------------------------------------
// Timer API
// -----------------------------------------------------------------------

pub const WM_TIMER: u32 = 0x0113;

pub extern "user32" fn SetTimer(
    hWnd: ?HWND,
    nIDEvent: usize,
    uElapse: u32,
    lpTimerFunc: ?*const anyopaque,
) callconv(.c) usize;

pub extern "user32" fn KillTimer(
    hWnd: ?HWND,
    uIDEvent: usize,
) callconv(.c) i32;
```

- [ ] **Step 2: Add global hotkey API**

```zig
// -----------------------------------------------------------------------
// Global hotkey API
// -----------------------------------------------------------------------

pub const WM_HOTKEY: u32 = 0x0312;

pub const MOD_ALT: u32 = 0x0001;
pub const MOD_CONTROL: u32 = 0x0002;
pub const MOD_SHIFT: u32 = 0x0004;
pub const MOD_WIN: u32 = 0x0008;
pub const MOD_NOREPEAT: u32 = 0x4000;

pub extern "user32" fn RegisterHotKey(
    hWnd: ?HWND,
    id: i32,
    fsModifiers: u32,
    vk: u32,
) callconv(.c) i32;

pub extern "user32" fn UnregisterHotKey(
    hWnd: ?HWND,
    id: i32,
) callconv(.c) i32;
```

- [ ] **Step 3: Add monitor info API**

```zig
// -----------------------------------------------------------------------
// Monitor info API
// -----------------------------------------------------------------------

pub const MONITOR_DEFAULTTOPRIMARY: u32 = 0x00000001;
pub const MONITOR_DEFAULTTONEAREST: u32 = 0x00000002;

pub const HMONITOR = *opaque {};

pub const MONITORINFO = extern struct {
    cbSize: u32,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: u32,
};

pub extern "user32" fn MonitorFromPoint(
    pt: POINT,
    dwFlags: u32,
) callconv(.c) ?HMONITOR;

pub extern "user32" fn GetMonitorInfoW(
    hMonitor: HMONITOR,
    lpmi: *MONITORINFO,
) callconv(.c) i32;
```

- [ ] **Step 4: Add performance counter, thread, and focus APIs**

```zig
// -----------------------------------------------------------------------
// Performance counter API
// -----------------------------------------------------------------------

pub extern "kernel32" fn QueryPerformanceCounter(
    lpPerformanceCount: *i64,
) callconv(.c) i32;

pub extern "kernel32" fn QueryPerformanceFrequency(
    lpFrequency: *i64,
) callconv(.c) i32;

// -----------------------------------------------------------------------
// Thread input and foreground focus API
// -----------------------------------------------------------------------

pub const WM_ACTIVATE: u32 = 0x0006;
pub const WA_INACTIVE: u16 = 0;

pub extern "kernel32" fn GetCurrentThreadId() callconv(.c) u32;

pub extern "user32" fn GetForegroundWindow() callconv(.c) ?HWND;

pub extern "user32" fn AttachThreadInput(
    idAttach: u32,
    idAttachTo: u32,
    fAttach: i32,
) callconv(.c) i32;

pub extern "user32" fn SetForegroundWindow(
    hWnd: HWND,
) callconv(.c) i32;
```

- [ ] **Step 5: Add window positioning constants**

```zig
// -----------------------------------------------------------------------
// Window positioning constants
// -----------------------------------------------------------------------

pub const HWND_TOPMOST: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
pub const SWP_NOACTIVATE: u32 = 0x0010;
pub const SWP_SHOWWINDOW: u32 = 0x0040;
pub const SWP_NOSENDCHANGING: u32 = 0x0400;
pub const SW_SHOWNOACTIVATE: i32 = 4;

pub const WS_EX_TOOLWINDOW: u32 = 0x00000080;
pub const WS_EX_TOPMOST: u32 = 0x00000008;
pub const WS_POPUP: u32 = 0x80000000;
```

- [ ] **Step 6: Build to verify declarations compile**

Run: `zig build -Dapp-runtime=win32 2>&1 | grep -E "win32\.zig" | grep -v "note:" | head -5`
Expected: No output (no compile errors in win32.zig)

- [ ] **Step 7: Commit**

```bash
git add src/apprt/win32/win32.zig
git commit -m "feat(win32): add Win32 API declarations for quick terminal

Add timer, global hotkey, monitor info, performance counter, thread
input, and window positioning APIs needed for quick terminal."
```

---

### Task 2: Window.zig — Quick Terminal Mode

**Files:**
- Modify: `src/apprt/win32/Window.zig`

- [ ] **Step 1: Add `is_quick_terminal` field**

Add after `dragging_split` fields (~line 82):

```zig
/// Whether this window is a quick terminal (borderless popup, no tabs).
is_quick_terminal: bool = false,
```

- [ ] **Step 2: Modify `init()` to support WS_POPUP style**

In `init()`, replace the `CreateWindowExW` call to use different style/exstyle when `is_quick_terminal` is true. The init method should accept an options struct:

```zig
pub const InitOptions = struct {
    is_quick_terminal: bool = false,
};

pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .is_quick_terminal = options.is_quick_terminal,
    };

    const style: u32 = if (options.is_quick_terminal) w32.WS_POPUP else w32.WS_OVERLAPPEDWINDOW;
    const ex_style: u32 = if (options.is_quick_terminal) w32.WS_EX_TOOLWINDOW else 0;

    const hwnd = w32.CreateWindowExW(
        ex_style,
        App.WINDOW_CLASS_NAME,
        // ... rest same as before, but use `style` variable
    );
```

Update existing `init` callers (`App.performAction .new_window`, `App.run`) to pass `.{}` (default options).

- [ ] **Step 3: Skip tab bar for quick terminal windows**

In `tabBarHeight()`, return 0 when `is_quick_terminal`:

```zig
fn tabBarHeight(self: *const Window) i32 {
    if (self.is_quick_terminal) return 0;
    if (!self.tab_bar_visible) return 0;
    return @intFromFloat(@round(32.0 * self.scale));
}
```

In `updateTabBarVisibility()`, force hidden when `is_quick_terminal`:

```zig
fn updateTabBarVisibility(self: *Window) void {
    if (self.is_quick_terminal) {
        self.tab_bar_visible = false;
        return;
    }
    // ... existing logic
}
```

- [ ] **Step 4: Handle WM_ACTIVATE for autohide**

In `windowWndProc`, add `WM_ACTIVATE` case (before the `else` arm):

```zig
w32.WM_ACTIVATE => {
    const activated = @as(u16, @truncate(wparam & 0xFFFF));
    if (activated == w32.WA_INACTIVE and window.is_quick_terminal) {
        if (window.app.quick_terminal) |qt| {
            qt.onFocusLost();
        }
    }
    return 0;
},
```

- [ ] **Step 5: Route quick terminal destroy correctly**

In `onDestroy()`, check `is_quick_terminal` and route to QuickTerminal cleanup instead of `app.windows` removal:

```zig
fn onDestroy(self: *Window) void {
    if (self.is_quick_terminal) {
        if (self.app.quick_terminal) |qt| {
            qt.onWindowDestroyed();
        }
        return;
    }
    // ... existing windows list removal and quit timer logic
}
```

- [ ] **Step 6: Update quit timer check**

Where `onDestroy` checks whether to start the quit timer (after removing from windows list), add quick terminal check:

```zig
if (self.app.windows.items.len == 0 and self.app.quick_terminal == null) {
    self.app.startQuitTimer();
}
```

- [ ] **Step 7: Build to verify**

Run: `zig build -Dapp-runtime=win32 2>&1 | grep -E "Window\.zig" | grep -v "note:" | head -5`
Expected: No compile errors

- [ ] **Step 8: Commit**

```bash
git add src/apprt/win32/Window.zig
git commit -m "feat(win32): add quick terminal mode to Window

Add is_quick_terminal flag, WS_POPUP creation path, suppress tab bar,
WM_ACTIVATE autohide routing, and quick terminal destroy path."
```

---

### Task 3: QuickTerminal.zig — Core Structure

**Files:**
- Create: `src/apprt/win32/QuickTerminal.zig`

- [ ] **Step 1: Create the file with struct and imports**

```zig
//! Quick Terminal: a borderless popup window that slides in/out from a
//! screen edge. Owned by App, separate from the normal windows list.
const QuickTerminal = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_quick_terminal);

/// Animation timer ID (must not collide with QUIT_TIMER_ID=1 or notification=2).
const ANIM_TIMER_ID: usize = 3;

/// Animation tick interval in milliseconds (~60fps).
const ANIM_TICK_MS: u32 = 16;
```

- [ ] **Step 2: Add struct fields**

```zig
app: *App,
window: *Window,
visible: bool = false,
animating: bool = false,
animation_direction: enum { in, out } = .in,
animation_start_time: i64 = 0,
animation_duration: f64 = 0.2,
perf_freq: i64 = 0,

// Cached rects for animation interpolation.
target_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
hidden_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
```

- [ ] **Step 3: Add init/deinit**

```zig
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

    // Kill animation timer if running.
    if (self.animating) {
        _ = w32.KillTimer(self.app.msg_hwnd, ANIM_TIMER_ID);
        self.animating = false;
    }

    // Clean up the window.
    self.window.close();
    alloc.destroy(self.window);
    alloc.destroy(self);
}
```

- [ ] **Step 4: Add position calculation**

```zig
/// Compute the target (visible) and hidden (off-screen) rects for the
/// quick terminal based on the current monitor and config.
fn calculateRects(self: *QuickTerminal) void {
    const config = &self.app.config;
    const position = config.@"quick-terminal-position";

    // Get monitor work area.
    var mi = w32.MONITORINFO{ .cbSize = @sizeOf(w32.MONITORINFO), .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
    const monitor = self.getMonitor();
    if (monitor) |mon| {
        _ = w32.GetMonitorInfoW(mon, &mi);
    } else return;

    const work = mi.rcWork;
    const mw = work.right - work.left;
    const mh = work.bottom - work.top;

    // Determine quick terminal size.
    const scale = self.window.scale;
    var qw: i32 = mw;
    var qh: i32 = @intFromFloat(@round(400.0 * scale));

    if (config.@"quick-terminal-size".primary) |primary| {
        switch (primary) {
            .percent => |p| {
                switch (position) {
                    .top, .bottom, .center => qh = @intFromFloat(@round(@as(f64, @floatFromInt(mh)) * p)),
                    .left, .right => qw = @intFromFloat(@round(@as(f64, @floatFromInt(mw)) * p)),
                }
            },
            .pixels => |px| {
                switch (position) {
                    .top, .bottom, .center => qh = @intCast(px),
                    .left, .right => qw = @intCast(px),
                }
            },
        }
    }

    // For left/right, default height is full work area.
    switch (position) {
        .left, .right => qh = mh,
        else => {},
    }

    if (config.@"quick-terminal-size".secondary) |secondary| {
        switch (secondary) {
            .percent => |p| {
                switch (position) {
                    .top, .bottom, .center => qw = @intFromFloat(@round(@as(f64, @floatFromInt(mw)) * p)),
                    .left, .right => qh = @intFromFloat(@round(@as(f64, @floatFromInt(mh)) * p)),
                }
            },
            .pixels => |px| {
                switch (position) {
                    .top, .bottom, .center => qw = @intCast(px),
                    .left, .right => qh = @intCast(px),
                }
            },
        }
    }

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
            const cx = work.left + @divTrunc(mw - qw, 2);
            const cy = work.top + @divTrunc(mh - qh, 2);
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
```

- [ ] **Step 5: Add easing function**

```zig
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
```

- [ ] **Step 6: Build to verify**

Run: `zig build -Dapp-runtime=win32 2>&1 | grep -E "QuickTerminal\.zig" | grep -v "note:" | head -5`
Expected: No compile errors (file may not be referenced yet — that's fine, will be connected in Task 4)

- [ ] **Step 7: Commit**

```bash
git add src/apprt/win32/QuickTerminal.zig
git commit -m "feat(win32): add QuickTerminal core structure

New QuickTerminal.zig with init/deinit, position calculations for all
5 positions (top/bottom/left/right/center), easing function, and
monitor selection."
```

---

### Task 4: QuickTerminal.zig — Animation & Toggle

**Files:**
- Modify: `src/apprt/win32/QuickTerminal.zig`

- [ ] **Step 1: Add toggle method**

```zig
/// Toggle the quick terminal in or out. Called from App.performAction.
pub fn toggle(self: *QuickTerminal) void {
    if (self.animating) {
        // Mid-animation: reverse direction from current position.
        self.animation_direction = if (self.animation_direction == .in) .out else .in;
        // Adjust start time so progress continues smoothly.
        const now = self.now();
        const elapsed = @as(f64, @floatFromInt(now - self.animation_start_time)) / @as(f64, @floatFromInt(self.perf_freq));
        const progress = @min(elapsed / self.animation_duration, 1.0);
        // Invert: new_start = now - (1-progress) * duration * freq
        const remaining = (1.0 - progress) * self.animation_duration;
        self.animation_start_time = now - @as(i64, @intFromFloat(remaining * @as(f64, @floatFromInt(self.perf_freq))));
        return;
    }

    if (self.visible) {
        self.animateOut();
    } else {
        self.animateIn();
    }
}

fn now(self: *QuickTerminal) i64 {
    _ = self;
    var count: i64 = 0;
    _ = w32.QueryPerformanceCounter(&count);
    return count;
}
```

- [ ] **Step 2: Add animateIn**

```zig
fn animateIn(self: *QuickTerminal) void {
    // Recalculate position each time (handles monitor changes).
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
```

- [ ] **Step 3: Add animateOut**

```zig
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
```

- [ ] **Step 4: Add animation tick handler**

```zig
/// Called from App's WM_TIMER handler on each animation tick.
pub fn onAnimationTick(self: *QuickTerminal) void {
    if (!self.animating) return;

    const elapsed = @as(f64, @floatFromInt(self.now() - self.animation_start_time)) / @as(f64, @floatFromInt(self.perf_freq));
    var progress = @min(elapsed / self.animation_duration, 1.0);

    // For animate-out, invert progress (1.0 = fully hidden).
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
```

- [ ] **Step 5: Add forceForeground**

```zig
/// Force the quick terminal to the foreground, even when Ghostty is
/// a background process. Uses AttachThreadInput to work around the
/// Win32 SetForegroundWindow restriction.
fn forceForeground(self: *QuickTerminal) void {
    const hwnd = self.window.hwnd orelse return;
    const fg = w32.GetForegroundWindow();
    if (fg) |fg_hwnd| {
        var fg_pid: u32 = 0;
        const fg_tid = w32.GetWindowThreadProcessId_(fg_hwnd, &fg_pid);
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
```

- [ ] **Step 6: Add autohide handler**

```zig
/// Called when the quick terminal window loses focus.
pub fn onFocusLost(self: *QuickTerminal) void {
    if (!self.visible) return;
    if (self.animating and self.animation_direction == .out) return;

    // Check autohide config.
    if (!self.app.config.@"quick-terminal-autohide") return;

    self.animateOut();
}
```

- [ ] **Step 7: Add window destroyed handler**

```zig
/// Called when the quick terminal's window is destroyed (shell exited).
pub fn onWindowDestroyed(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;

    if (self.animating) {
        _ = w32.KillTimer(self.app.msg_hwnd, ANIM_TIMER_ID);
        self.animating = false;
    }

    // Don't call window.close() here — it's already being destroyed.
    alloc.destroy(self.window);
    self.app.quick_terminal = null;
    alloc.destroy(self);

    // Check if we should start the quit timer.
    if (self.app.windows.items.len == 0) {
        self.app.startQuitTimer();
    }
}
```

Note: `onWindowDestroyed` accesses `self.app` after setting `self.app.quick_terminal = null` — this is safe because `self` is still valid until `alloc.destroy(self)` at the end. However, the quit timer check must come before `alloc.destroy(self)`. Reorder:

```zig
pub fn onWindowDestroyed(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;

    if (self.animating) {
        _ = w32.KillTimer(app.msg_hwnd, ANIM_TIMER_ID);
    }

    alloc.destroy(self.window);
    app.quick_terminal = null;
    alloc.destroy(self);

    // Check if we should start the quit timer (after self is freed).
    if (app.windows.items.len == 0) {
        app.startQuitTimer();
    }
}
```

- [ ] **Step 8: Build to verify**

Run: `zig build -Dapp-runtime=win32 2>&1 | grep -E "QuickTerminal\.zig" | grep -v "note:" | head -5`
Expected: No compile errors

- [ ] **Step 9: Commit**

```bash
git add src/apprt/win32/QuickTerminal.zig
git commit -m "feat(win32): add quick terminal animation and toggle

Timer-driven slide animation with cubic ease-in-out, mid-animation
reversal, forceForeground via AttachThreadInput, autohide on focus
loss, and shell exit cleanup."
```

---

### Task 5: App.zig — Integration & Global Hotkey

**Files:**
- Modify: `src/apprt/win32/App.zig`

- [ ] **Step 1: Add imports and fields**

Add import at top:
```zig
const QuickTerminal = @import("QuickTerminal.zig");
```

Add fields to App struct:
```zig
/// The quick terminal instance (if active).
quick_terminal: ?*QuickTerminal = null,

/// ID used for the registered global hotkey (-1 = none registered).
global_hotkey_registered: bool = false,
```

- [ ] **Step 2: Add toggle_quick_terminal to performAction**

In the `performAction` switch, add:

```zig
.toggle_quick_terminal => {
    if (self.quick_terminal) |qt| {
        qt.toggle();
    } else {
        const qt = QuickTerminal.init(self) catch |err| {
            log.err("failed to create quick terminal: {}", .{err});
            return true;
        };
        self.quick_terminal = qt;
        qt.toggle();
    }
    return true;
},
```

- [ ] **Step 3: Handle WM_TIMER for animation in msgWndProc**

In `msgWndProc`, add a case for `WM_TIMER` alongside the existing `QUIT_TIMER_ID` handling:

```zig
w32.WM_TIMER => {
    if (wparam == QUIT_TIMER_ID) {
        // existing quit timer logic
        app.quit_timer_state = .expired;
        w32.PostQuitMessage(0);
        return 0;
    }
    if (wparam == QuickTerminal.ANIM_TIMER_ID) {
        if (app.quick_terminal) |qt| {
            qt.onAnimationTick();
        }
        return 0;
    }
    return 0;
},
```

Note: The existing quit timer handling is inside a `WM_TIMER` case already — refactor it to check `wparam` for the timer ID. If the existing code uses a separate match arm (e.g., matching on a custom message), adapt accordingly. From the exploration, the existing code checks `msg == WM_TIMER` at line 1187 — this needs to become a shared handler.

- [ ] **Step 4: Handle WM_HOTKEY in message loop**

In `run()`, add WM_HOTKEY interception in the message loop, before `TranslateMessage`:

```zig
// In the message loop, after GetMessageW and before TranslateMessage:
if (msg.message == w32.WM_HOTKEY) {
    _ = self.performAction(
        .{ .app = {} },
        .toggle_quick_terminal,
        {},
    ) catch {};
    continue;
}
```

- [ ] **Step 5: Register global hotkey at init**

Add a method to register the global hotkey and call it at the end of `init()`:

```zig
fn registerGlobalHotkey(self: *App) void {
    // Scan keybinds for global toggle_quick_terminal binding.
    const bindings = self.config.keybinds();
    for (bindings) |bind| {
        if (bind.action != .toggle_quick_terminal) continue;
        if (!bind.flags.global) continue;

        // Convert Ghostty mods to Win32 mods.
        var mods: u32 = w32.MOD_NOREPEAT;
        if (bind.trigger.mods.ctrl) mods |= w32.MOD_CONTROL;
        if (bind.trigger.mods.alt) mods |= w32.MOD_ALT;
        if (bind.trigger.mods.shift) mods |= w32.MOD_SHIFT;
        if (bind.trigger.mods.super) mods |= w32.MOD_WIN;

        // Convert Ghostty key to Win32 VK.
        const vk = keyToVk(bind.trigger.key) orelse continue;

        if (w32.RegisterHotKey(null, 1, mods, vk) != 0) {
            self.global_hotkey_registered = true;
            log.info("registered global hotkey for quick terminal", .{});
        } else {
            log.warn("failed to register global hotkey (may be in use by another app)", .{});
        }
        break; // Only register the first matching binding.
    }
}
```

The `keybinds()` and `keyToVk()` functions need to be adapted to the actual config and key types. The exact implementation depends on how keybinds are stored. Check `self.config` for the keybind iteration API and adapt. The key-to-VK mapping already exists in Surface.zig for keyboard handling — reference or extract it.

- [ ] **Step 6: Unregister hotkey in terminate**

In `terminate()`, before cleanup:

```zig
// Unregister global hotkey.
if (self.global_hotkey_registered) {
    _ = w32.UnregisterHotKey(null, 1);
    self.global_hotkey_registered = false;
}

// Destroy quick terminal if active.
if (self.quick_terminal) |qt| {
    qt.deinit();
    self.quick_terminal = null;
}
```

- [ ] **Step 7: Add GetWindowThreadProcessId_ wrapper to win32.zig**

The `forceForeground` code needs `GetWindowThreadProcessId` that returns the thread ID. Check if it exists; if not, add:

```zig
pub fn GetWindowThreadProcessId_(hWnd: HWND, lpdwProcessId: ?*u32) u32 {
    return @bitCast(GetWindowThreadProcessId(hWnd, lpdwProcessId));
}

pub extern "user32" fn GetWindowThreadProcessId(
    hWnd: HWND,
    lpdwProcessId: ?*u32,
) callconv(.c) u32;
```

Check if this already exists (the exploration showed it's used in test_tabs.ps1 but may not be in win32.zig).

- [ ] **Step 8: Build to verify everything compiles**

Run: `zig build -Dapp-runtime=win32 2>&1 | grep -E "(App|Window|QuickTerminal|win32)\.zig" | grep -v "note:" | head -10`
Expected: No compile errors in our files

- [ ] **Step 9: Commit**

```bash
git add src/apprt/win32/App.zig src/apprt/win32/QuickTerminal.zig src/apprt/win32/win32.zig
git commit -m "feat(win32): integrate quick terminal with App

Add toggle_quick_terminal action handler, WM_TIMER animation dispatch,
WM_HOTKEY handling in message loop, global hotkey registration via
RegisterHotKey, and cleanup in terminate."
```

---

### Task 6: Polish & Edge Cases

**Files:**
- Modify: `src/apprt/win32/QuickTerminal.zig`
- Modify: `src/apprt/win32/Window.zig`

- [ ] **Step 1: Expose ANIM_TIMER_ID as pub const**

In QuickTerminal.zig, make the constant public so App.zig can reference it:

```zig
pub const ANIM_TIMER_ID: usize = 3;
```

- [ ] **Step 2: Ensure DPI scaling in size calculations**

In `calculateRects`, the default 400px should use `self.window.scale`:

```zig
var qh: i32 = @intFromFloat(@round(400.0 * scale));
```

This is already in the plan — verify it's implemented correctly.

- [ ] **Step 3: Handle config reload**

When config changes, update the animation duration:

In `QuickTerminal.zig`, add:

```zig
pub fn onConfigChange(self: *QuickTerminal, config: *const configpkg.Config) void {
    self.animation_duration = config.@"quick-terminal-animation-duration";
}
```

In `App.zig`, in the `.config_change` handler, after updating `self.config`:

```zig
if (self.quick_terminal) |qt| {
    qt.onConfigChange(&self.config);
}
```

- [ ] **Step 4: Build and run full test suite**

Run: `zig build test -Dapp-runtime=win32 2>&1 | tail -5`
Expected: All existing tests pass

Run: `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows 2>&1 | tail -3`
Expected: Successful cross-compilation

- [ ] **Step 5: Commit**

```bash
git add src/apprt/win32/QuickTerminal.zig src/apprt/win32/App.zig src/apprt/win32/Window.zig
git commit -m "feat(win32): quick terminal polish and config reload

Expose animation timer ID, verify DPI scaling, handle config reload
for animation duration changes."
```

---

### Task 7: Manual Testing & Final Commit

**Files:**
- Modify: various (bug fixes from testing)

- [ ] **Step 1: Cross-compile for Windows**

Run: `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows`
Copy: `cp zig-out/bin/ghostty.exe /mnt/c/Users/admin/Desktop/ghostty_test.exe`

- [ ] **Step 2: Create test config**

Create a Ghostty config file with:
```
keybind = global:ctrl+grave_accent=toggle_quick_terminal
quick-terminal-position = top
quick-terminal-animation-duration = 0.2
quick-terminal-autohide = true
```

- [ ] **Step 3: Test scenarios**

1. Launch Ghostty, press Ctrl+` → quick terminal slides down from top
2. Press Ctrl+` again → slides back up
3. Click elsewhere → autohides (slides up)
4. Press Ctrl+` from another app → should appear and take focus
5. Open a normal Ghostty window, then toggle quick terminal → both coexist
6. Close all normal windows with quick terminal open → app should NOT quit
7. Close quick terminal's shell (type `exit`) → quick terminal destroyed
8. Press Ctrl+` again → fresh quick terminal created
9. Test all 5 positions by changing config and reloading

- [ ] **Step 4: Fix any bugs found during testing**

- [ ] **Step 5: Final commit with any fixes**

```bash
git add -A
git commit -m "fix(win32): quick terminal bug fixes from manual testing"
```

- [ ] **Step 6: Push**

```bash
git push
```
