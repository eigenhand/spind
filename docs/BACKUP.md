# Sicherungen der Storage Box

Spind synchronisiert — es sichert nicht. Ein gelöschte Datei ist auf
beiden Seiten weg, und ein Sync-Bug kann Daten beschädigen. Das
Sicherheitsnetz sind die ZFS-Snapshots der Storage Box.

## Aktuelle Einstellung (Box <BOX-ID>, bx11)

* **Automatisch:** täglich um **03:30 Uhr**, Aufbewahrung **7 Snapshots**
  (eine Woche Historie)
* **Manuell:** „Spind Basis vor Weiterentwicklung" als Ausgangspunkt
* Tarif-Limit: **10 Snapshots gesamt** — die 3 freien Plätze bleiben
  bewusst für manuelle Sicherungen vor riskanten Aktionen

Snapshots sind Copy-on-Write: Sie kosten anfangs nichts und wachsen nur
mit den Änderungen.

## Plan ändern

```bash
TOKEN=$(security find-generic-password -w -s dev.eigenhand.spind.app -a hetzner-api-token)
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"max_snapshots": 7, "hour": 3, "minute": 30, "day_of_week": null, "day_of_month": null}' \
  https://api.hetzner.com/v1/storage_boxes/<BOX-ID>/actions/enable_snapshot_plan
```

Manuellen Snapshot anlegen (z. B. vor einer riskanten Änderung):

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"description":"vor Umbau XY"}' \
  https://api.hetzner.com/v1/storage_boxes/<BOX-ID>/snapshots
```

## Wiederherstellen — wichtig

Getestet: **Der Spind-Sub-Account kommt an die Snapshots nicht heran.**
Weder `/.zfs/snapshot` noch `/home/.zfs/snapshot` sind aus einem
Sub-Account sichtbar (die API erlaubt auch keinen Sub-Account auf
Box-Ebene), und die API kennt keinen Rollback-Endpunkt.

Zwei Wege bleiben, beide brauchen den **Hauptzugang** der Box:

1. **Einzelne Dateien:** per SFTP/SSH als Hauptbenutzer `uXXXXXX` auf
   Port 23 anmelden, dann liegen die Snapshots unter
   `/home/.zfs/snapshot/<snapshot-name>/…` — von dort ganz normal
   herunterladen. Das Verzeichnis ist schreibgeschützt.
2. **Komplett zurückrollen:** Hetzner Console → Storage Box →
   Snapshots → gewünschten Snapshot wiederherstellen.

Für den Ernstfall heißt das: Das Passwort des Hauptzugangs griffbereit
haben (Passwortmanager), es wird für die Wiederherstellung gebraucht.
