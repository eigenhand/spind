# Spind

*English · [Deutsch](README.de.md)*

[![CI](https://github.com/eigenhand/spind/actions/workflows/ci.yml/badge.svg)](https://github.com/eigenhand/spind/actions/workflows/ci.yml)

Your own Hetzner Storage Box as a cloud drive. Native for macOS and iOS, open
source, no subscription and nobody else's cloud in between.

**Early stage – set up snapshots on your Storage Box before you use it
([docs/BACKUP.md](docs/BACKUP.md)).**

**Requirements:** macOS 14+ (iPhone app: iOS 17+) and a Hetzner Storage Box
or any other SFTP server. Sync, versions and the drive work with any SFTP
server; sharing and collaborative editing need a Storage Box, because they
rely on its sub-accounts, of which Hetzner allows 100 per Storage Box.

## Features

- A Finder volume with files on demand – files take up space only once you
  open them; "keep on this computer" and "free up space" from the context menu
- Two-way sync, optionally with a plain mirror folder as well
- On the Mac, delta transfers (rsync) for large files; moves are free
  server-side renames
- Version history for every file, thinned out over time (details in
  [SECURITY.md](SECURITY.md)); each version is an ordinary file on the
  server, and deleted files can be restored
- Shared folders with their own web interface – preview, search, and for
  writable shares also upload, rename and delete – via expiring, extendable
  share links
- Optional collaborative editing of office documents in the browser
  (your own Collabora server)
- Menu bar app with live progress, offline detection, Siri shortcuts and a
  command line (`spind`)
- Conflicts: the mirror folder keeps both versions as a conflict copy; in the
  Finder volume the last writer wins
- iPhone app: your Storage Box in the Files app, photo backup, app lock;
  pair it with the Mac by QR code

## Status

Spind runs in the author's daily use and every feature was tested end to end
against a real Storage Box – but so far on one Mac with one box, and a sync
bug can cause data loss. The version history is no substitute for a backup.

## Roadmap

- [ ] A signed and notarized DMG as the first release, with automatic updates
- [ ] Homebrew cask

## Installation

There is no release yet, so build it yourself. You need macOS 14+,
Xcode 15.3+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen), plus a
[Hetzner Storage Box](https://www.hetzner.com/storage/storage-box) with SSH
access and "External reachability" enabled (or another SFTP server).

```bash
cp Config.example.xcconfig Config.xcconfig
# edit Config.xcconfig: your own team ID, app group and bundle identifiers
xcodegen generate
xcodebuild -project Spind.xcodeproj -scheme Spind -configuration Release \
    -derivedDataPath build -allowProvisioningUpdates build
```

Set `SPIND_TEAM_ID` in `Config.xcconfig` to your own Apple development team
and change the bundle identifiers if Xcode refuses them; the comments in
`Config.example.xcconfig` explain each value. The app ends up in
`build/Build/Products/Release/Spind.app`; `./scripts/make-dmg.sh` runs the
same build and packs it into a DMG. The iPhone app is the `SpindMobile`
scheme.

`./scripts/make-app.sh` is only a quick SwiftPM build: an ad-hoc signed menu
bar app in `dist/Spind.app`, **without the Finder volume** and without
automatic updates.

On first launch the setup assistant creates the SSH key and guides you to a
tested connection. Shares additionally need a Hetzner API token (read and
write), collaborative editing your own Collabora server
([server/collabora/README.md](server/collabora/README.md)).

Command line only, without the app:

```bash
swift run spind setup --host uXXXXXX.your-storagebox.de --user uXXXXXX
swift run spind sync
```

## Security

Spind connects exclusively with an SSH key and a pinned host key; it never
asks for or stores your Storage Box password. The Hetzner API token, share
passwords and the Collabora secret are kept in the macOS Keychain. Anyone who
has a share link has access. Details and trade-offs: [SECURITY.md](SECURITY.md).
Structure, repository layout and design decisions:
[ARCHITECTURE.md](ARCHITECTURE.md).

## License

Apache License 2.0, see [LICENSE](LICENSE). Third-party components:
[NOTICE.md](NOTICE.md).
