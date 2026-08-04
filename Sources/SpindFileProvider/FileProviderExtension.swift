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

import FileProvider
import SpindCore
import UniformTypeIdentifiers
import os

/// Aus der Info.plist (Build-Einstellung SPIND_APP_GROUP in
/// Config.xcconfig) — damit im Quelltext keine Team-ID klebt.
let appGroupID = (Bundle.main.object(forInfoDictionaryKey: "SpindAppGroup") as? String)
    ?? "dev.eigenhand.spind.group"

private let osLogger = Logger(subsystem: "dev.eigenhand.spind.ext", category: "provider")

func extLog(_ message: String) {
    osLogger.error("\(message, privacy: .public)")
    // Simulator-Logging verliert os_log-Zeilen — zusätzlich in eine Datei
    // schreiben. /tmp des Simulators ist das /tmp des Macs: verlässlich
    // lesbar, ganz ohne Gruppencontainer-Abhängigkeit.
    #if targetEnvironment(simulator)
    let url = URL(fileURLWithPath: "/tmp/spind-ext.log")
    let line = "\(Date())  \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
    #endif
}

/// Replicated file provider extension: the system keeps the local replica,
/// we answer with remote state and transfer contents on demand.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let config: SpindConfig?
    private let pool: StorageBoxConnectionPool?
    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            self.config = try? SpindConfig.load(
                from: container.appendingPathComponent("spind/config.json")
            )
        } else {
            self.config = nil
        }
        self.pool = config.map { StorageBoxConnectionPool(config: $0) }
        super.init()
        extLog("init: config \(config == nil ? "FEHLT" : "geladen"), gruppe=\(appGroupID), container=\(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?.path ?? "NIL")")
    }

    func invalidate() {
        let pool = self.pool
        Task { await pool?.drain() }
    }

    // MARK: - Helpers

    /// Übersetzt Transportfehler in den passenden File-Provider-Fehler.
    /// Vorher wurde pauschal »Server nicht erreichbar« gemeldet — wer einen
    /// kaputten Schlüsselpfad hatte, suchte den Fehler beim Netzwerk.
    private func mapToFileProviderError(_ error: Error) -> Error {
        if error is NSFileProviderError { return error }
        if let boxError = error as? StorageBoxError {
            switch boxError {
            case .privateKeyUnreadable: return NSFileProviderError(.notAuthenticated)
            case .notConnected: return NSFileProviderError(.serverUnreachable)
            // Falscher Server-Schlüssel: bewusst verweigert, nicht „weg".
            case .hostKeyMismatch: return NSFileProviderError(.notAuthenticated)
            }
        }
        let text = String(describing: error).lowercased()
        if text.contains("authent") || text.contains("permission denied") {
            return NSFileProviderError(.notAuthenticated)
        }
        if text.contains("nosuchfile") || text.contains("no such file") {
            return NSFileProviderError(.noSuchItem)
        }
        return NSFileProviderError(.serverUnreachable)
    }

    private func withClient<T>(
        _ body: @escaping @Sendable (StorageBoxClient, SpindConfig) async throws -> T
    ) async throws -> T {
        guard let config, let pool else {
            extLog("withClient: keine Konfiguration")
            throw NSFileProviderError(.notAuthenticated)
        }
        do {
            return try await pool.withClient { client in
                try await body(client, config)
            }
        } catch {
            extLog("Operation fehlgeschlagen: \(error)")
            throw error
        }
    }

    /// Touches a marker in the group container after any write through the
    /// Finder volume; the app watches it and syncs the mirror folder
    /// immediately instead of waiting for the next remote poll.
    private func notifyLocalChange() {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("spind/remote-changed") else { return }
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: url, options: .atomic)
    }

    private func remotePath(_ relative: String, _ config: SpindConfig) -> String {
        var root = config.remoteRoot
        if root.hasSuffix("/") { root = String(root.dropLast()) }
        return relative.isEmpty ? root : root + "/" + relative
    }

    fileprivate func loadItem(_ relative: String) async throws -> FileProviderItem {
        try await withClient { client, config in
            let stat = try await client.stat(self.remotePath(relative, config))
            return FileProviderItem(
                relativePath: relative,
                isDirectory: stat.isDirectory,
                size: Int64(stat.size),
                modificationDate: stat.modificationDate,
                xattrs: await XattrStore.shared.attributes(for: relative),
                keepDownloaded: await KeepStore.shared.contains(relative)
            )
        }
    }

    fileprivate func listItems(_ directoryRelative: String) async throws -> [FileProviderItem] {
        try await withClient { client, config in
            let entries = try await client.listDirectory(
                self.remotePath(directoryRelative, config)
            )
            var items: [FileProviderItem] = []
            for entry in entries where !entry.name.hasPrefix(".") {
                let relative = directoryRelative.isEmpty
                    ? entry.name
                    : directoryRelative + "/" + entry.name
                items.append(FileProviderItem(
                    relativePath: relative,
                    isDirectory: entry.isDirectory,
                    size: Int64(entry.size),
                    modificationDate: entry.modificationDate,
                    xattrs: await XattrStore.shared.attributes(for: relative),
                    keepDownloaded: await KeepStore.shared.contains(relative)
                ))
            }
            return items
        }
    }

    // MARK: - NSFileProviderReplicatedExtension

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if identifier == .rootContainer {
            completionHandler(FileProviderItem.root(), nil)
            progress.completedUnitCount = 1
            return progress
        }
        if identifier == .trashContainer || identifier == .workingSet {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        let relative = FileProviderItem.relativePath(for: identifier)
        Task {
            do {
                let item = try await self.withClient { client, config in
                    let stat = try await client.stat(self.remotePath(relative, config))
                    return FileProviderItem(
                        relativePath: relative,
                        isDirectory: stat.isDirectory,
                        size: Int64(stat.size),
                        modificationDate: stat.modificationDate,
                        xattrs: await XattrStore.shared.attributes(for: relative),
                        keepDownloaded: await KeepStore.shared.contains(relative)
                    )
                }
                completionHandler(item, nil)
            } catch {
                completionHandler(nil, NSFileProviderError(.noSuchItem))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let relative = FileProviderItem.relativePath(for: itemIdentifier)
        Task {
            do {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                let item = try await self.withClient { client, config in
                    let remote = self.remotePath(relative, config)
                    try await client.download(remote, to: tempURL)
                    let stat = try await client.stat(remote)
                    return FileProviderItem(
                        relativePath: relative,
                        isDirectory: false,
                        size: Int64(stat.size),
                        modificationDate: stat.modificationDate,
                        xattrs: await XattrStore.shared.attributes(for: relative),
                        keepDownloaded: await KeepStore.shared.contains(relative)
                    )
                }
                completionHandler(tempURL, item, nil)
            } catch {
                completionHandler(nil, nil, self.mapToFileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let parentRelative = FileProviderItem.relativePath(for: itemTemplate.parentItemIdentifier)
        let newName = itemTemplate.filename.canonicalPathKey
        let relative = parentRelative.isEmpty
            ? newName
            : parentRelative + "/" + newName
        let isFolder = itemTemplate.contentType == .folder
        let templateXattrs = itemTemplate.extendedAttributes ?? [:]
        let mayAlreadyExist = options.contains(.mayAlreadyExist)
        let templateSize = itemTemplate.documentSize.flatMap { $0?.int64Value } ?? 0
        Task {
            do {
                await XattrStore.shared.set(templateXattrs, for: relative)
                let item: FileProviderItem? = try await self.withClient { client, config in
                    let remote = self.remotePath(relative, config)
                    if isFolder {
                        if (try? await client.stat(remote))?.isDirectory != true {
                            try await client.makeDirectory(remote)
                        }
                        return FileProviderItem(
                            relativePath: relative, isDirectory: true,
                            size: 0, modificationDate: Date(),
                            xattrs: templateXattrs
                        )
                    }
                    if let url {
                        try await client.upload(url, to: remote)
                    } else if mayAlreadyExist {
                        // Reimport/reconciliation: the local copy may be a
                        // dataless placeholder. NEVER fabricate content —
                        // adopt what the server has, or drop the item.
                        guard let stat = try? await client.stat(remote),
                              !stat.isDirectory else {
                            return nil
                        }
                        return FileProviderItem(
                            relativePath: relative, isDirectory: false,
                            size: Int64(stat.size),
                            modificationDate: stat.modificationDate,
                            xattrs: templateXattrs
                        )
                    } else if templateSize == 0 {
                        // Genuinely new empty file.
                        let empty = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                        try Data().write(to: empty)
                        try await client.upload(empty, to: remote)
                        try? FileManager.default.removeItem(at: empty)
                    } else {
                        // No contents for a non-empty new file — refuse
                        // instead of writing a truncated version.
                        throw NSFileProviderError(.noSuchItem)
                    }
                    let stat = try await client.stat(remote)
                    return FileProviderItem(
                        relativePath: relative, isDirectory: false,
                        size: Int64(stat.size), modificationDate: stat.modificationDate,
                        xattrs: templateXattrs
                    )
                }
                if item != nil { self.notifyLocalChange() }
                completionHandler(item, [], false, nil)
            } catch {
                completionHandler(nil, [], false, self.mapToFileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let oldRelative = FileProviderItem.relativePath(for: item.itemIdentifier)
        let changedXattrs = changedFields.contains(.extendedAttributes)
            ? (item.extendedAttributes ?? [:]) : nil
        Task {
            do {
                let resultItem = try await self.withClient { client, config in
                    var relative = oldRelative
                    // Rename / move first
                    if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                        let parentRelative = FileProviderItem.relativePath(for: item.parentItemIdentifier)
                        let newName = item.filename.canonicalPathKey
                        let newRelative = parentRelative.isEmpty
                            ? newName
                            : parentRelative + "/" + newName
                        if newRelative != relative {
                            try await client.rename(
                                self.remotePath(relative, config),
                                to: self.remotePath(newRelative, config)
                            )
                            await XattrStore.shared.rename(from: relative, to: newRelative)
                            await KeepStore.shared.rename(from: relative, to: newRelative)
                            relative = newRelative
                        }
                    }
                    // Acknowledge extended attributes (stored device-locally;
                    // required or the system treats the item as never fully
                    // synced and refuses to evict it).
                    if let changedXattrs {
                        var merged = await XattrStore.shared.attributes(for: relative)
                        merged = merged.filter { $0.key.hasPrefix("#") }
                        for (key, value) in changedXattrs { merged[key] = value }
                        await XattrStore.shared.set(merged, for: relative)
                    }
                    // Finder tags survive as a pseudo-attribute.
                    if changedFields.contains(.tagData) {
                        var attrs = await XattrStore.shared.attributes(for: relative)
                        attrs[FileProviderItem.tagDataKey] = (item.tagData ?? nil) ?? Data()
                        await XattrStore.shared.set(attrs, for: relative)
                    }
                    // Then new contents — the previous state goes into the
                    // history first, so a write-through here stays
                    // recoverable even without three-way merging.
                    if changedFields.contains(.contents), let newContents {
                        let target = self.remotePath(relative, config)
                        try await VersionStore.snapshot(
                            relativePath: relative, remotePath: target,
                            client: client, config: config
                        )
                        try await client.upload(newContents, to: target)
                    }
                    let stat = try await client.stat(self.remotePath(relative, config))
                    return FileProviderItem(
                        relativePath: relative,
                        isDirectory: item.contentType == .folder,
                        size: Int64(stat.size),
                        modificationDate: stat.modificationDate,
                        xattrs: await XattrStore.shared.attributes(for: relative),
                        keepDownloaded: await KeepStore.shared.contains(relative)
                    )
                }
                self.notifyLocalChange()
                completionHandler(resultItem, [], false, nil)
            } catch {
                completionHandler(nil, [], false, self.mapToFileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let relative = FileProviderItem.relativePath(for: identifier)
        Task {
            do {
                try await self.withClient { client, config in
                    let target = self.remotePath(relative, config)
                    let stat = try? await client.stat(target)
                    if stat?.isDirectory == true {
                        // Ordner: jede enthaltene Datei einzeln sichern —
                        // sonst ist der komplette Inhalt unwiederbringlich.
                        for file in try await self.collectFiles(client, config, relative) {
                            try? await VersionStore.snapshot(
                                relativePath: file,
                                remotePath: self.remotePath(file, config),
                                client: client, config: config
                            )
                        }
                    } else if stat != nil {
                        try await VersionStore.snapshot(
                            relativePath: relative, remotePath: target,
                            client: client, config: config
                        )
                    }
                    try await client.removeRecursively(target)
                }
                await XattrStore.shared.remove(relative)
                await KeepStore.shared.remove(relative)
                self.notifyLocalChange()
                completionHandler(nil)
            } catch {
                completionHandler(self.mapToFileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer {
            throw NSFileProviderError(.noSuchItem)
        }
        return FileProviderEnumerator(
            container: containerItemIdentifier,
            extension: self
        )
    }
}

// MARK: - Change reporting

/// Items whose metadata changed out-of-band (keep/free policy switches).
/// The working-set enumerator drains this queue so the system applies
/// new content policies immediately.
actor PendingUpdates {
    static let shared = PendingUpdates()
    private(set) var anchor = 1
    private var updated: Set<String> = []
    private var deleted: Set<String> = []

    func enqueue(_ newPaths: [String]) {
        updated.formUnion(newPaths)
        anchor += 1
    }

    func enqueueDeleted(_ newPaths: [String]) {
        deleted.formUnion(newPaths)
        updated.subtract(newPaths)
        anchor += 1
    }

    func drain() -> (updated: Set<String>, deleted: Set<String>, anchor: Int) {
        let result = (updated, deleted, anchor)
        updated = []
        deleted = []
        return result
    }

    func bump() -> Int {
        anchor += 1
        return anchor
    }
}

/// Changes produced by the app's folder-sync engine, handed over through
/// the group container so the Finder volume stays fresh without stale
/// ghosts after remote-side syncs.
func drainAppChangeFeed() -> (updated: [String], deleted: [String]) {
    guard let dir = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupID
    )?.appendingPathComponent("spind") else { return ([], []) }
    func drain(_ name: String) -> [String] {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        try? FileManager.default.removeItem(at: url)
        return list
    }
    return (drain("feed-updated"), drain("feed-deleted"))
}

// MARK: - Finder context menu actions

extension FileProviderExtension: NSFileProviderCustomAction {
    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let manager = NSFileProviderManager(for: domain)
        Task {
            for identifier in itemIdentifiers {
                guard identifier != .rootContainer else {
                    progress.completedUnitCount += 1
                    continue
                }
                let path = FileProviderItem.relativePath(for: identifier)
                // Stale Finder entry (moved/deleted remotely)? Report the
                // deletion so the system cleans it up instead of failing.
                guard let subtree = await self.subtreeFiles(of: path) else {
                    extLog("Eintrag existiert remote nicht mehr – räume auf: \(path)")
                    await KeepStore.shared.removeSubtree(path)
                    await PendingUpdates.shared.enqueueDeleted([path])
                    try? await manager?.signalEnumerator(for: .workingSet)
                    await self.refreshMetadata(around: path, manager: manager)
                    progress.completedUnitCount += 1
                    continue
                }
                switch actionIdentifier.rawValue {
                case "dev.eigenhand.spind.keep":
                    await KeepStore.shared.add(path)
                    extLog("behalten: \(path)")
                    let files = subtree
                    await PendingUpdates.shared.enqueue([path] + files)
                    try? await manager?.signalEnumerator(for: .workingSet)
                    await self.refreshMetadata(around: path, manager: manager)
                    // requestDownloadForItem only schedules "at a system
                    // convenient time" — the app materializes immediately
                    // by reading the placeholders.
                    self.requestMaterialization(files)
                    for filePath in files {
                        await self.requestDownload(
                            FileProviderItem.identifier(for: filePath),
                            path: filePath, manager: manager
                        )
                    }
                case "dev.eigenhand.spind.free":
                    await KeepStore.shared.removeSubtree(path)
                    extLog("freigeben: \(path)")
                    let files = subtree
                    // Tell the system the keep policy is gone BEFORE trying
                    // to evict, or it keeps refusing with -2008.
                    await PendingUpdates.shared.enqueue([path] + files)
                    try? await manager?.signalEnumerator(for: .workingSet)
                    await self.refreshMetadata(around: path, manager: manager)
                    for filePath in files {
                        await self.evictWithRetry(
                            FileProviderItem.identifier(for: filePath),
                            manager: manager
                        )
                    }
                case "dev.eigenhand.spind.share":
                    extLog("teilen: \(path)")
                    self.appendRequestFile("share-request", paths: [path])
                case "dev.eigenhand.spind.edit":
                    extLog("bearbeiten: \(path)")
                    self.appendRequestFile("edit-request", paths: [path])
                case "dev.eigenhand.spind.versions":
                    extLog("versionen: \(path)")
                    self.appendRequestFile("versions-request", paths: [path])
                default:
                    break
                }
                progress.completedUnitCount += 1
            }
            try? await manager?.signalEnumerator(for: .workingSet)
            completionHandler(nil)
        }
        return progress
    }

    /// Appends paths to a request file in the group container; the app
    /// watches the directory and acts on it (materialization, shares, …).
    private func appendRequestFile(_ name: String, paths: [String]) {
        guard !paths.isEmpty,
              let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
              )?.appendingPathComponent("spind/\(name)")
        else { return }
        var pending = (try? JSONDecoder().decode(
            [String].self, from: Data(contentsOf: url)
        )) ?? []
        pending.append(contentsOf: paths)
        if let data = try? JSONEncoder().encode(Array(Set(pending)).sorted()) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func requestMaterialization(_ paths: [String]) {
        appendRequestFile("materialize-request", paths: paths)
    }

    /// The system only picks up policy changes (keep/free) when item
    /// metadata is re-enumerated — signal the parent and, for folders,
    /// the item itself.
    private func refreshMetadata(around path: String, manager: NSFileProviderManager?) async {
        let parent = FileProviderItem.identifier(
            for: (path as NSString).deletingLastPathComponent
        )
        try? await manager?.signalEnumerator(for: parent)
        try? await manager?.signalEnumerator(for: FileProviderItem.identifier(for: path))
    }

    /// All files at or below the given path (remote view). A plain file
    /// returns just itself; folders are walked recursively so actions
    /// apply to their whole contents. Returns nil when the path no longer
    /// exists remotely (stale Finder entry).
    private func subtreeFiles(of path: String) async -> [String]? {
        do {
            return try await withClient { client, config in
                let stat = try await client.stat(self.remotePath(path, config))
                guard stat.isDirectory else { return [path] }
                return try await self.collectFiles(client, config, path)
            }
        } catch {
            if String(describing: error).contains("NO_SUCH_FILE") {
                return nil
            }
            extLog("Teilbaum-Scan fehlgeschlagen für \(path): \(error)")
            return [path]
        }
    }

    private func collectFiles(
        _ client: StorageBoxClient, _ config: SpindConfig, _ directory: String
    ) async throws -> [String] {
        var result: [String] = []
        for entry in try await client.listDirectory(remotePath(directory, config))
        where !entry.name.hasPrefix(".") {
            let relative = directory.isEmpty ? entry.name : directory + "/" + entry.name
            if entry.isDirectory {
                result += try await collectFiles(client, config, relative)
            } else {
                result.append(relative)
            }
        }
        return result
    }

    private func requestDownload(
        _ identifier: NSFileProviderItemIdentifier,
        path: String,
        manager: NSFileProviderManager?
    ) async {
        guard let manager else { return }
        guard #available(macOS 15.0, *) else { return }
        do {
            try await manager.requestDownloadForItem(
                withIdentifier: identifier,
                requestedRange: NSRange(location: NSNotFound, length: 0)
            )
        } catch {
            extLog("Download-Anforderung fehlgeschlagen für \(path): \(error)")
        }
    }

    /// Eviction can fail while the system still processes the policy
    /// update; retry a few times before giving up.
    private func evictWithRetry(
        _ identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager?
    ) async {
        guard let manager else { return }
        for attempt in 1...4 {
            do {
                try await evict(identifier, with: manager)
                return
            } catch {
                if attempt == 4 {
                    extLog("Platz freigeben fehlgeschlagen: \(error)")
                    return
                }
                try? await manager.signalEnumerator(for: .workingSet)
                let parent = FileProviderItem.identifier(
                    for: (FileProviderItem.relativePath(for: identifier) as NSString)
                        .deletingLastPathComponent
                )
                try? await manager.signalEnumerator(for: parent)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func evict(
        _ identifier: NSFileProviderItemIdentifier,
        with manager: NSFileProviderManager
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.evictItem(identifier: identifier) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Enumerator

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private weak var ext: FileProviderExtension?

    init(container: NSFileProviderItemIdentifier, extension ext: FileProviderExtension) {
        self.container = container
        self.ext = ext
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        if container == .workingSet {
            observer.finishEnumerating(upTo: nil)
            return
        }
        let relative = FileProviderItem.relativePath(for: container)
        Task {
            do {
                guard let ext = self.ext else {
                    observer.finishEnumerating(upTo: nil)
                    return
                }
                extLog("enumerateItems: '\(relative)' start")
                let items = try await ext.listItems(relative)
                extLog("enumerateItems: '\(relative)' -> \(items.count) Einträge")
                if !items.isEmpty {
                    observer.didEnumerate(items)
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                extLog("enumerateItems: '\(relative)' Fehler: \(error)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        // No server-side change feed on SFTP — but keep/free policy
        // switches are queued in PendingUpdates and delivered through the
        // working set so the system applies them immediately.
        guard container == .workingSet else {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }
        Task {
            guard let ext = self.ext else {
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }
            let (queueUpdated, queueDeleted, drainedAnchor) = await PendingUpdates.shared.drain()
            let appFeed = drainAppChangeFeed()
            var updatedPaths = queueUpdated.union(appFeed.updated)
            var deletedPaths = queueDeleted.union(appFeed.deleted)
            updatedPaths.subtract(deletedPaths)
            let current = (appFeed.updated.isEmpty && appFeed.deleted.isEmpty)
                ? drainedAnchor
                : await PendingUpdates.shared.bump()
            var items: [FileProviderItem] = []
            for path in updatedPaths {
                if let item = try? await ext.loadItem(path) {
                    items.append(item)
                } else {
                    // Path from the feed no longer exists — treat as gone.
                    deletedPaths.insert(path)
                }
            }
            if !items.isEmpty {
                extLog("Änderungs-Feed: \(items.count) Item(s) aktualisiert")
                observer.didUpdate(items)
            }
            if !deletedPaths.isEmpty {
                extLog("Änderungs-Feed: \(deletedPaths.count) Item(s) entfernt")
                observer.didDeleteItems(
                    withIdentifiers: deletedPaths.map(FileProviderItem.identifier(for:))
                )
            }
            observer.finishEnumeratingChanges(
                upTo: NSFileProviderSyncAnchor(Data("spind-\(current)".utf8)),
                moreComing: false
            )
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            let anchor = await PendingUpdates.shared.anchor
            completionHandler(NSFileProviderSyncAnchor(Data("spind-\(anchor)".utf8)))
        }
    }
}
