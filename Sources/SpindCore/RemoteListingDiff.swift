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

/// Dateinamen in der App-Gruppe, über die App und Extension sich
/// verständigen — beide Seiten müssen denselben meinen.
public enum SpindGroupFile {
    /// „Bitte jetzt beim Server nachsehen": von der App abgelegt, von der
    /// Extension gelesen und gelöscht.
    public static let sweepRequest = "sweep-now"
}

/// Ein Eintrag, so wie er zuletzt auf dem Server gesehen wurde.
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

/// Der Vergleich zweier Ordner-Auflistungen. SFTP kennt keinen
/// Änderungs-Kanal — wer wissen will, was anderswo passiert ist, muss
/// nachsehen und mit dem letzten bekannten Stand vergleichen.
public enum RemoteListingDiff {
    /// - Warning: `current` muss aus einer **erfolgreichen** Auflistung
    ///   stammen. Was hier fehlt, gilt als gelöscht — eine leere Liste nach
    ///   einem Verbindungsfehler würde den ganzen Ordner für gelöscht
    ///   erklären.
    public static func compare(
        previous: [String: RemoteEntry], current: [String: RemoteEntry]
    ) -> RemoteListingChange {
        RemoteListingChange(
            updated: current.compactMap { previous[$0.key] == $0.value ? nil : $0.key }.sorted(),
            deleted: previous.keys.filter { current[$0] == nil }.sorted()
        )
    }
}
