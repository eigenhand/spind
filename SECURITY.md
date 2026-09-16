# Security

*English · [Deutsch](SECURITY.de.md)*

## Reporting a vulnerability

Please do **not** open a public issue for security problems — send an email to
<christoph.lindl-guk@pm.me> instead. I answer as fast as I can; this is a
spare-time project without a promised response time.

## How Spind handles credentials

* **To the storage box** Spind connects exclusively with an **SSH key**. A box
  password is never stored and never asked for.
* The **Hetzner API token**, **share passwords** and the **Collabora secret**
  live in the **macOS keychain**, not in configuration files.
* The configuration (`~/.config/spind/config.json`) holds only host, user
  name, paths and the location of the key.
* The File Provider extension needs the key and gets a copy in the app group
  container for it (mode 0600).

## Deliberate trade-offs

These are not oversights but decisions. Whoever cannot live with one of them
should not use the feature it belongs to.

**Share links carry credentials.** A link of the form
`https://user:password@host/…` works on a click, without the recipient having
to set anything up — that is the point of it. The consequence: whoever has the
link has access. It ends up in mailboxes, chat logs and browser histories.
What limits the damage is that every share gets its own random password, is
confined to **one folder**, and can be revoked at any time. For genuinely
sensitive data this route is still the wrong one.

**The share page carries the credentials in its source.** Browsers do not pass
the credentials from a `user:password@host` link on to content loaded
afterwards (the file list, images and downloads fail with 401), so the page
sends them itself. Nothing is exposed that was not already: the page is only
reachable with exactly those credentials in the first place.

**Editor tokens are keys.** For Collabora, Spind mints encrypted tokens
(AES-GCM) holding the share access, the file path, the write permission and an
expiry. Whoever holds a token can open exactly the file named in it. Tokens
appear in URLs, so they are **not logged** on the server side and expire after
30 days at the latest.

**No encryption at rest.** Files sit on the storage box as they are. Whoever
does not want that encrypts them before putting them there.

**The version history preserves deleted data — for years.** Earlier versions
of every file stay under `.spind-versions`, including after a deletion, and
the history is only thinned with age, not ended: every version from today, one
per day this month, one per week this year, one per month before that (at most
50 per file). Whoever has to remove data for good has to clear that out too —
and to think of the box's own snapshots.

**No three-way merge in the Finder volume.** Writes through the volume go
straight to the box; on a simultaneous change the last writer wins. The mirror
folder does detect conflicts and keeps both versions. For folders several
people work in, the mirror folder or Collabora is the safer route.

## What Spind does not do

* No telemetry, no crash reports, no analytics — the app talks to your storage
  box, to the Hetzner API (only when sharing) and to the Collabora server you
  entered yourself, and to nothing else.
* No servers in between: files travel directly between the Mac and the box.
