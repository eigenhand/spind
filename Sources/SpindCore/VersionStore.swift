// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// File history on the storage box.
///
/// Before anything overwrites or deletes a remote file, the current
/// version is copied aside into `.spind-versions/<path>/<timestamp>`.
/// The copy happens server-side (`cp` in the box shell), so a version
/// costs no transfer at all. The folder starts with a dot and is
/// therefore invisible to sync and Finder.
public struct FileVersion: Sendable, Identifiable {
    public let id: String          // timestamp key, e.g. "2026-08-02T14-30-00Z"
    public let date: Date
    public let size: Int64
    public let remotePath: String
}

public enum VersionStore {
    public static let folderName = ".spind-versions"
    /// How many versions are kept per file at most. Which ones survive is
    /// decided by `VersionRetention` — the older, the coarser the grid.
    public static let keepPerFile = VersionRetention.maxPerFile

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func versionsRoot(_ config: SpindConfig) -> String {
        var root = config.remoteRoot
        if root.hasSuffix("/") { root = String(root.dropLast()) }
        return root.isEmpty ? folderName : root + "/" + folderName
    }

    public static func versionsDirectory(for relativePath: String, config: SpindConfig) -> String {
        versionsRoot(config) + "/" + relativePath
    }

    /// Copies the current remote file into the history.
    ///
    /// Throws when the snapshot fails (box full, quota spent) — the
    /// caller must then **not** overwrite or delete. Returns false when
    /// there simply was nothing to preserve.
    @discardableResult
    public static func snapshot(
        relativePath: String, remotePath: String,
        client: StorageBoxClient, config: SpindConfig
    ) async throws -> Bool {
        guard let current = try? await client.stat(remotePath) else { return false }
        // Unchanged? Then the copy would be a twin of the newest version.
        // Compare the size first (free, it is already known) and only on
        // a tie the hash — both computed on the server, so no byte crosses
        // the wire to find out that nothing changed.
        if let newest = await list(
            relativePath: relativePath.canonicalPathKey, client: client, config: config
        ).first, newest.size == Int64(current.size),
           let now = try? await checksum(remotePath, client: client),
           let before = try? await checksum(newest.remotePath, client: client),
           now == before {
            return false
        }
        let directory = versionsDirectory(for: relativePath.canonicalPathKey, config: config)
        // A resolution of seconds is not enough: two snapshots of the same
        // file within one second would overwrite each other.
        var target = directory + "/" + stamp.string(from: Date())
        if (try? await client.stat(target)) != nil {
            target += "-\(UUID().uuidString.prefix(4))"
        }
        let temporary = target + ".partial"
        try await client.run("mkdir -p -- \(StorageBoxClient.quote(directory))")
        try await client.run(
            "cp -- \(StorageBoxClient.quote(remotePath)) \(StorageBoxClient.quote(temporary))"
        )
        // Only make it visible once the copy is complete, so that an
        // interruption leaves no torn version in the history.
        try await client.run(
            "mv -- \(StorageBoxClient.quote(temporary)) \(StorageBoxClient.quote(target))"
        )
        await prune(relativePath: relativePath.canonicalPathKey, client: client, config: config)
        return true
    }

    public static func list(
        relativePath: String, client: StorageBoxClient, config: SpindConfig
    ) async -> [FileVersion] {
        let directory = versionsDirectory(for: relativePath, config: config)
        guard let entries = try? await client.listDirectory(directory) else { return [] }
        return entries
            .filter { !$0.isDirectory }
            .compactMap { entry in
                guard let date = stamp.date(from: entry.name) else { return nil }
                return FileVersion(
                    id: entry.name, date: date,
                    size: Int64(entry.size), remotePath: entry.path
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// Restores a version as the current file — the state being replaced
    /// is preserved as a new version first, so restoring is never lossy.
    /// Works for deleted files too: there is nothing to preserve then,
    /// and a parent folder that went with it is recreated.
    public static func restore(
        version: FileVersion, relativePath: String, remotePath: String,
        client: StorageBoxClient, config: SpindConfig
    ) async throws {
        try await snapshot(
            relativePath: relativePath, remotePath: remotePath,
            client: client, config: config
        )
        let parent = (remotePath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try await client.run("mkdir -p -- \(StorageBoxClient.quote(parent))")
        }
        try await client.run(
            "cp -- \(StorageBoxClient.quote(version.remotePath)) "
            + StorageBoxClient.quote(remotePath)
        )
    }

    /// A deleted file that still has versions in the history.
    public struct DeletedFile: Sendable, Identifiable {
        public var id: String { relativePath }
        public let relativePath: String
        public let latest: FileVersion
        public let versionCount: Int
    }

    /// Searches the history for files that no longer exist live — the
    /// basis for "restore deleted files".
    public static func listDeleted(
        client: StorageBoxClient, config: SpindConfig
    ) async -> [DeletedFile] {
        var liveRoot = config.remoteRoot
        if liveRoot.hasSuffix("/") { liveRoot = String(liveRoot.dropLast()) }
        var result: [DeletedFile] = []
        var queue: [String] = [""]
        while let relative = queue.popLast() {
            let directory = relative.isEmpty
                ? versionsRoot(config)
                : versionsDirectory(for: relative, config: config)
            guard let entries = try? await client.listDirectory(directory) else { continue }
            var versions: [FileVersion] = []
            for entry in entries {
                if entry.isDirectory {
                    queue.append(relative.isEmpty ? entry.name : relative + "/" + entry.name)
                } else if let date = stamp.date(from: String(entry.name.prefix(20))) {
                    versions.append(FileVersion(
                        id: entry.name, date: date,
                        size: Int64(entry.size), remotePath: entry.path
                    ))
                }
            }
            guard !versions.isEmpty, !relative.isEmpty else { continue }
            // Versions exist — is the file still alive?
            let livePath = liveRoot.isEmpty ? relative : liveRoot + "/" + relative
            let live = try? await client.stat(livePath)
            if live == nil || live?.isDirectory == true {
                versions.sort { $0.date > $1.date }
                result.append(DeletedFile(
                    relativePath: relative,
                    latest: versions[0],
                    versionCount: versions.count
                ))
            }
        }
        return result.sorted { $0.latest.date > $1.latest.date }
    }

    /// Checksum of a file, computed on the server.
    static func checksum(
        _ remotePath: String, client: StorageBoxClient
    ) async throws -> String? {
        let output = try await client.run(
            "sha256sum -- " + StorageBoxClient.quote(remotePath)
        )
        // Output format: "<hash>  <filename>"
        return output.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    /// Thins the history out instead of cutting it off at the back: every
    /// version from today, one per day this month, one per week this year,
    /// one per month before that.
    private static func prune(
        relativePath: String, client: StorageBoxClient, config: SpindConfig
    ) async {
        let versions = await list(relativePath: relativePath, client: client, config: config)
        for version in VersionRetention.expendable(versions, now: Date()) {
            _ = try? await client.run("rm -- \(StorageBoxClient.quote(version.remotePath))")
        }
    }
}
