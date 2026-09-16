# Backups of the Storage Box

*English · [Deutsch](BACKUP.de.md)*

Spind syncs — it does not back up. A deleted file is gone on both sides, and a sync bug
can damage data. The safety net is the Storage Box's ZFS snapshots.

## Current setting (box <BOX-ID>, bx11)

* **Automatic:** daily at **03:30**, retention **7 snapshots** (one week of history)
* **Manual:** “Spind base before further development” as a starting point
* Plan limit: **10 snapshots in total** — the 3 free slots are deliberately kept for
  manual backups before risky operations

Snapshots are copy-on-write: they cost nothing at first and grow only with the changes.

## Changing the plan

```bash
TOKEN=$(security find-generic-password -w -s dev.eigenhand.spind.app -a hetzner-api-token)
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"max_snapshots": 7, "hour": 3, "minute": 30, "day_of_week": null, "day_of_month": null}' \
  https://api.hetzner.com/v1/storage_boxes/<BOX-ID>/actions/enable_snapshot_plan
```

Creating a manual snapshot (before a risky change, for instance):

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"description":"before rebuilding XY"}' \
  https://api.hetzner.com/v1/storage_boxes/<BOX-ID>/snapshots
```

## Restoring — important

Tested: **the Spind sub-account cannot reach the snapshots.** Neither `/.zfs/snapshot`
nor `/home/.zfs/snapshot` is visible from a sub-account (nor does the API allow a
sub-account at box level), and the API knows no rollback endpoint.

Two routes remain, and both need the box's **main access**:

1. **Individual files:** sign in over SFTP/SSH as the main user `uXXXXXX` on port 23;
   the snapshots then lie under `/home/.zfs/snapshot/<snapshot-name>/…` — download from
   there as usual. The directory is read-only.
2. **Rolling back completely:** Hetzner Console → Storage Box → Snapshots → restore the
   snapshot you want.

For the real emergency that means: keep the password of the main access to hand (in a
password manager), it is needed for the restore.
