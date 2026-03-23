# Tier 1: Splits, move_tab, close_tab modes — Design Spec

**Date:** 2026-03-23
**Scope:** Win32 apprt — Window.zig, Surface.zig, App.zig

## Overview

Implement the three highest-priority missing features for the Windows port:

1. **Splits** — 5 actions: `new_split`, `goto_split`, `resize_split`, `equalize_splits`, `toggle_split_zoom`
2. **move_tab** — keyboard reorder tabs (shift left/right with wrapping)
3. **close_tab modes** — support `other` (close all but current) and `right` (close tabs to right)

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Split tree data structure | Reuse core `SplitTree(V)` from `src/datastruct/split_tree.zig` | Already proven in GTK, handles insert/remove/navigate/equalize/spatial layout |
| Divider interaction | Mouse-draggable + keyboard resize | Matches macOS parity |
| Divider visual | 1px line, 6px invisible hit area | Matches macOS, clean aesthetic |
| Divider HWNDs | No separate HWNDs — gaps between Surface children | Simpler, fewer window handles |
| Divider gap | DPI-scaled: `round(5 * scale)` pixels | Prevents sub-pixel dividers at high DPI |
| Min pane size | 80px minimum pixel width/height | Prevents unusably small panes in nested splits |

## 1. Splits

### Architecture

Each tab owns a `SplitTree(*Surface)` instead of a bare `*Surface`. The tree is the immutable binary tree from `src/datastruct/split_tree.zig`, instantiated with `*Surface` as the view type.

**Immutability lifecycle:** Every mutation (`split`, `remove`, `resize`, `equalize`) returns a **new** `SplitTree` and the old one must be `deinit()`-ed. The only exception is `resizeInPlace()` for live drag. Pattern:
```zig
var new_tree = try old_tree.split(...);
old_tree.deinit(alloc);
tab_trees[tab] = new_tree;
```

```
Window HWND (top-level)
├── Tab bar region (top 32px × scale)
└── Content area (below tab bar)
    └── Tab's SplitTree layout:
        ├── Surface HWND (leaf)    ← positioned by layoutSplits()
        ├── 1px divider            ← painted by Window in WM_PAINT
        └── Surface HWND (leaf)    ← positioned by layoutSplits()
```

### Window.zig Changes

**Data structure replacement:**
```zig
// Before:
tab_surfaces: [64]*Surface
// After:
tab_trees: [64]SplitTree(*Surface)
tab_active_surface: [64]*Surface   // focused surface within each tab's tree
```

`tab_count`, `active_tab` remain the same. `getActiveSurface()` returns `tab_active_surface[active_tab]`.

**Handle lookup:** To get a `Node.Handle` for the active surface, scan the tree's iterator:
```zig
fn findHandle(tree: SplitTree(*Surface), surface: *Surface) ?SplitTree(*Surface).Node.Handle {
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) return entry.handle;
    }
    return null;
}
```
This is O(n) but acceptable — split counts per tab are small (typically <10).

**New functions:**

| Function | Purpose |
|----------|---------|
| `layoutSplits(tree, rect)` | Recursive: walk tree, `MoveWindow()` each leaf Surface HWND into position. After layout, `InvalidateRect()` the content area for divider painting. |
| `paintDividers(hdc, tree, rect)` | Recursive: draw 1px lines at split boundaries |
| `hitTestDivider(tree, rect, point)` | Return split node handle + orientation if point is within 3px of a divider |
| `startDividerDrag(handle)` | Begin drag tracking (`SetCapture`) |
| `updateDividerDrag(point)` | Compute new ratio, `resizeInPlace()`, re-layout |
| `endDividerDrag()` | Release capture (`ReleaseCapture`) |
| `findHandle(tree, surface)` | Find `Node.Handle` for a surface by scanning tree iterator |
| `hideAllSurfaces(tree)` | Walk tree leaves, `ShowWindow(SW_HIDE)` each — used on tab switch |

**Layout algorithm:**
```
layoutSplits(node, rect):
  if leaf:
    MoveWindow(surface.hwnd, rect.left, rect.top, rect.width, rect.height, TRUE)
    ShowWindow(surface.hwnd, SW_SHOW)
  if split:
    gap = round(5 * scale)  // DPI-scaled divider gap
    if horizontal:
      split_x = rect.left + round(rect.width * ratio)
      layoutSplits(left,  {rect.left, rect.top, split_x - gap/2, rect.bottom})
      layoutSplits(right, {split_x + gap/2, rect.top, rect.right, rect.bottom})
    if vertical:
      split_y = rect.top + round(rect.height * ratio)
      layoutSplits(top,    {rect.left, rect.top, rect.right, split_y - gap/2})
      layoutSplits(bottom, {rect.left, split_y + gap/2, rect.right, rect.bottom})
```

**Zoom handling:** When `tree.zoomed` is set, `layoutSplits()` only shows the zoomed surface (full rect), hides all others with `ShowWindow(SW_HIDE)`.

**WM_SIZE:** Call `layoutSplits()` for the active tab's tree.

**Tab switch (`selectTabIndex`):** `hideAllSurfaces()` on old tab's tree, then `layoutSplits()` for new tab's tree.

**WM_PAINT:** After painting tab bar, call `paintDividers()` for active tab below the tab bar area.

**WM_LBUTTONDOWN (content area):** Parent Window only receives clicks in the divider gap area (child HWNDs handle their own clicks). Call `hitTestDivider()`. If hit, `startDividerDrag()`.

**WM_MOUSEMOVE:** If dragging, `updateDividerDrag()`. Also update cursor.

**WM_LBUTTONUP:** If dragging, `endDividerDrag()`.

**WM_SETCURSOR:** If hovering near divider, set `IDC_SIZEWE` (horizontal split) or `IDC_SIZENS` (vertical split).

**WM_LBUTTONDBLCLK:** If on divider, equalize that split node's ratio to 0.5.

### Surface.zig Changes

Implement the `SplitTree(V)` view protocol:

```zig
// Add field:
ref_count: u32 = 1,

pub fn ref(self: *Surface, alloc: Allocator) Allocator.Error!*Surface {
    _ = alloc;
    self.ref_count += 1;
    return self;
}

pub fn unref(self: *Surface, alloc: Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        self.deinit();
        alloc.destroy(self);
    }
}

pub fn eql(self: *Surface, other: *Surface) bool {
    return self == other;
}
```

### Closing a split pane

When a surface is closed (via `Surface.close()` → `WM_CLOSE`), the handler must distinguish:

- **Single-leaf tree (no splits):** Close the entire tab (existing `closeTab` behavior).
- **Multi-leaf tree:** Remove the surface from the tree:
  1. Find the surface's `Node.Handle` via `findHandle()`.
  2. Find next focus target: `tree.goto(handle, .next)` or `.previous`.
  3. Call `tree.remove(alloc, handle)` → returns new tree.
  4. `deinit()` old tree, store new tree.
  5. Focus the next surface, update `tab_active_surface`.
  6. `layoutSplits()`.

### App.zig Action Handlers

| Action | Implementation |
|--------|---------------|
| `new_split(direction)` | Get active tab's tree + active surface handle. Create new Surface. Create single-node tree via `SplitTree.init(alloc, new_surface)`. Call `tree.split(alloc, handle, direction, 0.5, &single_tree)` → returns new tree. `deinit()` old tree + single tree. Store new tree. `layoutSplits()`. Focus new surface. |
| `goto_split(target)` | For `previous`/`next`: use tree iterator (non-wrapping, matching GTK). For directional (`up`/`down`/`left`/`right`): use `tree.nearest()` spatial lookup. Focus returned surface HWND. Update `tab_active_surface`. |
| `resize_split(direction, amount)` | Map `ResizeSplit.Direction` to `Split.Layout` + sign: left/right → `.horizontal` (left = negative), up/down → `.vertical` (up = negative). Convert pixel amount to ratio: `delta = amount / dimension`. Find active surface handle. Call `tree.resize(alloc, handle, layout, delta)` → new tree. `deinit()` old, store new. `layoutSplits()`. |
| `equalize_splits` | Call `tree.equalize(alloc)` → new tree. `deinit()` old, store new. `layoutSplits()`. |
| `toggle_split_zoom` | Find active surface handle. If `tree.zoomed == handle`: call `tree.zoom(null)` (unzoom). Else: call `tree.zoom(handle)`. `layoutSplits()` (handles show/hide). |

**Direction mapping for `new_split`:** `apprt.action.SplitDirection` and `SplitTree.Split.Direction` have the same values (`left, right, up, down`) — cast via `@enumFromInt(@intFromEnum(action_direction))`.

### Constraints

- Minimum pane size: 80px (enforced during drag resize and `resize_split`)
- Divider gap: `round(5 * scale)` pixels (DPI-scaled)
- Hit area for drag: 3px each side of visible line (6px total, DPI-scaled)

## 2. move_tab

### Window.zig

New function `moveTab(amount: isize)`:

```zig
// Zig requires explicit signed/unsigned handling for wrapping modulo
const n: isize = @intCast(self.active_tab);
const count: isize = @intCast(self.tab_count);
const new_index: usize = @intCast(@mod(n + amount, count));

// Swap all tab state
std.mem.swap(SplitTree(*Surface), &self.tab_trees[self.active_tab], &self.tab_trees[new_index]);
std.mem.swap(*Surface, &self.tab_active_surface[self.active_tab], &self.tab_active_surface[new_index]);
// Also swap tab_titles and tab_title_lens
self.active_tab = new_index;
self.invalidateTabBar();
```

### App.zig

Replace the no-op stub:

```zig
.move_tab => {
    const surface = target.surface() orelse return false;
    surface.parent_window.moveTab(value.amount);
    return true;
}
```

## 3. close_tab modes

### Window.zig

New function `closeTabMode(mode: CloseTabMode, requesting_surface: *Surface)`:

```
switch (mode) {
    .this => closeTab(requesting_surface),
    .other => {
        const current = findTabIndex(requesting_surface);
        // Close all tabs except current, iterate in reverse
        var i = tab_count;
        while (i > 0) {
            i -= 1;
            if (i != current) closeTabByIndex(i);
        }
    },
    .right => {
        const current = findTabIndex(requesting_surface);
        // Close all tabs after current, iterate in reverse
        var i = tab_count;
        while (i > current + 1) {
            i -= 1;
            closeTabByIndex(i);
        }
    },
}
```

Helper `findTabIndex(surface)`: scan `tab_active_surface` array for matching pointer. Helper `closeTabByIndex(index)`: extracted from existing `closeTab(*Surface)` logic.

### App.zig

Update `.close_tab` handler to pass the mode:

```zig
.close_tab => {
    const surface = target.surface() orelse return false;
    surface.parent_window.closeTabMode(value, surface);
    return true;
}
```

## Migration Path

The shift from `tab_surfaces` to `tab_trees` is the biggest structural change. A single-surface tab is a tree with one leaf node. All existing tab operations (add, close, switch, paint) continue to work — they access the tree's root leaf instead of a bare pointer. `addTab` creates a single-node tree via `SplitTree.init(alloc, surface)`.

## Files Modified

| File | Changes |
|------|---------|
| `src/apprt/win32/Window.zig` | Replace tab_surfaces with tab_trees, add split layout/paint/drag/close, add moveTab, add closeTabMode, add findHandle/hideAllSurfaces/findTabIndex/closeTabByIndex |
| `src/apprt/win32/Surface.zig` | Add ref_count, implement ref/unref/eql for SplitTree protocol |
| `src/apprt/win32/App.zig` | Wire new_split, goto_split, resize_split, equalize_splits, toggle_split_zoom, move_tab, close_tab modes |

## Testing

- Existing 4 tab tests should continue passing (single-leaf tree = same behavior)
- New tests: split creation, navigation, resize, equalize, zoom, close split pane, move_tab wrapping, close_tab modes
