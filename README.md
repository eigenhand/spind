# Spind

*English · [Deutsch](README.de.md)*

[![CI](https://github.com/eigenhand/spind/actions/workflows/ci.yml/badge.svg)](https://github.com/eigenhand/spind/actions/workflows/ci.yml)

Your own Hetzner Storage Box as a cloud drive. Native for macOS and iOS, open
source, no subscription and nobody else's cloud in between.

**Early stage – set up snapshots on your Storage Box before you use it
([docs/BACKUP.md](docs/BACKUP.md)).**

**Requirements:** macOS 14+ (iPhone app: iOS 17+) and a Hetzner Storage Box
or any other SFTP server. The core sync works with any SFTP server; sharing
and collaborative editing need a Storage Box.

## Features

- A Finder volume with files on demand – files take up space only once you
  open them; "keep on this computer" and "free up space" from the context menu
- Two-way sync, optionally with a plain mirror folder as well
- On the Mac, delta transfers (rsync) for large files; moving a file is a
  rename on the server and costs nothing
- Version history for every file – thinned out over time (up to 25 versions
  from the last 24 hours, one per day for the last 30 days, one per week for
  the last year, one per month before that, at most 50 per file), each one an
  ordinary file on the server; deleted files can be restored
- Share folders, with a web interface of its own: preview, search, and for
  writable shares also upload, rename and delete. Link with password, or
  address and password separately, chosen per share; shares expire after 30
  days and can be extended without a new link
- Shares and collaborative editing need a Hetzner Storage Box – they rely on
  its sub-accounts (100 per box). Sync, versions and the drive work with any
  SFTP server
- Optional collaborative editing of office documents in the browser
  (your own Collabora server)
- Menu bar app with live progress, offline detection, Siri shortcuts and a
  command line (`spind`)
- Conflicts: the mirror folder detects them and keeps both versions as a
  conflict copy; in the Finder volume the last writer wins (details in
  [SECURITY.md](SECURITY.md))
- iPhone app: your Storage Box in the Files app, photo backup, app lock;
  pair it with the Mac by QR code

## Status

Early stage. Spind runs in the author's daily use and every feature was
tested end to end against a real Storage Box – but so far on one Mac with one
box, and a sync bug can cause data loss.

**Set up snapshots on the Storage Box before using it**
([docs/BACKUP.md](docs/BACKUP.md)). The version history is no substitute for
a backup.

## Roadmap

- [ ] A signed and notarised DMG as the first release
- [x] English localisation
- [x] Automatic updates (Sparkle, appcast attached to the GitHub release) –
      built in, active from the first release
- [ ] Homebrew cask
- [x] Any SFTP server as the target (shares and Collabora stay exclusive to
      Storage Boxes)
- [x] iPhone app (Files integration)
- [x] Pair devices and people by QR code

## Installation

There is no release yet; a finished DMG comes with the first one. Until then,
build it yourself.

You need macOS 14+, Xcode 15.3+ and
[XcodeGen](https://github.com/yonaskolb/XcodeGen), plus a
[Hetzner Storage Box](https://www.hetzner.com/storage/storage-box) with SSH
access and the "External reachability" option enabled (or any other SFTP
server).

```bash
cp Config.example.xcconfig Config.xcconfig
# edit Config.xcconfig: your own team ID, app group and bundle identifiers
xcodegen generate
xcodebuild -project Spind.xcodeproj -scheme Spind -configuration Release \
    -derivedDataPath build -allowProvisioningUpdates build
```

The app then is in `build/Build/Products/Release/Spind.app`. Alternatively,
`./scripts/make-dmg.sh` runs the same build and packs it into
`dist/Spind-<version>.dmg` (signed with a Developer ID if you have one,
otherwise with your development signature). The iPhone app is the
`SpindMobile` scheme in the same project.

`Config.xcconfig` is where signing happens: set `SPIND_TEAM_ID` to your own
Apple development team; the app group has to start with it. The bundle
identifiers (`SPIND_BUNDLE_ID`, `SPIND_IOS_BUNDLE_ID`, `SPIND_IOS_APP_GROUP`)
are registered to the author's team, so change them to your own if Xcode
refuses them. The comments in `Config.example.xcconfig` explain each value.

`./scripts/make-app.sh` is only a quick SwiftPM build: it yields the menu bar
app in `dist/Spind.app`, ad-hoc signed, **without the Finder volume** (the
File Provider extension is not embedded) and without automatic updates.

On first launch the setup assistant creates the SSH key and leads you to a
tested connection. Shares additionally need a Hetzner API token (read and
write), collaborative editing needs your own Collabora server
([server/collabora/README.md](server/collabora/README.md)).

Command line only, without the app:

```bash
swift run spind setup --host uXXXXXX.your-storagebox.de --user uXXXXXX
swift run spind sync
```

## Layout

| Directory | Contents |
| --- | --- |
| `Sources/SpindCore` | Sync engine, SFTP client, metadata database, version history |
| `Sources/SpindApp` | macOS menu bar app, settings, shares, web interface |
| `Sources/SpindMobile` | iPhone app: setup, status, photo backup, app lock |
| `Sources/SpindFileProvider` | Finder volume and Files app integration (File Provider extension, built for macOS and iOS) |
| `Sources/spind` | Command line |
| `server/collabora` | Collabora Online and the WOPI bridge (optional, Docker) |

## Security

The connection to the box runs exclusively over an SSH key with a pinned host
key; Spind never asks for or stores your Storage Box password. The Hetzner API
token, share passwords and the Collabora secret are kept in the macOS
Keychain. Share links deliberately carry credentials – anyone who has the link
has access. Details and the trade-offs behind them: [SECURITY.md](SECURITY.md).
Structure and design decisions: [ARCHITECTURE.md](ARCHITECTURE.md).

## Licence

GNU AGPL v3 or later, see [LICENSE](LICENSE). Third-party components:
[NOTICE.md](NOTICE.md).
