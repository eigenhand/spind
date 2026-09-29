// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// A single remote entry as reported by the storage box.
public struct RemoteItem: Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modificationDate: Date?
}

public enum StorageBoxError: LocalizedError, CustomStringConvertible {
    case privateKeyUnreadable(String)
    case notConnected
    case hostKeyMismatch(String)
    /// The stored pin cannot be read — refused rather than trusted blindly.
    case hostKeyPinUnreadable(String)

    public var description: String {
        switch self {
        case .privateKeyUnreadable(let path):
            return String(localized: """
                Der SSH-Schlüssel unter »\(path)« konnte nicht gelesen werden. \
                Prüfe in den Einstellungen, ob der Pfad stimmt und die Datei \
                existiert.
                """)
        case .notConnected:
            return String(localized: "Keine Verbindung zur Storage Box.")
        case .hostKeyMismatch(let host):
            #if os(iOS)
            return String(localized: """
                »\(host)« meldet sich mit einem anderen Server-Schlüssel als \
                beim ersten Mal. Zur Sicherheit wurde nichts übertragen. Das \
                passiert bei einem Serverumzug – oder wenn sich jemand \
                dazwischenschaltet. Wenn du dem Server vertraust, setze die \
                Einrichtung zurück und verbinde dich neu.
                """)
            #else
            return String(localized: """
                »\(host)« meldet sich mit einem anderen Server-Schlüssel als \
                beim ersten Mal. Zur Sicherheit wurde nichts übertragen. Das \
                passiert bei einem Serverumzug – oder wenn sich jemand \
                dazwischenschaltet. Wenn du dem Server vertraust, speichere \
                die Verbindung in den Einstellungen neu.
                """)
            #endif
        case .hostKeyPinUnreadable(let host):
            #if os(iOS)
            return String(localized: """
                Der gespeicherte Server-Schlüssel für »\(host)« ist beschädigt. \
                Zur Sicherheit wurde keine Verbindung aufgebaut. Setze die \
                Einrichtung zurück und verbinde dich neu – am besten per \
                QR-Code vom Mac.
                """)
            #else
            return String(localized: """
                Der gespeicherte Server-Schlüssel für »\(host)« ist beschädigt. \
                Zur Sicherheit wurde keine Verbindung aufgebaut. Speichere die \
                Verbindung in den Einstellungen neu.
                """)
            #endif
        }
    }

    public var errorDescription: String? { description }
}

/// SFTP client for a Hetzner Storage Box, authenticated via ed25519 key.
public final class StorageBoxClient {
    private let config: SpindConfig
    private let pinStore: URL?
    private var ssh: SSHClient?
    private var sftp: SFTPClient?

    /// The host key the server presented on the last successful connect
    /// (OpenSSH format).
    public private(set) var observedHostKey: String?

    /// - Parameter pinStore: the config file that keeps the host key pin.
    ///   When given, trust on first use is done here: a pin stored there
    ///   by another process counts even if `config` predates it, and the
    ///   key seen at the first successful login is written back. Without
    ///   it an unpinned config accepts any key (the Mac pins via
    ///   ssh-keyscan instead).
    public init(config: SpindConfig, pinStore: URL? = nil) {
        self.config = config
        self.pinStore = pinStore
    }

    public func connect() async throws {
        let keyPath = (config.privateKeyPath as NSString).expandingTildeInPath
        guard let keyString = try? String(contentsOfFile: keyPath, encoding: .utf8) else {
            throw StorageBoxError.privateKeyUnreadable(keyPath)
        }
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyString)
        } catch {
            throw StorageBoxError.privateKeyUnreadable(keyPath)
        }

        // Pinned host key (TOFU): seen once, demanded ever after. Without
        // a pin (first contact, older configs) the first contact is
        // accepted and the key it presented recorded.
        let pinned = HostKey.pin(for: config, storedAt: pinStore)
        let recorder = HostKeyRecorder()
        let validator: SSHHostKeyValidator
        if let pinned {
            // A pin that cannot be read fails closed: falling back to
            // "accept anything" would quietly switch the protection off.
            validator = .trustedKeys([try Self.parsePin(pinned, host: config.host)])
        } else {
            validator = .custom(recorder)
        }

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: .ed25519(username: config.username, privateKey: privateKey),
                hostKeyValidator: validator,
                reconnect: .never
            )
        } catch let error where String(describing: error).contains("InvalidHostKey") {
            throw StorageBoxError.hostKeyMismatch(config.host)
        }
        observedHostKey = pinned ?? recorder.key
        // Pinned only now, after the login went through — a server that
        // refuses us leaves no pin behind.
        if pinned == nil, let pinStore, let key = recorder.key {
            try? HostKey.pinOnFirstUse(key, for: config, storedAt: pinStore)
        }
        self.ssh = client
        self.sftp = try await client.openSFTP()
    }

    static func parsePin(_ pin: String, host: String) throws -> NIOSSHPublicKey {
        do {
            return try NIOSSHPublicKey(openSSHPublicKey: pin)
        } catch {
            throw StorageBoxError.hostKeyPinUnreadable(host)
        }
    }

    public func disconnect() async {
        try? await sftp?.close()
        try? await ssh?.close()
        sftp = nil
        ssh = nil
    }

    private func requireSFTP() throws -> SFTPClient {
        guard let sftp else { throw StorageBoxError.notConnected }
        return sftp
    }

    // MARK: - Operations

    public func listDirectory(_ path: String) async throws -> [RemoteItem] {
        let sftp = try requireSFTP()
        let names = try await sftp.listDirectory(atPath: path)
        var items: [RemoteItem] = []
        for name in names {
            for component in name.components {
                let filename = component.filename
                if filename == "." || filename == ".." { continue }
                let attrs = component.attributes
                let isDir = attrs.permissions.map { ($0 & 0o40000) != 0 } ?? false
                items.append(
                    RemoteItem(
                        path: path.hasSuffix("/") ? path + filename : path + "/" + filename,
                        name: filename,
                        isDirectory: isDir,
                        size: attrs.size ?? 0,
                        modificationDate: attrs.accessModificationTime.map(\.modificationTime)
                    )
                )
            }
        }
        return items.sorted { $0.name < $1.name }
    }

    public func makeDirectory(_ path: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.createDirectory(atPath: path)
    }

    private static let transferChunkSize = 512 * 1024

    /// Streams the remote file to disk in chunks; memory use stays flat
    /// regardless of file size. Writes to a temp file first so a dropped
    /// connection never leaves a half-written file at the destination.
    public func download(
        _ remotePath: String,
        to localURL: URL,
        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil
    ) async throws {
        let sftp = try requireSFTP()
        let totalSize = (try? await stat(remotePath).size) ?? 0
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tempURL = localURL.deletingLastPathComponent()
            .appendingPathComponent(".\(localURL.lastPathComponent).\(UUID().uuidString.prefix(8)).spind-tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        do {
            var offset: UInt64 = 0
            while true {
                let buffer = try await file.read(
                    from: offset, length: UInt32(Self.transferChunkSize)
                )
                // Servers may return less than requested per read (often
                // 64-256 KB); only an empty read means end of file.
                if buffer.readableBytes == 0 { break }
                try handle.write(contentsOf: Data(buffer.readableBytesView))
                offset += UInt64(buffer.readableBytes)
                progress?(offset, totalSize)
            }
            try handle.close()
            try? await file.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            try? await file.close()
            throw error
        }
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: localURL)
    }

    /// Streams the local file to the box in chunks read via FileHandle;
    /// never loads the whole file into memory.
    public func upload(
        _ localURL: URL,
        to remotePath: String,
        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil
    ) async throws {
        let sftp = try requireSFTP()
        let totalSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        // Do not write straight into the target file: .truncate empties it
        // immediately, and an interruption (network gone, box full) leaves
        // a broken file behind. Write beside it instead and move it into
        // place on the server at the very end.
        let temporaryPath = remotePath + ".spind-upload-tmp"
        let file = try await sftp.openFile(
            filePath: temporaryPath,
            flags: [.write, .create, .truncate]
        )
        do {
            var offset: UInt64 = 0
            while let chunk = try handle.read(upToCount: Self.transferChunkSize),
                  !chunk.isEmpty {
                try await file.write(ByteBuffer(bytes: chunk), at: offset)
                offset += UInt64(chunk.count)
                progress?(offset, totalSize)
            }
            try await file.close()
            // On the server mv is an atomic rename — either the old or the
            // new version, never half of one.
            try await run("mv -- \(Self.quote(temporaryPath)) \(Self.quote(remotePath))")
        } catch {
            try? await file.close()
            try? await remove(temporaryPath)
            throw error
        }
    }

    public func stat(_ remotePath: String) async throws -> (size: UInt64, modificationDate: Date?, isDirectory: Bool) {
        let sftp = try requireSFTP()
        let attrs = try await sftp.getAttributes(at: remotePath)
        return (
            size: attrs.size ?? 0,
            modificationDate: attrs.accessModificationTime.map(\.modificationTime),
            isDirectory: attrs.permissions.map { ($0 & 0o170000) == 0o40000 } ?? false
        )
    }

    /// Deletes a file, or a directory including all of its contents.
    public func removeRecursively(_ remotePath: String) async throws {
        if try await stat(remotePath).isDirectory {
            for entry in try await listDirectory(remotePath) {
                try await removeRecursively(entry.path)
            }
            try await removeDirectory(remotePath)
        } else {
            try await remove(remotePath)
        }
    }

    public func remove(_ remotePath: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.remove(at: remotePath)
    }

    public func removeDirectory(_ remotePath: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.rmdir(at: remotePath)
    }

    public func rename(_ from: String, to: String) async throws {
        let sftp = try requireSFTP()
        try await sftp.rename(at: from, to: to)
    }

    /// Runs a command in the storage box's restricted shell (ls, cp, mv,
    /// rm, mkdir, stat, md5sum …). Used for server-side copies, which
    /// keep version snapshots free of any data transfer.
    @discardableResult
    public func run(_ command: String) async throws -> String {
        guard let ssh else { throw StorageBoxError.notConnected }
        let buffer = try await ssh.executeCommand(command)
        return String(buffer: buffer)
    }

    /// Quotes a path for the box shell.
    public static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Accepts any host key and remembers it — the first contact of trust
/// on first use. Called once per handshake on the channel's event loop.
private final class HostKeyRecorder: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: String?

    var key: String? {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        lock.lock()
        recorded = String(openSSHPublicKey: hostKey)
        lock.unlock()
        validationCompletePromise.succeed(())
    }
}
