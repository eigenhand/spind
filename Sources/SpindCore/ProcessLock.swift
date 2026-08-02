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

/// Exklusive Sperre über eine Datei, damit nie zwei Spind-Prozesse
/// gleichzeitig synchronisieren.
///
/// Ohne sie können Menüleisten-App und `spind watch` (bzw. zwei manuell
/// gestartete Instanzen) aus je eigenen, veralteten Scans planen — die
/// eine lädt hoch, während die andere die alte Fassung herunterlädt.
/// Die Sperre wird vom Betriebssystem gehalten und fällt beim Beenden
/// des Prozesses automatisch weg, auch bei einem Absturz.
public final class ProcessLock {
    private let descriptor: Int32

    /// Gibt nil zurück, wenn bereits ein anderer Prozess die Sperre hält.
    public init?(path: String) {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let info = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = info.withCString { write(descriptor, $0, strlen($0)) }
    }

    public static var defaultPath: String {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/spind/sync.lock").path
        #else
        return NSTemporaryDirectory() + "spind-sync.lock"
        #endif
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
