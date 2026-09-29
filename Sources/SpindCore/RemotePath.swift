// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

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
