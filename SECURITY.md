# Security

*English · [Deutsch](SECURITY.de.md)*

## Reporting a vulnerability

Please do **not** open a public issue for security problems — send an email to
<christoph.lindl-guk@pm.me> instead. I answer as fast as I can; this is a
spare-time project without a promised response time.

## How Spind handles credentials

* **To the Storage Box** Spind connects exclusively with an **SSH key**. The
  box password is never asked for and never stored.
* The **Hetzner API token**, **share passwords** and the **Collabora secret**
  are kept in the **macOS Keychain**, not in configuration files.
* The configuration (`~/.config/spind/config.json`) holds only host, user
  name, paths and the location of the key.
* The File Provider extension needs the key and gets a copy in the app group
  container for it (mode 0600).

## Deliberate trade-offs

These are not oversights but decisions. If you cannot live with one of them,
do not use the feature it belongs to.

**Share links may carry credentials – or not.** The share window offers
two equal choices. "Copy link" yields `https://user:password@host/…`: one
click, nothing for the recipient to set up. The price: the password is in
the URL, hence in the recipient's browser history, and a messenger hands the
URL to its link preview. "Copy credentials separately" yields the bare
address plus user and password as text; the address can go anywhere, the
password takes a second channel. A preview bot then gets a 401 instead of
the page. Which one fits depends on the folder – so you decide per share;
there is no default. Either way: anyone who has address and password has
access, as with any share link. What secures it is that every share has its
own random password, checked by Hetzner's server (not by the page), is
confined to **one folder**, and can be revoked at any time. Spind does not
count accesses. For truly sensitive data: encrypt first.

**The expiry is soft.** A share expires after 30 days by default; the date
is stored as a label on the sub-account at Hetzner. No server enforces it: the
share is removed by the Mac that runs Spind, which checks hourly. If no Spind
with a valid API token is running anywhere, the share outlives its date.
That is why the window does not say "expires on" but "removed from … on,
once Spind runs", and shows per share when this Mac last checked and whether
the check is failing. The reason for the date is a ceiling: Hetzner allows
100 sub-accounts per Storage Box, and every share, every paired device or
person and the Collabora account take one. Without expiry the counter only
ever goes up. Re-sharing a folder can only extend its life; the only way to
shorten it is to revoke the share. The credentials stay the same when
extending, so links already sent keep working. The same run sweeps share page
and manifest out of folders whose share no longer exists. Shares, extending
and the count exist only with a Storage Box, because they rely on its
sub-account API.

**The share page carries the credentials in its source.** Browsers do not pass
the credentials from a `user:password@host` link on to content loaded
afterwards (the file list, images and downloads fail with 401), so the page
sends them itself. Nothing is exposed that was not already: the page is only
reachable with exactly those credentials in the first place.

This yields a rule that binds future work: **on the box, a share's
credentials live exclusively in files inside the very folder they grant
access to** – today the share page itself and the manifest with its encrypted
editor token. They can therefore be read only by someone who already holds
the credentials, or by the box owner, who could reset the sub-accounts through
the API anyway. No new reader, no privilege gained – and a second Mac of the
same owner may recover them from there. A cross-folder index that carried
credentials would move this boundary and is therefore not built. On the Mac,
share passwords belong in the Keychain and nowhere else; the local list of
shared folders holds paths only. The rule holds only because the sync engine
does not download dot files from the box: anyone who changes that filter pulls
the share page, credentials included, into every mirror folder and thus into
Time Machine.

**Editor tokens are keys.** For Collabora, Spind mints encrypted tokens
(AES-GCM) holding the share access, the file path, the write permission and an
expiry. Anyone holding a token can open exactly the file named in it. Tokens
appear in URLs, so they are **not logged** on the server side and expire after
30 days at the latest.

**No encryption at rest.** Files are stored on the Storage Box as they are. If
you do not want that, encrypt them before putting them there.

**The version history preserves deleted data — for years.** Earlier versions
of every file stay under `.spind-versions`, including after a deletion, and
the history is only thinned with age, not ended: up to 25 versions from the
last 24 hours, one per day for the last 30 days, one per week for the last
year, one per month before that – at most 50 per file. If you have to remove
data for good, you have to clear that out too — and think of the box's own
snapshots.

**No three-way merge in the Finder volume.** Writes through the volume go
straight to the box; on a simultaneous change the last writer wins. The mirror
folder does detect conflicts and keeps both versions. For folders several
people work in, the mirror folder or Collabora is the safer route.

## What Spind does not do

* No telemetry, no crash reports, no analytics — the app talks to your Storage
  Box, to the Hetzner API (only when sharing), to the Collabora server you
  entered yourself and, on the Mac, to GitHub to check for updates (Sparkle
  appcast), and to nothing else.
* No servers in between: files travel directly between your device and the
  box.
