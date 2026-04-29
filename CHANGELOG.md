# Changelog

All notable changes to the Ghostty Windows fork. Each release line includes
the underlying upstream commit when known.

## Unreleased

### Added
- Horizontal scroll support via WM_MOUSEHWHEEL.
- File drag-and-drop onto a terminal pastes the file path(s), quoting if
  whitespace is present.
- `present_terminal` action now restores+focuses the window.
- `mouse_visibility` action toggles the cursor via SetCursor(NULL).
- `command_finished` flashes the taskbar button on non-zero exit when the
  window is unfocused.
- `float_window` action sets/clears WS_EX_TOPMOST.
- `toggle_visibility` hides/shows all top-level windows.
- `size_limit` action enforces minimum/maximum window dimensions via
  WM_GETMINMAXINFO.
- `color_change` (OSC 10/11) updates the class background brush so the
  resize-flash matches.
- `ring_bell` now also flashes the taskbar when the window is unfocused.
- Confirm-close dialog when programmatically closing a tab while a shell
  command is running.
- Built-in `ghostty.ico` is used for the window icon and tray notifications
  (was the generic Windows app icon).
- New windows cascade 30px from the most recently created window.
- Build option `-Dwindows-console=true` keeps stderr visible in release
  builds for debugging.

### Changed
- Update-check version source is now `build_config.version` (set by the
  win-v git tag at build time) instead of a hardcoded constant that drifted
  every release.
- Build accepts `win-vX.Y.Z` tags as a separate version namespace from
  upstream's `vX.Y.Z` (which still must match `build.zig.zon`).
- Manifest declares UTF-8 active codepage, longPathAware, and supportedOS
  for Windows 7-11.
- All Win32 bindings use `callconv(.winapi)` instead of `callconv(.c)`.
  Identical ABI on x64 today; correct WNDPROC type, future-proof for x86.
- DirectWrite locale fallback chain widened: en-US, en-us, en-GB, en before
  index 0.
- DragDropFiles, FlashWindowEx, ShowCursor, GetSystemMetrics,
  SetClassLongPtrW, SIF_TRACKPOS bindings added.
- DrawTextW binding moved from `gdi32` to `user32` (correct DLL).

### Fixed
- C1: `cleanupAllSurfaces` was deinit'ing a local copy of each SplitTree,
  leaving stale arena pointers; now deinits in place and resets the slot
  to `.empty`.
- C2: A `closing` flag is now set before posting WM_CLOSE for the last
  tab; queued mouse/keyboard events are dropped while it's set so they
  can't allocate into a window about to be freed.
- C6: Packaging now includes `share/terminfo/ghostty.terminfo` (the
  resourcesDir sentinel on Windows). Without it, fresh ZIP installs
  silently failed to load themes.
- C7: Update-check version is now passed via heap pointer through
  WPARAM/LPARAM instead of a static buffer with no fence.
- DirectWrite no longer panics when the factory or system font collection
  is unavailable (Wine, restricted SKUs); discovery returns empty and
  callers fall back to bundled JetBrains Mono.
- ToUnicode scancode mask was 0x1FF; including bit 24 (extended-key flag)
  produced wrong translations for AltGr layouts.
- Palette `scroll_offset @intCast` could panic when the popup was too
  small to render any items.
- IME `ImmGetCompositionStringW` byte length now uses `@divTrunc` with
  parity check instead of `@divExact` (which would panic on odd input).
- `high_surrogate` buffer is cleared on focus loss and IME composition
  start so a stray surrogate can't pair with the next character key.
- `selectTab(_)` clamps the discriminant non-negative before `@intCast`.
- `tab_rects` is zero-initialized so input handlers reading it before
  the first WM_PAINT see a no-match instead of stack garbage.
- `moveTabTo` now cancels any in-progress tab rename.
- `paintTabBar` brush failures no longer skip the geometry update at the
  bottom of the loop (was piling subsequent tabs on top of the failed
  one).
- `QuickTerminal.onWindowDestroyed` unconditionally KillTimers the
  animation timer.
- Search/palette popup fonts are rebuilt on DPI change.
- Multi-button mouse capture: SetCapture/ReleaseCapture only run on the
  0→nonzero and nonzero→0 transitions of a button-mask.
- `show_child_exited` MessageBoxW now actually formats the exit code
  into the body text instead of building it and discarding.
- Desktop and update notifications use distinct (uID, timer-id) pairs so
  one's auto-cleanup doesn't NIM_DELETE the other's icon.
- `paintPalette` font and bg brush are cached for the popup lifetime
  instead of allocated per repaint.
- Process HANDLE in `Command.zig` is now `CloseHandle`d on deinit.
- Several upstream features that had been dropped during past merges
  (R1-R9 in the audit) were restored: `GHOSTTY_SURFACE_ID` env var, the
  `processLinks` renderer-state mutex, `semantic_prompt_boundary` in
  link detection, `middle-click-action` config option, default `move_tab`
  keybinding, DECBKM mode 67, macOS-only scroll magnitude flooring,
  `freetype_windows` backend variant, the `GHOSTTY_ENUM_TYPED` macro and
  `GHOSTTY_MODE_REPORT_MAX_VALUE` sentinel.

## win-v1.0.0 — 2026-03-31

Initial public release.
