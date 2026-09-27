// Spind — Copyright (C) 2026 Christoph Lindl-Guk
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
import AppKit
import SpindCore

/// Web-based collaborative editing for any file in the Spind volume —
/// no local office installation, everything runs in the browser.
///
/// The WOPI bridge needs WebDAV access to files that are not part of a
/// share, so Spind keeps one hidden service sub-account scoped to the
/// sync root. It is created once, its password lives in the Keychain and
/// never leaves this Mac (only sealed inside editor tokens).
enum CollaboraService {
    static let serviceDescription = "Spind-Collabora-Zugang"

    enum ServiceError: LocalizedError {
        case notConfigured
        case creationFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Collabora ist nicht eingerichtet (Schlüssel oder API-Token fehlt)"
            case .creationFailed:
                return "Dienst-Zugang für Collabora konnte nicht angelegt werden"
            }
        }
    }

    /// Returns the service access, creating the sub-account on first use.
    static func access(config: SpindConfig) async throws -> ShareManager.ShareAccess {
        let api = try HetznerAPI()
        let box = try await api.findBox(forUser: config.username)
        let accounts = try await api.subaccounts(boxID: box.id)

        if let existing = accounts.first(where: { $0.description == serviceDescription }),
           let password = KeychainHelper.load(account: "share-pass-\(existing.username)") {
            return ShareManager.ShareAccess(
                host: existing.server.isEmpty ? box.server : existing.server,
                username: existing.username, password: password, writable: true
            )
        }

        guard ShareRules.remainingSlots(used: accounts.count) > 0 else {
            throw HetznerAPI.APIError.limitReached(used: accounts.count)
        }
        // Same home directory as the sync account: every path in the
        // Finder volume maps 1:1 into this account.
        let home = accounts.first(where: { $0.username == config.username })?.homeDirectory ?? ""
        let password = ShareManager.generatePassword()
        try await api.createSubaccount(
            boxID: box.id, homeDirectory: home, password: password,
            description: serviceDescription, readonly: false
        )

        for _ in 0..<15 {
            try? await Task.sleep(for: .seconds(2))
            let updated = try await api.subaccounts(boxID: box.id)
            if let created = updated.first(where: { $0.description == serviceDescription }) {
                KeychainHelper.save(password, account: "share-pass-\(created.username)")
                let access = ShareManager.ShareAccess(
                    host: created.server.isEmpty ? box.server : created.server,
                    username: created.username, password: password, writable: true
                )
                await waitForHost(access.host)
                return access
            }
        }
        throw ServiceError.creationFailed
    }

    /// Fresh sub-account hostnames need a moment before they answer.
    private static func waitForHost(_ host: String, timeout: TimeInterval = 180) async {
        guard let url = URL(string: "https://\(host)/") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let code = (response as? HTTPURLResponse)?.statusCode,
               code == 200 || code == 401 {
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Builds the browser link for collaborative editing of one file.
    static func editorLink(
        forRelativePath path: String, config: SpindConfig
    ) async throws -> URL {
        guard WopiToken.isConfiguredForEditing else { throw ServiceError.notConfigured }
        let access = try await access(config: config)
        guard let token = WopiToken.make(
            host: access.host, username: access.username, password: access.password,
            path: path, writable: true, displayName: NSFullUserName()
        ) else { throw ServiceError.notConfigured }

        var components = URLComponents(string: "\(WopiToken.server)/edit")!
        components.queryItems = [
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "name", value: NSFullUserName()),
        ]
        guard let url = components.url else { throw ServiceError.notConfigured }
        return url
    }
}
