// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Delta transfers via rsync — the storage box speaks rsync natively, and
/// its rolling checksum moves only changed blocks over the wire (both
/// directions). Verified against openrsync on macOS: an 8 MB file with a
/// 100 KB change transfers ~116 KB up / ~64 KB down.
public struct RsyncStats: Sendable {
    public let sent: Int64
    public let received: Int64
}

public enum RsyncTransfer {
    public enum RsyncError: Error, CustomStringConvertible {
        case unavailable
        case failed(Int32, String)

        public var description: String {
            switch self {
            case .unavailable: return "rsync nicht gefunden"
            case .failed(let code, let message): return "rsync exit \(code): \(message)"
            }
        }
    }

    #if os(macOS)
    /// Deliberately ONLY the system rsync (openrsync): Homebrew rsync
    /// ≥ 3.2.4 quotes arguments itself — the shell quotes openrsync needs
    /// would become part of the filename there, and every transfer would
    /// land in "'name'" instead of "name".
    public static let binaryPath: String? = ["/usr/bin/rsync"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    #else
    /// iOS apps cannot spawn processes — transfers fall back to streaming
    /// SFTP there.
    public static let binaryPath: String? = nil
    #endif

    public static var isAvailable: Bool { binaryPath != nil }

    @discardableResult
    public static func transfer(
        upload: Bool, localPath: String, remotePath: String, config: SpindConfig
    ) async throws -> RsyncStats {
        #if !os(macOS)
        throw RsyncError.unavailable
        #else
        guard let binary = binaryPath else { throw RsyncError.unavailable }
        let key = (config.privateKeyPath as NSString).expandingTildeInPath
        var ssh = "ssh -p \(config.port) -i \(key) -o IdentitiesOnly=yes "
            + "-o BatchMode=yes"
        // Demand the same pinned host key as the SFTP client — otherwise
        // rsync would be the weakest link.
        var hostsFile: URL?
        if let pinned = config.hostPublicKey {
            let entry = config.port == 22
                ? "\(config.host) \(pinned)\n"
                : "[\(config.host)]:\(config.port) \(pinned)\n"
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("spind-known-host-\(UUID().uuidString.prefix(8))")
            try Data(entry.utf8).write(to: file)
            hostsFile = file
            ssh += " -o UserKnownHostsFile=\(file.path)"
                + " -o StrictHostKeyChecking=yes"
        } else {
            ssh += " -o StrictHostKeyChecking=accept-new"
        }
        defer { hostsFile.map { try? FileManager.default.removeItem(at: $0) } }
        // The remote side runs through a shell — single-quote the path.
        let quoted = "'" + remotePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let remoteSpec = "\(config.username)@\(config.host):\(quoted)"
        let arguments = upload
            ? ["-t", "-v", "-e", ssh, localPath, remoteSpec]
            : ["-t", "-v", "-e", ssh, remoteSpec, localPath]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            let error = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            ) ?? ""
            throw RsyncError.failed(
                process.terminationStatus,
                String(error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            )
        }

        // "sent 115811 bytes  received 17424 bytes  …"
        func number(after label: String) -> Int64 {
            guard let range = output.range(of: "\(label) ") else { return 0 }
            let tail = output[range.upperBound...]
            return Int64(tail.prefix { $0.isNumber }) ?? 0
        }
        return RsyncStats(sent: number(after: "sent"), received: number(after: "received"))
        #endif
    }
}
