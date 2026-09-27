# Architecture

*English · [Deutsch](ARCHITECTURE.de.md)*

The README says what Spind does, `SECURITY.md` says how it handles credentials and where
the deliberate compromises are. This one says how it is put together and which decisions
you should know before you change something.

Unlike its sibling projects [Faden](https://github.com/eigenhand/faden) and
[Fundus](https://github.com/eigenhand/fundus), Spind has more than one product built on one
core, so most of this document is about that seam.

## One core, four products

```
                         ┌──────────────┐
                         │  SpindCore   │   ~2,800 lines · Foundation, no UI
                         │              │   SFTP · sync · versions · pairing
                         └──────┬───────┘
          ┌─────────────┬───────┴────────┬──────────────┐
          ▼             ▼                ▼              ▼
   ┌─────────────┐ ┌──────────┐ ┌─────────────────┐ ┌────────┐
   │  SpindApp   │ │SpindMobile│ │ SpindFileProvider│ │ spind  │
   │ macOS ~6,500│ │ iOS ~2,000│ │  ~1,500 lines    │ │CLI ~400│
   └─────────────┘ └──────────┘ └─────────────────┘ └────────┘
                                   built twice:
                                   macOS + iOS extension
```

`SpindCore` imports Foundation and its dependencies (Citadel for SFTP, GRDB for the
metadata store, plus swift-crypto and swift-nio, which come in through Citadel). It knows nothing about a window, a menu bar or
a Files app.

There is one exception, and it is guarded: `AppAppearance.swift` imports SwiftUI for
`ColorScheme` and, behind `#if os(macOS)`, AppKit — because setting the appearance of a
menu bar app means `NSApp.appearance` and not a view modifier. That is the only file in
the core that imports a UI framework. (A few other files have `#if os(macOS)` branches for
things iOS does not offer, such as FSEvents and spawning `rsync`.)

## The file provider is written once and built twice

`SpindFileProvider` and `SpindMobileFileProvider` are two targets in `project.yml` that
point at **the same source folder**. The Finder drive on the Mac and the Spind entry in
the iPhone's Files app are the same source files, compiled for two platforms.

That is possible because `NSFileProviderReplicatedExtension` is the same API on both, and
it is worth knowing before you add a `#if os(macOS)` in there: everything you write in
that folder ships twice.

| Target | Platform | What it is |
| --- | --- | --- |
| `SpindCore` | both | Library: SFTP client, sync engine, versions, pairing, config |
| `SpindApp` | macOS | Menu bar app, settings, sharing, the share web page, Collabora tokens |
| `SpindMobile` | iOS | Setup, status, photo backup, recovery, app lock |
| `SpindFileProvider` | macOS + iOS | The drive, twice from one source |
| `spind` | macOS | Command line: `sync`, `watch`, `versions`, `restore`, agent install |

## What is in the core, and why exactly that

The rule the core follows: **everything that decides what happens to a file, and nothing
that decides what it looks like.** Four files carry the weight, and all four have tests
because a mistake in them costs data rather than pixels.

- **`SyncEngine`** turns two directory listings into a plan of actions. Deterministic,
  no I/O of its own — which is why more than half of the tests are about it.
- **`RemoteListingDiff`** compares the last known state with the current one. A handful
  of lines, and they decide what gets downloaded and what gets **deleted**. Its contract is
  dangerous and written down as such: what is missing from the current listing counts as
  deleted, so an empty listing after a connection failure would declare the whole folder
  gone. The function is supposed to do that; the guarantee that it never sees a failed
  call's result lives one level up, at the caller.
- **`VersionRetention`** decides which versions may go. A few dozen lines, and the
  promise at the top is the first test: as long as there is any version at all, one is
  kept. The tiers: up to 25 versions from the last 24 hours, one per day for 30 days, one
  per week for a year, one per month after that, and a hard ceiling of 50 per file.
- **`RemotePath`** checks names that come from the server — because the server is not
  always ours, and a `..` in a name walks straight out of the sync folder. A few lines,
  called from the sync engine and from the file provider.

Everything else in the core is infrastructure: `StorageBoxClient` (SFTP over Citadel),
`ConnectionPool`, `MetadataStore` (GRDB), `FolderWatcher`, `ProcessLock`, `HostKey`,
`SSHKeyGen`, `PairingCode`, `DeviceEnrollment`, `RsyncTransfer` (delta transfers for
large files on the Mac, falling back to a full SFTP transfer if rsync fails).

## The Mac app is the largest part, and that is correct

Roughly twice the size of the core. Not because the logic sits there — it does not —
but because that is where everything lives that has no counterpart on a phone: the
sharing flow with Hetzner sub-accounts, the share web page, the Collabora bridge and its
encrypted tokens, the versions and deleted-files windows, the storage optimiser, the
setup wizard, Sparkle updates.

`SyncController` is the one long-lived object: an `ObservableObject` that owns the engine,
the poll timer and the state the menu bar shows. The app has no view models beyond it,
for the same reason as in [Faden](https://github.com/eigenhand/faden) — a second layer of indirection would add files, not
clarity.

## The share page has no server

`ShareWebUI.html(folderName:authorization:)` returns one string of roughly 40 KB.
`ShareManager` uploads it to the Storage Box as a file, next to the folder it shares.
There is no process serving it.

That single fact decides several things that look arbitrary otherwise:

- **The recipient's browser picks the language.** There is nothing to read an
  `Accept-Language` header. The page carries a dictionary and translates its own text
  nodes on load.
- **The credentials are in the page source.** Browsers do not pass the authentication
  from a `user:password@host` link on to subresources, so the page sends it itself. No
  additional exposure arises: the page is only reachable with exactly those credentials.
- **The date follows the reader**, not the sender — `toLocaleDateString(undefined, …)`.

The Collabora bridge is the opposite case: it *is* a server, it is optional, it is not
part of the app, and it lives in `server/collabora/`.

## The CLI is a fifth product, not a debugging aid

`spind` is a single file of about 400 lines and does what the app does: sync, watch, list versions, restore,
install a launchd agent. It links the same core, so there is no second implementation of
anything that matters.

It has its own string catalogue, because a SwiftPM executable is not an app bundle and
`Bundle.module` is the only way to reach resources. If the bundle is missing — a binary
copied somewhere on its own — the German key is shown. That is not a fallback that
was tolerated; it is the reason the keys are the German sentences themselves.

## Where state lives

**`~/.config/spind/config.json`** — host, user, paths, the location of the SSH key.
Nothing secret. It may be copied.

**The Keychain** — the Hetzner API token, share passwords, the Collabora secret. The SSH
key itself is a file, and the file provider extension gets a copy in the app group
container at mode 0600, because an extension cannot reach the app's keychain items. That
is written down in `SECURITY.md` rather than hidden.

**The metadata store (GRDB)** — what the last listing looked like, which file is
materialised, what was already uploaded. This is the state that makes a sync incremental,
and it is the state whose loss is expensive rather than dangerous: a rebuilt store costs
a full listing, not data.

**At Hetzner** — a share's expiry, as a label on the sub-account. There because every
Mac of the owner must see the same thing, and because a PUT on the label leaves the
credentials, and with them every link already sent, untouched. Enforced by whichever Mac
happens to be running (`ShareManager.maintain`), not by Hetzner.

**On the box** — `.spind-versions` for the history, `.spind-share.html` and
`.spind-share.json` for a share. Every version is an ordinary file; there is no format
that only Spind can read. The two share files live inside the shared folder itself, never
outside it – an invariant, not a convenience (`SECURITY.md`): a share's credentials never
leave the folder they grant access to.

## Repository layout

| Directory | Contents |
| --- | --- |
| `Sources/SpindCore` | Sync engine, SFTP client, metadata database, version history |
| `Sources/SpindApp` | macOS menu bar app, settings, shares, web interface |
| `Sources/SpindMobile` | iPhone app: setup, status, photo backup, app lock |
| `Sources/SpindFileProvider` | Finder volume and Files app integration (File Provider extension, built for macOS and iOS) |
| `Sources/spind` | Command line |
| `server/collabora` | Collabora Online and the WOPI bridge (optional, Docker) |

## Building

There are two ways to build, and they do not produce the same thing:

- **The Xcode project** (`xcodegen generate`, then `xcodebuild -scheme Spind` or
  `scripts/make-dmg.sh`) is the real app. It embeds `SpindFileProvider.appex`, links
  Sparkle and reads signing, app group and bundle identifiers from `Config.xcconfig`.
  The project file is generated from `project.yml` and not checked in. The iPhone app is
  the `SpindMobile` scheme.
- **SwiftPM** (`swift build`, `swift test`, `scripts/make-app.sh`) builds the core, the
  CLI and the menu bar app only. `make-app.sh` wraps the binary into an ad-hoc signed
  `dist/Spind.app` without the Finder volume, and `UpdaterManager` falls back to a no-op
  because Sparkle is only a dependency of the Xcode project. Good for quick iterations on
  the menu bar, not for real use.

## Testing

Roughly 80 unit tests, all in `SpindCoreTests`, all without a network. That is the split:
everything decidable from values sits in the core and has a test; everything that needs a
server or a window does not, and says so. The one exception is `SpindMobileUITests`, a UI
test of the Files integration that runs in the iOS simulator against a configured
connection.

The distribution says something about the project's history. More than half the tests
cover the sync plan, which is where the arithmetic was hardest. Most of the rest were
added later at the three places where a mistake costs **data** — retention, the listing
diff, path checking. Those are different questions, and the second one is the better one.

`swift test` runs the unit tests. The CI additionally builds the package and fails on
warnings in our own sources — only ours; a warning inside a dependency is not ours to
fix — and builds both apps from the generated Xcode project without signing, which
catches a file missing from `project.yml` or an extension that no longer compiles.
