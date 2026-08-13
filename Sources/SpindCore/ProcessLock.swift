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

/// An exclusive lock held on a file, so that two Spind processes never
/// sync at the same time.
///
/// Without it the menu bar app and `spind watch` (or two hand-started
/// instances) plan from their own stale scans — one uploads while the
/// other downloads the older copy. The lock is held by the operating
/// system and is released when the process ends, including a crash.
public final class ProcessLock {
    private let descriptor: Int32

    /// Returns nil when another process already holds the lock.
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
