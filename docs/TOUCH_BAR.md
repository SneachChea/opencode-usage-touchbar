# Touch Bar implementation

## Public API path

The application creates an `NSTouchBar` containing:

- five-hour usage and progress;
- weekly usage and progress;
- reset timestamps;
- a manual refresh button.

The bar is assigned to `NSApplication.touchBar` while Touch Bar display is
enabled. This path uses public AppKit APIs.

## Automatic presentation while Codex is frontmost

macOS does not provide a public API for one application to keep its full Touch
Bar visible while another application owns keyboard focus. To support the
requested behavior on Touch Bar MacBook Pro models, the app optionally invokes:

```text
presentSystemModalTouchBar:placement:systemTrayItemIdentifier:
dismissSystemModalTouchBar:
```

These AppKit selectors are undocumented. Calls are isolated behind runtime
availability checks. The feature is enabled only when:

1. Touch Bar display is enabled;
2. automatic Codex presentation is enabled;
3. the frontmost application bundle identifier is `com.openai.codex`;
4. both selectors exist in the current AppKit runtime.

The modal bar is dismissed when Codex is no longer frontmost.

## Compatibility and review

- This behavior is not suitable for Mac App Store distribution.
- Apple may change or remove the selectors in any macOS release.
- Contributors must preserve the fallback and must not assume Touch Bar
  hardware exists.
- A failure of the optional path must never affect the menu bar usage display.
