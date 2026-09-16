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

/// Names arrive from the server, and the server is not always ours: a
/// shared box carries other people's folders, and Spind talks to any SFTP
/// host. Such a name becomes a local path, and a ".." in it walks straight
/// out of the sync folder — appending "../../evil.txt" to ~/Spind lands in
/// /Users. Everything that comes from a listing passes through here first.
public enum RemotePath {
    public static func isSafe(_ relative: String) -> Bool {
        guard !relative.isEmpty, !relative.contains("\0") else { return false }
        // Only a whole component counts: "..foo" and "file..txt" are
        // ordinary names and must keep working.
        return !relative.split(separator: "/", omittingEmptySubsequences: true)
            .contains("..")
    }
}
