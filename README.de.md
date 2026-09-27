# Spind

*[English](README.md) · Deutsch*

[![CI](https://github.com/eigenhand/spind/actions/workflows/ci.yml/badge.svg)](https://github.com/eigenhand/spind/actions/workflows/ci.yml)

Deine eigene Hetzner Storage Box als Cloud-Laufwerk. Nativ für macOS und iOS,
quelloffen, ohne Abo und ohne fremde Cloud dazwischen.

**Frühes Stadium – richte Snapshots auf deiner Storage Box ein, bevor du
Spind nutzt ([docs/BACKUP.de.md](docs/BACKUP.de.md)).**

**Voraussetzungen:** macOS 14+ (iPhone-App: iOS 17+) und eine Hetzner Storage
Box oder ein beliebiger anderer SFTP-Server. Der Sync funktioniert mit jedem
SFTP-Server; Freigaben und gemeinsames Bearbeiten benötigen eine Storage Box.

## Funktionen

- Finder-Laufwerk mit Dateien auf Abruf (Files on Demand) – Dateien belegen
  erst Platz, wenn du sie öffnest; „Auf dem Computer behalten“ und „Platz
  freigeben“ per Rechtsklick
- Beidseitiger Sync, wahlweise zusätzlich als klassischer Spiegelordner
- Auf dem Mac Delta-Übertragung (rsync) für große Dateien; Verschieben ist ein
  serverseitiges Umbenennen und kostet nichts
- Versionsverlauf für jede Datei – mit der Zeit ausgedünnt (bis zu 25 Fassungen
  aus den letzten 24 Stunden, eine pro Tag für die letzten 30 Tage, eine pro
  Woche für das letzte Jahr, davor eine pro Monat, höchstens 50 je Datei), jede
  davon eine gewöhnliche Datei auf dem Server; gelöschte Dateien lassen sich
  wiederherstellen
- Ordner teilen, mit eigener Weboberfläche: Vorschau, Suche, bei
  Schreibfreigaben auch Hochladen, Umbenennen, Löschen. Link mit Passwort oder
  Adresse und Passwort getrennt, nach Wahl pro Freigabe; Freigaben laufen
  nach 30 Tagen ab und lassen sich ohne neuen Link verlängern
- Freigaben und gemeinsames Bearbeiten benötigen eine Hetzner Storage Box –
  sie beruhen auf deren Unterkonten (100 je Box). Sync, Versionen und Laufwerk
  funktionieren mit jedem SFTP-Server
- Optional gemeinsames Bearbeiten von Office-Dokumenten im Browser
  (eigener Collabora-Server)
- Menüleisten-App mit Live-Fortschritt, Offline-Erkennung, Siri-Kurzbefehlen
  und Kommandozeile (`spind`)
- Konflikte: Der Spiegelordner erkennt sie und behält beide Fassungen als
  Konfliktkopie; im Finder-Laufwerk gewinnt der letzte Schreiber (Details in
  [SECURITY.de.md](SECURITY.de.md))
- iPhone-App: deine Storage Box in der Dateien-App, Fotosicherung,
  App-Sperre; Kopplung mit dem Mac per QR-Code

## Status

Frühes Stadium. Spind läuft im täglichen Einsatz des Autors, und jede Funktion
wurde durchgängig gegen eine echte Storage Box getestet – aber bisher auf
einem Mac mit einer Box, und ein Sync-Fehler kann zu Datenverlust führen.

**Richte vor dem Einsatz Snapshots auf der Storage Box ein**
([docs/BACKUP.de.md](docs/BACKUP.de.md)). Der Versionsverlauf ersetzt kein Backup.

## Roadmap

- [ ] Signierte und notarisierte DMG als erstes Release
- [x] Englische Übersetzung
- [x] Automatische Updates (Sparkle, Appcast am GitHub-Release) – eingebaut,
      aktiv ab dem ersten Release
- [ ] Homebrew Cask
- [x] Beliebige SFTP-Server als Ziel (Freigaben und Collabora bleiben der
      Storage Box vorbehalten)
- [x] iPhone-App (Dateien-Integration)
- [x] Geräte und Personen per QR-Code verbinden

## Installation

Ein Release gibt es noch nicht; eine fertige DMG kommt mit dem ersten. Bis
dahin baust du Spind selbst.

Du brauchst macOS 14+, Xcode 15.3+ und
[XcodeGen](https://github.com/yonaskolb/XcodeGen), dazu eine
[Hetzner Storage Box](https://www.hetzner.com/storage/storage-box) mit
aktiviertem SSH-Zugang und aktivierter Option „Externe Erreichbarkeit“ (oder
einen anderen SFTP-Server).

```bash
cp Config.example.xcconfig Config.xcconfig
# Config.xcconfig anpassen: eigene Team-ID, App-Gruppe und Bundle-IDs
xcodegen generate
xcodebuild -project Spind.xcodeproj -scheme Spind -configuration Release \
    -derivedDataPath build -allowProvisioningUpdates build
```

Die App liegt danach unter `build/Build/Products/Release/Spind.app`. Alternativ
führt `./scripts/make-dmg.sh` denselben Build aus und packt ihn in
`dist/Spind-<Version>.dmg` (signiert mit einer Developer ID, wenn du eine
hast, sonst mit deiner Entwicklersignatur). Die iPhone-App ist das Schema
`SpindMobile` im selben Projekt.

In `Config.xcconfig` steckt die Signierung: Trag bei `SPIND_TEAM_ID` dein
eigenes Apple-Entwicklerteam ein; die App-Gruppe muss damit beginnen. Die
Bundle-IDs (`SPIND_BUNDLE_ID`, `SPIND_IOS_BUNDLE_ID`, `SPIND_IOS_APP_GROUP`)
sind auf das Team des Autors registriert – ändere sie auf eigene, falls Xcode
sie ablehnt. Die Kommentare in `Config.example.xcconfig` erklären jeden Wert.

`./scripts/make-app.sh` ist nur ein schneller SwiftPM-Build: Er erzeugt die
Menüleisten-App unter `dist/Spind.app`, ad hoc signiert, **ohne
Finder-Laufwerk** (die File-Provider-Erweiterung wird nicht eingebettet) und
ohne automatische Updates.

Beim ersten Start erzeugt der Einrichtungsassistent den SSH-Schlüssel und
führt dich bis zur geprüften Verbindung. Für Freigaben benötigst du zusätzlich
einen Hetzner-API-Token (Lesen & Schreiben), für gemeinsames Bearbeiten einen
eigenen Collabora-Server
([server/collabora/README.de.md](server/collabora/README.de.md)).

Nur Kommandozeile, ohne App:

```bash
swift run spind setup --host uXXXXXX.your-storagebox.de --user uXXXXXX
swift run spind sync
```

## Aufbau

| Verzeichnis | Inhalt |
| --- | --- |
| `Sources/SpindCore` | Sync-Motor, SFTP-Client, Metadaten-Datenbank, Versionsverlauf |
| `Sources/SpindApp` | macOS-Menüleisten-App, Einstellungen, Freigaben, Weboberfläche |
| `Sources/SpindMobile` | iPhone-App: Einrichtung, Status, Fotosicherung, App-Sperre |
| `Sources/SpindFileProvider` | Finder-Laufwerk und Dateien-App-Integration (File-Provider-Erweiterung, gebaut für macOS und iOS) |
| `Sources/spind` | Kommandozeile |
| `server/collabora` | Collabora Online und WOPI-Brücke (optional, Docker) |

## Sicherheit

Die Verbindung zur Box läuft ausschließlich über einen SSH-Schlüssel mit
angepinntem Server-Schlüssel; nach deinem Storage-Box-Passwort fragt Spind nie,
und es speichert es auch nicht. Hetzner-API-Token, Freigabe-Passwörter und der
Collabora-Schlüssel liegen im macOS-Schlüsselbund. Freigabe-Links enthalten
absichtlich Zugangsdaten – wer den Link hat, hat Zugriff. Details und bewusste
Kompromisse: [SECURITY.de.md](SECURITY.de.md).
Aufbau und Designentscheidungen: [ARCHITECTURE.de.md](ARCHITECTURE.de.md).

## Lizenz

GNU AGPL v3 oder neuer, siehe [LICENSE](LICENSE). Fremdkomponenten:
[NOTICE.de.md](NOTICE.de.md).
