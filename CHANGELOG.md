# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- OpenCode Go usage tracking alongside Codex: rolling (5-hour), weekly, and monthly limits.
- OpenCode Go section in the usage menu with reset times and error reporting.
- OpenCode Go progress, percentages, and reset times on the Touch Bar.
- OpenCode Go API key entry in Settings, stored securely in the macOS Keychain (environment variable fallback).
- `--self-test-opencode-go` live check and unit tests for response parsing.
- Persistent Touch Bar: new `Always visible` mode keeps the quotas on the
  Touch Bar across app switches (Terminal, Firefox, Finder, VS Code, Safari),
  sharing the bar with the Control Strip (placement 0), re-asserted on every
  app activation, screen unlock, and system wake.
- `x` button at the right end of the Touch Bar hides the usage info and
  restores the native Touch Bar (re-show from the popover, or change mode).
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
