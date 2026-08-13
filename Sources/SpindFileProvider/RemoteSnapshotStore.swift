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

import CryptoKit
import Foundation
import SpindCore

/// Der zuletzt gesehene Stand eines Ordners auf dem Server.
///
/// SFTP hat keinen Benachrichtigungs-Kanal: Der Server meldet von sich aus
/// nie, dass anderswo etwas gelöscht wurde. Ohne einen gespeicherten
/// Vergleichspunkt kann die Extension auf die Frage „was hat sich geändert?"
/// nur „nichts" antworten — und die Dateien-App zeigt Gelöschtes für immer
/// weiter an. Dieser Speicher ist der Vergleichspunkt.
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

    // MARK: - Ablage in der App-Gruppe

    private static var directoryURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("spind/enum", isDirectory: true)
    }

    /// Pfade taugen nicht als Dateinamen (Schrägstriche, Länge, Groß- und
    /// Kleinschreibung) — der Hash schon.
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
        // Der Zwischenspeicher ist immer der frischere Stand.
        for (path, snapshot) in cache { result[path] = snapshot }
        return Array(result.values)
    }

    // MARK: - Stand merken und vergleichen

    /// Übernimmt einen Stand, ohne ihn als Änderung zu melden — für die
    /// vollständige Auflistung, die selbst der neue Vergleichspunkt ist.
    func record(_ entries: [String: Entry], in directory: String) {
        var snapshot = self.snapshot(for: directory)
            ?? Snapshot(path: directory, anchor: 1, lastSeen: 0, entries: [:])
        if snapshot.entries != entries { snapshot.anchor += 1 }
        snapshot.entries = entries
        snapshot.lastSeen = Date().timeIntervalSince1970
        persist(snapshot)
    }

    /// Vergleicht eine frische Auflistung mit dem gemerkten Stand und
    /// übernimmt sie. Nur mit einer **erfolgreichen** Auflistung aufrufen:
    /// Was hier fehlt, gilt als gelöscht.
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

        // Ein verschwundener Ordner nimmt die Stände darunter mit, sonst
        // meldet ein späterer Durchlauf dessen Inhalt noch einmal.
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

    /// Ordner, die die Dateien-App schon einmal gesehen hat — nur die
    /// müssen nachgeprüft werden. Am längsten nicht geprüfte zuerst, damit
    /// bei begrenzter Zeit reihum jeder drankommt statt immer dieselben.
    func directoriesToRecheck(limit: Int = 25) -> [String] {
        allSnapshots()
            .sorted { $0.lastSeen < $1.lastSeen }
            .prefix(limit)
            .map(\.path)
    }

    /// Bremse für den Nachprüf-Durchlauf: Der Arbeitssatz wird oft
    /// abgefragt, der Server soll davon nichts merken.
    /// - Parameter force: Die App hat ausdrücklich um eine Nachschau
    ///   gebeten (geöffnete App, Knopf) — dann zählt nur, dass nicht schon
    ///   ein Durchlauf läuft.
    func beginSweep(minimumInterval: Double, force: Bool) -> Bool {
        // Zwei Durchläufe gleichzeitig wären doppelte Serverlast und
        // doppelte Meldungen — bei kurzem Takt sonst der Normalfall.
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
