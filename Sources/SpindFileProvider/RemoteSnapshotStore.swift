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

import CryptoKit
import Foundation
import SpindCore

/// The state of a folder as it was last seen on the server.
///
/// SFTP has no notification channel: the server never says by itself
/// that something was deleted elsewhere. Without a stored reference
/// point the extension can only answer "nothing" to the question "what
/// changed?" — and the Files app goes on showing deleted items forever.
/// This store is that reference point.
actor RemoteSnapshotStore {
    static let shared = RemoteSnapshotStore()

    typealias Entry = RemoteEntry

    struct Change {
        var updated: [String] = []
        var deleted: [String] = []
        var anchor: Int = 1
    }

    private struct Snapshot: Codable {
        var path: String
        var anchor: Int
        var lastSeen: Double
        var entries: [String: Entry]
    }

    private var cache: [String: Snapshot] = [:]
    private var lastSweep: Double = 0
    private var sweeping = false

    // MARK: - Storage in the app group

    private static var directoryURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("spind/enum", isDirectory: true)
    }

    /// Paths make poor filenames (slashes, length, upper and lower case) —
    /// the hash does not.
    private static func fileURL(for path: String) -> URL? {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directoryURL?.appendingPathComponent(digest + ".json")
    }

    private func snapshot(for path: String) -> Snapshot? {
        if let cached = cache[path] { return cached }
        guard let url = Self.fileURL(for: path),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        cache[path] = snapshot
        return snapshot
    }

    private func persist(_ snapshot: Snapshot) {
        cache[snapshot.path] = snapshot
        guard let dir = Self.directoryURL,
              let url = Self.fileURL(for: snapshot.path) else { return }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func allSnapshots() -> [Snapshot] {
        guard let dir = Self.directoryURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
              )
        else { return Array(cache.values) }
        var result: [String: Snapshot] = [:]
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                result[snapshot.path] = snapshot
            }
        }
        // The cache always holds the fresher state.
        for (path, snapshot) in cache { result[path] = snapshot }
        return Array(result.values)
    }

    // MARK: - Remembering and comparing

    /// Takes over a state without reporting it as a change — for the full
    /// listing, which is itself the new reference point.
    func record(_ entries: [String: Entry], in directory: String) {
        var snapshot = self.snapshot(for: directory)
            ?? Snapshot(path: directory, anchor: 1, lastSeen: 0, entries: [:])
        if snapshot.entries != entries { snapshot.anchor += 1 }
        snapshot.entries = entries
        snapshot.lastSeen = Date().timeIntervalSince1970
        persist(snapshot)
    }

    /// Compares a fresh listing against the remembered state and adopts
    /// it. Only call this with a **successful** listing: whatever is
    /// missing here counts as deleted.
    func diff(_ entries: [String: Entry], in directory: String) -> Change {
        let previous = snapshot(for: directory)
        let old = previous?.entries ?? [:]
        let comparison = RemoteListingDiff.compare(previous: old, current: entries)
        var change = Change(
            updated: comparison.updated, deleted: comparison.deleted,
            anchor: previous?.anchor ?? 1
        )
        if !comparison.isEmpty { change.anchor += 1 }

        var snapshot = previous
            ?? Snapshot(path: directory, anchor: change.anchor, lastSeen: 0, entries: [:])
        snapshot.anchor = change.anchor
        snapshot.entries = entries
        snapshot.lastSeen = Date().timeIntervalSince1970
        persist(snapshot)

        // A folder that vanished takes the states below it along, or a
        // later round would report its content all over again.
        for path in change.deleted where old[path]?.isDirectory == true {
            forgetSubtree(path)
        }
        return change
    }

    func anchor(for directory: String) -> Int {
        snapshot(for: directory)?.anchor ?? 1
    }

    func forgetSubtree(_ path: String) {
        guard !path.isEmpty else { return }
        let prefix = path + "/"
        for snapshot in allSnapshots()
        where snapshot.path == path || snapshot.path.hasPrefix(prefix) {
            cache.removeValue(forKey: snapshot.path)
            if let url = Self.fileURL(for: snapshot.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Folders the Files app has seen at least once — only those need
    /// checking. Longest unchecked first, so that with limited time
    /// everyone gets a turn instead of always the same ones.
    func directoriesToRecheck(limit: Int = 25) -> [String] {
        allSnapshots()
            .sorted { $0.lastSeen < $1.lastSeen }
            .prefix(limit)
            .map(\.path)
    }

    /// The throttle for the re-check round: the working set is queried
    /// often, and the server should not notice.
    /// - Parameter force: the app asked for a look explicitly (open app,
    ///   button) — then all that counts is that no round is already
    ///   running.
    func beginSweep(minimumInterval: Double, force: Bool) -> Bool {
        // Two rounds at once would be double the server load and double
        // the reports — at a short interval otherwise the normal case.
        guard !sweeping else { return false }
        let now = Date().timeIntervalSince1970
        guard force || now - lastSweep >= minimumInterval else { return false }
        lastSweep = now
        sweeping = true
        return true
    }

    func endSweep() {
        sweeping = false
    }

    static func entries(for items: [FileProviderItem]) -> [String: Entry] {
        var result: [String: Entry] = [:]
        for item in items {
            result[item.relativePath] = Entry(
                isDirectory: item.isDirectory,
                size: item.size,
                modified: item.modificationDate?.timeIntervalSince1970 ?? 0
            )
        }
        return result
    }
}
