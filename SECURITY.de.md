# Sicherheit

*[English](SECURITY.md) · Deutsch*

## Lücken melden

Sicherheitsprobleme bitte **nicht** als öffentliches Issue, sondern per
E-Mail an <christoph.lindl-guk@pm.me>. Ich antworte, so schnell ich kann –
dies ist ein Freizeitprojekt ohne zugesagte Reaktionszeiten.

## Wie Spind mit Zugangsdaten umgeht

* **Zur Storage Box** verbindet sich Spind ausschließlich per
  **SSH-Schlüssel**. Das Box-Passwort wird nie abgefragt und nirgends
  gespeichert.
* **Hetzner-API-Token**, **Freigabe-Passwörter** und der **Collabora-Schlüssel**
  liegen im **macOS-Schlüsselbund**, nicht in Konfigurationsdateien.
* Die Konfiguration (`~/.config/spind/config.json`) enthält nur Host,
  Benutzername, Pfade und den Ort des Schlüssels.
* Die File-Provider-Erweiterung braucht Zugriff auf den Schlüssel und bekommt
  dafür eine Kopie im App-Gruppen-Container (Rechte 0600).
* **Auf dem iPhone** liegen Schlüssel und Konfiguration nur im
  App-Gruppen-Container (Schlüssel mit Rechten 0600). Beide sind erst nach dem
  ersten Entsperren seit dem Start lesbar (damit die Dateien-App auch bei
  gesperrtem Gerät funktioniert) und **vom Backup ausgenommen**: Nach der
  Wiederherstellung auf einem neuen Gerät will Spind neu eingerichtet werden.
  Der **Server-Schlüssel** wird bei der ersten erfolgreichen Verbindung
  angepinnt (oder aus dem QR-Kopplungscode übernommen); danach lehnen App und
  Dateien-Erweiterung jeden anderen ab.

## Bewusste Kompromisse

Diese Punkte sind keine Versehen, sondern Abwägungen. Wenn du einen davon
nicht mittragen willst, nutze die betroffene Funktion nicht.

**Freigabe-Links können Zugangsdaten enthalten – oder nicht.** Das
Freigabe-Fenster bietet zwei gleichwertige Wege. „Link kopieren“ liefert
`https://benutzer:passwort@host/…`: ein Klick, der Empfänger richtet nichts
ein. Der Preis: Das Passwort steht in der URL, also im Browser-Verlauf des
Empfängers, und ein Messenger reicht die URL an seine Link-Vorschau weiter.
„Zugangsdaten getrennt kopieren“ liefert die nackte Adresse plus Benutzer und
Passwort als Text; die Adresse darf überall hin, das Passwort geht über einen
zweiten Kanal. Ein Vorschau-Bot bekommt dann 401 statt der Seite. Welcher Weg
passt, hängt vom Ordner ab – deshalb entscheidest du pro Freigabe; eine
Voreinstellung gibt es nicht. In beiden Fällen gilt: Wer Adresse und Passwort
hat, hat Zugriff, wie bei jedem Freigabelink. Abgesichert ist das dadurch,
dass jede Freigabe ein eigenes, zufälliges Passwort hat, das Hetzners Server
prüft (nicht die Seite), nur auf **einen Ordner** beschränkt ist und
jederzeit widerrufen werden kann. Zugriffe zählt Spind nicht. Für besonders
schützenswerte Daten: vorher verschlüsseln.

**Das Ablaufdatum ist weich.** Eine Freigabe läuft standardmäßig nach 30
Tagen ab; das Datum steht als Label am Unterkonto bei Hetzner. Es gibt keinen
Server, der es durchsetzt: Entfernt wird die Freigabe von dem Mac, auf dem
Spind läuft und der stündlich prüft. Läuft nirgends ein Spind mit gültigem
API-Token, lebt die Freigabe über ihr Datum hinaus. Das Fenster sagt deshalb
nicht „läuft ab am“, sondern „wird ab dem … entfernt, sobald Spind läuft“, und
zeigt pro Freigabe, wann dieser Mac zuletzt geprüft hat und ob die Prüfung
fehlschlägt. Der Grund für das Datum ist eine Obergrenze: Hetzner erlaubt 100
Unterkonten pro Storage Box, und jede Freigabe, jedes verbundene Gerät, jede
verbundene Person und der Collabora-Zugang belegen eines. Ohne Ablauf kennt
der Zähler nur eine Richtung. Neuteilen eines Ordners verlängert die Frist
nur, verkürzt wird ausschließlich per Widerruf; die Zugangsdaten bleiben beim
Verlängern gleich, verschickte Links funktionieren weiter. Derselbe Lauf
räumt Freigabe-Seite und Manifest aus Ordnern, deren Freigabe nicht mehr
existiert. Freigaben, Verlängern und die Zählung gibt es nur mit einer
Storage Box, weil sie auf deren Unterkonten-API beruhen.

**Die Freigabe-Seite trägt die Zugangsdaten im Quelltext.** Browser reichen
die Anmeldung aus einem `benutzer:passwort@host`-Link nicht an nachgeladene
Inhalte weiter (Dateiliste, Bilder, Downloads scheitern mit 401). Die Seite
sendet die Anmeldung deshalb selbst. Zusätzliche Preisgabe entsteht dadurch
nicht: Die Seite ist ohnehin nur mit genau diesen Zugangsdaten abrufbar.

Daraus folgt eine Regel, die beim Weiterbauen gilt: **Zugangsdaten einer
Freigabe liegen auf der Box ausschließlich in Dateien innerhalb genau des
Ordners, für den sie gelten** – heute die Freigabe-Seite selbst und das
Manifest mit dem verschlüsselten Editor-Token. Lesen kann sie damit nur, wer
die Zugangsdaten ohnehin hat, oder wer als Eigentümer der Box die Unterkonten
sowieso über die API zurücksetzen könnte. Kein neuer Leser, keine
Rechteausweitung – und ein zweiter Mac desselben Eigentümers darf sie von dort
wiederherstellen. Ein ordnerübergreifender Index, der Zugangsdaten enthält,
würde diese Grenze verschieben und wird deshalb nicht gebaut. Auf dem Mac
gehören Freigabe-Passwörter in den Schlüsselbund und sonst nirgendwohin; die
lokale Liste geteilter Ordner enthält nur Pfade. Die Regel hält nur, weil der
Sync-Motor Punkt-Dateien von der Box nicht herunterlädt: Wer diesen Filter
ändert, lädt die Freigabe-Seite samt Zugangsdaten in jeden Spiegelordner und
damit in Time Machine.

**Editor-Token sind Schlüssel.** Für Collabora erzeugt Spind verschlüsselte
Token (AES-GCM), die Freigabe-Zugang, Dateipfad, Schreibrecht und Ablaufdatum
enthalten. Wer ein Token hat, kann genau die darin benannte Datei öffnen.
Token stehen in URLs – sie werden deshalb serverseitig **nicht protokolliert**
und laufen nach spätestens 30 Tagen ab.

**Keine Verschlüsselung im Ruhezustand.** Dateien liegen auf der Storage Box
so, wie sie sind. Wenn du das nicht möchtest, verschlüssle sie vor dem
Ablegen selbst.

**Der Versionsverlauf konserviert gelöschte Daten – über Jahre.** Unter
`.spind-versions` bleiben frühere Fassungen jeder Datei liegen, auch nach dem
Löschen, und der Verlauf wird mit dem Alter nur ausgedünnt, nicht beendet:
bis zu 25 Fassungen aus den letzten 24 Stunden, eine pro Tag für die letzten
30 Tage, eine pro Woche für das letzte Jahr, davor eine pro Monat – höchstens
50 je Datei. Musst du Daten endgültig entfernen, räum auch dort auf – und
denk zusätzlich an die Snapshots der Box.

**Kein Drei-Wege-Abgleich im Finder-Laufwerk.** Schreibvorgänge im Laufwerk
gehen direkt zur Box; bei gleichzeitiger Änderung gewinnt der letzte
Schreiber. Der Spiegelordner dagegen erkennt Konflikte und behält beide
Fassungen. Für Ordner, an denen mehrere Leute arbeiten, ist der Spiegelordner
oder Collabora der sicherere Weg.

## Was Spind nicht tut

* Keine Telemetrie, keine Absturzberichte, keine Analyse – die App spricht
  ausschließlich mit deiner Storage Box, der Hetzner-API (nur beim Teilen),
  dem Collabora-Server, den du selbst einträgst, und auf dem Mac mit GitHub,
  um nach Updates zu sehen (Sparkle-Appcast).
* Keine Zwischenserver: Dateien laufen direkt zwischen deinem Gerät und der
  Box.
