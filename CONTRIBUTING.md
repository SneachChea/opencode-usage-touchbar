# Contributing

Contributions are welcome.

## Development requirements

- macOS 14 or later
- Xcode command-line tools with Swift 5.10 or later
- Codex desktop app or a compatible local `codex` executable for live testing

## Workflow

1. Fork the repository and create a focused branch.
2. Run `swift build` before submitting a pull request.
3. Run `./build-app.sh dist` to verify the application bundle.
4. Run `dist/Codex\ Usage\ Bar.app/Contents/MacOS/CodexUsageBar --self-test`
   while Codex is signed in.
5. Describe user-visible changes and compatibility implications in the pull
   request.

Please keep changes scoped and avoid adding analytics, remote services, or
third-party dependencies without prior discussion.

## Touch Bar changes

The normal Touch Bar implementation uses public `NSTouchBar` APIs. Automatic
presentation while Codex is frontmost uses undocumented AppKit selectors and
must always retain a safe availability check and a public-API fallback.
