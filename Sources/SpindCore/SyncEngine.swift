// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation

public extension String {
    /// Canonical NFC form used as sync key. macOS stores filenames as NFD
    /// ("ä" = a + combining diaeresis), most servers/clients use NFC —
    /// comparing raw strings would treat them as different files.
    var canonicalPathKey: String { precomposedStringWithCanonicalMapping }
}

public enum SyncError: LocalizedError, CustomStringConvertible {
    case localRootUnusable(String)
    case localRootMissing(String)
    case localScanFailed(String)
    case pathOutsideRoot(String)
    case emptyLocalScan(Int)
    case emptyRemoteScan(Int)
    case tooManyDeletions(Int, Int)

    public var description: String {
        switch self {
        case .localRootUnusable(let path):
            return "Der Sync-Ordner »\(path)« ist kein benutzbares Verzeichnis."
        case .localRootMissing(let path):
            return """
                Der Sync-Ordner »\(path)« ist nicht mehr an seinem Platz. Zur \
                Sicherheit wurde nichts übertragen und nichts gelöscht. Verschiebe \
                ihn genau dorthin zurück – er wird absichtlich nicht neu angelegt, \
                damit das Zurückschieben an der richtigen Stelle landet. Alternativ \
                wählst du in den Einstellungen einen anderen Ordner.
                """
        case .localScanFailed(let message):
            return "Der Sync-Ordner konnte nicht vollständig gelesen werden: \(message)"
        case .pathOutsideRoot(let path):
            return "Unerwarteter Pfad außerhalb des Sync-Ordners: \(path)"
        case .emptyLocalScan(let known):
            return """
                Der Sync-Ordner ist leer, obwohl \(known) Dateien erwartet wurden. \
                Zur Sicherheit wurde nichts gelöscht – prüfe, ob der Ordner noch am \
                richtigen Ort liegt.
                """
        case .emptyRemoteScan(let known):
            return """
                Auf der Storage Box wurde nichts gefunden, obwohl \(known) Dateien \
                erwartet wurden. Zur Sicherheit wurde lokal nichts gelöscht – prüfe \
                Verbindung und Remote-Verzeichnis.
                """
        case .tooManyDeletions(let count, let known):
            return """
                \(count) von \(known) Dateien würden gelöscht. Das sieht nach einem \
                Versehen aus, deshalb wurde nichts unternommen. Ist es beabsichtigt, \
                bestätige es unten mit einem Klick.
                """
        }
    }

    /// Without this the interface shows "(SpindCore.SyncError error 3.)".
    public var errorDescription: String? { description }
}

public struct LocalItem: Sendable {
    public let relativePath: String
    public let isDirectory: Bool
    public let size: Int64
    public let modTime: Double
}

public enum SyncAction: Sendable {
    case upload(String)
    case download(String)
    case deleteLocal(String)
    case deleteRemote(String)
    case createLocalDir(String)
    case createRemoteDir(String)
    case moveRemote(from: String, to: String)
    case moveLocal(from: String, to: String)
    case conflict(String)
}

public enum TransferDirection: Sendable {
    case upload
    case download
}

/// Bidirectional three-way sync between a local folder and the storage box.
///
/// The metadata store holds the state of every path at the last successful
/// sync ("base"). Comparing base vs. current local and current remote state
/// tells us which side changed, so we can distinguish "new file" from
/// "deleted on the other side" and detect true conflicts.
public final class SyncEngine {
    private let config: SpindConfig
    private let client: StorageBoxClient
    private let store: MetadataStore
    private let ignoredNames: Set<String> = [".DS_Store", ".spind"]
    private let excludedPaths: [String]
    public var onEvent: (@Sendable (String) -> Void)?
    /// Fires while a file transfer is running: (path key, direction, bytes done, bytes total)
    public var onProgress: (@Sendable (String, TransferDirection, UInt64, UInt64) -> Void)?
    /// Fires after an action completed successfully.
    public var onAction: (@Sendable (SyncAction) -> Void)?

    public init(config: SpindConfig, client: StorageBoxClient, store: MetadataStore) {
        self.config = config
        self.client = client
        self.store = store
        var excluded = config.excludedPaths.map(\.canonicalPathKey)
        #if os(macOS)
        // Syncing the whole home directory must never touch system data —
        // Library contains the File Provider replica itself (recursion!).
        let localRoot = (config.localRoot as NSString).expandingTildeInPath
        if localRoot == FileManager.default.homeDirectoryForCurrentUser.path {
            excluded += ["Library", "Applications"]
        }
        #endif
        self.excludedPaths = excluded
    }

    private func isExcluded(_ key: String) -> Bool {
        excludedPaths.contains { key == $0 || key.hasPrefix($0 + "/") }
    }

    /// Files at least this big that exist on both sides go through rsync,
    /// which transfers only changed blocks.
    private static let deltaThreshold: Int64 = 4 << 20

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var localRoot: URL {
        URL(fileURLWithPath: (config.localRoot as NSString).expandingTildeInPath)
    }

    private func emit(_ message: String) { onEvent?(message) }

    // MARK: - Scanning

    public func scanLocal(createIfMissing: Bool = true) throws -> [String: LocalItem] {
        // Resolve symlinks: the enumerator hands out standardised paths
        // (/tmp → /private/tmp). Without this step the prefix does not
        // match and junk keys appear, which lead to deletions.
        var root = localRoot.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            root = root.resolvingSymlinksInPath().standardizedFileURL
            guard FileManager.default.fileExists(
                atPath: root.path, isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw SyncError.localRootUnusable(localRoot.path)
            }
        } else if !createIfMissing {
            // Dry run: touch nothing, an empty folder is the honest view.
            return [:]
        } else {
            // The folder is gone. Recreating it silently is doubly harmful
            // once a sync has happened: the comparison would see nothing
            // but deletions, and the empty folder stands in the way of the
            // obvious repair — a "mv OldName RightName" then moves the
            // folder *into* it instead of onto its place, and everything
            // ends up one level too deep.
            let known = (try? store.allStates().count) ?? 0
            guard known == 0 else { throw SyncError.localRootMissing(localRoot.path) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        var items: [String: LocalItem] = [:]
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey,
        ]
        var scanFailure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, error in scanFailure = error; return false }
        ) else { throw SyncError.localRootUnusable(root.path) }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            // Skip symlinks: size and modification time describe the link,
            // while the content would come from the target — that leads to
            // silent non-transfers.
            if values.isSymbolicLink == true {
                if values.isDirectory != true { enumerator.skipDescendants() }
                continue
            }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix) else {
                throw SyncError.pathOutsideRoot(full)
            }
            let relative = String(full.dropFirst(prefix.count))
            let name = url.lastPathComponent
            if ignoredNames.contains(name) || name.hasSuffix(".spind-tmp") { continue }
            let key = relative.canonicalPathKey
            if isExcluded(key) {
                if (values.isDirectory ?? false) { enumerator.skipDescendants() }
                continue
            }
            items[key] = LocalItem(
                relativePath: relative,
                isDirectory: values.isDirectory ?? false,
                size: Int64(values.fileSize ?? 0),
                modTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            )
        }
        // The enumerator's error handler ends the walk. Without this check
        // a half list would come back, and everything that was no longer
        // read would look deleted — the comparison would go on to delete it
        // on the server.
        if let scanFailure {
            throw SyncError.localScanFailed(scanFailure.localizedDescription)
        }
        return items
    }

    public func scanRemote() async throws -> [String: RemoteItem] {
        var items: [String: RemoteItem] = [:]
        try await scanRemoteDirectory(config.remoteRoot, into: &items)
        return items
    }

    private func scanRemoteDirectory(_ path: String, into items: inout [String: RemoteItem]) async throws {
        let entries = try await client.listDirectory(path)
        for entry in entries {
            if ignoredNames.contains(entry.name) || entry.name.hasPrefix(".") { continue }
            // Leftovers of aborted uploads are not real files — do not
            // download them, clear them out server-side after a day (a
            // fresh one may belong to an upload that is still running).
            if entry.name.hasSuffix(".spind-upload-tmp") {
                let age = entry.modificationDate.map { Date().timeIntervalSince($0) } ?? 0
                if age > 86_400 {
                    _ = try? await client.run("rm -- \(StorageBoxClient.quote(entry.path))")
                    emit("Aufgeräumt: verwaister Upload-Rest \(entry.name)")
                }
                continue
            }
            let key = relativeRemotePath(entry.path).canonicalPathKey
            guard RemotePath.isSafe(key) else {
                emit("Übersprungen — unsicherer Name vom Server: \(entry.name)")
                continue
            }
            if isExcluded(key) { continue }
            items[key] = entry
            if entry.isDirectory {
                try await scanRemoteDirectory(entry.path, into: &items)
            }
        }
    }

    private func relativeRemotePath(_ absolute: String) -> String {
        let prefix = config.remoteRoot.hasSuffix("/") ? config.remoteRoot : config.remoteRoot + "/"
        return absolute.hasPrefix(prefix) ? String(absolute.dropFirst(prefix.count)) : absolute
    }

    private func absoluteRemotePath(_ relative: String) -> String {
        let prefix = config.remoteRoot.hasSuffix("/") ? config.remoteRoot : config.remoteRoot + "/"
        return prefix + relative
    }

    // MARK: - Planning

    public func plan(
        local: [String: LocalItem],
        remote: [String: RemoteItem],
        base: [String: FileState]
    ) -> [SyncAction] {
        var actions: [SyncAction] = []
        let allPaths = Set(local.keys).union(remote.keys).union(base.keys)
        var consumed = Set<String>()

        // Move detection (files only): a vanished path plus a new path with
        // identical size and mtime is a move — rename on the other side
        // instead of re-transferring the content.
        let locallyAppeared = allPaths.filter {
            local[$0]?.isDirectory == false && base[$0] == nil && remote[$0] == nil
        }
        let locallyVanished = allPaths.filter {
            local[$0] == nil && base[$0]?.isDirectory == false && remote[$0] != nil
        }
        for newPath in locallyAppeared {
            guard let item = local[newPath] else { continue }
            // Compare the filename as well: size and timestamp alone would
            // pair up coincidentally equal files (unpacked archives, cp -p)
            // and rename the wrong one on the box.
            let name = (newPath as NSString).lastPathComponent
            let matches = locallyVanished.filter {
                !consumed.contains($0)
                    && ($0 as NSString).lastPathComponent == name
                    && base[$0]?.localSize == item.size
                    && base[$0]?.localModTime == item.modTime
            }
            if matches.count == 1, let oldPath = matches.first {
                actions.append(.moveRemote(from: oldPath, to: newPath))
                consumed.insert(oldPath)
                consumed.insert(newPath)
            }
        }
        let remotelyAppeared = allPaths.filter {
            remote[$0]?.isDirectory == false && base[$0] == nil && local[$0] == nil
        }
        let remotelyVanished = allPaths.filter {
            remote[$0] == nil && base[$0]?.isDirectory == false && local[$0] != nil
        }
        for newPath in remotelyAppeared {
            guard let item = remote[newPath], !consumed.contains(newPath) else { continue }
            let mtime = item.modificationDate?.timeIntervalSince1970
            let name = (newPath as NSString).lastPathComponent
            let matches = remotelyVanished.filter {
                !consumed.contains($0)
                    && ($0 as NSString).lastPathComponent == name
                    && base[$0]?.remoteSize == Int64(item.size)
                    && base[$0]?.remoteModTime == mtime
            }
            if matches.count == 1, let oldPath = matches.first {
                actions.append(.moveLocal(from: oldPath, to: newPath))
                consumed.insert(oldPath)
                consumed.insert(newPath)
            }
        }

        for path in allPaths {
            if consumed.contains(path) { continue }
            let l = local[path]
            let r = remote[path]
            let b = base[path]

            // Directories: existence is all that matters.
            if l?.isDirectory == true || r?.isDirectory == true {
                switch (l, r, b) {
                case (.some, .none, .none): actions.append(.createRemoteDir(path))
                case (.none, .some, .none): actions.append(.createLocalDir(path))
                case (.some, .none, .some): actions.append(.deleteLocal(path))
                case (.none, .some, .some): actions.append(.deleteRemote(path))
                case (.some, .some, .none):
                    // Both sides have the folder, the base does not know it
                    // yet (first run, root change, lifted exclusion): adopt
                    // it — otherwise the base never learns of it and a later
                    // deletion comes back as a resurrection.
                    try? store.upsert(FileState(
                        path: path, isDirectory: true,
                        lastSyncedAt: Date().timeIntervalSince1970
                    ))
                default: break
                }
                continue
            }

            let localChanged = l.map { item in
                b == nil || item.modTime != b?.localModTime || item.size != b?.localSize
            } ?? false
            let remoteChanged = r.map { item in
                let mtime = item.modificationDate?.timeIntervalSince1970
                return b == nil || mtime != b?.remoteModTime || Int64(item.size) != b?.remoteSize
            } ?? false

            switch (l, r) {
            case (.some(let li), .some(let ri)):
                if b == nil && li.size == Int64(ri.size) {
                    // Never-seen pair with identical size (e.g. first run
                    // over pre-existing data, or an NFC/NFD key change):
                    // adopt as in-sync instead of manufacturing a conflict.
                    try? store.upsert(FileState(
                        path: path, isDirectory: false,
                        localModTime: li.modTime, localSize: li.size,
                        remoteModTime: ri.modificationDate?.timeIntervalSince1970,
                        remoteSize: Int64(ri.size),
                        lastSyncedAt: Date().timeIntervalSince1970
                    ))
                } else if localChanged && remoteChanged {
                    actions.append(.conflict(path))
                } else if localChanged {
                    actions.append(.upload(path))
                } else if remoteChanged {
                    actions.append(.download(path))
                }
            case (.some, .none):
                if b != nil && !localChanged {
                    actions.append(.deleteLocal(path))
                } else {
                    // New local file, or edited locally while deleted remotely:
                    // never throw away data, upload it.
                    actions.append(.upload(path))
                }
            case (.none, .some):
                if b != nil && !remoteChanged {
                    actions.append(.deleteRemote(path))
                } else {
                    actions.append(.download(path))
                }
            case (.none, .none):
                // Gone on both sides, drop stale base entry.
                try? store.delete(path: path)
            }
        }

        return sorted(actions)
    }

    /// Creates shallow-first, deletes deep-first, transfers in between.
    private func sorted(_ actions: [SyncAction]) -> [SyncAction] {
        func depth(_ p: String) -> Int { p.components(separatedBy: "/").count }
        var creates: [SyncAction] = []
        var transfers: [SyncAction] = []
        var deletes: [SyncAction] = []
        for action in actions {
            switch action {
            case .createLocalDir, .createRemoteDir: creates.append(action)
            case .deleteLocal, .deleteRemote: deletes.append(action)
            default: transfers.append(action)
            }
        }
        creates.sort { depth(path(of: $0)) < depth(path(of: $1)) }
        deletes.sort { depth(path(of: $0)) > depth(path(of: $1)) }
        return creates + transfers + deletes
    }

    private func path(of action: SyncAction) -> String {
        switch action {
        case .upload(let p), .download(let p), .deleteLocal(let p), .deleteRemote(let p),
             .createLocalDir(let p), .createRemoteDir(let p), .conflict(let p):
            return p
        case .moveRemote(_, let to), .moveLocal(_, let to):
            return to
        }
    }

    // MARK: - Execution

    /// Allows one unusually large deletion, just this once.
    public var allowBulkDeletions = false

    /// box + remote folder + local folder. If any of them changes, the
    /// stored base state loses its meaning.
    private var scopeFingerprint: String {
        let root = (config.localRoot as NSString).expandingTildeInPath
        return "\(config.host)|\(config.username)|\(config.remoteRoot)|\(root)"
    }

    public func sync(dryRun: Bool = false) async throws -> [SyncAction] {
        // A dry run only reads: it discards no base state and creates no
        // folders — but it does calculate the way the real run would after
        // a change of scope (with an empty base).
        let scopeChanged = dryRun
            ? try store.scopeChanged(fingerprint: scopeFingerprint)
            : try store.resetIfScopeChanged(fingerprint: scopeFingerprint)
        if scopeChanged {
            emit("Ordner oder Zugang geändert – Abgleich beginnt neu, es wird nichts gelöscht.")
        }
        var local = try scanLocal(createIfMissing: !dryRun)
        var remote = try await scanRemote()
        var base = dryRun && scopeChanged ? [:] : try store.allStates()

        // The box distinguishes upper and lower case, APFS usually does
        // not: "Readme.txt" and "readme.txt" would be ONE file locally and
        // would overwrite each other in turn. Such paths are frozen
        // entirely until one side is renamed.
        let collisions = Self.caseCollisions(local: local, remote: remote)
        if !collisions.isEmpty {
            emit("⚠ Nicht übertragen (Namen unterscheiden sich nur in Groß-/"
                 + "Kleinschreibung, bitte eine Seite umbenennen): "
                 + collisions.sorted().joined(separator: ", "))
        }
        // Same path, a folder here and a file there: any transfer would
        // have to delete one form to write the other. That is frozen too,
        // until one side is renamed or removed.
        let typeClashes = Self.typeConflicts(local: local, remote: remote)
        if !typeClashes.isEmpty {
            emit("⚠ Nicht übertragen (hier Ordner, dort Datei – bitte eine "
                 + "Seite umbenennen oder entfernen): "
                 + typeClashes.sorted().joined(separator: ", "))
        }
        let frozen = collisions.union(typeClashes)
        if !frozen.isEmpty {
            let isFrozen: (String) -> Bool = { key in
                frozen.contains(key) || frozen.contains(where: { key.hasPrefix($0 + "/") })
            }
            local = local.filter { !isFrozen($0.key) }
            remote = remote.filter { !isFrozen($0.key) }
            base = base.filter { !isFrozen($0.key) }
        }

        try checkPlausibility(local: local, remote: remote, base: base)
        let actions = plan(local: local, remote: remote, base: base)
        try checkDeletionVolume(actions, known: base.count)

        if dryRun { return actions }

        // One error must not hold up the rest of the list — otherwise the
        // sync stops at the same place forever and downloads that would
        // bring data in never run.
        var failures: [(SyncAction, Error)] = []
        for action in actions {
            do {
                try await apply(action, local: local, remote: remote)
                onAction?(action)
            } catch {
                failures.append((action, error))
                emit("⚠ übersprungen: \(path(of: action)) – \(error)")
            }
        }
        if let first = failures.first, failures.count == actions.count {
            throw first.1
        }
        if !failures.isEmpty {
            emit("\(failures.count) von \(actions.count) Aktionen fehlgeschlagen")
        }
        return actions.filter { action in
            !failures.contains { path(of: $0.0) == path(of: action) }
        }
    }

    /// Paths that differ only in case — locally (APFS, usually
    /// case-insensitive) they would collapse into one. Internal rather
    /// than private so the tests can check them directly.
    static func caseCollisions(
        local: [String: LocalItem], remote: [String: RemoteItem]
    ) -> Set<String> {
        var byFold: [String: Set<String>] = [:]
        for key in Set(local.keys).union(remote.keys) {
            byFold[key.lowercased(), default: []].insert(key)
        }
        return Set(byFold.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// Paths that are a folder on one side and a file on the other.
    /// Internal rather than private so the tests can check them directly.
    static func typeConflicts(
        local: [String: LocalItem], remote: [String: RemoteItem]
    ) -> Set<String> {
        var conflicts: Set<String> = []
        for (key, item) in local {
            if let counterpart = remote[key], counterpart.isDirectory != item.isDirectory {
                conflicts.insert(key)
            }
        }
        return conflicts
    }

    /// Catches the cases where a scan is wrongly empty — a sync folder
    /// that was moved away, or an empty remote listing, would otherwise
    /// delete the other side completely.
    private func checkPlausibility(
        local: [String: LocalItem], remote: [String: RemoteItem], base: [String: FileState]
    ) throws {
        guard !allowBulkDeletions, !base.isEmpty else { return }
        if local.isEmpty && !remote.isEmpty {
            throw SyncError.emptyLocalScan(base.count)
        }
        if remote.isEmpty && !local.isEmpty {
            throw SyncError.emptyRemoteScan(base.count)
        }
    }

    // Internal rather than private so the tests can drive the brake.
    func checkDeletionVolume(_ actions: [SyncAction], known: Int) throws {
        guard !allowBulkDeletions, known > 0 else { return }
        let deletions = actions.filter {
            if case .deleteLocal = $0 { return true }
            if case .deleteRemote = $0 { return true }
            return false
        }.count
        let limit = max(10, known / 5)
        if deletions > limit {
            throw SyncError.tooManyDeletions(deletions, known)
        }
    }

    /// Actions carry canonical NFC keys; the actual on-disk / on-box names
    /// (possibly NFD) are resolved through the scan dictionaries.
    private func apply(
        _ action: SyncAction,
        local: [String: LocalItem],
        remote: [String: RemoteItem]
    ) async throws {
        func resolvedLocalURL(_ key: String) -> URL {
            localRoot.appendingPathComponent(
                local[key]?.relativePath
                    ?? remote[key].map { relativeRemotePath($0.path) }
                    ?? key
            )
        }
        func resolvedRemotePath(_ key: String) -> String {
            remote[key]?.path ?? absoluteRemotePath(local[key]?.relativePath.canonicalPathKey ?? key)
        }
        let now = Date().timeIntervalSince1970
        switch action {
        case .upload(let path):
            emit("↑ \(path)")
            let localURL = resolvedLocalURL(path)
            let remotePath = resolvedRemotePath(path)
            let onProgress = self.onProgress
            let localSize = local[path]?.size ?? 0
            // Preserve what is about to be overwritten (server-side copy).
            if remote[path] != nil {
                // Throws when the snapshot fails — nothing is overwritten
                // then, deliberately.
                try await VersionStore.snapshot(
                    relativePath: path, remotePath: remotePath,
                    client: client, config: config
                )
            }
            var transferred = false
            if RsyncTransfer.isAvailable, remote[path] != nil,
               localSize >= Self.deltaThreshold {
                do {
                    onProgress?(path, .upload, 0, UInt64(localSize))
                    let stats = try await RsyncTransfer.transfer(
                        upload: true, localPath: localURL.path,
                        remotePath: remotePath, config: config
                    )
                    onProgress?(path, .upload, UInt64(localSize), UInt64(localSize))
                    transferred = true
                    emit("Δ \(path): \(formatBytes(stats.sent)) statt \(formatBytes(localSize)) übertragen")
                } catch {
                    emit("Δ-Upload fehlgeschlagen, volle Übertragung: \(error)")
                }
            }
            if !transferred {
                try await client.upload(localURL, to: remotePath) { done, total in
                    onProgress?(path, .upload, done, total)
                }
            }
            let remoteStat = try await client.stat(remotePath)
            let l = local[path]
            try store.upsert(FileState(
                path: path, isDirectory: false,
                localModTime: l?.modTime, localSize: l?.size,
                remoteModTime: remoteStat.modificationDate?.timeIntervalSince1970,
                remoteSize: Int64(remoteStat.size),
                lastSyncedAt: now
            ))

        case .download(let path):
            emit("↓ \(path)")
            let localURL = resolvedLocalURL(path)
            let remotePath = resolvedRemotePath(path)
            let onProgress = self.onProgress
            let remoteSize = remote[path].map { Int64($0.size) } ?? 0
            var transferred = false
            if RsyncTransfer.isAvailable, local[path] != nil,
               remoteSize >= Self.deltaThreshold {
                do {
                    onProgress?(path, .download, 0, UInt64(remoteSize))
                    try FileManager.default.createDirectory(
                        at: localURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let stats = try await RsyncTransfer.transfer(
                        upload: false, localPath: localURL.path,
                        remotePath: remotePath, config: config
                    )
                    onProgress?(path, .download, UInt64(remoteSize), UInt64(remoteSize))
                    transferred = true
                    emit("Δ \(path): \(formatBytes(stats.received)) statt \(formatBytes(remoteSize)) empfangen")
                } catch {
                    emit("Δ-Download fehlgeschlagen, volle Übertragung: \(error)")
                }
            }
            if !transferred {
                try await client.download(remotePath, to: localURL) { done, total in
                    onProgress?(path, .download, done, total)
                }
            }
            let values = try localURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let remoteStat = try await client.stat(remotePath)
            try store.upsert(FileState(
                path: path, isDirectory: false,
                localModTime: values.contentModificationDate?.timeIntervalSince1970,
                localSize: Int64(values.fileSize ?? 0),
                remoteModTime: remoteStat.modificationDate?.timeIntervalSince1970,
                remoteSize: Int64(remoteStat.size),
                lastSyncedAt: now
            ))

        case .deleteLocal(let path):
            emit("✕ lokal: \(path)")
            let url = resolvedLocalURL(path)
            if FileManager.default.fileExists(atPath: url.path) {
                // Trash rather than final: locally there is no version
                // history that could catch a mistake.
                if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
                    try FileManager.default.removeItem(at: url)
                }
            }
            try store.deleteSubtree(path: path)

        case .deleteRemote(let path):
            emit("✕ remote: \(path)")
            let remotePath = resolvedRemotePath(path)
            let isDir = remote[path]?.isDirectory
                ?? (try? store.allStates()[path]?.isDirectory) ?? false
            if isDir != true {
                // Deleted files stay recoverable from the history.
                try await VersionStore.snapshot(
                    relativePath: path, remotePath: remotePath,
                    client: client, config: config
                )
            }
            if isDir == true {
                try? await client.removeDirectory(remotePath)
            } else {
                try await client.remove(remotePath)
            }
            try store.deleteSubtree(path: path)

        case .createLocalDir(let path):
            emit("+ dir lokal: \(path)")
            try FileManager.default.createDirectory(
                at: resolvedLocalURL(path),
                withIntermediateDirectories: true
            )
            try store.upsert(FileState(path: path, isDirectory: true, lastSyncedAt: now))

        case .createRemoteDir(let path):
            emit("+ dir remote: \(path)")
            try await client.makeDirectory(resolvedRemotePath(path))
            try store.upsert(FileState(path: path, isDirectory: true, lastSyncedAt: now))

        case .moveRemote(let from, let to):
            emit("→ remote: \(from) → \(to)")
            let target = absoluteRemotePath(local[to]?.relativePath.canonicalPathKey ?? to)
            try await client.rename(resolvedRemotePath(from), to: target)
            try? store.delete(path: from)
            let remoteStat = try await client.stat(target)
            let l = local[to]
            try store.upsert(FileState(
                path: to, isDirectory: false,
                localModTime: l?.modTime, localSize: l?.size,
                remoteModTime: remoteStat.modificationDate?.timeIntervalSince1970,
                remoteSize: Int64(remoteStat.size),
                lastSyncedAt: now
            ))

        case .moveLocal(let from, let to):
            emit("→ lokal: \(from) → \(to)")
            let targetURL = localRoot.appendingPathComponent(
                remote[to].map { relativeRemotePath($0.path) } ?? to
            )
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let sourceURL = resolvedLocalURL(from)
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.moveItem(at: sourceURL, to: targetURL)
            }
            try? store.delete(path: from)
            let values = try? targetURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            let r = remote[to]
            try store.upsert(FileState(
                path: to, isDirectory: false,
                localModTime: values?.contentModificationDate?.timeIntervalSince1970,
                localSize: (values?.fileSize).map(Int64.init),
                remoteModTime: r?.modificationDate?.timeIntervalSince1970,
                remoteSize: r.map { Int64($0.size) },
                lastSyncedAt: now
            ))

        case .conflict(let path):
            // Keep both versions: local copy is renamed with a conflict
            // suffix and uploaded, the remote version wins the original name.
            emit("⚠ Konflikt: \(path)")
            let url = resolvedLocalURL(path)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let stamp = formatter.string(from: Date())
            let ext = url.pathExtension
            let baseName = url.deletingPathExtension().lastPathComponent
            let conflictName = ext.isEmpty
                ? "\(baseName) (Konflikt \(stamp))"
                : "\(baseName) (Konflikt \(stamp)).\(ext)"
            var conflictURL = url.deletingLastPathComponent()
                .appendingPathComponent(conflictName)
            var attempt = 2
            while FileManager.default.fileExists(atPath: conflictURL.path) {
                let numbered = ext.isEmpty
                    ? "\(baseName) (Konflikt \(stamp)-\(attempt))"
                    : "\(baseName) (Konflikt \(stamp)-\(attempt)).\(ext)"
                conflictURL = url.deletingLastPathComponent().appendingPathComponent(numbered)
                attempt += 1
            }
            try FileManager.default.moveItem(at: url, to: conflictURL)

            let dir = ((local[path]?.relativePath ?? path) as NSString).deletingLastPathComponent
            let conflictRelative = dir.isEmpty ? conflictName : dir + "/" + conflictName
            try await apply(
                .upload(conflictRelative.canonicalPathKey),
                local: try scanLocal(), remote: remote
            )
            try await apply(.download(path), local: [:], remote: remote)
        }
    }
}
