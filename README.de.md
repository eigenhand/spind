# Spind

*[English](README.md) · Deutsch*

[![CI](https://github.com/eigenhand/spind/actions/workflows/ci.yml/badge.svg)](https://github.com/eigenhand/spind/actions/workflows/ci.yml)

Deine eigene Hetzner Storage Box als Cloud-Laufwerk. Nativ für macOS und iOS,
quelloffen, ohne Abo und ohne fremde Cloud dazwischen.

**Frühes Stadium – richte Snapshots auf deiner Storage Box ein, bevor du
Spind nutzt ([docs/BACKUP.de.md](docs/BACKUP.de.md)).**

**Voraussetzungen:** macOS 14+ (iPhone-App: iOS 17+) und eine Hetzner Storage
Box oder ein beliebiger anderer SFTP-Server. Sync, Versionen und Laufwerk
funktionieren mit jedem SFTP-Server; Freigaben und gemeinsames Bearbeiten
benötigen eine Storage Box, weil sie auf deren Unterkonten beruhen, von denen
Hetzner 100 je Storage Box erlaubt.

## Funktionen

- Finder-Laufwerk mit Dateien auf Abruf – Dateien belegen erst Platz, wenn du
  sie öffnest; „Auf dem Computer behalten“ und „Platz freigeben“ per
  Rechtsklick
- Beidseitiger Sync, wahlweise zusätzlich als klassischer Spiegelordner
- Auf dem Mac Delta-Übertragung (rsync) für große Dateien; Verschieben ist ein
  kostenloses Umbenennen auf dem Server
- Versionsverlauf für jede Datei, mit der Zeit ausgedünnt (Details in
  [SECURITY.de.md](SECURITY.de.md)); jede Fassung ist eine gewöhnliche Datei
  auf dem Server, und gelöschte Dateien lassen sich wiederherstellen
- Geteilte Ordner mit eigener Weboberfläche – Vorschau, Suche, bei
  Schreibfreigaben auch Hochladen, Umbenennen, Löschen – über ablaufende,
  verlängerbare Freigabe-Links
- Optional gemeinsames Bearbeiten von Office-Dokumenten im Browser
  (eigener Collabora-Server)
- Menüleisten-App mit Live-Fortschritt, Offline-Erkennung, Siri-Kurzbefehlen
  und Kommandozeile (`spind`)
- Konflikte: Der Spiegelordner behält beide Fassungen als Konfliktkopie; im
  Finder-Laufwerk gewinnt der letzte Schreiber
- iPhone-App: deine Storage Box in der Dateien-App, Fotosicherung,
  App-Sperre; Kopplung mit dem Mac per QR-Code

## Status

Spind läuft im täglichen Einsatz des Autors, und jede Funktion wurde
durchgängig gegen eine echte Storage Box getestet – aber bisher auf einem Mac
mit einer Box, und ein Sync-Fehler kann zu Datenverlust führen. Der
Versionsverlauf ersetzt kein Backup.

## Roadmap

- [ ] Signierte und notarisierte DMG als erstes Release, mit automatischen
      Updates
- [ ] Homebrew Cask

## Installation

Ein Release gibt es noch nicht, also baust du Spind selbst. Du brauchst
macOS 14+, Xcode 15.3+ und [XcodeGen](https://github.com/yonaskolb/XcodeGen),
dazu eine [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box)
mit aktiviertem SSH-Zugang und aktivierter Option „Externe Erreichbarkeit“ (oder
einen anderen SFTP-Server).

```bash
cp Config.example.xcconfig Config.xcconfig
# Config.xcconfig anpassen: eigene Team-ID, App-Gruppe und Bundle-IDs
xcodegen generate
xcodebuild -project Spind.xcodeproj -scheme Spind -configuration Release \
    -derivedDataPath build -allowProvisioningUpdates build
```

Trag in `Config.xcconfig` bei `SPIND_TEAM_ID` dein eigenes
Apple-Entwicklerteam ein und ändere die Bundle-IDs, falls Xcode sie ablehnt;
die Kommentare in `Config.example.xcconfig` erklären jeden Wert. Die App liegt
danach unter `build/Build/Products/Release/Spind.app`; `./scripts/make-dmg.sh`
führt denselben Build aus und packt ihn in eine DMG. Die iPhone-App ist das
Schema `SpindMobile`.

`./scripts/make-app.sh` ist nur ein schneller SwiftPM-Build: eine ad hoc
signierte Menüleisten-App unter `dist/Spind.app`, **ohne Finder-Laufwerk** und
ohne automatische Updates.

Beim ersten Start erzeugt der Einrichtungsassistent den SSH-Schlüssel und
führt dich bis zur geprüften Verbindung. Für Freigaben brauchst du zusätzlich
einen Hetzner-API-Token (Lesen & Schreiben), für gemeinsames Bearbeiten einen
eigenen Collabora-Server
([server/collabora/README.de.md](server/collabora/README.de.md)).

Nur Kommandozeile, ohne App:

```bash
swift run spind setup --host uXXXXXX.your-storagebox.de --user uXXXXXX
swift run spind sync
```

## Sicherheit

Spind verbindet sich ausschließlich über einen SSH-Schlüssel mit angepinntem
Server-Schlüssel; nach deinem Storage-Box-Passwort fragt es nie, und es
speichert es auch nicht. Hetzner-API-Token, Freigabe-Passwörter und der
Collabora-Schlüssel liegen im macOS-Schlüsselbund. Wer einen Freigabe-Link
hat, hat Zugriff. Details und bewusste Kompromisse:
[SECURITY.de.md](SECURITY.de.md). Aufbau, Verzeichnisstruktur und
Designentscheidungen: [ARCHITECTURE.de.md](ARCHITECTURE.de.md).

## Lizenz

GNU AGPL v3 oder neuer, siehe [LICENSE](LICENSE). Fremdkomponenten:
[NOTICE.de.md](NOTICE.de.md).
