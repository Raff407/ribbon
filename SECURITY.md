# Security policy

## Reporting a vulnerability

Please report security issues **privately**: go to the repository's **Security** tab and use
**Report a vulnerability** (GitHub private vulnerability reporting). Don't open a public
issue, pull request or discussion about it.

Include what you found, how to reproduce it, and which version and macOS release you
tested on. You'll get a reply in that advisory thread.

## Scope

Ribbon runs locally with the Accessibility permission and makes no network connections.
Issues that matter most:

- anything that lets another process or website make Ribbon do more than arrange windows
  (for example through the `ribbon://` URL scheme)
- anything that leaks key presses, window contents or titles out of the app
- crashes that leave windows stuck off-screen

## Supported versions

Only the latest release receives fixes.
