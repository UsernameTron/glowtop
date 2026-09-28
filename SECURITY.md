# Security policy

GlowTop is a local-only app. It opens no network connections, runs no privileged helper and asks for no password. Its only write actions are quitting a process and enabling, disabling, starting or stopping jobs in your own `~/Library/LaunchAgents`, each behind a confirmation sheet.

## Reporting a vulnerability

Please report security problems privately through GitHub's **Report a vulnerability** button on the [Security tab](https://github.com/UsernameTron/glowtop/security) of this repository, not in a public issue. Include the GlowTop version, your macOS version and chip, and steps to reproduce.

## Supported versions

Only the latest release receives fixes.
