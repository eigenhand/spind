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

/// File history on the storage box.
///
/// Before anything overwrites or deletes a remote file, the current
/// version is copied aside into `.spind-versions/<pfad>/<zeitstempel>`.
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
    /// Wie viele Fassungen höchstens je Datei liegen bleiben. Die
    /// tatsächliche Auswahl trifft `VersionRetention` — je älter, desto
    /// grober das Raster.
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
    /// Wirft, wenn die Sicherung fehlschlägt (volle Box, Kontingent
    /// erschöpft) — der Aufrufer darf dann **nicht** überschreiben oder
    /// löschen. Gibt false zurück, wenn es schlicht nichts zu sichern gab.
    @discardableResult
    public static func snapshot(
        relativePath: String, remotePath: String,
        client: StorageBoxClient, config: SpindConfig
    ) async throws -> Bool {
        guard let current = try? await client.stat(remotePath) else { return false }
        // Unverändert? Dann wäre die Kopie ein Zwilling der jüngsten
        // Fassung. Erst die Größe vergleichen (kostet nichts, weil schon
        // bekannt), nur bei Gleichstand den Hash — beides serverseitig,
        // es geht dabei kein Byte über die Leitung.
        if let newest = await list(
            relativePath: relativePath.canonicalPathKey, client: client, config: config
        ).first, newest.size == Int64(current.size),
           let now = try? await checksum(remotePath, client: client),
           let before = try? await checksum(newest.remotePath, client: client),
           now == before {
            return false
        }
        let directory = versionsDirectory(for: relativePath.canonicalPathKey, config: config)
        // Sekundenauflösung reicht nicht: zwei Sicherungen derselben Datei
        // in derselben Sekunde würden einander überschreiben.
        var target = directory + "/" + stamp.string(from: Date())
        if (try? await client.stat(target)) != nil {
            target += "-\(UUID().uuidString.prefix(4))"
        }
        let temporary = target + ".partial"
        try await client.run("mkdir -p -- \(StorageBoxClient.quote(directory))")
        try await client.run(
            "cp -- \(StorageBoxClient.quote(remotePath)) \(StorageBoxClient.quote(temporary))"
        )
        // Erst nach vollständiger Kopie sichtbar machen, damit ein Abbruch
        // keine angerissene Fassung im Verlauf hinterlässt.
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
    /// Funktioniert auch für gelöschte Dateien: dann gibt es nichts zu
    /// sichern, und ein mitgelöschter Elternordner wird neu angelegt.
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

    /// Eine gelöschte Datei, von der noch Fassungen im Verlauf liegen.
    public struct DeletedFile: Sendable, Identifiable {
        public var id: String { relativePath }
        public let relativePath: String
        public let latest: FileVersion
        public let versionCount: Int
    }

    /// Durchsucht den Verlauf nach Dateien, die es live nicht mehr gibt —
    /// die Grundlage für »Gelöschte Dateien wiederherstellen«.
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
            // Fassungen vorhanden — lebt die Datei noch?
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

    /// Prüfsumme einer Datei, gebildet auf dem Server.
    static func checksum(
        _ remotePath: String, client: StorageBoxClient
    ) async throws -> String? {
        let output = try await client.run(
            "sha256sum -- " + StorageBoxClient.quote(remotePath)
        )
        // Ausgabeformat: »<hash>  <dateiname>«
        return output.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    /// Dünnt den Verlauf aus, statt ihn hinten abzuschneiden: heute jede
    /// Fassung, diesen Monat eine pro Tag, dieses Jahr eine pro Woche,
    /// davor eine pro Monat.
    private static func prune(
        relativePath: String, client: StorageBoxClient, config: SpindConfig
    ) async {
        let versions = await list(relativePath: relativePath, client: client, config: config)
        for version in VersionRetention.expendable(versions, now: Date()) {
            try? await client.run("rm -- \(StorageBoxClient.quote(version.remotePath))")
        }
    }
}
