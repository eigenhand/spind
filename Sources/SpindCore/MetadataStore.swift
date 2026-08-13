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
import GRDB

/// Last-synced state of a single path, used as the "base" in three-way sync.
public struct FileState: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "file_state"

    /// Path relative to the sync root, e.g. "docs/notes.txt"
    public var path: String
    public var isDirectory: Bool
    /// Local mtime (unix seconds) as observed at last successful sync
    public var localModTime: Double?
    public var localSize: Int64?
    /// Remote mtime (unix seconds) as observed at last successful sync
    public var remoteModTime: Double?
    public var remoteSize: Int64?
    public var lastSyncedAt: Double

    public init(
        path: String,
        isDirectory: Bool,
        localModTime: Double? = nil,
        localSize: Int64? = nil,
        remoteModTime: Double? = nil,
        remoteSize: Int64? = nil,
        lastSyncedAt: Double
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.localModTime = localModTime
        self.localSize = localSize
        self.remoteModTime = remoteModTime
        self.remoteSize = remoteSize
        self.lastSyncedAt = lastSyncedAt
    }
}

public final class MetadataStore {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v2-scope") { db in
            try db.create(table: "sync_scope", ifNotExists: true) { t in
                t.column("id", .integer).primaryKey()
                t.column("fingerprint", .text).notNull()
            }
        }
        migrator.registerMigration("v1") { db in
            try db.create(table: FileState.databaseTableName) { t in
                t.column("path", .text).primaryKey()
                t.column("isDirectory", .boolean).notNull()
                t.column("localModTime", .double)
                t.column("localSize", .integer)
                t.column("remoteModTime", .double)
                t.column("remoteSize", .integer)
                t.column("lastSyncedAt", .double).notNull()
            }
        }
        try migrator.migrate(dbQueue)
    }

    public func allStates() throws -> [String: FileState] {
        let states = try dbQueue.read { try FileState.fetchAll($0) }
        return Dictionary(uniqueKeysWithValues: states.map { ($0.path, $0) })
    }

    public func upsert(_ state: FileState) throws {
        try dbQueue.write { try state.save($0) }
    }

    public func delete(path: String) throws {
        _ = try dbQueue.write { try FileState.deleteOne($0, key: path) }
    }

    /// Removes a folder and every entry below it. Without this, orphaned
    /// rows stay behind and make the next run delete their counterparts
    /// on the other side.
    public func deleteSubtree(path: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM \(FileState.databaseTableName) WHERE path = ? OR path LIKE ?",
                arguments: [path, path + "/%"]
            )
        }
    }

    /// The base state is valid for exactly one combination of box, remote
    /// root and local root. If any of them changes, the old state is
    /// meaningless — and must **not** be read as "everything was deleted".
    ///
    /// - Returns: true when the state was discarded because of a switch.
    @discardableResult
    public func resetIfScopeChanged(fingerprint: String) throws -> Bool {
        try dbQueue.write { db in
            let stored = try String.fetchOne(
                db, sql: "SELECT fingerprint FROM sync_scope WHERE id = 1"
            )
            guard stored != fingerprint else { return false }
            if stored != nil {
                try db.execute(sql: "DELETE FROM \(FileState.databaseTableName)")
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO sync_scope (id, fingerprint) VALUES (1, ?)",
                arguments: [fingerprint]
            )
            return stored != nil
        }
    }

    /// Read-only variant for dry runs: would the next real run discard
    /// the base state?
    public func scopeChanged(fingerprint: String) throws -> Bool {
        try dbQueue.read { db in
            let stored = try String.fetchOne(
                db, sql: "SELECT fingerprint FROM sync_scope WHERE id = 1"
            )
            return stored != nil && stored != fingerprint
        }
    }
}
