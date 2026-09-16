# Architecture

*English · [Deutsch](ARCHITECTURE.de.md)*

The README says what Spind does, `SECURITY.md` says how it handles credentials and where
the deliberate compromises are. This one says how it is put together and which decisions
you have to know before you change something.

Spind is the only one of the three eigenhand apps with more than one product built on one
core, so most of this document is about that seam.

## One core, four products

```
                         ┌──────────────┐
                         │  SpindCore   │   2,700 lines · Foundation, no UI
                         │  19 files    │   SFTP · sync · versions · pairing
                         └──────┬───────┘
          ┌─────────────┬───────┴────────┬──────────────┐
          ▼             ▼                ▼              ▼
   ┌─────────────┐ ┌──────────┐ ┌─────────────────┐ ┌────────┐
   │  SpindApp   │ │SpindMobile│ │ SpindFileProvider│ │ spind  │
   │ macOS 6,000 │ │ iOS 2,000 │ │  1,500 lines     │ │ CLI 417│
   └─────────────┘ └──────────┘ └─────────────────┘ └────────┘
                                   built twice:
                                   macOS + iOS extension
```

`SpindCore` imports Foundation and its four dependencies (Citadel for SFTP, GRDB for the
metadata store, swift-crypto, swift-nio). It knows nothing about a window, a menu bar or
a Files app.

There is one exception, and it is guarded: `AppAppearance.swift` imports SwiftUI for
`ColorScheme` and, behind `#if os(macOS)`, AppKit — because setting the appearance of a
menu bar app means `NSApp.appearance` and not a view modifier. That is the only file in
the core that knows a platform exists.

## The file provider is written once and built twice

`SpindFileProvider` and `SpindMobileFileProvider` are two targets in `project.yml` that
point at **the same source folder**. The Finder drive on the Mac and the Spind entry in
the iPhone's Files app are the same 1,500 lines, compiled for two platforms.

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
  no I/O of its own — which is why 45 of the 76 tests are about it.
- **`RemoteListingDiff`** compares the last known state with the current one. Seven
  lines, and they decide what gets downloaded and what gets **deleted**. Its contract is
  dangerous and written down as such: what is missing from the current listing counts as
  deleted, so an empty listing after a connection failure would declare the whole folder
  gone. The function is supposed to do that; the guarantee that it never sees a failed
  call's result lives one level up, at the caller.
- **`VersionRetention`** decides which versions may go. Thirty-three lines, and the
  promise at the top is the first test: as long as there is any version at all, one is
  kept.
- **`RemotePath`** checks names that come from the server — because the server is not
  always ours, and a `..` in a name walks straight out of the sync folder. Six lines at
  two call sites.

Everything else in the core is infrastructure: `StorageBoxClient` (SFTP over Citadel),
`ConnectionPool`, `MetadataStore` (GRDB), `FolderWatcher`, `ProcessLock`, `HostKey`,
`SSHKeyGen`, `PairingCode`, `DeviceEnrollment`.

## The Mac app is the largest part, and that is correct

6,000 lines against the core's 2,700. Not because the logic sits there — it does not —
but because that is where everything lives that has no counterpart on a phone: the
sharing flow with Hetzner sub-accounts, the share web page, the Collabora bridge and its
encrypted tokens, the versions and deleted-files windows, the storage optimiser, the
setup wizard, Sparkle updates.

`SyncController` is the one long-lived object: an `ObservableObject` that owns the engine,
the poll timer and the state the menu bar shows. The app has no view models beyond it,
for the same reason as in Faden — a second layer of indirection would add files, not
clarity.

## The share page has no server

`ShareWebUI.html(folderName:authorization:)` returns one 42 KB string.
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

`spind` is 417 lines and does what the app does: sync, watch, list versions, restore,
install a launchd agent. It links the same core, so there is no second implementation of
anything that matters.

It has its own string catalogue, because a SwiftPM executable is not an app bundle and
`Bundle.module` is the only way to reach resources. If the bundle is missing — a binary
copied somewhere on its own — the German key stands there. That is not a fallback that
was tolerated; it is the reason the keys are the German sentences themselves.

## Where state lives

**`~/.config/spind/config.json`** — host, user, paths, the location of the SSH key.
Nothing secret. It may be copied.

**The keychain** — the Hetzner API token, share passwords, the Collabora secret. The SSH
key itself lies as a file, and the file provider extension gets a copy in the app group
container at mode 0600, because an extension cannot reach the app's keychain items. That
is written down in `SECURITY.md` rather than hidden.

**The metadata store (GRDB)** — what the last listing looked like, which file is
materialised, what was already uploaded. This is the state that makes a sync incremental,
and it is the state whose loss is expensive rather than dangerous: a rebuilt store costs
a full listing, not data.

**On the box** — `.spind-versions` for the history, `.spind-share.html` and
`.spind-share.json` for a share. Every version is an ordinary file; there is no format
that only Spind can read.

## Testing

76 tests, all in `SpindCoreTests`, all without a network. That is the split: everything
decidable from values sits in the core and has a test; everything that needs a server or
a window does not, and says so.

The distribution says something about the project's history. 45 tests cover the sync
plan, which is where the arithmetic was hardest. 25 were added later at the three places
where a mistake costs **data** — retention, the listing diff, path checking. Those are
different questions, and the second one is the better one.

`swift test` runs them. The CI additionally builds the package and fails on warnings in
our own sources — only ours; a warning inside a dependency is not ours to fix.
