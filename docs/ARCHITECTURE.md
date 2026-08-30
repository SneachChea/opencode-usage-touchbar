# Architecture

Codex Usage Bar is a single-target Swift Package using AppKit, SwiftUI,
Combine, and ServiceManagement. It has no third-party dependencies.

## Data flow

```text
Codex Usage Bar
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
```

## Main components

- `CodexUsageClient` locates the local Codex executable, speaks newline-delimited
  JSON-RPC over standard input/output, and parses the rate-limit response.
- `UsageStore` owns observable state, preferences, refresh timing, and launch at
  login.
- `AppDelegate` owns the AppKit status item, native menu, settings window, and
  Touch Bar controller.
- `UsageTouchBarController` renders and updates the Touch Bar and observes which
  application is frontmost.
- `TouchBarSystemModal` isolates the optional undocumented AppKit selectors and
  checks their availability before use.

## Failure behavior

- A request timeout terminates only the child Codex process.
- Parse and server failures are shown in the menu without terminating the app.
- If system-modal Touch Bar selectors are unavailable, the app uses only the
  public application Touch Bar path.
- Existing data remains visible when a later refresh fails.

## Distribution

`build-app.sh` builds a SwiftPM release binary, compiles the asset catalog,
constructs an application bundle, and signs it. `scripts/release.sh` verifies
the bundle and creates a versioned zip plus SHA-256 checksum.
