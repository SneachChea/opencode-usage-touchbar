# Architecture

OpenCode Usage TouchBar is a single-target Swift Package using AppKit, SwiftUI,
Combine, and ServiceManagement. It has no third-party dependencies.

## Data flow

```text
OpenCode Usage TouchBar
    │
    ├─ launches local `codex app-server --stdio`
    │
    ├─ initialize
    └─ account/rateLimits/read
             │
             ▼
        UsageSnapshot
          ├─ NSStatusItem title
          ├─ SwiftUI detail view inside NSMenu
          └─ NSTouchBar items
    │
    └─ GET https://opencode.ai/zen/go/v1/usage
               │  Bearer key from OPENCODE_GO_API_KEY
               ▼
        OpenCodeGoUsageSnapshot
          ├─ NSStatusItem title
          ├─ SwiftUI detail view inside NSMenu
          └─ NSTouchBar items
```

## Main components

- `CodexUsageClient` locates the local Codex executable, speaks newline-delimited
  JSON-RPC over standard input/output, and parses the rate-limit response.
- `OpenCodeGoUsageClient` calls the OpenCode Go usage endpoint with a bearer
  token taken from the macOS Keychain (set in Settings) or, as a fallback,
  from the `OPENCODE_GO_API_KEY` environment variable, and parses the rolling,
  weekly, and monthly windows.
- `UsageStore` owns observable state for both sources, preferences, refresh
  timing, and launch at login.
- `AppDelegate` owns the AppKit status item, native menu, settings window, and
  Touch Bar controller.
- `UsageTouchBarController` renders and updates the Touch Bar for both sources
  and observes which application is frontmost.
- `CodexPetPackage` parses a local pet manifest (`pet.json`), decodes the
  spritesheet once, and crops the canonical animation rows.
- `TouchBarPetView` plays the selected pet on the Touch Bar: ambient random
  states, a tap-triggered wave, and an App Nap activity held only while the
  pet is actually visible.
- `TouchBarSystemModal` isolates the optional undocumented AppKit selectors and
  checks their availability before use.

## Failure behavior

- A request timeout terminates only the child Codex process.
- Parse and server failures are shown in the menu without terminating the app.
- OpenCode Go failures (missing key, HTTP errors, parse failures) are shown in
  the menu and never affect Codex data.
- If system-modal Touch Bar selectors are unavailable, the app uses only the
  public application Touch Bar path.
- Existing data remains visible when a later refresh fails.

## Distribution

`build-app.sh` builds a SwiftPM release binary, compiles the asset catalog,
constructs an application bundle, and signs it. `scripts/release.sh` verifies
the bundle and creates a versioned zip plus SHA-256 checksum.
