// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pairing code for "connect a device by QR": the connected device
/// generates a key pair for the new one, registers the public half on
/// the server and packs the private key, the account and the server pin
/// into a code. The new device scans it — and is connected.
///
/// The code grants full access: only ever scan it straight off your own
/// screen, and store it nowhere. The grant can be revoked at any time
/// by removing the line from .ssh/authorized_keys.
public struct PairingCode: Codable, Sendable {
    public var version: Int
    public var host: String
    public var port: Int
    public var username: String
    /// Private OpenSSH key of the NEW device (freshly generated, its
    /// public half is already registered on the server).
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
