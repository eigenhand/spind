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

/// Global configuration for Spind, stored at ~/.config/spind/config.json
public struct SpindConfig: Codable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var privateKeyPath: String
    /// Remote directory on the storage box that is synced (e.g. "/spind")
    public var remoteRoot: String
    /// Local directory that mirrors the remote root
    public var localRoot: String
    /// Folders (relative to the roots) excluded from syncing
    public var excludedPaths: [String]
    /// Pinned server host key (OpenSSH format, e.g. "ssh-ed25519 AAAA…").
    /// Filled on first contact; afterwards a different key aborts the
    /// connection instead of silently talking to a stranger.
    public var hostPublicKey: String?

    public init(
        host: String,
        port: Int = 23,
        username: String,
        privateKeyPath: String,
        remoteRoot: String = "/spind",
        localRoot: String,
        excludedPaths: [String] = [],
        hostPublicKey: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.privateKeyPath = privateKeyPath
        self.remoteRoot = remoteRoot
        self.localRoot = localRoot
        self.excludedPaths = excludedPaths
        self.hostPublicKey = hostPublicKey
    }

    enum CodingKeys: String, CodingKey {
        case host, port, username, privateKeyPath, remoteRoot, localRoot, excludedPaths
        case hostPublicKey
    }

    /// Sync, versions and the Finder volume speak plain SFTP/SSH and
    /// work against any server. Only the shares (subaccounts) and
    /// collaborative editing depend on the Hetzner API — which exists
    /// for storage boxes and nothing else.
    public var isHetznerBox: Bool { host.hasSuffix(".your-storagebox.de") }

    /// Hetzner listens on 23, the rest of the world on 22.
    public static func defaultPort(forHost host: String) -> Int {
        host.hasSuffix(".your-storagebox.de") ? 23 : 22
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        privateKeyPath = try container.decode(String.self, forKey: .privateKeyPath)
        remoteRoot = try container.decode(String.self, forKey: .remoteRoot)
        localRoot = try container.decode(String.self, forKey: .localRoot)
        excludedPaths = try container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        hostPublicKey = try container.decodeIfPresent(String.self, forKey: .hostPublicKey)
    }

    public static var defaultConfigURL: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/spind/config.json")
        #else
        // iOS sandbox: no user home, the app container is the root.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("spind/config.json")
        #endif
    }

    public static func load(from url: URL = defaultConfigURL) throws -> SpindConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SpindConfig.self, from: data)
    }

    public func save(to url: URL = defaultConfigURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
