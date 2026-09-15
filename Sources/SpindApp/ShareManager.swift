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

/// Creates and revokes folder shares. A share is a read-only, WebDAV-only
/// sub-account scoped to the folder — the native sharing mechanism of the
/// storage box, revocable at any time.
enum ShareManager {
    static let descriptionPrefix = "Spind-Freigabe: "
    /// Shares from before the rename stay visible and revocable; new ones
    /// are only ever created with the new marker.
    static let legacyDescriptionPrefix = "HDrive-Freigabe: "

    /// Folder path from the subaccount description, old marker as new.
    static func folderPath(fromDescription description: String) -> String? {
        for prefix in [descriptionPrefix, legacyDescriptionPrefix]
        where description.hasPrefix(prefix) {
            return String(description.dropFirst(prefix.count))
        }
        return nil
    }

    struct ShareResult {
        let folder: String
        let server: String
        let username: String
        let password: String
        var writable = false

        /// One-click link with embedded credentials — opens the Spind
        /// share page (a hidden HTML we place in the folder), not the raw
        /// WebDAV listing.
        var directLink: String {
            "https://\(username):\(password)@\(server)/\(ShareWebUI.fileName)"
        }

        var clipboardText: String {
            """
            Spind-Freigabe „\(folder)“ (\(writable ? "Lesen und Schreiben" : "nur Lesen"))

            Link (einfach im Browser öffnen):
            \(directLink)

            Falls der Browser den Link nicht annimmt (z. B. Safari):
            Adresse:  https://\(server)/\(ShareWebUI.fileName)
            Benutzer: \(username)
            Passwort: \(password)

            Im Finder einbinden: „Gehe zu“ → „Mit Server verbinden“ (⌘K) → https://\(server)
            """
        }
    }

    /// Finds an existing share for the folder, if any.
    static func findShare(folder: String, syncUser: String) async throws -> HetznerAPI.Subaccount? {
        let wanted = folder.isEmpty ? "/" : folder
        return try await activeShares(syncUser: syncUser)
            .first { folderPath(fromDescription: $0.description) == wanted }
    }

    static func createShare(
        folderRelativePath: String, syncUser: String, config: SpindConfig?,
        readonly: Bool = true
    ) async throws -> ShareResult {
        let api = try HetznerAPI()
        let box = try await api.findBox(forUser: syncUser)
        let existing = try await api.subaccounts(boxID: box.id)

        // The drive root is the sync user's home directory on the box.
        let root = existing.first(where: { $0.username == syncUser })?.homeDirectory ?? ""
        let cleanRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let homeDirectory = folderRelativePath.isEmpty
            ? cleanRoot
            : cleanRoot.isEmpty ? folderRelativePath : cleanRoot + "/" + folderRelativePath

        let password = generatePassword()
        let description = descriptionPrefix + (folderRelativePath.isEmpty ? "/" : folderRelativePath)
        try await api.createSubaccount(
            boxID: box.id, homeDirectory: homeDirectory,
            password: password, description: description, readonly: readonly
        )

        // Creation is asynchronous — wait for the account to appear.
        for _ in 0..<15 {
            try? await Task.sleep(for: .seconds(2))
            let accounts = try await api.subaccounts(boxID: box.id)
            if let created = accounts.first(where: { candidate in
                candidate.description == description
                    && !existing.contains(where: { $0.id == candidate.id })
            }) {
                let server = created.server.isEmpty ? box.server : created.server
                // Remember the password so the share dialog can show the
                // full link again later.
                KeychainHelper.save(password, account: "share-pass-\(created.username)")
                // Now that the credentials exist, place the share page and
                // its manifest (incl. Collabora editor tokens) in the folder.
                if let config {
                    try? await uploadShareUI(
                        folder: folderRelativePath, config: config,
                        access: ShareAccess(
                            host: server, username: created.username,
                            password: password, writable: !readonly
                        )
                    )
                }
                return ShareResult(
                    folder: folderRelativePath.isEmpty ? "/" : folderRelativePath,
                    server: server,
                    username: created.username,
                    password: password,
                    writable: !readonly
                )
            }
        }
        throw HetznerAPI.APIError.shareNotReady
    }

    static func activeShares(syncUser: String) async throws -> [HetznerAPI.Subaccount] {
        let api = try HetznerAPI()
        let box = try await api.findBox(forUser: syncUser)
        return try await api.subaccounts(boxID: box.id)
            .filter { folderPath(fromDescription: $0.description) != nil }
    }

    static func revoke(
        _ subaccount: HetznerAPI.Subaccount, syncUser: String, config: SpindConfig?
    ) async throws {
        let api = try HetznerAPI()
        let box = try await api.findBox(forUser: syncUser)
        try await api.deleteSubaccount(boxID: box.id, subaccountID: subaccount.id)
        // Best effort: remove the share page from the folder.
        if let config {
            let folder = folderPath(fromDescription: subaccount.description)
                ?? subaccount.description
            let path = folder == "/" ? "" : folder
            let client = StorageBoxClient(config: config)
            if (try? await client.connect()) != nil {
                let htmlPath = remoteSharePath(folder: path, config: config)
                try? await client.remove(htmlPath)
                try? await client.remove(
                    (htmlPath as NSString).deletingLastPathComponent + "/.spind-share.json"
                )
                await client.disconnect()
            }
        }
    }

    private static func remoteSharePath(folder: String, config: SpindConfig) -> String {
        var root = config.remoteRoot
        if root.hasSuffix("/") { root = String(root.dropLast()) }
        let dir = folder.isEmpty ? root : root + "/" + folder
        return dir + "/" + ShareWebUI.fileName
    }

    private static func uploadShareUI(
        folder: String, config: SpindConfig, access: ShareAccess?
    ) async throws {
        let client = StorageBoxClient(config: config)
        try await client.connect()
        do {
            try await uploadShareFiles(
                folder: folder, config: config, client: client, access: access
            )
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private static func uploadShareFiles(
        folder: String, config: SpindConfig, client: StorageBoxClient,
        access: ShareAccess?
    ) async throws {
        let name = (folder as NSString).lastPathComponent
        let authorization = access.map {
            "Basic " + Data("\($0.username):\($0.password)".utf8).base64EncodedString()
        } ?? ""
        let html = ShareWebUI.html(
            folderName: name.isEmpty ? "Freigabe" : name,
            authorization: authorization
        )
        let manifest = try await buildManifest(
            folder: folder, config: config, client: client, access: access
        )

        func upload(_ data: Data, name: String) async throws {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try data.write(to: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            var target = remoteSharePath(folder: folder, config: config)
            target = (target as NSString).deletingLastPathComponent + "/" + name
            try await client.upload(temp, to: target)
        }
        try await upload(Data(html.utf8), name: ShareWebUI.fileName)
        try await upload(manifest, name: ".spind-share.json")
    }

    /// Share credentials, needed to mint Collabora editor tokens.
    struct ShareAccess {
        let host: String
        let username: String
        let password: String
        let writable: Bool
    }

    private struct Manifest: Encodable {
        struct Entry: Encodable {
            let p: String
            let d: Bool
            let s: Int64
            let m: Double?
            /// Collabora editor token (only for editable files)
            let t: String?
        }
        let v = 2
        let folder: String
        let generated: Double
        let editBase: String?
        let canEdit: Bool
        /// One token for the whole share — lets the page build editor
        /// links for files that appear after this manifest was written.
        let shareToken: String?
        let entries: [Entry]
    }

    /// Walks the shared folder remotely and produces the JSON the share
    /// page renders.
    private static func buildManifest(
        folder: String, config: SpindConfig, client: StorageBoxClient,
        access: ShareAccess?
    ) async throws -> Data {
        var root = config.remoteRoot
        if root.hasSuffix("/") { root = String(root.dropLast()) }
        let base = folder.isEmpty ? root : root + "/" + folder

        var entries: [Manifest.Entry] = []
        func walk(_ relative: String) async throws {
            let absolute = relative.isEmpty ? base : base + "/" + relative
            for item in try await client.listDirectory(absolute)
            where !item.name.hasPrefix(".") {
                let path = relative.isEmpty ? item.name : relative + "/" + item.name
                entries.append(Manifest.Entry(
                    p: path, d: item.isDirectory, s: Int64(item.size),
                    m: item.modificationDate?.timeIntervalSince1970, t: nil
                ))
                if item.isDirectory {
                    try await walk(path)
                }
            }
        }
        try await walk("")
        var shareToken: String?
        if let access, WopiToken.isConfiguredForEditing {
            shareToken = WopiToken.makeShareToken(
                host: access.host, username: access.username,
                password: access.password, writable: access.writable
            )
        }
        let manifest = Manifest(
            folder: (folder as NSString).lastPathComponent,
            generated: Date().timeIntervalSince1970,
            editBase: shareToken != nil ? WopiToken.server : nil,
            canEdit: access?.writable ?? false,
            shareToken: shareToken,
            entries: entries
        )
        return try JSONEncoder().encode(manifest)
    }

    /// Regenerates the manifests of the given shared folders (called by
    /// the sync engine after changes inside them).
    static func refreshManifests(folders: [String], config: SpindConfig) async {
        guard !folders.isEmpty else { return }
        let shares = (try? await activeShares(syncUser: config.username)) ?? []
        let client = StorageBoxClient(config: config)
        guard (try? await client.connect()) != nil else { return }
        for folder in folders {
            let description = descriptionPrefix + (folder.isEmpty ? "/" : folder)
            var access: ShareAccess?
            if let share = shares.first(where: { $0.description == description }),
               let password = KeychainHelper.load(account: "share-pass-\(share.username)") {
                access = ShareAccess(
                    host: share.server, username: share.username,
                    password: password, writable: !share.readonly
                )
            }
            try? await uploadShareFiles(
                folder: folder, config: config, client: client, access: access
            )
        }
        await client.disconnect()
    }

    static func loadSharedFolderList() -> [String] {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("spind/shared-folders.json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    /// Rewrites the shared-folders list in the group container (read by
    /// the extension to badge shared folders) and returns the folder paths.
    @discardableResult
    static func refreshSharedFolders(syncUser: String) async throws -> [String] {
        let folders = try await activeShares(syncUser: syncUser).map { share -> String in
            let path = folderPath(fromDescription: share.description) ?? share.description
            return path == "/" ? "" : path
        }
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("spind/shared-folders.json"),
           let data = try? JSONEncoder().encode(folders.sorted()) {
            try? data.write(to: url, options: .atomic)
        }
        return folders.filter { !$0.isEmpty }
    }

    /// Fresh subaccount hostnames take up to ~2 minutes to provision;
    /// blocks until the share page actually answers so users never get a
    /// dead link.
    static func waitUntilReachable(_ result: ShareResult, timeout: TimeInterval = 150) async {
        guard let url = URL(string: "https://\(result.server)/\(ShareWebUI.fileName)") else { return }
        let auth = Data("\(result.username):\(result.password)".utf8).base64EncodedString()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try? await Task.sleep(for: .seconds(6))
        }
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Hetzner's password policy requires mixed classes incl. specials;
    /// we only use URL-safe specials so the credentials-in-link stays
    /// copy-pasteable without encoding.
    static func generatePassword() -> String {
        func pick(_ pool: String, _ count: Int) -> [Character] {
            (0..<count).compactMap { _ in pool.randomElement() }
        }
        var chars = pick("ABCDEFGHJKLMNPQRSTUVWXYZ", 5)
            + pick("abcdefghijkmnopqrstuvwxyz", 5)
            + pick("23456789", 4)
            + pick("-._~", 2)
        chars.shuffle()
        return String(chars)
    }
}
