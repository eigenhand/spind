// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Files that grant access to the server — the private key, the account
/// configuration — on the iPhone.
///
/// Readable only after the first unlock since boot, so that the file
/// provider extension can still reach them while the device is locked.
/// And excluded from backups: a key restored onto another device from an
/// iCloud or Finder backup is a copy nobody knows about. After a restore
/// the app starts at setup again instead.
///
/// On the Mac this does nothing; there the files live in the user's home.
public enum ProtectedFile {
    /// Writes atomically and protects the result. An atomic write replaces
    /// the file — and with it any backup exclusion set earlier — so this
    /// has to happen on every write, not once.
    public static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try protect(url)
    }

    /// Protects an existing file; a missing one is not an error.
    public static func protect(_ url: URL) throws {
        #if os(iOS)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
        #endif
    }
}
