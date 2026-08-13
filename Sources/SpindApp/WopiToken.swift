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
import CryptoKit

/// Editor links for Collabora. A token is an AES-GCM sealed JSON blob
/// carrying share host, credentials, file path, write permission and an
/// expiry — the counterpart to the self-hosted WOPI bridge.
/// Whoever holds the link can open exactly that one file, nothing else.
enum WopiToken {
    static let secretAccount = "wopi-secret"

    /// File types Collabora can open.
    static let editableExtensions: Set<String> = [
        "odt", "ods", "odp", "odg", "otg", "ott", "ots", "otp",
        "doc", "docx", "dot", "dotx", "xls", "xlsx", "xlt", "xltx",
        "ppt", "pptx", "pot", "potx", "rtf", "txt", "csv",
    ]

    static var isConfigured: Bool {
        KeychainHelper.load(account: secretAccount)?.isEmpty == false
    }

    /// Address of your own Collabora server; without an entry the editing
    /// features stay switched off (see server/collabora/README.md).
    static var server: String {
        let stored = UserDefaults.standard.string(forKey: "docServerURL") ?? ""
        return stored.hasSuffix("/") ? String(stored.dropLast()) : stored
    }

    static var isConfiguredForEditing: Bool { !server.isEmpty && isConfigured }

    static func isEditable(_ name: String) -> Bool {
        editableExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Token covering a whole share (no file path). The share page turns
    /// it into per-file editor links via the bridge, so files added later
    /// are editable without regenerating the page.
    static func makeShareToken(
        host: String, username: String, password: String,
        writable: Bool, validFor days: Int = 30
    ) -> String? {
        seal([
            "h": host, "u": username, "p": password, "w": writable, "n": "Gast",
            "e": Date().addingTimeInterval(Double(days) * 86_400).timeIntervalSince1970,
        ])
    }

    /// Seals a token; returns nil when no secret is configured.
    static func make(
        host: String, username: String, password: String,
        path: String, writable: Bool, displayName: String = "Gast",
        validFor days: Int = 30
    ) -> String? {
        return seal([
            "h": host, "u": username, "p": password, "f": path,
            "w": writable, "n": displayName,
            "e": Date().addingTimeInterval(Double(days) * 86_400).timeIntervalSince1970,
        ])
    }

    private static func seal(_ payload: [String: Any]) -> String? {
        guard let secretString = KeychainHelper.load(account: secretAccount),
              let secret = Data(base64URLEncoded: secretString), secret.count == 32,
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let sealed = try? AES.GCM.seal(json, using: SymmetricKey(data: secret))
        else { return nil }
        return (Data(sealed.nonce) + sealed.ciphertext + sealed.tag).base64URLEncodedString()
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var value = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        self.init(base64Encoded: value)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
