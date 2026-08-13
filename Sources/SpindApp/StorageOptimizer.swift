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
import FileProvider

/// "Free up space" like a cloud drive: evicts local copies of files in the
/// File Provider volume that haven't been touched for a while. The files
/// stay fully visible in Finder as cloud placeholders and re-download on
/// first access. The system refuses eviction for pinned items ("Keep
/// Downloaded") and for files with unsynced edits — both are silently
/// skipped, which is exactly the safe behavior we want.
struct StorageOptimizer {
    struct Result {
        var evictedCount = 0
        var evictedBytes: UInt64 = 0
        var skippedCount = 0
        var lastError: String?
    }

    /// Dataless placeholder flag in stat.st_flags (SF_DATALESS).
    private static let datalessFlag: UInt32 = 0x4000_0000

    static var domainURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/Spind-Spind")
    }

    static func isDataless(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_flags & datalessFlag) != 0
    }

    /// Evicts all materialized files whose last use is older than the
    /// threshold. Returns what was freed.
    static func freeSpace(olderThanDays days: Int) async -> Result {
        var result = Result()
        let root = domainURL
        guard FileManager.default.fileExists(atPath: root.path),
              let manager = NSFileProviderManager(
                for: NSFileProviderDomain(
                    identifier: NSFileProviderDomainIdentifier("spind"),
                    displayName: "Spind"
                )
              )
        else { return result }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for candidate in candidates(root: root, cutoff: cutoff) {
            do {
                try await evict(
                    NSFileProviderItemIdentifier(candidate.relative), with: manager
                )
                result.evictedCount += 1
                result.evictedBytes += candidate.size
            } catch {
                // Pinned, unsynced edits, or in use — leave it alone.
                result.skippedCount += 1
                result.lastError = "\(candidate.relative): \(error)"
            }
        }
        return result
    }

    /// Collects the candidates for eviction.
    ///
    /// Deliberately synchronous: a directory enumerator must not be read
    /// from an asynchronous context — in Swift 6 that is an error, not
    /// merely a warning.
    private static func candidates(
        root: URL, cutoff: Date
    ) -> [(relative: String, size: UInt64)] {
        let keepList = loadKeepList()
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey,
            .contentAccessDateKey, .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [(relative: String, size: UInt64)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }

            // Already just a placeholder? Nothing to free.
            if isDataless(url.path) { continue }

            let lastUse = max(
                values.contentAccessDate ?? .distantPast,
                values.contentModificationDate ?? .distantPast
            )
            guard lastUse < cutoff else { continue }

            let relative = url.path
                .replacingOccurrences(of: root.path + "/", with: "")
            // "Auf dem Computer behalten" wins, including whole folders.
            if keepList.contains(relative)
                || keepList.contains(where: { relative.hasPrefix($0 + "/") }) {
                continue
            }
            found.append((relative, UInt64(values.fileSize ?? 0)))
        }
        return found
    }

    private static func evict(
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

    /// Paths marked "Auf dem Computer behalten" via the Finder context
    /// menu action (written by the extension into the group container).
    private static func loadKeepList() -> Set<String> {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("spind/keep.json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
