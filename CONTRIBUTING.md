# Contributing

Contributions are welcome.

## Development requirements

- macOS 14 or later
- Xcode command-line tools with Swift 5.10 or later (full Xcode is required to run `swift test`)
- Codex desktop app or a compatible local `codex` executable for live testing

## Workflow

1. Fork the repository and create a focused branch.
2. Run `swift build` before submitting a pull request.
3. Run `./build-app.sh dist` to verify the application bundle.
4. Run `dist/OpenCode\ Usage\ TouchBar.app/Contents/MacOS/opencode-usage-touchbar --self-test`
   while Codex is signed in.
5. For OpenCode Go changes, run
   `dist/OpenCode\ Usage\ TouchBar.app/Contents/MacOS/opencode-usage-touchbar --self-test-opencode-go`
   with `OPENCODE_GO_API_KEY` exported, and run `swift test` (requires Xcode).
6. Describe user-visible changes and compatibility implications in the pull
   request.

Please keep changes scoped and avoid adding analytics, remote services, or
third-party dependencies without prior discussion.

## Touch Bar changes

The normal Touch Bar implementation uses public `NSTouchBar` APIs. Automatic
presentation while Codex is frontmost uses undocumented AppKit selectors and
must always retain a safe availability check and a public-API fallback.
