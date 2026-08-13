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
import Crypto

/// Generates ed25519 key pairs in OpenSSH format — without ssh-keygen,
/// so that it also works on iOS, where no process can be spawned. The
/// unencrypted openssh-key-v1 format is exactly what Citadel reads back
/// as a private key.
public enum SSHKeyGen {
    public struct KeyPair: Sendable {
        /// Complete contents of the private key file (PEM-like).
        public let privateOpenSSH: String
        /// A single line for authorized_keys or the Hetzner console.
        public let publicLine: String
    }

    public static func generate(comment: String = "spind") -> KeyPair {
        let key = Curve25519.Signing.PrivateKey()
        let publicRaw = key.publicKey.rawRepresentation
        let privateRaw = key.rawRepresentation

        func lengthPrefixed(_ data: Data) -> Data {
            var out = Data()
            var length = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(data)
            return out
        }
        func string(_ text: String) -> Data { lengthPrefixed(Data(text.utf8)) }

        // Public key blob: string "ssh-ed25519" + string key
        var publicBlob = Data()
        publicBlob.append(string("ssh-ed25519"))
        publicBlob.append(lengthPrefixed(publicRaw))

        // Private section: checkint ×2, type, pub, priv (64 = seed+pub),
        // comment, padding 1,2,3,…
        var checkBytes = Data(count: 4)
        checkBytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        var privateSection = Data()
        privateSection.append(checkBytes)
        privateSection.append(checkBytes)
        privateSection.append(string("ssh-ed25519"))
        privateSection.append(lengthPrefixed(publicRaw))
        privateSection.append(lengthPrefixed(privateRaw + publicRaw))
        privateSection.append(string(comment))
        var pad: UInt8 = 1
        while privateSection.count % 8 != 0 {
            privateSection.append(pad)
            pad += 1
        }

        var blob = Data("openssh-key-v1\u{0}".utf8)
        blob.append(string("none"))            // cipher
        blob.append(string("none"))            // kdf
        blob.append(lengthPrefixed(Data()))    // kdf options
        var one = UInt32(1).bigEndian
        withUnsafeBytes(of: &one) { blob.append(contentsOf: $0) }
        blob.append(lengthPrefixed(publicBlob))
        blob.append(lengthPrefixed(privateSection))

        let body = blob.base64EncodedString()
        // OpenSSH wraps after 70 characters.
        let wrapped = stride(from: 0, to: body.count, by: 70).map { start -> Substring in
            let from = body.index(body.startIndex, offsetBy: start)
            let to = body.index(from, offsetBy: 70, limitedBy: body.endIndex) ?? body.endIndex
            return body[from..<to]
        }.joined(separator: "\n")

        let privateFile = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + wrapped + "\n-----END OPENSSH PRIVATE KEY-----\n"
        let publicLine = "ssh-ed25519 \(publicBlob.base64EncodedString()) \(comment)"
        return KeyPair(privateOpenSSH: privateFile, publicLine: publicLine)
    }
}
