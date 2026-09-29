// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Fetches a server's SSH host key so it can be pinned in the config
/// (trust on first use). Uses the system's ssh-keyscan, which speaks
/// the protocol without authenticating.
public enum HostKey {
    public enum HostKeyError: LocalizedError {
        case scanFailed(String)

        public var errorDescription: String? {
            switch self {
            case .scanFailed(let host):
                return String(localized: "Der Server-Schlüssel von »\(host)« ließ sich nicht abrufen.")
            }
        }
    }

    // MARK: - Trust on first use without ssh-keyscan

    /// The pin that applies to `config`: its own, or — when it carries none —
    /// the one stored in the config file at `store`, provided that file
    /// describes the same server. Another process (app or extension) may
    /// have pinned in the meantime; an in-memory copy does not see that.
    public static func pin(for config: SpindConfig, storedAt store: URL?) -> String? {
        if let own = config.hostPublicKey { return own }
        guard let store, let stored = try? SpindConfig.load(from: store),
              sameServer(stored, config)
        else { return nil }
        return stored.hostPublicKey
    }

    /// Writes `key` as the pin into the config file at `store` — only if
    /// that file describes the same server and carries no pin yet. An
    /// existing pin is never replaced here. Returns true when written.
    @discardableResult
    public static func pinOnFirstUse(
        _ key: String, for config: SpindConfig, storedAt store: URL
    ) throws -> Bool {
        guard var stored = try? SpindConfig.load(from: store),
              sameServer(stored, config), stored.hostPublicKey == nil
        else { return false }
        stored.hostPublicKey = key
        try stored.save(to: store)
        return true
    }

    static func sameServer(_ a: SpindConfig, _ b: SpindConfig) -> Bool {
        a.host.lowercased() == b.host.lowercased() && a.port == b.port
    }

    #if os(macOS)
    /// Returns the key in OpenSSH format ("ssh-ed25519 AAAA…"), preferring
    /// ed25519. Runs off the calling thread.
    public static func scan(host: String, port: Int) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
            process.arguments = ["-p", String(port), "-T", "10", "-t", "ed25519,rsa", host]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .filter { !$0.hasPrefix("#") }
            // "host ssh-ed25519 AAAA…" → keep type and material, drop host.
            let keys = lines.compactMap { line -> String? in
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count >= 3 else { return nil }
                return parts[1] + " " + parts[2]
            }
            guard let key = keys.first(where: { $0.hasPrefix("ssh-ed25519") }) ?? keys.first
            else { throw HostKeyError.scanFailed(host) }
            return key
        }.value
    }
    #endif
}
