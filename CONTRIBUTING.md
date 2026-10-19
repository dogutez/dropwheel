# Contributing to Dropwheel

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting

- **Bugs and ideas:** open an issue with the matching template. Include your macOS version, the
  Dropwheel version (menu bar icon → About Dropwheel) and, if you can, a file that shows the
  problem. Remove anything private from it first.
- **Security problems:** please don't open a public issue. Use **Security → Report a
  vulnerability** instead (see [SECURITY.md](SECURITY.md)).

## Building

You need macOS 15 or later and Xcode 26 (Swift 6.2).

```sh
swift build                 # build everything
swift test                  # unit tests
scripts/build.sh --install  # build Dropwheel.app and install it to ~/Applications
swift run dropwheel-cli run png photo.heic   # use the conversion engine without the UI
```

`Sources/DropwheelCore` is the conversion engine (no UI), `Sources/Dropwheel` is the menu bar
app, `Sources/dropwheel-cli` drives the engine from the terminal.

## Ground rules for changes

Dropwheel's promise is privacy, so a few things need extra care:

- **No network access in the app.** Only the updater (Sparkle) may connect. Don't add networking,
  analytics or crash reporting.
- **No new third-party code** without discussing it in an issue first.
- **Entitlements stay minimal.** Any change to `Resources/*.entitlements` needs an explanation.
- **Never touch the original file.** Results go next to it under a new name, written to a temporary
  file first and renamed without overwriting anything.
- **Claims must stay true.** If you change what the app does with files, metadata or the
  network, update the "Privacy and security" section of the README and add or adjust a test.

Match the style of the surrounding code, keep pull requests focused on one thing, and run
`swift test` before opening one.

By contributing you agree that your work is released under the [MIT License](LICENSE).
