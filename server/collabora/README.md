# Collabora Online for Spind (doc.example.de)

*English · [Deutsch](README.de.md)*

Collaborative editing of documents that live on the Hetzner Storage Box. Two containers
on the gateway host (`<server>`):

| Service | Port (localhost only) | Task |
| --- | --- | --- |
| `spind-collabora` | 9980 | Collabora Online (CODE) – renders and edits |
| `spind-wopi` | 9981 | WOPI bridge – delivers and saves files over WebDAV |

Collabora cannot read files from WebDAV itself; it speaks WOPI and nothing else. The
bridge is that WOPI host.

## Security model

Every editor link carries an **AES-GCM-encrypted token** holding the share host, the
credentials, the file path, the write permission and an expiry. Without the shared
secret (`wopi.env` on the server, the keychain on the Mac) no token can be forged, and
a token only ever opens that one file. Read-only shares produce tokens without write
permission — Collabora then opens them in read-only mode.

## Deployment

```bash
rsync -a server/collabora/ <server>:~/spind-collabora/
ssh <server> 'cd ~/spind-collabora && sudo docker compose -p spind-collabora up -d --build'
```

`wopi.env` is created once on first start with a random key (`SPIND_WOPI_SECRET`,
base64, 32 bytes) and must not go into git.

Caddy: append the contents of `Caddyfile.snippet` to
`Work-LifeOS/deploy/gateway/Caddyfile`, then

```bash
sudo docker exec lifeos-gateway caddy validate --config /etc/caddy/Caddyfile
sudo docker compose -p lifeos-gateway -f deploy/gateway/docker-compose.yml restart gateway
```

The gateway runs with `admin off`, hence a restart instead of `caddy reload`.

## Stumbling blocks (verified)

* **`no-new-privileges` prevents the start**: Collabora locks every document into a
  jail with the setuid helper `coolmount`. The container needs
  `cap_add: [MKNOD, SYS_ADMIN]` and must *not* run with `no-new-privileges`, or it
  hangs in “Waiting for a new child”.
* **Discovery URLs contain the requesting host**: if the bridge asks from inside the
  container network (`http://collabora:9980`), the answer holds URLs with
  `collabora:9980` that no browser can reach. The bridge therefore rewrites the origin
  to `PUBLIC_URL`.
* `sharedpresets/template` errors in the log are cosmetic (a CODE bug).

## Testing

```bash
curl https://doc.example.de/health              # -> ok
curl -o /dev/null -w "%{http_code}\n" https://doc.example.de/hosting/discovery
```

Creating an editor link (token inside the container, password from the keychain):

```bash
PW=$(security find-generic-password -w -s dev.eigenhand.spind.app -a share-pass-<subaccount>)
ssh <server> "sudo docker exec -e PW='$PW' spind-wopi python -c \"
import base64,json,os,time
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
p={'h':'<sub>.your-storagebox.de','u':'<sub>','p':os.environ['PW'],
   'f':'<file.odt>','w':True,'e':time.time()+7200,'n':'Christoph'}
k=base64.urlsafe_b64decode(os.environ['SPIND_WOPI_SECRET']); n=os.urandom(12)
print('https://doc.example.de/edit?t='+base64.urlsafe_b64encode(
    n+AESGCM(k).encrypt(n,json.dumps(p).encode(),None)).decode().rstrip('='))\""
```
