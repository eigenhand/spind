# Verwendete Open-Source-Komponenten

Spind – Copyright (C) 2026 eigenhand – steht unter der GNU Affero General
Public License v3 oder neuer (siehe `LICENSE`). Es verwendet die
folgenden Bibliotheken und Dienste, deren Lizenzbedingungen fortgelten.

## Swift-Abhängigkeiten (in der App enthalten)

| Projekt | Lizenz | Copyright |
| --- | --- | --- |
| [Citadel](https://github.com/orlandos-nl/Citadel) | MIT | Joannis Orlandos |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | Gwendal Roué |
| [BigInt](https://github.com/attaswift/BigInt) | MIT | Károly Lőrentey |
| [swift-nio](https://github.com/apple/swift-nio) | Apache 2.0 | Apple Inc. und Mitwirkende |
| [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) | Apache 2.0 | Apple Inc. und Mitwirkende |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache 2.0 | Apple Inc. und Mitwirkende |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache 2.0 | Apple Inc. und Mitwirkende |
| [swift-collections](https://github.com/apple/swift-collections) | Apache 2.0 | Apple Inc. und Mitwirkende |

Die Apache-2.0-lizenzierten Komponenten werden unverändert verwendet. Eine
Kopie der Apache License 2.0 findet sich unter
<https://www.apache.org/licenses/LICENSE-2.0>.

## Optionale Serverkomponenten (nicht in der App enthalten)

Wer gemeinsames Bearbeiten nutzen möchte, betreibt diese Dienste selbst:

| Projekt | Lizenz |
| --- | --- |
| [Collabora Online Development Edition](https://www.collaboraonline.com) | MPL-2.0 |
| [FastAPI](https://fastapi.tiangolo.com) | MIT |
| [Uvicorn](https://www.uvicorn.org) | BSD-3-Clause |
| [HTTPX](https://www.python-httpx.org) | BSD-3-Clause |
| [cryptography](https://cryptography.io) | Apache 2.0 / BSD-3-Clause |
| [Caddy](https://caddyserver.com) | Apache 2.0 |

„Collabora" ist eine Marke der Collabora Productivity Ltd. Dieses Projekt
steht in keiner Verbindung zu Collabora und wird von dort weder unterstützt
noch geprüft. Es beschreibt lediglich, wie sich die frei verfügbare
Development Edition selbst betreiben lässt.

„Hetzner" und „Storage Box" sind Marken der Hetzner Online GmbH. Auch hier
besteht keine Verbindung; Spind nutzt lediglich die öffentlich
dokumentierten Schnittstellen SFTP, WebDAV und die Hetzner-API.
