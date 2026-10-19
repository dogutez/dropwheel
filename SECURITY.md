# Security

## Reporting a vulnerability

Please report security problems privately through GitHub's
"Report a vulnerability" button (Security → Advisories) on this repository, not in a public
issue. Include the macOS version, the Dropwheel version (menu bar icon → About) and, if you can,
a file or steps that reproduce it. You'll get an answer within a week.

## Design

- **Sandboxed, no network.** The app runs in the App Sandbox without any network entitlement.
  Only Sparkle's separate Downloader service may connect, and only to check for and download
  updates (release builds, when automatic updates are on).
- **Signed updates.** The feed and every update are verified against the EdDSA public key built
  into the app; a modified feed or download is rejected.
- **No sensitive permissions.** No Accessibility, Input Monitoring or Screen Recording. Dropwheel
  never reads keystrokes or the clipboard.
- **Least-privilege file access.** It reads files dropped on it and writes only into folders the
  user explicitly allows. There is no fallback location. Originals are never modified or overwritten.
- **No third-party code** apart from [Sparkle](https://sparkle-project.org) for updates.

The full list of guarantees and limits is in the README under "Privacy and security".
