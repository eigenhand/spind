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
import Security

/// Minimal Keychain wrapper for the Hetzner API token — the one secret
/// Spind stores, and it never touches disk in plain text.
enum KeychainHelper {
    private static let service = "dev.eigenhand.spind.app"
    /// Einträge aus der HDrive-Zeit. Wichtig: die Übernahme in den neuen
    /// Dienst MUSS die App selbst machen — per `security`-CLI kopierte
    /// Einträge tragen eine Partitions-Sperre, bei der „Immer erlauben"
    /// nicht greift, und macOS fragt dann in einer Endlosschleife nach
    /// dem Schlüsselbund-Passwort.
    private static let legacyService = "me.hdrive.app"

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load(account: String) -> String? {
        if let value = read(service: service, account: account) {
            return value
        }
        // Einmalige Übernahme: unter dem neuen Dienst neu anlegen — der
        // Eintrag gehört dann dieser App, macOS fragt nie wieder.
        guard let legacy = read(service: legacyService, account: account) else {
            return nil
        }
        save(legacy, account: account)
        return legacy
    }

    private static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
