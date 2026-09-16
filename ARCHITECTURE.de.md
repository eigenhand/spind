# Architektur

*[English](ARCHITECTURE.md) · Deutsch*

Die README sagt, was Spind tut, `SECURITY.de.md` sagt, wie es mit Zugangsdaten umgeht und
wo die bewussten Kompromisse liegen. Dieses hier sagt, wie es gebaut ist und welche
Entscheidungen man kennen muss, bevor man etwas ändert.

Spind ist das einzige der drei eigenhand-Projekte mit mehr als einem Produkt auf einem
Kern, und der größte Teil dieses Dokuments handelt von dieser Naht.

## Ein Kern, vier Produkte

```
                         ┌──────────────┐
                         │  SpindCore   │   2 700 Zeilen · Foundation, keine Oberfläche
                         │  19 Dateien  │   SFTP · Sync · Versionen · Verbinden
                         └──────┬───────┘
          ┌─────────────┬───────┴────────┬──────────────┐
          ▼             ▼                ▼              ▼
   ┌─────────────┐ ┌──────────┐ ┌─────────────────┐ ┌────────┐
   │  SpindApp   │ │SpindMobile│ │ SpindFileProvider│ │ spind  │
   │ macOS 6 000 │ │ iOS 2 000 │ │  1 500 Zeilen    │ │ CLI 417│
   └─────────────┘ └──────────┘ └─────────────────┘ └────────┘
                                   zweimal gebaut:
                                   macOS + iOS-Erweiterung
```

`SpindCore` importiert Foundation und seine vier Abhängigkeiten (Citadel für SFTP, GRDB
für den Metadatenspeicher, swift-crypto, swift-nio). Es weiß nichts von einem Fenster,
einer Menüleiste oder einer Dateien-App.

Es gibt eine Ausnahme, und sie ist abgegrenzt: `AppAppearance.swift` importiert SwiftUI
für `ColorScheme` und hinter `#if os(macOS)` auch AppKit — weil das Erscheinungsbild
einer Menüleisten-App über `NSApp.appearance` gesetzt wird und nicht über einen
View-Modifier. Es ist die einzige Datei im Kern, die weiß, dass es Plattformen gibt.

## Das Finder-Laufwerk ist einmal geschrieben und zweimal gebaut

`SpindFileProvider` und `SpindMobileFileProvider` sind zwei Ziele in `project.yml`, die
auf **denselben Quellordner** zeigen. Das Laufwerk im Finder und der Spind-Eintrag in der
Dateien-App des iPhones sind dieselben 1 500 Zeilen, für zwei Plattformen übersetzt.

Das geht, weil `NSFileProviderReplicatedExtension` auf beiden dieselbe Schnittstelle ist,
und es gehört gewusst, bevor man dort ein `#if os(macOS)` einbaut: Alles, was in diesem
Ordner steht, wird zweimal ausgeliefert.

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
  Deterministisch, ohne eigene Ein- und Ausgabe — deshalb handeln 45 der 76 Tests davon.
- **`RemoteListingDiff`** vergleicht den letzten bekannten Stand mit dem aktuellen.
  Sieben Zeilen, und sie entscheiden, was heruntergeladen und was **gelöscht** wird. Sein
  Vertrag ist gefährlich und steht als solcher da: Was in der aktuellen Liste fehlt, gilt
  als gelöscht — eine leere Liste nach einem Verbindungsfehler erklärte also den ganzen
  Ordner für verschwunden. Die Funktion soll das tun; die Zusicherung, dass sie nie das
  Ergebnis eines fehlgeschlagenen Aufrufs sieht, liegt eine Ebene höher, beim Aufrufer.
- **`VersionRetention`** entscheidet, welche Fassungen gehen dürfen. Dreiunddreißig
  Zeilen, und das Versprechen darüber ist der erste Test: Solange es überhaupt eine
  Fassung gibt, bleibt eine.
- **`RemotePath`** prüft Namen, die vom Server kommen — weil der Server nicht immer
  unserer ist und ein `..` in einem Namen geradewegs aus dem Sync-Ordner herausläuft.
  Sechs Zeilen an zwei Aufrufstellen.

Alles andere im Kern ist Unterbau: `StorageBoxClient` (SFTP über Citadel),
`ConnectionPool`, `MetadataStore` (GRDB), `FolderWatcher`, `ProcessLock`, `HostKey`,
`SSHKeyGen`, `PairingCode`, `DeviceEnrollment`.

## Die Mac-App ist der größte Teil, und das stimmt so

6 000 Zeilen gegen 2 700 im Kern. Nicht, weil die Logik dort läge — sie liegt nicht dort
—, sondern weil dort alles wohnt, was auf einem Telefon kein Gegenstück hat: der
Freigabe-Ablauf mit Hetzner-Unterkonten, die Freigabe-Webseite, die Collabora-Brücke und
ihre verschlüsselten Token, die Fenster für Versionen und gelöschte Dateien, der
Speicher-Optimierer, der Einrichtungsassistent, die Sparkle-Updates.

`SyncController` ist das eine langlebige Objekt: ein `ObservableObject`, dem der Motor,
der Abfragetakt und der Zustand gehören, den die Menüleiste zeigt. Darüber hinaus hat die
App keine View Models, aus demselben Grund wie in Faden — eine zweite Ebene Indirektion
brächte Dateien, keine Klarheit.

## Die Freigabe-Seite hat keinen Server

`ShareWebUI.html(folderName:authorization:)` gibt eine Zeichenkette von 42 KB zurück.
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

`spind` sind 417 Zeilen und tut, was die App tut: abgleichen, beobachten, Fassungen
zeigen, zurückholen, einen launchd-Agenten einrichten. Es bindet denselben Kern, also
gibt es keine zweite Implementierung von irgendetwas, worauf es ankommt.

Es hat einen eigenen Stringkatalog, weil eine SwiftPM-Anwendung kein App-Bundle ist und
`Bundle.module` der einzige Weg zu Ressourcen ist. Fehlt das Bündel — ein Binary, das
jemand allein irgendwohin kopiert hat —, steht der deutsche Schlüssel da. Das ist kein
hingenommener Notbehelf, sondern der Grund, warum die Schlüssel die deutschen Sätze
selbst sind.

## Wo der Zustand liegt

**`~/.config/spind/config.json`** — Host, Benutzer, Pfade, der Ort des SSH-Schlüssels.
Nichts Geheimes. Man darf sie kopieren.

**Der Schlüsselbund** — der Hetzner-API-Token, Freigabe-Passwörter, das Collabora-Geheimnis.
Der SSH-Schlüssel selbst liegt als Datei, und die File-Provider-Erweiterung bekommt eine
Kopie im App-Gruppen-Container mit Rechten 0600, weil eine Erweiterung nicht an die
Schlüsselbund-Einträge der App kommt. Das steht in `SECURITY.de.md` und ist nicht
versteckt.

**Der Metadatenspeicher (GRDB)** — wie die letzte Liste aussah, welche Datei
materialisiert ist, was schon hochgeladen wurde. Das ist der Zustand, der einen Abgleich
inkrementell macht, und der Zustand, dessen Verlust teuer ist, aber nicht gefährlich: Ein
neu aufgebauter Speicher kostet eine vollständige Liste, keine Daten.

**Auf der Box** — `.spind-versions` für den Verlauf, `.spind-share.html` und
`.spind-share.json` für eine Freigabe. Jede Fassung ist eine gewöhnliche Datei; es gibt
kein Format, das nur Spind lesen kann.

## Prüfen

76 Tests, alle in `SpindCoreTests`, alle ohne Netz. Das ist die Teilung: Was sich aus
Werten entscheiden lässt, liegt im Kern und hat einen Test; was einen Server oder ein
Fenster braucht, hat keinen und sagt das.

Ihre Verteilung sagt etwas über die Geschichte des Projekts. 45 Tests decken den
Abgleichsplan ab — dort war das Rechnen am schwierigsten. 25 kamen später an den drei
Stellen dazu, an denen ein Fehler **Daten** kostet: Aufbewahrung, Listenvergleich,
Pfadprüfung. Das sind verschiedene Fragen, und die zweite ist die bessere.

`swift test` führt sie aus. Die CI baut zusätzlich das Paket und bricht bei Warnungen in
unseren eigenen Quellen ab — nur in unseren; eine Warnung in einer Abhängigkeit ist nicht
unsere.
