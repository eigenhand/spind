# Sicherheit

*[English](SECURITY.md) · Deutsch*

## Lücken melden

Sicherheitsprobleme bitte **nicht** als öffentliches Issue, sondern per
E-Mail an <christoph.lindl-guk@pm.me>. Ich antworte, so schnell ich kann –
dies ist ein Freizeitprojekt ohne zugesagte Reaktionszeiten.

## Wie Spind mit Zugangsdaten umgeht

* **Zur Storage Box** verbindet sich Spind ausschließlich per
  **SSH-Schlüssel**. Ein Box-Passwort wird nirgends gespeichert oder
  abgefragt.
* **Hetzner-API-Token**, **Freigabe-Passwörter** und der **Collabora-Schlüssel**
  liegen im **macOS-Schlüsselbund**, nicht in Konfigurationsdateien.
* Die Konfiguration (`~/.config/spind/config.json`) enthält nur Host,
  Benutzername, Pfade und den Ort des Schlüssels.
* Die File-Provider-Erweiterung braucht Zugriff auf den Schlüssel und bekommt
  dafür eine Kopie im App-Gruppen-Container (Rechte 0600).

## Bewusste Kompromisse

Diese Punkte sind keine Versehen, sondern Abwägungen. Wer sie nicht mittragen
will, sollte die betroffene Funktion nicht nutzen.

**Freigabe-Links enthalten Zugangsdaten.** Ein Link der Form
`https://benutzer:passwort@host/…` funktioniert per Klick, ohne dass der
Empfänger etwas einrichten muss – das ist der Sinn der Sache. Folge: Wer den
Link hat, hat Zugriff. Er landet in Mail-Postfächern, Chat-Verläufen und
Browser-Historien. Abgesichert ist das dadurch, dass jede Freigabe ein
eigenes, zufälliges Passwort hat, nur auf **einen Ordner** beschränkt ist und
jederzeit widerrufen werden kann. Für besonders schützenswerte Daten ist
dieser Weg trotzdem ungeeignet.

**Die Freigabe-Seite trägt die Zugangsdaten im Quelltext.** Browser reichen
die Anmeldung aus einem `benutzer:passwort@host`-Link nicht an nachgeladene
Inhalte weiter (Dateiliste, Bilder, Downloads scheitern mit 401). Die Seite
sendet die Anmeldung deshalb selbst. Zusätzliche Preisgabe entsteht dadurch
nicht: Die Seite ist ohnehin nur mit genau diesen Zugangsdaten abrufbar.

**Editor-Token sind Schlüssel.** Für Collabora erzeugt Spind verschlüsselte
Token (AES-GCM), die Freigabe-Zugang, Dateipfad, Schreibrecht und Ablaufdatum
enthalten. Wer ein Token hat, kann genau die darin benannte Datei öffnen.
Token stehen in URLs – sie werden deshalb serverseitig **nicht protokolliert**
und laufen nach spätestens 30 Tagen ab.

**Keine Verschlüsselung im Ruhezustand.** Dateien liegen auf der Storage Box
so, wie sie sind. Wer das nicht möchte, verschlüsselt vor dem Ablegen selbst.

**Der Versionsverlauf konserviert gelöschte Daten – über Jahre.** Unter
`.spind-versions` bleiben frühere Fassungen jeder Datei liegen, auch nach dem
Löschen, und der Verlauf wird mit dem Alter nur ausgedünnt, nicht beendet:
heute jede Fassung, diesen Monat eine pro Tag, dieses Jahr eine pro Woche,
davor eine pro Monat (höchstens 50 je Datei). Wer Daten endgültig entfernen
muss, muss auch dort aufräumen – und zusätzlich an die Snapshots der Box
denken.

**Kein Drei-Wege-Abgleich im Finder-Laufwerk.** Schreibvorgänge im Laufwerk
gehen direkt zur Box; bei gleichzeitiger Änderung gewinnt der letzte
Schreiber. Der Spiegelordner dagegen erkennt Konflikte und behält beide
Fassungen. Für Ordner, an denen mehrere Leute arbeiten, ist der Spiegelordner
oder Collabora der sicherere Weg.

## Was Spind nicht tut

* Keine Telemetrie, keine Absturzberichte, keine Analyse – die App spricht
  ausschließlich mit deiner Storage Box, der Hetzner-API (nur beim Teilen) und
  dem Collabora-Server, den du selbst einträgst.
* Keine Zwischenserver: Dateien laufen direkt zwischen Mac und Box.
