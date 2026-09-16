# Collabora Online für Spind (doc.example.de)

*[English](README.md) · Deutsch*

Kollaboratives Bearbeiten von Dokumenten, die auf der Hetzner Storage Box
liegen. Zwei Container auf dem Gateway-Host (<server>):

| Dienst | Port (nur localhost) | Aufgabe |
| --- | --- | --- |
| `spind-collabora` | 9980 | Collabora Online (CODE) – rendert und editiert |
| `spind-wopi` | 9981 | WOPI-Brücke – liefert/speichert Dateien via WebDAV |

Collabora kann Dateien nicht selbst von WebDAV lesen; es spricht
ausschließlich WOPI. Die Brücke ist dieser WOPI-Host.

## Sicherheitsmodell

Jeder Editor-Link enthält ein **AES-GCM-verschlüsseltes Token** mit
Freigabe-Host, Zugangsdaten, Dateipfad, Schreibrecht und Ablaufzeit.
Ohne das gemeinsame Geheimnis (`wopi.env` auf dem Server,
Schlüsselbund auf dem Mac) lässt sich kein Token fälschen, und ein Token
öffnet immer nur genau die eine Datei. Read-only-Freigaben erzeugen
Tokens ohne Schreibrecht – Collabora öffnet sie dann im Nur-Lese-Modus.

## Deployment

```bash
rsync -a server/collabora/ <server>:~/spind-collabora/
ssh <server> 'cd ~/spind-collabora && sudo docker compose -p spind-collabora up -d --build'
```

`wopi.env` wird beim ersten Start einmalig mit einem Zufallsschlüssel
angelegt (`SPIND_WOPI_SECRET`, base64, 32 Byte) und darf nicht ins Git.

Caddy: Inhalt von `Caddyfile.snippet` an
`Work-LifeOS/deploy/gateway/Caddyfile` anhängen, dann

```bash
sudo docker exec lifeos-gateway caddy validate --config /etc/caddy/Caddyfile
sudo docker compose -p lifeos-gateway -f deploy/gateway/docker-compose.yml restart gateway
```

Der Gateway läuft mit `admin off`, deshalb Neustart statt `caddy reload`.

## Stolpersteine (verifiziert)

* **`no-new-privileges` verhindert den Start**: Collabora sperrt jedes
  Dokument per setuid-Helfer `coolmount` in ein Jail. Der Container
  braucht `cap_add: [MKNOD, SYS_ADMIN]` und darf *nicht* mit
  `no-new-privileges` laufen, sonst hängt es in „Waiting for a new
  child".
* **Discovery-URLs enthalten den Anfrage-Host**: Fragt die Brücke
  containerintern (`http://collabora:9980`), stehen in der Antwort
  URLs mit `collabora:9980`, die kein Browser erreicht. Die Brücke
  schreibt den Ursprung deshalb auf `PUBLIC_URL` um.
* `sharedpresets/template`-Fehler im Log sind kosmetisch (CODE-Bug).

## Test

```bash
curl https://doc.example.de/health              # -> ok
curl -o /dev/null -w "%{http_code}\n" https://doc.example.de/hosting/discovery
```

Editor-Link erzeugen (Token im Container, Passwort aus dem Keychain):

```bash
PW=$(security find-generic-password -w -s dev.eigenhand.spind.app -a share-pass-<subaccount>)
ssh <server> "sudo docker exec -e PW='$PW' spind-wopi python -c \"
import base64,json,os,time
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
p={'h':'<sub>.your-storagebox.de','u':'<sub>','p':os.environ['PW'],
   'f':'<datei.odt>','w':True,'e':time.time()+7200,'n':'Christoph'}
k=base64.urlsafe_b64decode(os.environ['SPIND_WOPI_SECRET']); n=os.urandom(12)
print('https://doc.example.de/edit?t='+base64.urlsafe_b64encode(
    n+AESGCM(k).encrypt(n,json.dumps(p).encode(),None)).decode().rstrip('='))\""
```
