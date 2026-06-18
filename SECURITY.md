# Security Policy

## Supported versions

Skelf is a small, actively developed macOS app. Only the latest released version receives
security fixes.

| Version | Supported |
|---------|-----------|
| 1.0.x   | ✅        |
| < 1.0   | ❌        |

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- Preferred: GitHub's [private vulnerability reporting](https://github.com/devbyshima/Skelf/security/advisories/new)
  (the repo's **Security ▸ Report a vulnerability** button).
- Or email **fulltimestudio29@gmail.com**.

Include steps to reproduce and the affected version (`Skelf --version`). Expect an initial
response within a few days. Once a fix ships you'll be credited in the release notes, unless you
prefer to stay anonymous.

## Scope notes

Skelf reads skill files from your local disk and fetches public-domain artwork from the Art
Institute of Chicago API plus creator avatars from GitHub, all over HTTPS. It has no account
system, sends no telemetry, and stores only local caches and `UserDefaults`. Released builds are
currently distributed unsigned (ad-hoc); verify a download against the published `SHA256SUMS`
before opening it.
