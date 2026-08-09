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

/// „Weiteres Gerät verbinden": ein bereits verbundenes Gerät hängt den
/// öffentlichen Schlüssel eines neuen Geräts an die authorized_keys des
/// Kontos an. Die Hetzner Console kann Schlüssel nur beim Anlegen einer
/// Box setzen — dieser Weg funktioniert jederzeit, auf jedem Server.
public enum DeviceEnrollment {
    public enum EnrollmentError: LocalizedError {
        case invalidKey

        public var errorDescription: String? {
            "Das ist kein öffentlicher SSH-Schlüssel. Erwartet wird eine "
            + "Zeile wie »ssh-ed25519 AAAA… gerätename«."
        }
    }

    static let acceptedTypes = [
        "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]

    /// Prüft und normalisiert eine authorized_keys-Zeile.
    public static func validated(_ line: String) throws -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ").map(String.init)
        guard !trimmed.contains("\n"), parts.count >= 2,
              acceptedTypes.contains(parts[0]),
              Data(base64Encoded: parts[1]) != nil
        else { throw EnrollmentError.invalidKey }
        return trimmed
    }

    /// Hängt den Schlüssel an `.ssh/authorized_keys` des verbundenen Kontos
    /// an. Idempotent: existiert das Schlüsselmaterial schon, passiert
    /// nichts. Gibt true zurück, wenn der Schlüssel neu hinzukam.
    /// - Parameter home: Zuhause, in dessen `.ssh` geschrieben wird.
    ///   Standard ist das Zuhause des verbundenen Kontos; für einen frisch
    ///   angelegten Subaccount steht hier dessen Ordner.
    @discardableResult
    public static func addAuthorizedKey(
        _ line: String, client: StorageBoxClient, home: String = ""
    ) async throws -> Bool {
        let key = try validated(line)
        let material = key.split(separator: " ").prefix(2).joined(separator: " ")
        let base = home.isEmpty ? "" : home + "/"
        let sshDir = base + ".ssh"
        let keysPath = sshDir + "/authorized_keys"

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("spind-authkeys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        var existing = ""
        if (try? await client.stat(keysPath)) != nil {
            try await client.download(keysPath, to: temporary)
            existing = (try? String(contentsOf: temporary, encoding: .utf8)) ?? ""
        }
        let alreadyThere = existing.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").prefix(2).joined(separator: " ") == material
        }
        if alreadyThere { return false }

        var content = existing
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += key + "\n"
        try content.write(to: temporary, atomically: true, encoding: .utf8)

        try await client.run("mkdir -p -- " + StorageBoxClient.quote(sshDir))
        try await client.run("chmod 700 -- " + StorageBoxClient.quote(sshDir))
        try await client.upload(temporary, to: keysPath)
        // sshd verweigert zu offene authorized_keys — Rechte festziehen.
        try await client.run("chmod 600 -- " + StorageBoxClient.quote(keysPath))
        return true
    }
}
