# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Animated Codex pet on the Touch Bar: pick any pet installed under
  `~/.codex/pets/` (or a custom folder) in Settings → Pet. The pet idles,
  changes state randomly (interval configurable in Settings, 5–300 s), and
  waves when tapped. V1 (8×9) and V2 (8×11) Codex pet atlases are supported.

### Changed

- App Nap suppression is now scoped to the animated Touch Bar pet while it is
  visible; the permanent app-wide anti-App-Nap activity was removed.
- The Touch Bar pet now rests on a static idle frame between animations, so a
  resting pet no longer redraws frame-by-frame; the anti-App-Nap token scope
  while the pet is visible is unchanged.
- Codex usage reads parse the child response line by line (stop at the first
  matching reply, bounded buffer), the unused stderr pipe no longer risks
  stalling the child, and `OPENCODE_GO_API_KEY` is no longer inherited by the
  launched Codex process.
- OpenCode Go requests reuse one stateless ephemeral session (no cookies, no
  on-disk cache) with a hard 15 s per-request resource timeout, and an
  in-flight request is cancelled when the API key is saved or removed. The
  512 KB response limit bounds which responses are accepted, not streamed
  memory.

### Fixed

- The Touch Bar now defaults to `Always visible` (persistent) on a clean
  preferences domain instead of silently falling back to `Only while Codex is
  active`.

### Changed

- Removed the reset-time text items from the Touch Bar (Codex and OpenCode Go);
  the bar now shows only the usage percentages and progress.
- Removed the in-bar `x` hide button (it duplicated the native close/Control
  Strip affordance); the mode picker restores the native Touch Bar.
- The Touch Bar refresh button renders as a compact borderless icon.
- Project renamed to OpenCode Usage TouchBar (`opencode-usage-touchbar`),
  continuing the original [Codex Usage Bar](https://github.com/yizhigou/codex-usage-bar).
  New app name, bundle identifier, executable name, keychain service, and
  release artifact names; previously stored OpenCode Go API keys must be
  re-entered after upgrade.

### Added

- OpenCode Go usage tracking alongside Codex: rolling (5-hour), weekly, and monthly limits.
- OpenCode Go section in the usage menu with reset times and error reporting.
- OpenCode Go progress and percentages on the Touch Bar.
- OpenCode Go API key entry in Settings, stored securely in the macOS Keychain (environment variable fallback).
- `--self-test-opencode-go` live check and unit tests for response parsing.
- Persistent Touch Bar: new `Always visible` mode keeps the quotas on the
  Touch Bar across app switches (Terminal, Firefox, Finder, VS Code, Safari),
  sharing the bar with the Control Strip (placement 0), re-asserted on every
  app activation, screen unlock, and system wake.
- OpenCode logo marks the OpenCode Go section on the Touch Bar.
- Codex items are omitted from the Touch Bar when no local Codex executable
  is found; the section reappears automatically once Codex is installed.
- Touch Bar settings replaced by a three-mode picker: Always visible /
  Only while Codex is active / Disabled. Existing preferences migrate
  automatically; dismissing restores the native Touch Bar immediately.

## [2.1.0] - 2026-08-31

### Added

- App-wide language switching with a system-default option.
- Simplified Chinese, Traditional Chinese, English, Japanese, Korean, and Spanish translations.
- Locale-aware date and time formatting in the usage menu and Touch Bar.

## [2.0.0] - 2026-08-30

### Added

- Native macOS menu bar usage display.
- Five-hour and weekly remaining quota with reset times.
- Configurable menu bar icon and text sizing.
- Launch-at-login support.
- Native menu presentation and settings window.
- Touch Bar usage progress, percentages, reset times, and refresh action.
- Optional automatic Touch Bar presentation while Codex is frontmost.

### Notes

- Usage data is read from the locally installed Codex app-server.
- Persistent Touch Bar presentation relies on an undocumented AppKit selector.
