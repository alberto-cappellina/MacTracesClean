# MacTracesClean

A **local** privacy utility for macOS. It shows you, **read-only**, what you've
left exposed on your Mac — browser histories, plaintext credentials, saved
Wi-Fi networks, leftovers of uninstalled apps — and can optionally clean those
traces away. No data ever leaves your machine.

Native SwiftUI app, no external dependencies.

## Features

**Privacy audit** (read-only, nothing leaves your Mac)

- Safari / Chromium (Chrome, Edge, Brave, Arc) / Firefox history
- Shell history, flagging commands that contain secrets
- Recently opened documents and recent downloads
- Plaintext credentials and keys (`~/.aws`, `~/.ssh`, `.env`, …) — values masked
- Known Wi-Fi networks
- Leftovers of uninstalled apps under `~/Library`
- Assorted privacy artifacts (Quick Look, Spotlight, Messages, Mail, Notes…)

**Trace cleanup** (dry-run by default, optional backup, files sent to Trash)

- Browser history · Shell history (secrets only or all) · Quick Look cache
- Downloads older than N days · Leftovers of uninstalled apps (high-confidence only)
- Credentials are **never** touched automatically.

## Build & run

```bash
cd MacTracesClean
./build.sh        # requires XcodeGen: brew install xcodegen
```

`build.sh` generates the Xcode project with XcodeGen, builds it with
`xcodebuild`, and launches the app. The `.xcodeproj` is generated and is **not**
checked in — regenerate it with `./build.sh` (or `xcodegen generate`) before
opening it in Xcode.

See [MacTracesClean/README.md](MacTracesClean/README.md) for more detail.

## Full Disk Access

To read Safari, Mail, Messages and similar sources, add **MacTracesClean** under
System Settings › Privacy & Security › **Full Disk Access**, then relaunch the
app. Without this permission the related sections stay empty; the app flags this
and offers a button to open the settings.

## Security & privacy

- Analysis is read-only; no data leaves the Mac.
- Cleanup is dry-run by default, with optional backup and removal to the Trash.
- Browser SQLite databases are read from a temporary read-only copy, so the app
  never interferes with a running browser.
- Not sandboxed (required to read `~/Library`).

## License

Released under the [MIT](LICENSE) license.
