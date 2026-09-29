// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation
import AppKit
import SpindCore

/// Creates, extends, revokes and tidies folder shares. A share is a
/// WebDAV-only sub-account scoped to the folder — the native sharing
/// mechanism of the storage box, revocable at any time. Its expiry lives
/// in the sub-account's labels and is enforced by whichever Mac runs Spind
/// (see `maintain`); the rules themselves are in `ShareRules`.
enum ShareManager {
    static let descriptionPrefix = "Spind-Freigabe: "
    /// Shares from before the rename stay visible and revocable; new ones
    /// are only ever created with the new marker.
    static let legacyDescriptionPrefix = "HDrive-Freigabe: "
    static let manifestFileName = ".spind-share.json"

    /// Folder path from the subaccount description, old marker as new.
    static func folderPath(fromDescription description: String) -> String? {
        for prefix in [descriptionPrefix, legacyDescriptionPrefix]
        where description.hasPrefix(prefix) {
            return String(description.dropFirst(prefix.count))
        }
        return nil
    }

    static func keychainAccount(for username: String) -> String {
        "share-pass-\(username)"
    }

    struct ShareResult {
        let folder: String
        let server: String
        let username: String
        let password: String
        var writable = false
        var expiresOn: Date?

        /// One-click link with embedded credentials — opens the Spind
        /// share page (a hidden HTML we place in the folder), not the raw
        /// WebDAV listing. Convenient, and it carries the password: into
        /// the recipient's browser history and into whatever a messenger
        /// fetches for its link preview.
        var directLink: String {
            "https://\(username):\(password)@\(server)/\(ShareWebUI.fileName)"
        }

        /// The same page without credentials; the browser asks for them.
        var address: String {
            "https://\(server)/\(ShareWebUI.fileName)"
        }

        private var accessLine: String {
            writable ? "Lesen und Schreiben" : "nur Lesen"
        }

        private var validityLine: String {
            guard let expiresOn else { return "Gültig, bis der Besitzer die Freigabe widerruft." }
            return "Gültig bis " + expiresOn.formatted(date: .long, time: .omitted) + "."
        }

        /// Text for "copy link": one thing to paste into a chat.
        var linkText: String {
            """
            Spind-Freigabe „\(folder)“ (\(accessLine))
            \(directLink)
            \(validityLine)
            """
        }

        /// Text for "copy credentials separately": the address is safe to
        /// send anywhere, the password goes over a second channel or into
        /// the recipient's password manager.
        var credentialsText: String {
            """
            Spind-Freigabe „\(folder)“ (\(accessLine))

            Adresse:  \(address)
            Benutzer: \(username)
            Passwort: \(password)
            \(validityLine)

            Im Finder einbinden: „Gehe zu“ → „Mit Server verbinden“ (⌘K) → https://\(server)
            """
        }
    }

    /// What the share window needs in one round trip.
    struct Lookup {
        let share: HetznerAPI.Subaccount?
        /// All sub-accounts on the box — shares, paired people, Collabora.
        let subaccountsUsed: Int
    }

    static func lookup(folder: String, syncUser: String) async throws -> Lookup {
        let api = try HetznerAPI()
        let box = try await api.findBox(forUser: syncUser)
        let all = try await api.subaccounts(boxID: box.id)
        let wanted = folder.isEmpty ? "/" : folder
        let share = all.first { folderPath(fromDescription: $0.description) == wanted }
        return Lookup(share: share, subaccountsUsed: all.count)
    }

    /// Finds an existing share for the folder, if any.
    static func findShare(folder: String, syncUser: String) async throws -> HetznerAPI.Subaccount? {
        try await lookup(folder: folder, syncUser: syncUser).share
    }

    static func createShare(
        folderRelativePath: String, syncUser: String, config: SpindConfig?,
        readonly: Bool = true, validFor days: Int? = ShareRules.defaultValidityDays
    ) async throws -> ShareResult {
        let api = try HetznerAPI()
        let box = try await api.findBox(forUser: syncUser)
        let existing = try await api.subaccounts(boxID: box.id)

        // The ceiling counts every sub-account, not only ours; failing here
        // beats an API error the user cannot place.
        guard ShareRules.remainingSlots(used: existing.count) > 0 else {
            throw HetznerAPI.APIError.limitReached(used: existing.count)
        }

        // The drive root is the sync user's home directory on the box.
        let root = existing.first(where: { $0.username == syncUser })?.homeDirectory ?? ""
        let cleanRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let homeDirectory = folderRelativePath.isEmpty
            ? cleanRoot
            : cleanRoot.isEmpty ? folderRelativePath : cleanRoot + "/" + folderRelativePath

        let password = generatePassword()
        let description = descriptionPrefix + (folderRelativePath.isEmpty ? "/" : folderRelativePath)
        let expiresOn = ShareRules.expiry(validFor: days)
        try await api.createSubaccount(
            boxID: box.id, homeDirectory: homeDirectory,
            password: password, description: description, readonly: readonly,
            labels: ShareRules.labels(expiresOn: expiresOn)
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
                KeychainHelper.save(password, account: keychainAccount(for: created.username))
                // Now that the credentials exist, place the share page and
                // its manifest (incl. Collabora editor tokens) in the folder.
                if let config {
                    try? await uploadShareUI(
                        folder: folderRelativePath, config: config,
                        access: ShareAccess(
                            host: server, username: created.username,
                            password: password, writable: !readonly
                        ),
                        expiresOn: expiresOn
                    )
                }
                return ShareResult(
                    folder: folderRelativePath.isEmpty ? "/" : folderRelativePath,
                    server: server,
                    username: created.username,
                    password: password,
                    writable: !readonly,
                    expiresOn: expiresOn
                )
            }
        }
        throw HetznerAPI.APIError.shareNotReady
    }

    /// Extends the share: the expiry is a property of the folder, and
    /// re-sharing can only push it out — see `ShareRules.extended`. The
    /// credentials do not change, so links already sent keep working.
    /// Returns the expiry that is now in force.
    @discardableResult
    static func extend(
        _ share: HetznerAPI.Subaccount, validFor days: Int?,
        syncUser: String, config: SpindConfig?
    ) async throws -> Date? {
        let requested = ShareRules.expiry(validFor: days)
        let expiresOn = ShareRules.extended(current: share.expiresOn, requested: requested)
        let api = try HetznerAPI()
        let box = try await api.findBox(forUser: syncUser)
        try await api.updateSubaccount(
            boxID: box.id, subaccountID: share.id,
            description: share.description, labels: ShareRules.labels(expiresOn: expiresOn)
        )
        // The page tells recipients how long the share lives; keep it true.
        if let config, let access = access(for: share) {
            let folder = folderPath(fromDescription: share.description) ?? share.description
            try? await uploadShareUI(
                folder: folder == "/" ? "" : folder, config: config,
                access: access, expiresOn: expiresOn
            )
        }
        return expiresOn
    }

    /// The Keychain entry of this Mac, if it has one.
    static func access(for share: HetznerAPI.Subaccount) -> ShareAccess? {
        guard let password = KeychainHelper.load(account: keychainAccount(for: share.username))
        else { return nil }
        return ShareAccess(
            host: share.server, username: share.username,
            password: password, writable: !share.readonly
        )
    }

    /// A second Mac has no Keychain entry for a share the first one made.
    /// The credentials are in the share page inside the folder, which the
    /// owner reads over SFTP like any other file — no new reader, nothing
    /// gained that the owner did not already have (SECURITY.md).
    static func recoverPassword(
        _ share: HetznerAPI.Subaccount, config: SpindConfig
    ) async -> String? {
        let folder = folderPath(fromDescription: share.description) ?? share.description
        let client = StorageBoxClient(config: config)
        guard (try? await client.connect()) != nil else { return nil }
        defer { Task { await client.disconnect() } }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let remote = remoteSharePath(folder: folder == "/" ? "" : folder, config: config)
        guard (try? await client.download(remote, to: temp)) != nil,
              let html = try? String(contentsOf: temp, encoding: .utf8),
              let found = ShareRules.credentials(fromSharePage: html),
              // A writable recipient could have edited the page; the
              // account name is the check that this is still our page.
              found.username == share.username
        else { return nil }
        KeychainHelper.save(found.password, account: keychainAccount(for: share.username))
        return found.password
    }

    /// Only for a share whose credentials are gone from both the Keychain
    /// and the folder. Same account, new password: the old links die, the
    /// expiry and the count of sub-accounts stay.
    static func resetPassword(
        _ share: HetznerAPI.Subaccount, syncUser: String, config: SpindConfig?
    ) async throws -> ShareResult {
        let api = try HetznerAPI()
        let box = try await api.findBox(forUser: syncUser)
        let password = generatePassword()
        try await api.resetSubaccountPassword(
            boxID: box.id, subaccountID: share.id, password: password
        )
        KeychainHelper.save(password, account: keychainAccount(for: share.username))
        let server = share.server.isEmpty ? box.server : share.server
        let folder = folderPath(fromDescription: share.description) ?? share.description
        let result = ShareResult(
            folder: folder, server: server, username: share.username,
            password: password, writable: !share.readonly, expiresOn: share.expiresOn
        )
        if let config {
            try? await uploadShareUI(
                folder: folder == "/" ? "" : folder, config: config,
                access: ShareAccess(
                    host: server, username: share.username,
                    password: password, writable: !share.readonly
                ),
                expiresOn: share.expiresOn
            )
        }
        return result
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
        // The account goes first: from here on the link answers 401, no
        // matter whether the files below can be removed right now.
        try await api.deleteSubaccount(boxID: box.id, subaccountID: subaccount.id)
        KeychainHelper.delete(account: keychainAccount(for: subaccount.username))
        // Best effort: remove the share page from the folder. Whatever
        // fails here is caught by the sweep in `maintain`.
        if let config {
            let folder = folderPath(fromDescription: subaccount.description)
                ?? subaccount.description
            let client = StorageBoxClient(config: config)
            if (try? await client.connect()) != nil {
                await removeShareFiles(folder: folder == "/" ? "" : folder, config: config, client: client)
                await client.disconnect()
            }
        }
    }

    // MARK: - Maintenance

    struct MaintenanceReport {
        /// Folders whose share expired and was removed in this run.
        var expired: [String] = []
        /// Folders whose leftover share files were swept away.
        var swept: [String] = []
    }

    static let checkDateKey = "shareCheckDate"
    static let checkErrorKey = "shareCheckError"
    static let checkFailingSinceKey = "shareCheckFailingSince"

    /// When this Mac last looked at the shares, and what went wrong if
    /// the last attempt failed. Shown per share, because the expiry is only
    /// as good as the last check: no Mac running, no enforcement.
    static var lastCheck: (date: Date?, failingSince: Date?, error: String?) {
        let defaults = UserDefaults.standard
        let date = defaults.object(forKey: checkDateKey) as? Double
        let since = defaults.object(forKey: checkFailingSinceKey) as? Double
        return (
            date.map { Date(timeIntervalSince1970: $0) },
            since.map { Date(timeIntervalSince1970: $0) },
            defaults.string(forKey: checkErrorKey)
        )
    }

    /// Enforces expiry and sweeps up. Removes every share whose day has
    /// come, and the share files of every folder that no longer has a
    /// share — leftovers of a revoke whose SFTP step failed, or of a share
    /// that expired while this Mac was off. Records the outcome for the
    /// share window.
    static func maintain(config: SpindConfig) async throws -> MaintenanceReport {
        var report = MaintenanceReport()
        let defaults = UserDefaults.standard
        do {
            let shares = try await activeShares(syncUser: config.username)
            for share in shares where ShareRules.isExpired(share.expiresOn) {
                try await revoke(share, syncUser: config.username, config: config)
                let folder = folderPath(fromDescription: share.description) ?? share.description
                report.expired.append(folder)
            }
            let remaining = try await activeShares(syncUser: config.username)
            let live = Set(remaining.map { share -> String in
                let path = folderPath(fromDescription: share.description) ?? share.description
                return path == "/" ? "" : path
            })
            let orphaned = foldersWithShareFiles().filter { !live.contains($0) }
            if !orphaned.isEmpty {
                let client = StorageBoxClient(config: config)
                try await client.connect()
                for folder in orphaned {
                    await removeShareFiles(folder: folder, config: config, client: client)
                    report.swept.append(folder.isEmpty ? "/" : folder)
                }
                await client.disconnect()
            }
            try await refreshSharedFolders(syncUser: config.username)
            defaults.set(Date().timeIntervalSince1970, forKey: checkDateKey)
            defaults.removeObject(forKey: checkErrorKey)
            defaults.removeObject(forKey: checkFailingSinceKey)
            return report
        } catch {
            if defaults.object(forKey: checkFailingSinceKey) == nil {
                defaults.set(Date().timeIntervalSince1970, forKey: checkFailingSinceKey)
            }
            defaults.set(error.localizedDescription, forKey: checkErrorKey)
            throw error
        }
    }

    // MARK: - Share files on the box

    private static func remoteSharePath(folder: String, config: SpindConfig) -> String {
        var root = config.remoteRoot
        if root.hasSuffix("/") { root = String(root.dropLast()) }
        let dir = folder.isEmpty ? root : root + "/" + folder
        return dir + "/" + ShareWebUI.fileName
    }

    private static func removeShareFiles(
        folder: String, config: SpindConfig, client: StorageBoxClient
    ) async {
        let htmlPath = remoteSharePath(folder: folder, config: config)
        let dir = (htmlPath as NSString).deletingLastPathComponent
        var clean = true
        for path in [htmlPath, dir + "/" + manifestFileName] {
            do { try await client.remove(path) } catch {
                // Already gone is fine; anything else keeps the folder on
                // the list so the next sweep tries again.
                if (try? await client.stat(path)) != nil { clean = false }
            }
        }
        if clean { forgetShareFiles(folder) }
    }

    private static func uploadShareUI(
        folder: String, config: SpindConfig, access: ShareAccess?, expiresOn: Date?
    ) async throws {
        let client = StorageBoxClient(config: config)
        try await client.connect()
        do {
            try await uploadShareFiles(
                folder: folder, config: config, client: client,
                access: access, expiresOn: expiresOn
            )
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private static func uploadShareFiles(
        folder: String, config: SpindConfig, client: StorageBoxClient,
        access: ShareAccess?, expiresOn: Date?
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
            folder: folder, config: config, client: client,
            access: access, expiresOn: expiresOn
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
        rememberShareFiles(folder)
        try await upload(Data(html.utf8), name: ShareWebUI.fileName)
        try await upload(manifest, name: manifestFileName)
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
        let v = 3
        let folder: String
        let generated: Double
        /// Start of the day the share is removed from; absent = until revoked.
        let expires: Double?
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
        access: ShareAccess?, expiresOn: Date?
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
            // The token must not outlive the share it opens.
            shareToken = WopiToken.makeShareToken(
                host: access.host, username: access.username,
                password: access.password, writable: access.writable,
                notAfter: expiresOn
            )
        }
        let manifest = Manifest(
            folder: (folder as NSString).lastPathComponent,
            generated: Date().timeIntervalSince1970,
            expires: expiresOn?.timeIntervalSince1970,
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
            let share = shares.first { $0.description == description }
            try? await uploadShareFiles(
                folder: folder, config: config, client: client,
                access: share.flatMap(access(for:)), expiresOn: share?.expiresOn
            )
        }
        await client.disconnect()
    }

    // MARK: - Local lists in the group container

    private static func groupFile(_ name: String) -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("spind/\(name)")
    }

    private static func readList(_ name: String) -> [String] {
        guard let url = groupFile(name),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    private static func writeList(_ list: [String], _ name: String) {
        guard let url = groupFile(name),
              let data = try? JSONEncoder().encode(Array(Set(list)).sorted())
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadSharedFolderList() -> [String] {
        readList("shared-folders.json")
    }

    /// Folders this Mac has put share files into. Kept apart from the
    /// badge list, which mirrors the API and would forget a folder the
    /// moment its share is gone — exactly when the files still need
    /// removing.
    static func foldersWithShareFiles() -> [String] {
        readList("share-files.json")
    }

    private static func rememberShareFiles(_ folder: String) {
        writeList(foldersWithShareFiles() + [folder], "share-files.json")
    }

    private static func forgetShareFiles(_ folder: String) {
        writeList(foldersWithShareFiles().filter { $0 != folder }, "share-files.json")
    }

    /// Rewrites the shared-folders list in the group container (read by
    /// the extension to badge shared folders) and returns the folder paths.
    @discardableResult
    static func refreshSharedFolders(syncUser: String) async throws -> [String] {
        let folders = try await activeShares(syncUser: syncUser).map { share -> String in
            let path = folderPath(fromDescription: share.description) ?? share.description
            return path == "/" ? "" : path
        }
        writeList(folders, "shared-folders.json")
        return folders.filter { !$0.isEmpty }
    }

    /// Fresh subaccount hostnames take up to ~2 minutes to provision;
    /// blocks until the share page actually answers so users never get a
    /// dead link.
    static func waitUntilReachable(_ result: ShareResult, timeout: TimeInterval = 150) async {
        guard let url = URL(string: result.address) else { return }
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
