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
                return "Der Server-Schlüssel von »\(host)« ließ sich nicht abrufen."
            }
        }
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
