// Spind — Copyright (C) 2026 eigenhand
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public
// License along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// Kopplungscode für „Gerät verbinden per QR": Das verbundene Gerät
/// erzeugt ein Schlüsselpaar für das neue Gerät, trägt den öffentlichen
/// Teil auf dem Server ein und verpackt privaten Schlüssel, Zugang und
/// Server-Pin in einen Code. Das neue Gerät scannt — und ist verbunden.
///
/// Der Code gewährt vollen Zugriff: nur direkt vom eigenen Bildschirm
/// scannen und nirgends speichern. Eintrag jederzeit widerrufbar
/// (Zeile in .ssh/authorized_keys entfernen).
public struct PairingCode: Codable, Sendable {
    public var version: Int
    public var host: String
    public var port: Int
    public var username: String
    /// Privater OpenSSH-Schlüssel des NEUEN Geräts (frisch erzeugt,
    /// öffentlicher Teil ist bereits auf dem Server eingetragen).
    public var privateKey: String
    public var publicLine: String
    public var hostPublicKey: String?

    static let prefix = "spind1:"

    public init(config: SpindConfig, pair: SSHKeyGen.KeyPair) {
        version = 1
        host = config.host
        port = config.port
        username = config.username
        privateKey = pair.privateOpenSSH
        publicLine = pair.publicLine
        hostPublicKey = config.hostPublicKey
    }

    public func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        return Self.prefix + data.base64EncodedString()
    }

    public static func decode(_ text: String) -> PairingCode? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix),
              let data = Data(base64Encoded: String(trimmed.dropFirst(prefix.count))),
              let code = try? JSONDecoder().decode(PairingCode.self, from: data),
              code.version == 1
        else { return nil }
        return code
    }
}
