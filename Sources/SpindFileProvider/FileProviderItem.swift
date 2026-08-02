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

import FileProvider
import UniformTypeIdentifiers

/// A file provider item backed by a path relative to the remote root.
/// The item identifier IS the relative path ("" is represented by
/// `.rootContainer`), which keeps identifiers stable and human-readable.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let relativePath: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    let xattrs: [String: Data]
    let keepDownloaded: Bool
    let isShared: Bool

    init(
        relativePath: String, isDirectory: Bool, size: Int64,
        modificationDate: Date?, xattrs: [String: Data] = [:],
        keepDownloaded: Bool = false
    ) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.xattrs = xattrs
        self.keepDownloaded = keepDownloaded
        self.isShared = isDirectory && SharedFolders.contains(relativePath)
    }

    static func root() -> FileProviderItem {
        FileProviderItem(relativePath: "", isDirectory: true, size: 0, modificationDate: nil)
    }

    static func identifier(for relativePath: String) -> NSFileProviderItemIdentifier {
        relativePath.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(relativePath)
    }

    static func relativePath(for identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? "" : identifier.rawValue
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        Self.identifier(for: relativePath)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return Self.identifier(for: parent)
    }

    var filename: String {
        relativePath.isEmpty ? "Spind" : (relativePath as NSString).lastPathComponent
    }

    var capabilities: NSFileProviderItemCapabilities {
        if isDirectory {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems,
                    .allowsRenaming, .allowsDeleting, .allowsReparenting]
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming,
                .allowsDeleting, .allowsReparenting, .allowsEvicting]
    }

    /// Files on demand: content may be dropped locally and re-fetched —
    /// unless the user chose "Auf dem Computer behalten".
    var contentPolicy: NSFileProviderContentPolicy {
        keepDownloaded ? .downloadEagerlyAndKeepDownloaded : .downloadLazily
    }

    /// Internal pseudo-attributes (Finder tags etc.) use a "#" prefix and
    /// are not real extended attributes.
    static let tagDataKey = "#dev.eigenhand.spind.tagData"

    var extendedAttributes: [String: Data] {
        xattrs.filter { !$0.key.hasPrefix("#") }
    }

    var tagData: Data? {
        xattrs[Self.tagDataKey].flatMap { $0.isEmpty ? nil : $0 }
    }

    var itemVersion: NSFileProviderItemVersion {
        let content = "\(size)-\(modificationDate?.timeIntervalSince1970 ?? 0)"
        // Metadata version must change when synced xattrs change, otherwise
        // the system keeps the item marked dirty (and non-evictable).
        let xattrDigest = xattrs.keys.sorted().map {
            "\($0):\(xattrs[$0]?.count ?? 0)"
        }.joined(separator: ",")
        // Version salt: any change to this format makes every item's
        // metadata "dirty" (and thus non-evictable) until the system
        // re-imports — when bumping it, ALWAYS bump the reimport flag key
        // in SyncController.setupFileProvider as well.
        return NSFileProviderItemVersion(
            contentVersion: Data(content.utf8),
            metadataVersion: Data("v3|\(relativePath)|\(keepDownloaded ? "k" : "-")\(isShared ? "s" : "-")|\(xattrDigest)".utf8)
        )
    }

    var contentType: UTType {
        if isDirectory { return .folder }
        let ext = (filename as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    var documentSize: NSNumber? {
        isDirectory ? nil : NSNumber(value: size)
    }

    var contentModificationDate: Date? { modificationDate }
}

extension FileProviderItem: NSFileProviderItemDecorating {
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        isShared ? [NSFileProviderItemDecorationIdentifier("dev.eigenhand.spind.shared")] : nil
    }
}
