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

/// Folders that currently have an active share — written by the app,
/// used to badge them in Finder.
enum SharedFolders {
    static func contains(_ path: String) -> Bool {
        guard !path.isEmpty,
              let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
              )?.appendingPathComponent("spind/shared-folders.json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return false }
        return list.contains(path)
    }
}

/// Paths the user marked "Auf dem Computer behalten". Stored as JSON in
/// the group container so both the extension (content policy, actions)
/// and the app (storage optimizer skip list) can read it.
actor KeepStore {
    static let shared = KeepStore()

    private var cache: Set<String>?

    static var fileURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("spind/keep.json")
    }

    private func load() -> Set<String> {
        if let cache { return cache }
        var result: Set<String> = []
        if let url = Self.fileURL,
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            result = Set(list)
        }
        cache = result
        return result
    }

    private func persist(_ store: Set<String>) {
        cache = store
        guard let url = Self.fileURL else { return }
        if let data = try? JSONEncoder().encode(store.sorted()) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func contains(_ path: String) -> Bool {
        let store = load()
        if store.contains(path) { return true }
        // A kept directory keeps everything below it.
        return store.contains { path.hasPrefix($0 + "/") }
    }

    func add(_ path: String) {
        var store = load()
        store.insert(path)
        persist(store)
    }

    func remove(_ path: String) {
        var store = load()
        store.remove(path)
        persist(store)
    }

    /// Removes a path and every pin below it (freeing a whole folder).
    func removeSubtree(_ path: String) {
        var store = load()
        store.remove(path)
        let prefix = path + "/"
        for entry in store where entry.hasPrefix(prefix) {
            store.remove(entry)
        }
        persist(store)
    }

    func rename(from oldPath: String, to newPath: String) {
        var store = load()
        if store.remove(oldPath) != nil {
            store.insert(newPath)
        }
        persist(store)
    }
}
