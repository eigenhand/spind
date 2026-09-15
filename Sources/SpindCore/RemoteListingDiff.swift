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

/// Names of files in the app group that the app and the extension use
/// to talk to each other — both sides must mean the same one.
public enum SpindGroupFile {
    /// "Please look at the server now": written by the app, read and
    /// deleted by the extension.
    public static let sweepRequest = "sweep-now"
}

/// An entry as it was last seen on the server.
public struct RemoteEntry: Codable, Equatable, Sendable {
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Double

    public init(isDirectory: Bool, size: Int64, modified: Double) {
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

public struct RemoteListingChange: Equatable, Sendable {
    public var updated: [String]
    public var deleted: [String]

    public var isEmpty: Bool { updated.isEmpty && deleted.isEmpty }
}

/// The comparison of two directory listings. SFTP has no channel for
/// changes — whoever wants to know what happened elsewhere has to look
/// and compare against the last known state.
public enum RemoteListingDiff {
    /// - Warning: `current` must come from a **successful** listing.
    ///   Whatever is missing here counts as deleted — an empty list after
    ///   a connection error would declare the whole folder gone.
    public static func compare(
        previous: [String: RemoteEntry], current: [String: RemoteEntry]
    ) -> RemoteListingChange {
        RemoteListingChange(
            updated: current.compactMap { previous[$0.key] == $0.value ? nil : $0.key }.sorted(),
            deleted: previous.keys.filter { current[$0] == nil }.sorted()
        )
    }
}
