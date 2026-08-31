# Touch Bar implementation

## Public API path

The application creates an `NSTouchBar` containing:

- five-hour usage and progress;
- weekly usage and progress;
- reset timestamps;
- OpenCode Go rolling, weekly, and monthly usage and progress;
- OpenCode Go reset timestamps;
- a manual refresh button (refreshes both Codex and OpenCode Go).

The bar is assigned to `NSApplication.touchBar` while Touch Bar display is
enabled. This path uses public AppKit APIs.

The automatic presentation feature remains limited to Codex being frontmost.
OpenCode Go runs inside a terminal, which cannot be distinguished reliably
from other terminal applications, so no automatic presentation is attempted
for it.

## Automatic presentation while Codex is frontmost

macOS does not provide a public API for one application to keep its full Touch
Bar visible while another application owns keyboard focus. To support the
requested behavior on Touch Bar MacBook Pro models, the app optionally invokes:

```text
presentSystemModalTouchBar:placement:systemTrayItemIdentifier:
dismissSystemModalTouchBar:
```

These AppKit selectors are undocumented. Calls are isolated behind runtime
availability checks. The controller also registers a matching system-tray item
through the private `NSTouchBarItem` API and DFR control-strip symbol; without
that registration, the modal bar has no valid system-tray anchor. The feature
is enabled only when:

1. Touch Bar display is enabled;
2. automatic Codex presentation is enabled;
3. the frontmost application bundle identifier is `com.openai.codex`;
4. the required AppKit selectors and DFR symbol exist in the current runtime.

The modal bar is dismissed when Codex is no longer frontmost.
It is re-presented after application switches because macOS can reclaim a
system-modal bar during activation changes.

## Compatibility and review

- This behavior is not suitable for Mac App Store distribution.
- Apple may change or remove the selectors in any macOS release.
- Contributors must preserve the fallback and must not assume Touch Bar
  hardware exists.
- A failure of the optional path must never affect the menu bar usage display.
