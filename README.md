# Spind

*English · [Deutsch](README.de.md)*

[![CI](https://github.com/eigenhand/spind/actions/workflows/ci.yml/badge.svg)](https://github.com/eigenhand/spind/actions/workflows/ci.yml)

Your own Hetzner Storage Box as a cloud drive. Native macOS, open source,
no subscription and nobody else's cloud in between.

## Features

- A Finder volume with files on demand – files take up space only once you
  open them; "keep on this computer" and "free up space" from the context menu
- Two-way sync, optionally with a plain mirror folder as well
- Delta transfers for large files; moving a file is a rename on the server
  and costs nothing
- Version history for every file – thinned out over time (every version from
  today, one per day this month, one per week this year), each one an ordinary
  file on the server; deleted files can be restored
- Share folders by link, with a web interface of its own: preview, search,
  and for writable shares also upload, rename and delete
- Optional collaborative editing of office documents in the browser
  (your own Collabora server)
- Menu bar app with live progress, conflict copies instead of data loss,
  offline detection, Siri shortcuts, command line (`spind`)

## Status

Young. Spind runs in the author's daily use and every feature was tested
end to end against a real storage box – but so far on one Mac with one box,
and sync bugs can cost data.

**Set up snapshots on the storage box before using it**
([docs/BACKUP.md](docs/BACKUP.md)). The version history is no substitute for
a backup.

## Roadmap

- [ ] A signed and notarised DMG as the first release
- [x] English localisation
- [x] Automatic updates (Sparkle, appcast attached to the GitHub release)
- [ ] Homebrew cask
- [x] Any SFTP server as the target (shares and Collabora stay exclusive to
      storage boxes)
- [x] iPhone app (Files integration, TestFlight)
- [x] Pair devices and people by QR code

## Installation

A finished DMG comes with the first release. Until then, build it yourself:

Requires macOS 14+, Xcode 15+ and
[XcodeGen](https://github.com/yonaskolb/XcodeGen), plus a
[Hetzner Storage Box](https://www.hetzner.com/storage/storage-box) with SSH
access and external reachability enabled.

```bash
cp Config.example.xcconfig Config.xcconfig   # enter your own team ID
xcodegen generate
./scripts/make-app.sh
```

The app then sits in `dist/Spind.app`; the setup assistant on first launch
creates the SSH key and leads you to a tested connection. Shares additionally
need a Hetzner API token (read and write), collaborative editing needs your
own Collabora server
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
| `Sources/SpindApp` | Menu bar app, settings, shares, web interface |
| `Sources/SpindFileProvider` | Finder volume (File Provider extension) |
| `Sources/spind` | Command line |
| `server/collabora` | Collabora Online and the WOPI bridge (optional, Docker) |

## Security

The connection to the box runs exclusively over SSH keys with a pinned host
key; Spind never stores passwords. Share links deliberately carry credentials –
whoever has the link has access. Details and the trade-offs behind them:
[SECURITY.md](SECURITY.md).
How it is put together: [ARCHITECTURE.md](ARCHITECTURE.md).

## Licence

GNU AGPL v3 or later, see [LICENSE](LICENSE). Third-party components:
[NOTICE.md](NOTICE.md).
