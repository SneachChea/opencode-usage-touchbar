# Privacy

OpenCode Usage TouchBar is local-first and contains no telemetry, advertising, crash
reporting SDK, or third-party analytics.

## Data the app reads

The app starts a locally installed `codex app-server --stdio` process and sends
the read-only `account/rateLimits/read` request. The response may include:

- account plan type;
- remaining rate-limit percentages;
- rate-limit reset timestamps;
- credit balance and available reset count.

This data is held in application memory for display. It is not written to a
database or transmitted by OpenCode Usage TouchBar.

When OpenCode Go is configured, the app additionally reads remaining usage for
the rolling (5-hour), weekly, and monthly windows, plus their reset
timestamps, from the OpenCode Go usage endpoint. This data is also held in
memory for display only.

When a pet is enabled in Settings, the app reads `pet.json` and the
referenced `spritesheet.webp` from the pet folder under `~/.codex/pets/` (or a
user-chosen folder). The image is decoded locally and cropped into animation
frames for the Touch Bar. No pet data is transmitted anywhere.

## Data the app stores

The following preferences are saved using macOS `UserDefaults`:

- menu bar icon and sizing;
- Touch Bar enablement;
- whether to show the Touch Bar while Codex is frontmost;
- the selected pet id and the optional pets folder override;
- the pet state-change interval (petMinInterval / petMaxInterval).

Launch-at-login state is managed by Apple's `SMAppService`.

## Network behavior

OpenCode Usage TouchBar does not make its own network requests for Codex data. The
local Codex process may communicate with OpenAI as part of its normal
signed-in operation. Clicking “Official Usage” asks macOS to open
`https://chatgpt.com/codex/settings/usage` in the default browser.

When OpenCode Go is enabled, the app sends one direct HTTPS request to
`https://opencode.ai/zen/go/v1/usage` per refresh cycle, authenticated with
the `OPENCODE_GO_API_KEY` bearer token. The request is read-only and carries
no telemetry.

## Credentials

The app does not request, copy, log, or persist Codex cookies, access tokens,
or API keys. Authentication remains owned by the installed Codex client.

The OpenCode Go API key can be entered in Settings, where it is stored only in
the macOS Keychain (`kSecClassGenericPassword`, accessible after first unlock).
It is never written to `UserDefaults`, logs, or files, and it is sent only to
the OpenCode Go endpoint as a bearer token. As a fallback, the key may also be
provided through the `OPENCODE_GO_API_KEY` environment variable of the app
process; the Keychain value takes precedence. An app launched from Finder does
not inherit shell exports. When the app starts the local Codex process, it
explicitly removes `OPENCODE_GO_API_KEY` from that child process' environment.

## Removing local data

Quit the app, disable launch at login, remove the application, and delete its
preferences if desired:

```bash
defaults delete com.local.opencodeusagetouchbar
```
