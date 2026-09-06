# Touch Bar implementation

## Public API path

The application creates an `NSTouchBar` containing:

- one usage page at a time: Codex (color logo, five-hour and weekly quotas)
  or OpenCode Go (OpenCode logo, rolling, weekly and monthly quotas);
- tapping the logo switches between configured sources (Codex ↔ OpenCode
  Go). Codex is the initial selection; if only one source is configured, it
  is shown automatically and tapping does nothing;
- the usage area keeps a fixed width. Switching only hides/shows its page
  views, without rebuilding the Touch Bar or detaching the selected pet.
  The pet stays to the right, in the same position, and keeps animating.
  Touches on the pet or refresh button never switch sources; tapping the pet
  still makes it wave;
- a manual refresh button (refreshes both Codex and OpenCode Go), rendered as
  a compact borderless icon. There is no in-bar hide button: the native
  close/Control Strip affordance already provides one, so the app relies on
  the mode picker to restore the native Touch Bar.
- an animated pet item (when enabled in Settings → Pet): a compact 30×30 px
  button showing the pet from a local `~/.codex/pets/<pet-id>/` package. It
  rests on a static idle frame, plays a random ambient state at a configurable
  interval (default 30–90 s, adjustable from 5–300 s in Settings), and waves
  when tapped. The V1 (8×9) and V2 (8×11) atlases are supported; only the nine
  standard animation rows are used.

The bar is assigned to `NSApplication.touchBar` unless the Touch Bar mode is
`Disabled`. This path uses public AppKit APIs and shows the bar only while
this application itself is active; it is also the automatic fallback when the
system-modal presentation below is unavailable.

## Persistent presentation

Settings offer three Touch Bar modes:

```text
● Always visible                         (default)
○ Only while Codex is active
○ Disabled
```

macOS does not provide a public API for one application to keep its full
Touch Bar visible while another application owns keyboard focus. Persistent
display uses the same undocumented mechanism as MTMR, Pock, and
claude-usage-touchbar, isolated in `TouchBarSystemModal`:

```text
+[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:]
+[NSTouchBar dismissSystemModalTouchBar:]
+[NSTouchBar minimizeSystemModalTouchBar:]
DFRSystemModalShowsCloseBoxWhenFrontMost()   (DFRFoundation private framework)
```

Details:

- Sources are conditional: Codex requires a local executable; OpenCode Go
  requires a configured API key. With neither available, the usage area shows
  the localized no-source message. The enabled pet and refresh remain visible.
- Source switching is a plain borderless `NSButton` behind each logo (target
  `switchUsageSource`) — the same reliable control path as the pet and refresh
  buttons. The button belongs only to the usage area.
- The selected source is persisted in `UserDefaults` (`touchBarSource`) and
  restored at launch; `TouchBarSource.available` corrects it if the chosen
  source is no longer configured.
- Both logos are created once when the usage area item is built; switching
  only toggles page visibility, so the tapped button survives the change.

- Presentation uses `placement 0` with a `nil` system-tray identifier, which
  shares the Touch Bar with the Apple Control Strip. The Control Strip stays
  usable in every mode. Without a tray anchor, `Disabled` mode uses
  `dismissSystemModalTouchBar:` (deterministic restore); `minimize` is kept
  only for the `Only while Codex is active` focus-out case.
- `DFRSystemModalShowsCloseBoxWhenFrontMost(false)` hides the system close
  box that would otherwise appear while this accessory app is frontmost.
- macOS can reclaim a system-modal bar during app-activation changes, so the
  bar is re-presented (cheap and idempotent) on every
  `NSWorkspaceDidActivateApplicationNotification`, after the screen unlocks
  (`com.apple.screenIsUnlocked`), and after `NSWorkspaceDidWakeNotification`
  (twice: the wake notification can arrive before DFR is ready to accept a
  presentation). This is what makes the quotas survive Terminal → Firefox →
  Finder → VS Code switches and sleep/wake cycles.
- The animated pet rests on a static idle frame between animations: it plays a
  random ambient action at a configurable interval (default 30–90 s), or a wave
  on tap, and only redraws frame-by-frame while an action is actually playing.
- The pet holds an App Nap suppression token
  (`ProcessInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep])`)
  while its item is attached to a presented bar — the same scope as before this
  release, so ambient actions keep firing while the pet is visible — and the
  token is released when the bar is dismissed, the pet is disabled, or the pet
  item is removed. There is no permanent app-wide activity; the battery win is
  that a resting pet no longer redraws continuously.
- In `Only while Codex is active` mode the modal bar is minimized when
  Codex (`com.openai.codex`) is not frontmost. OpenCode Go runs inside a
  terminal, which cannot be distinguished reliably from other terminal
  applications, so it does not gate presentation.
- All private calls sit behind runtime availability checks
  (`TouchBarSystemModal.isAvailable`). When unavailable, the app silently
  falls back to the public path.

## Restoring the native Touch Bar

The native Touch Bar is restored immediately when:

- the mode is set to `Disabled` (dismisses the modal bar);
- the mode is set to `Only while Codex is active` and Codex loses focus
  (minimizes);
- the application quits (`applicationWillTerminate` → `shutDown()` →
  `dismissSystemModalTouchBar:`).

Dismissing is synchronous; no relaunch of the frontmost app is required.

A crash or `kill -9` runs none of this, so the modal bar can stay claimed with a
frozen usage display until macOS or another presenter takes the bar back. Only
a normal quit (`applicationWillTerminate`) restores the native bar reliably.

## Verification

Run the source-selection check without credentials or Touch Bar hardware:

```sh
swiftc Sources/OpenCodeUsageTouchBar/TouchBarSource.swift scripts/verify-touchbar-source.swift -o .build/verify-touchbar-source
.build/verify-touchbar-source
```

On hardware, configure both sources and enable a pet. Tap the logo: the usage
page should switch between Codex and OpenCode Go; the pet should neither move
nor restart its animation. With only one source configured, tapping must do
nothing. Verify that tapping the pet and refresh button still works, and that
the Control Strip is usable.

## Compatibility and review

- This behavior is not suitable for Mac App Store distribution.
- Apple may change or remove the selectors in any macOS release.
- Contributors must preserve the fallback and must not assume Touch Bar
  hardware exists.
- A failure of the optional path must never affect the menu bar usage display.
