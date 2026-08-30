# Privacy

Codex Usage Bar is local-first and contains no telemetry, advertising, crash
reporting SDK, or third-party analytics.

## Data the app reads

The app starts a locally installed `codex app-server --stdio` process and sends
the read-only `account/rateLimits/read` request. The response may include:

- account plan type;
- remaining rate-limit percentages;
- rate-limit reset timestamps;
- credit balance and available reset count.

This data is held in application memory for display. It is not written to a
database or transmitted by Codex Usage Bar.

## Data the app stores

The following preferences are saved using macOS `UserDefaults`:

- menu bar icon and sizing;
- Touch Bar enablement;
- whether to show the Touch Bar while Codex is frontmost.

Launch-at-login state is managed by Apple's `SMAppService`.

## Network behavior

Codex Usage Bar does not make its own network requests. The local Codex process
may communicate with OpenAI as part of its normal signed-in operation. Clicking
“Official Usage” asks macOS to open `https://chatgpt.com/codex/settings/usage`
in the default browser.

## Credentials

The app does not request, copy, log, or persist Codex cookies, access tokens, or
API keys. Authentication remains owned by the installed Codex client.

## Removing local data

Quit the app, disable launch at login, remove the application, and delete its
preferences if desired:

```bash
defaults delete com.local.codexusagebar
```
