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

/// Client for the Hetzner API (api.hetzner.com) — used to create scoped,
/// read-only WebDAV sub-accounts as folder shares.
struct HetznerAPI {
    enum APIError: Error, LocalizedError {
        case noToken
        case http(Int, String)
        case boxNotFound
        case shareNotReady

        var errorDescription: String? {
            switch self {
            case .noToken:
                return "Kein Hetzner-API-Token hinterlegt (Einstellungen → Teilen)"
            case .http(let code, let message):
                return "Hetzner-API: HTTP \(code) – \(message)"
            case .boxNotFound:
                return "Keine passende Storage Box zum konfigurierten Benutzer gefunden"
            case .shareNotReady:
                return "Freigabe wurde angelegt, ist aber noch nicht abrufbar"
            }
        }
    }

    struct StorageBox {
        let id: Int
        let username: String
        let server: String
    }

    struct Subaccount {
        let id: Int
        let username: String
        let server: String
        let homeDirectory: String
        let description: String
        let readonly: Bool
    }

    static let tokenAccount = "hetzner-api-token"
    private let base = URL(string: "https://api.hetzner.com/v1")!
    private let token: String

    init() throws {
        guard let token = KeychainHelper.load(account: Self.tokenAccount),
              !token.isEmpty else {
            throw APIError.noToken
        }
        self.token = token
    }

    private func request(
        _ method: String, _ path: String, body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status, String(message.prefix(120)))
        }
        return json
    }

    /// Finds the storage box that belongs to the configured sync user
    /// (e.g. user "uXXXXXX-sub2" → box "uXXXXXX").
    func findBox(forUser syncUser: String) async throws -> StorageBox {
        let json = try await request("GET", "storage_boxes")
        let boxes = (json["storage_boxes"] as? [[String: Any]]) ?? []
        for box in boxes {
            guard let id = box["id"] as? Int,
                  let username = box["username"] as? String else { continue }
            if syncUser == username || syncUser.hasPrefix(username + "-") {
                let server = box["server"] as? String ?? "\(username).your-storagebox.de"
                return StorageBox(id: id, username: username, server: server)
            }
        }
        throw APIError.boxNotFound
    }

    func subaccounts(boxID: Int) async throws -> [Subaccount] {
        let json = try await request("GET", "storage_boxes/\(boxID)/subaccounts")
        let list = (json["subaccounts"] as? [[String: Any]]) ?? []
        return list.compactMap { entry in
            guard let id = entry["id"] as? Int,
                  let username = entry["username"] as? String else { return nil }
            let access = entry["access_settings"] as? [String: Any] ?? [:]
            return Subaccount(
                id: id,
                username: username,
                server: entry["server"] as? String ?? "",
                homeDirectory: entry["home_directory"] as? String ?? "",
                description: entry["description"] as? String ?? "",
                readonly: access["readonly"] as? Bool ?? false
            )
        }
    }

    /// - Parameter sshEnabled: true für echte Spind-Zugänge (SFTP per
    ///   Schlüssel), false für reine Web-Freigaben.
    func createSubaccount(
        boxID: Int, homeDirectory: String, password: String,
        description: String, readonly: Bool, sshEnabled: Bool = false
    ) async throws {
        _ = try await request("POST", "storage_boxes/\(boxID)/subaccounts", body: [
            "home_directory": homeDirectory,
            "password": password,
            "description": description,
            "access_settings": [
                "webdav_enabled": true,
                "samba_enabled": false,
                "ssh_enabled": sshEnabled,
                "reachable_externally": true,
                "readonly": readonly,
            ],
        ])
    }

    func deleteSubaccount(boxID: Int, subaccountID: Int) async throws {
        _ = try await request("DELETE", "storage_boxes/\(boxID)/subaccounts/\(subaccountID)")
    }
}
