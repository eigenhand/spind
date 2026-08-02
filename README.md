# Spind

Die eigene Hetzner Storage Box als Cloud-Laufwerk. Nativ für macOS, quelloffen,
ohne Abo und ohne fremde Cloud dazwischen.

## Funktionen

- Finder-Laufwerk mit Files-on-Demand – Dateien belegen erst Platz, wenn man
  sie öffnet; „Auf dem Computer behalten" und „Platz freigeben" per Rechtsklick
- Beidseitiger Sync, wahlweise zusätzlich als klassischer Spiegelordner
- Delta-Übertragung für große Dateien; Verschieben ist ein serverseitiges
  Umbenennen und kostet nichts
- Versionsverlauf für jede Datei, gelöschte Dateien lassen sich wiederherstellen
- Ordner teilen per Link, mit eigener Web-Oberfläche: Vorschau, Suche,
  bei Schreibfreigaben auch Upload, Umbenennen, Löschen
- Optional gemeinsames Bearbeiten von Office-Dokumenten im Browser
  (eigener Collabora-Server)
- Menüleisten-App mit Live-Fortschritt, Konfliktkopien statt Datenverlust,
  Offline-Erkennung, Siri-Kurzbefehle, Kommandozeile (`spind`)

## Status

Jung. Spind läuft im täglichen Einsatz des Autors und jede Funktion wurde
end-to-end gegen eine echte Storage Box getestet – aber bisher auf einem Mac
mit einer Box, und Sync-Fehler können Daten kosten.

**Vor dem Einsatz Snapshots auf der Storage Box einrichten**
([docs/BACKUP.md](docs/BACKUP.md)). Der Versionsverlauf ersetzt kein Backup.

## Roadmap

- [ ] Signierte und notarisierte DMG als erstes Release
- [ ] Englische Übersetzung
- [ ] Automatische Updates
- [ ] Homebrew Cask
- [x] Beliebige SFTP-Server als Ziel (Freigaben/Collabora bleiben Storage-Box-exklusiv)
- [ ] iPhone-App (Dateien-Integration)

## Installation

Eine fertige DMG kommt mit dem ersten Release. Bis dahin selbst bauen:

macOS 14+, Xcode 15+ und [XcodeGen](https://github.com/yonaskolb/XcodeGen)
vorausgesetzt, dazu eine
[Hetzner Storage Box](https://www.hetzner.com/storage/storage-box) mit
aktiviertem SSH-Zugang und externer Erreichbarkeit.

```bash
cp Config.example.xcconfig Config.xcconfig   # eigene Team-ID eintragen
xcodegen generate
./scripts/make-app.sh
```

Die App liegt danach unter `dist/Spind.app`; der Einrichtungsassistent beim
ersten Start erzeugt den SSH-Schlüssel und führt bis zur geprüften Verbindung.
Für Freigaben braucht es zusätzlich einen Hetzner-API-Token (Lesen &
Schreiben), für gemeinsames Bearbeiten einen eigenen Collabora-Server
([server/collabora/README.md](server/collabora/README.md)).

Nur Kommandozeile, ohne App:

```bash
swift run spind setup --host uXXXXXX.your-storagebox.de --user uXXXXXX
swift run spind sync
```

## Aufbau

| Verzeichnis | Inhalt |
| --- | --- |
| `Sources/SpindCore` | Sync-Engine, SFTP-Client, Metadaten-DB, Versionsverlauf |
| `Sources/SpindApp` | Menüleisten-App, Einstellungen, Freigaben, Weboberfläche |
| `Sources/SpindFileProvider` | Finder-Laufwerk (File Provider Extension) |
| `Sources/spind` | Kommandozeile |
| `server/collabora` | Collabora Online + WOPI-Brücke (optional, Docker) |

## Sicherheit

Die Verbindung zur Box läuft ausschließlich über SSH-Schlüssel mit angepinntem
Server-Schlüssel; Passwörter speichert Spind nie. Freigabe-Links enthalten
absichtlich Zugangsdaten – wer den Link hat, hat Zugriff. Details und bewusste
Kompromisse: [SECURITY.md](SECURITY.md).

## Lizenz

GNU AGPL v3 oder neuer, siehe [LICENSE](LICENSE). Fremdkomponenten:
[NOTICE.md](NOTICE.md).
