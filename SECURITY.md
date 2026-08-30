# Security policy

## Supported version

Security fixes are provided for the latest published release.

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public issue. Use
GitHub's private vulnerability reporting feature for the repository. Include:

- the affected version;
- reproduction steps;
- expected and actual behavior;
- any relevant crash log, with account and local path information removed.

## Security model

Codex Usage Bar launches the locally installed `codex app-server --stdio`
process and sends a read-only rate-limit request. It does not request, copy, or
store account tokens. See [docs/PRIVACY.md](docs/PRIVACY.md) for details.
