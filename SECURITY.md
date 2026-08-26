# Security policy

Erylo is pre-release and has no supported production version yet. Security fixes will be prioritized on the active development branch; supported-version details will be added before the first public release.

## Report a vulnerability privately

Use [GitHub's private vulnerability reporting](https://github.com/eduardtomas1/Erylo/security/advisories/new). Include the affected revision, macOS version and hardware, a minimal reproduction, impact, and any relevant redacted logs. Do not include credentials, signing material, private files, calendar data, media history, security-scoped bookmark data, socket payloads containing user data, or unredacted diagnostics.

If private reporting is unavailable, open a public issue requesting a private contact channel without vulnerability details.

## Security boundaries

Reports are especially useful when they involve:

- focus or input capture outside the visible Erylo surface;
- access that outlives a disabled module or exceeds a contextual permission grant;
- unsafe handling or cleanup of held files, bookmarks, diagnostics, or crash data;
- local IPC impersonation, cross-user access, malformed JSON, replay, or arbitrary command execution;
- updater, signing, Hardened Runtime, notarization, or rollback integrity;
- undisclosed network activity, telemetry, or crash reporting.

Erylo must not require root or Full Disk Access. Crash reporting is opt-in, and local diagnostics must be reviewed and redacted before sharing.
