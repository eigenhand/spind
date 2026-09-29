// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// "Connect another device": a device that is already paired appends
/// the public key of a new one to the account's authorized_keys. The
/// Hetzner console can only set keys while a box is being created —
/// this way works at any time, on any server.
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

    /// Validates and normalises an authorized_keys line.
    public static func validated(_ line: String) throws -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ").map(String.init)
        guard !trimmed.contains("\n"), parts.count >= 2,
              acceptedTypes.contains(parts[0]),
              Data(base64Encoded: parts[1]) != nil
        else { throw EnrollmentError.invalidKey }
        return trimmed
    }

    /// Appends the key to `.ssh/authorized_keys` of the connected
    /// account. Idempotent: if the key material is already there,
    /// nothing happens. Returns true when the key was newly added.
    /// - Parameter home: the home whose `.ssh` is written to. Defaults
    ///   to the connected account's home; for a freshly created
    ///   subaccount this is its folder.
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
        // sshd refuses authorized_keys that are too permissive.
        try await client.run("chmod 600 -- " + StorageBoxClient.quote(keysPath))
        return true
    }
}
