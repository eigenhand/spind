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

/// Device-local storage for synced extended attributes, keyed by relative
/// path. SFTP has no xattr support, but the system requires the provider
/// to acknowledge and reproduce xattrs — otherwise items count as "not
/// fully uploaded" and can never be evicted. Attributes are small
/// (macl/FinderInfo, capped at 32 KiB per item by the system), so a JSON
/// file in the group container is plenty.
actor XattrStore {
    static let shared = XattrStore()

    private var cache: [String: [String: Data]]?

    private var fileURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("spind/xattrs.json")
    }

    private func load() -> [String: [String: Data]] {
        if let cache { return cache }
        var result: [String: [String: Data]] = [:]
        if let url = fileURL,
           let data = try? Data(contentsOf: url),
           let raw = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            for (path, attrs) in raw {
                result[path] = attrs.compactMapValues { Data(base64Encoded: $0) }
            }
        }
        cache = result
        return result
    }

    private func persist(_ store: [String: [String: Data]]) {
        cache = store
        guard let url = fileURL else { return }
        let raw = store.mapValues { $0.mapValues { $0.base64EncodedString() } }
        if let data = try? JSONEncoder().encode(raw) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func attributes(for path: String) -> [String: Data] {
        load()[path] ?? [:]
    }

    func set(_ attributes: [String: Data], for path: String) {
        var store = load()
        if attributes.isEmpty {
            store.removeValue(forKey: path)
        } else {
            store[path] = attributes
        }
        persist(store)
    }

    func rename(from oldPath: String, to newPath: String) {
        var store = load()
        if let attrs = store.removeValue(forKey: oldPath) {
            store[newPath] = attrs
        }
        persist(store)
    }

    func remove(_ path: String) {
        var store = load()
        store.removeValue(forKey: path)
        // Also drop everything below a deleted directory.
        let prefix = path + "/"
        for key in store.keys where key.hasPrefix(prefix) {
            store.removeValue(forKey: key)
        }
        persist(store)
    }
}
