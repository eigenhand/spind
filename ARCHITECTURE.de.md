# Architektur

*[English](ARCHITECTURE.md) · Deutsch*

Die README sagt, was Spind tut, `SECURITY.de.md` sagt, wie es mit Zugangsdaten umgeht und
wo die bewussten Kompromisse liegen. Dieses Dokument beschreibt Aufbau und
Designentscheidungen – und was du wissen solltest, bevor du etwas änderst.

Anders als seine Schwesterprojekte [Faden](https://github.com/eigenhand/faden) und
[Fundus](https://github.com/eigenhand/fundus) hat Spind mehr als ein Produkt auf einem
Kern, und der größte Teil dieses Dokuments handelt von dieser Naht.

## Ein Kern, vier Produkte

```
                         ┌──────────────┐
                         │  SpindCore   │   ~2 800 Zeilen · Foundation, keine Oberfläche
                         │              │   SFTP · Sync · Versionen · Verbinden
                         └──────┬───────┘
          ┌─────────────┬───────┴────────┬──────────────┐
          ▼             ▼                ▼              ▼
   ┌─────────────┐ ┌──────────┐ ┌─────────────────┐ ┌────────┐
   │  SpindApp   │ │SpindMobile│ │ SpindFileProvider│ │ spind  │
   │ macOS ~6 500│ │ iOS ~2 000│ │  ~1 500 Zeilen   │ │CLI ~400│
   └─────────────┘ └──────────┘ └─────────────────┘ └────────┘
                                   zweimal gebaut:
                                   macOS + iOS-Erweiterung
```

`SpindCore` importiert Foundation und seine Abhängigkeiten (Citadel für SFTP, GRDB für
den Metadatenspeicher, dazu swift-crypto und swift-nio, die über Citadel hereinkommen). Es weiß nichts von einem Fenster,
einer Menüleiste oder einer Dateien-App.

Es gibt eine Ausnahme, und sie ist abgegrenzt: `AppAppearance.swift` importiert SwiftUI
für `ColorScheme` und hinter `#if os(macOS)` auch AppKit — weil das Erscheinungsbild
einer Menüleisten-App über `NSApp.appearance` gesetzt wird und nicht über einen
View-Modifier. Es ist die einzige Datei im Kern, die ein UI-Framework importiert. (Einige
andere Dateien haben `#if os(macOS)`-Zweige für Dinge, die iOS nicht bietet, etwa FSEvents
und das Starten von `rsync`.)

## Das Finder-Laufwerk ist einmal geschrieben und zweimal gebaut

`SpindFileProvider` und `SpindMobileFileProvider` sind zwei Ziele in `project.yml`, die
auf **denselben Quellordner** zeigen. Das Laufwerk im Finder und der Spind-Eintrag in der
Dateien-App des iPhones sind dieselben Quelldateien, für zwei Plattformen übersetzt.

Das geht, weil `NSFileProviderReplicatedExtension` auf beiden dieselbe Schnittstelle ist,
und das solltest du wissen, bevor du dort ein `#if os(macOS)` einbaust: Alles, was in
diesem Ordner steht, wird zweimal ausgeliefert.

| Ziel | Plattform | Was es ist |
| --- | --- | --- |
| `SpindCore` | beide | Bibliothek: SFTP-Client, Sync-Motor, Versionen, Verbinden, Konfiguration |
| `SpindApp` | macOS | Menüleisten-App, Einstellungen, Freigaben, die Freigabe-Seite, Collabora-Token |
| `SpindMobile` | iOS | Einrichtung, Status, Fotosicherung, Wiederherstellen, App-Sperre |
| `SpindFileProvider` | macOS + iOS | Das Laufwerk, zweimal aus einer Quelle |
| `spind` | macOS | Kommandozeile: `sync`, `watch`, `versions`, `restore`, Agent einrichten |

## Was im Kern liegt, und warum genau das

Die Regel, der der Kern folgt: **alles, was entscheidet, was mit einer Datei geschieht,
und nichts, was entscheidet, wie sie aussieht.** Vier Dateien tragen das Gewicht, und
alle vier haben Tests, weil ein Fehler darin Daten kostet und nicht Pixel.

- **`SyncEngine`** macht aus zwei Verzeichnislisten einen Plan von Aktionen.
  Deterministisch, ohne eigene Ein- und Ausgabe — deshalb handelt mehr als die Hälfte
  der Tests davon.
- **`RemoteListingDiff`** vergleicht den letzten bekannten Stand mit dem aktuellen.
  Eine Handvoll Zeilen, und sie entscheiden, was heruntergeladen und was **gelöscht** wird. Sein
  Vertrag ist gefährlich und steht als solcher da: Was in der aktuellen Liste fehlt, gilt
  als gelöscht — eine leere Liste nach einem Verbindungsfehler erklärte also den ganzen
  Ordner für verschwunden. Die Funktion soll das tun; die Zusicherung, dass sie nie das
  Ergebnis eines fehlgeschlagenen Aufrufs sieht, liegt eine Ebene höher, beim Aufrufer.
- **`VersionRetention`** entscheidet, welche Fassungen gehen dürfen. Ein paar Dutzend
  Zeilen, und das Versprechen darüber ist der erste Test: Solange es überhaupt eine
  Fassung gibt, bleibt eine. Die Stufen: bis zu 25 Fassungen aus den letzten 24 Stunden,
  eine pro Tag für 30 Tage, eine pro Woche für ein Jahr, danach eine pro Monat, und eine
  feste Obergrenze von 50 je Datei.
- **`RemotePath`** prüft Namen, die vom Server kommen — weil der Server nicht immer
  unserer ist und ein `..` in einem Namen geradewegs aus dem Sync-Ordner herausläuft.
  Wenige Zeilen, aufgerufen vom Sync-Motor und von der File-Provider-Erweiterung.

Alles andere im Kern ist Unterbau: `StorageBoxClient` (SFTP über Citadel),
`ConnectionPool`, `MetadataStore` (GRDB), `FolderWatcher`, `ProcessLock`, `HostKey`,
`SSHKeyGen`, `PairingCode`, `DeviceEnrollment`, `RsyncTransfer` (Delta-Übertragung
großer Dateien auf dem Mac; scheitert rsync, folgt eine vollständige Übertragung per
SFTP).

## Die Mac-App ist der größte Teil, und das stimmt so

Ungefähr doppelt so groß wie der Kern. Nicht, weil die Logik dort läge — sie liegt nicht dort
—, sondern weil dort alles wohnt, was auf einem Telefon kein Gegenstück hat: der
Freigabe-Ablauf mit Hetzner-Unterkonten, die Freigabe-Webseite, die Collabora-Brücke und
ihre verschlüsselten Token, die Fenster für Versionen und gelöschte Dateien, der
Speicher-Optimierer, der Einrichtungsassistent, die Sparkle-Updates.

`SyncController` ist das eine langlebige Objekt: ein `ObservableObject`, dem der Motor,
der Abfragetakt und der Zustand gehören, den die Menüleiste zeigt. Darüber hinaus hat die
App keine View Models, aus demselben Grund wie in [Faden](https://github.com/eigenhand/faden) — eine zweite Ebene Indirektion
brächte Dateien, keine Klarheit.

## Die Freigabe-Seite hat keinen Server

`ShareWebUI.html(folderName:authorization:)` gibt eine Zeichenkette von rund 40 KB zurück.
`ShareManager` lädt sie als Datei auf die Storage Box, neben den Ordner, den sie
freigibt. Es gibt keinen Prozess, der sie ausliefert.

Diese eine Tatsache entscheidet mehreres, das sonst willkürlich aussieht:

- **Die Sprache wählt der Browser des Empfängers.** Es gibt nichts, das einen
  `Accept-Language`-Kopf lesen könnte. Die Seite trägt ein Wörterbuch und übersetzt ihre
  eigenen Textknoten beim Laden.
- **Die Zugangsdaten stehen im Quelltext der Seite.** Browser reichen die Anmeldung aus
  einem `benutzer:passwort@host`-Link nicht an nachgeladene Inhalte weiter, also sendet
  die Seite sie selbst. Zusätzliche Preisgabe entsteht dadurch nicht: Die Seite ist
  ohnehin nur mit genau diesen Zugangsdaten abrufbar.
- **Das Datum folgt dem Leser**, nicht dem Absender — `toLocaleDateString(undefined, …)`.

Die Collabora-Brücke ist der umgekehrte Fall: Sie *ist* ein Server, sie ist optional, sie
gehört nicht zur App, und sie liegt in `server/collabora/`.

## Die Kommandozeile ist ein fünftes Produkt, kein Hilfsmittel zum Fehlersuchen

`spind` ist eine einzige Datei mit rund 400 Zeilen und tut, was die App tut: abgleichen, beobachten, Fassungen
zeigen, zurückholen, einen launchd-Agenten einrichten. Es bindet denselben Kern, also
gibt es keine zweite Implementierung von irgendetwas, worauf es ankommt.

Es hat einen eigenen String-Katalog, weil eine SwiftPM-Anwendung kein App-Bundle ist und
`Bundle.module` der einzige Weg zu Ressourcen ist. Fehlt das Bündel — ein Binary, das
jemand allein irgendwohin kopiert hat —, erscheint der deutsche Schlüssel. Das ist kein
hingenommener Notbehelf, sondern der Grund, warum die Schlüssel die deutschen Sätze
selbst sind.

## Wo der Zustand liegt

**`~/.config/spind/config.json`** — Host, Benutzer, Pfade, der Ort des SSH-Schlüssels.
Nichts Geheimes. Du darfst sie kopieren.

**Der Schlüsselbund** — der Hetzner-API-Token, Freigabe-Passwörter, das Collabora-Geheimnis.
Der SSH-Schlüssel selbst liegt als Datei, und die File-Provider-Erweiterung bekommt eine
Kopie im App-Gruppen-Container mit Rechten 0600, weil eine Erweiterung nicht an die
Schlüsselbund-Einträge der App kommt. Das steht in `SECURITY.de.md` und ist nicht
versteckt.

**Der Metadatenspeicher (GRDB)** — wie die letzte Liste aussah, welche Datei
materialisiert ist, was schon hochgeladen wurde. Das ist der Zustand, der einen Abgleich
inkrementell macht, und der Zustand, dessen Verlust teuer ist, aber nicht gefährlich: Ein
neu aufgebauter Speicher kostet eine vollständige Liste, keine Daten.

**Bei Hetzner** — das Ablaufdatum einer Freigabe, als Label am Unterkonto. Dort, weil jeder
Mac des Besitzers dasselbe sehen muss und weil ein PUT auf das Label die Zugangsdaten und
damit jeden verschickten Link unangetastet lässt. Durchgesetzt wird es vom Mac, der
gerade läuft (`ShareManager.maintain`), nicht von Hetzner.

**Auf der Box** — `.spind-versions` für den Verlauf, `.spind-share.html` und
`.spind-share.json` für eine Freigabe. Jede Fassung ist eine gewöhnliche Datei; es gibt
kein Format, das nur Spind lesen kann. Die beiden Freigabe-Dateien liegen im geteilten
Ordner selbst, nie außerhalb – das ist eine Invariante, keine Bequemlichkeit
(`SECURITY.de.md`): Die Zugangsdaten einer Freigabe verlassen den Ordner nicht, für den
sie gelten.

## Bauen

Es gibt zwei Wege zu bauen, und sie liefern nicht dasselbe:

- **Das Xcode-Projekt** (`xcodegen generate`, dann `xcodebuild -scheme Spind` oder
  `scripts/make-dmg.sh`) ist die eigentliche App. Es bettet `SpindFileProvider.appex` ein,
  bindet Sparkle ein und liest Signierung, App-Gruppe und Bundle-IDs aus
  `Config.xcconfig`. Die Projektdatei wird aus `project.yml` erzeugt und nicht
  eingecheckt. Die iPhone-App ist das Schema `SpindMobile`.
- **SwiftPM** (`swift build`, `swift test`, `scripts/make-app.sh`) baut nur den Kern, die
  Kommandozeile und die Menüleisten-App. `make-app.sh` verpackt das Binary zu einer ad hoc
  signierten `dist/Spind.app` ohne Finder-Laufwerk, und `UpdaterManager` fällt auf eine
  leere Attrappe zurück, weil Sparkle nur eine Abhängigkeit des Xcode-Projekts ist. Gut
  für schnelle Durchläufe an der Menüleiste, nicht für den echten Einsatz.

## Prüfen

Rund 80 Unit-Tests, alle in `SpindCoreTests`, alle ohne Netz. Das ist die Teilung: Was
sich aus Werten entscheiden lässt, liegt im Kern und hat einen Test; was einen Server oder
ein Fenster braucht, hat keinen und sagt das. Die eine Ausnahme ist `SpindMobileUITests`,
ein UI-Test der Dateien-Integration, der im iOS-Simulator gegen eine eingerichtete
Verbindung läuft.

Ihre Verteilung sagt etwas über die Geschichte des Projekts. Mehr als die Hälfte der
Tests deckt den Abgleichsplan ab — dort war das Rechnen am schwierigsten. Der Großteil
des Rests kam später an den drei Stellen dazu, an denen ein Fehler **Daten** kostet:
Aufbewahrung, Listenvergleich, Pfadprüfung. Das sind verschiedene Fragen, und die zweite
ist die bessere.

`swift test` führt die Unit-Tests aus. Die CI baut zusätzlich das Paket und bricht bei
Warnungen in unseren eigenen Quellen ab — nur in unseren; eine Warnung in einer
Abhängigkeit ist nicht unsere —, und sie baut beide Apps ohne Signierung aus dem erzeugten
Xcode-Projekt. Das fängt eine Datei, die in `project.yml` fehlt, oder eine Erweiterung,
die nicht mehr kompiliert.
