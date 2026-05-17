# Changelog

All notable changes to the Ghostty Windows fork. Each release line includes
the underlying upstream commit when known.

## Unreleased

### Added
- Themed scrollbar replaces the native white `WS_VSCROLL`. Painted in the
  terminal's foreground/background colors via a layered popup overlay
  (`UpdateLayeredWindow` with per-pixel alpha) composited above the OpenGL
  surface. Honors the OS "Always show scrollbars" accessibility setting:
  overlay (auto-hide on idle) by default, always-visible when the OS prefers
  it; mode switches live without a Ghostty restart. Mouse drag, hover, and
  page-click work; clicks fall through to the terminal when the scrollbar
  is hidden.

### Fixed
- Alt-modified keybindings (`Alt+-`, `Alt+\`, `Alt+letter`, …) no longer
  ring the system bell on press. `TranslateMessage` synthesizes a
  `WM_SYSCHAR` after every `WM_SYSKEYDOWN` with a printable character,
  and forwarding `WM_SYSCHAR` to `DefWindowProc` was treating it as an
  unmatched menu accelerator and triggering `MessageBeep`. The keystroke
  itself is dispatched in `WM_SYSKEYDOWN`, so the new `WM_SYSCHAR`
  handler simply consumes the message.
- JIS keyboard layout no longer drifts to a US-like mapping inside
  applications that use Win32 Input Mode (notably Claude Code's prompt
  via ConPTY): `@` becoming `` ` ``, `[` becoming `]`, `]` becoming `\`,
  etc. The trigger was `ToUnicode` returning -1 for a dead key and
  ghostty leaving the buffered dead character in the kernel's per-thread
  keyboard state. Subsequent `ToUnicode` calls then composed against
  that residue, producing wrong characters until ghostty exited — the
  damage even survived a `claude -c` restart because the state lives in
  ghostty's process, not Claude's. The fix drains the dead-key state
  after detecting it (mirroring wezterm's
  `KeyboardLayoutInfo::clear_key_state`) and surfaces the dead character
  itself as the `Uc` field so the application still sees the keystroke.
  Both `ToUnicode` call sites now also skip modifier-only VKs (Shift,
  Ctrl, Alt, Win, lock keys), which never produce a character on their
  own and are another way to perturb the per-thread state.
- Ghostty no longer freezes after extended use under heavy ConPTY output
  (notably while a long Claude Code task streamed through the terminal).
  The UI thread was deadlocking inside `oleacc!CAccessible::QueryInterface
  -> SleepConditionVariableSRW`: every cross-pane focus transition caused
  oleacc to destroy the outgoing surface's MSAA AccWrap synchronously
  inside `DefWindowProc`, the destructor re-entered our WindowProc via
  `SetFocus` -> `user32!ImeSystemHandler` -> `oleacc!CreateClient`, and
  the resulting COM marshaling waited for a reply that the same UI thread
  needed to pump. Each split being its own `WS_CHILD` HWND (vs.
  wezterm/rio's single-HWND model) is what wedged the round-trip. Both
  `surfaceWndProc` and `windowWndProc` now return `0` from
  `WM_GETOBJECT` for `OBJID_CLIENT`, opting out of the default oleacc
  proxy entirely. We don't expose terminal-cell-level accessibility
  today, so the only thing this disables is the generic window-frame
  proxy a screen reader would otherwise see; once a proper IAccessible
  / UI Automation provider lands, it can be returned here via
  `LresultFromObject` instead.
- Dead-key composition now works correctly on pt-BR ABNT2 and other
  layouts with dead keys (`~`+`a` → `ã`, `´`+`e` → `é`, `^`+`o` →
  `ô`). The root cause was `TranslateMessage` being called before
  `DispatchMessage` for terminal surface windows: its internal
  `ToUnicodeEx` mutated the thread's per-queue dead-key state before
  `handleKeyEvent`'s own `ToUnicode` call, so dead keys composed with
  themselves instead of the following character. The fix skips
  `TranslateMessage` for surface windows (discriminated by class atom);
  `ToUnicode` in `handleKeyEvent` is now the sole consumer of the
  dead-key state. The same race in the Win32 Input Mode path (used by
  PowerShell + PSReadLine) is fixed by the same change: `~`+`a` in a
  PowerShell prompt now correctly produces `ã`. Edit controls (search
  bar, command palette, tab rename) are unaffected and still receive
  `TranslateMessage`.
- `shift+5`, `ctrl+u`, `ctrl+d`, `ctrl+f`, arrow keys, and `enter` no
  longer drop their effective character when typed into applications
  that use Win32 Input Mode (notably Claude Code's prompt via ConPTY):
  on a JIS layout `shift+5` was arriving as `5` instead of `%`. The
  trigger was Claude enabling kitty-keyboard / modifyOtherKeys on top
  of Win32 Input Mode, after which `core_surface.keyCallback` would
  encode the keystroke through the legacy/kitty path *and* return
  `.consumed` — the apprt then suppressed its own
  `\x1b[Vk;Sc;Uc;Kd;Cs;Rc_` sequence, so the receiving app only ever
  saw the core encoding (a kitty-kbd CSI for `shift+5` that Claude
  rendered as `5`). Win32 Input Mode is the apprt's exclusive wire
  format, so `Surface.encodeKey` now short-circuits whenever DEC mode
  9001 is active. Bindings still fire (binding lookup runs before
  `encodeKey`); modifier release tracking still works.

## win-v1.0.1 — 2026-04-29

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
- Title-bar color tracks the configured background on Windows 11 22H2+
  (DWMWA_CAPTION_COLOR), and dark/light chrome is chosen by background
  luminance instead of being hardcoded dark.
- Title-bar chrome refreshes on config reload.
- Clicking the update-available balloon opens the GitHub releases page
  in the user's default browser.
- Update-check requests are rate-limited to once per hour via a
  persisted timestamp at `%LOCALAPPDATA%/ghostty/update_check_at`.
- VS_VERSION_INFO resource is filled in (Explorer → Properties → Details
  shows real values; signtool tooling has version metadata to attach).
- Application manifest declares UTF-8 active codepage, longPathAware,
  and supportedOS GUIDs for Windows 7 through 11.
- `test_window_size_config` now hard-fails (was non-blocking) if the
  configured window width didn't take effect.
- `test_resize` is a real test (was permanently SKIPPED).
- `ghostty_test.sh` pre-kills leftover processes and retries the exe
  copy once, eliminating intermittent EBUSY in batch runs.

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
