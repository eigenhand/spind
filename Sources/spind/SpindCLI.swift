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

import ArgumentParser
import Foundation
import SpindCore

/// A sentence for the human at the terminal.
///
/// `bundle: .module`, because the catalogue lies with the target and not in the main
/// bundle. If it is missing — a binary copied somewhere on its own does not have it —
/// the German key stands there. That is not a stopgap but the reason the keys are the
/// German sentences themselves.
func say(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}


@main
struct SpindCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spind",
        abstract: "Sync a local folder with a Hetzner Storage Box",
        subcommands: [
            Setup.self, Check.self, List.self, Sync.self, Watch.self,
            Versions.self, Restore.self, Deleted.self, Enroll.self,
            InstallAgent.self, UninstallAgent.self,
        ]
    )
}

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write the spind configuration")

    @Option(help: "Storage box host, e.g. u123456.your-storagebox.de")
    var host: String

    @Option(help: "Storage box username, e.g. u123456 or u123456-sub1")
    var user: String

    @Option(help: "SSH-Port (Standard: 23 für Storage Boxen, sonst 22)")
    var port: Int?

    @Option(help: "Path to the ed25519 private key")
    var key: String = "~/.ssh/spind_storagebox"

    @Option(help: "Remote directory to sync")
    var remoteRoot: String = "/home/spind"

    @Option(help: "Local directory to sync")
    var localRoot: String = "~/Spind"

    func run() async throws {
        var config = SpindConfig(
            host: host, port: port ?? SpindConfig.defaultPort(forHost: host), username: user,
            privateKeyPath: key, remoteRoot: remoteRoot, localRoot: localRoot
        )
        // Pin the host key (TOFU): from now on any other key is refused.
        //
        config.hostPublicKey = try? await HostKey.scan(host: host, port: config.port)
        if config.hostPublicKey == nil {
            print(say("⚠ Server-Schlüssel nicht abrufbar – wird beim ersten Kontakt angepinnt."))
        }
        try config.save()
        print(say("Konfiguration gespeichert: \(SpindConfig.defaultConfigURL.path)"))
    }
}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Test the connection to the storage box")

    func run() async throws {
        let config = try SpindConfig.load()
        let client = StorageBoxClient(config: config)
        print(say("Verbinde zu \(config.username)@\(config.host):\(config.port) ..."))
        try await client.connect()
        let items = try await client.listDirectory(".")
        print(say("✓ Verbunden. Wurzelverzeichnis enthält \(items.count) Einträge."))
        await client.disconnect()
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List a remote directory"
    )

    @Argument(help: "Remote path")
    var path: String = "."

    func run() async throws {
        let config = try SpindConfig.load()
        let client = StorageBoxClient(config: config)
        try await client.connect()
        let items = try await client.listDirectory(path)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for item in items {
            let type = item.isDirectory ? "d" : "-"
            let date = item.modificationDate.map { formatter.string(from: $0) } ?? "?"
            print("\(type) \(String(format: "%10d", item.size)) \(date)  \(item.name)")
        }
        await client.disconnect()
    }
}

struct Versions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the version history of a file"
    )

    @Argument(help: "Path relative to the sync root, e.g. docs/Bericht.odt")
    var path: String

    func run() async throws {
        let config = try SpindConfig.load()
        let client = StorageBoxClient(config: config)
        try await client.connect()
        let versions = await VersionStore.list(
            relativePath: path, client: client, config: config
        )
        await client.disconnect()
        if versions.isEmpty {
            print(say("Keine früheren Fassungen für \(path)"))
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        for version in versions {
            let size = ByteCountFormatter.string(
                fromByteCount: version.size, countStyle: .file
            )
            print("\(version.id)  \(formatter.string(from: version.date))  \(size)")
        }
    }
}

struct Deleted: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List deleted files that can still be restored from the history"
    )

    func run() async throws {
        let config = try SpindConfig.load()
        let client = StorageBoxClient(config: config)
        try await client.connect()
        let deleted = await VersionStore.listDeleted(client: client, config: config)
        await client.disconnect()
        if deleted.isEmpty {
            print(say("Keine gelöschten Dateien im Verlauf."))
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        for file in deleted {
            let size = ByteCountFormatter.string(
                fromByteCount: file.latest.size, countStyle: .file
            )
            let count = file.versionCount > 1 ? " (\(file.versionCount) Fassungen)" : ""
            print("\(formatter.string(from: file.latest.date))  \(size)\t\(file.relativePath)\(count)")
        }
        print(say("\nWiederherstellen: spind restore <pfad> <fassung> — Fassungen zeigt »spind versions <pfad>«."))
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore a previous version (the current one is kept as a new version)"
    )

    @Argument(help: "Path relative to the sync root")
    var path: String

    @Argument(help: "Version id from »spind versions«")
    var version: String

    func run() async throws {
        let config = try SpindConfig.load()
        let client = StorageBoxClient(config: config)
        try await client.connect()
        defer { Task { await client.disconnect() } }
        let versions = await VersionStore.list(
            relativePath: path, client: client, config: config
        )
        guard let target = versions.first(where: { $0.id == version }) else {
            print(say("Fassung \(version) nicht gefunden"))
            throw ExitCode(1)
        }
        var root = config.remoteRoot
        if root.hasSuffix("/") { root = String(root.dropLast()) }
        let remotePath = root.isEmpty ? path : root + "/" + path
        try await VersionStore.restore(
            version: target, relativePath: path,
            remotePath: remotePath, client: client, config: config
        )
        print(say("✓ \(path) auf Stand \(version) zurückgesetzt"))
    }
}

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run continuously: sync on local changes and poll the remote"
    )

    @Option(help: "Remote poll interval in seconds")
    var interval: Int = 30

    func run() async throws {
        let config = try SpindConfig.load()
        let dbURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/spind/state.sqlite")
        let store = try MetadataStore(databaseURL: dbURL)
        let localRoot = (config.localRoot as NSString).expandingTildeInPath
        try FileManager.default.createDirectory(
            atPath: localRoot, withIntermediateDirectories: true
        )

        // A plain local function here is captured by the event closure,
        // which runs on another thread — an error in the Swift 6 language
        // mode. As a @Sendable value it may cross that boundary.
        let timestamp: @Sendable () -> String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: Date())
        }

        func runOnce() async {
            do {
                let client = StorageBoxClient(config: config)
                try await client.connect()
                let engine = SyncEngine(config: config, client: client, store: store)
                engine.onEvent = { print("[\(timestamp())] \($0)") }
                let actions = try await engine.sync()
                if !actions.isEmpty {
                    print(say("[\(timestamp())] ✓ \(actions.count) Aktionen"))
                }
                await client.disconnect()
            } catch {
                print(say("[\(timestamp())] ✗ Sync-Fehler: \(String(describing: error))"))
            }
        }

        let (events, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1)
        )
        let watcher = FolderWatcher(path: localRoot) { continuation.yield(()) }
        watcher.start()
        let poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                continuation.yield(())
            }
        }
        defer { poller.cancel(); watcher.stop() }

        print(say("[\(timestamp())] spind watch gestartet: \(localRoot) ⇄ \(config.username)@\(config.host)"))
        await runOnce()
        for await _ in events {
            // Debounce: let a burst of file events settle before syncing.
            try? await Task.sleep(for: .seconds(2))
            await runOnce()
        }
    }
}

struct InstallAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-agent",
        abstract: "Install spind watch as a launchd agent (starts at login)"
    )

    @Option(help: "Remote poll interval in seconds")
    var interval: Int = 30

    static let label = "dev.eigenhand.spind.sync"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    func run() async throws {
        // Copy the current binary to a stable location so the agent
        // survives .build being cleaned.
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let binDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let target = binDir.appendingPathComponent("spind")
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [target.path, "watch", "--interval", String(interval)],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logDir.appendingPathComponent("spind.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("spind.log").path,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try FileManager.default.createDirectory(
            at: Self.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: Self.plistURL)

        let uid = getuid()
        _ = shell("launchctl", "bootout", "gui/\(uid)", Self.plistURL.path)
        let result = shell("launchctl", "bootstrap", "gui/\(uid)", Self.plistURL.path)
        if result != 0 {
            print(say("✗ launchctl bootstrap fehlgeschlagen (Code \(result))"))
            throw ExitCode(1)
        }
        print(say("✓ Agent installiert und gestartet (\(Self.label))"))
        print(say("  Binary: \(target.path)"))
        print(say("  Log:    ~/Library/Logs/spind.log"))
    }
}

struct UninstallAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall-agent",
        abstract: "Stop and remove the launchd agent"
    )

    func run() async throws {
        _ = shell("launchctl", "bootout", "gui/\(getuid())", InstallAgent.plistURL.path)
        try? FileManager.default.removeItem(at: InstallAgent.plistURL)
        print(say("✓ Agent entfernt"))
    }
}

@discardableResult
func shell(_ args: String...) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return -1
    }
}

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a bidirectional sync")

    @Flag(help: "Only show what would be done")
    var dryRun = false

    func run() async throws {
        let config = try SpindConfig.load()
        let client = StorageBoxClient(config: config)
        let dbURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/spind/state.sqlite")
        let store = try MetadataStore(databaseURL: dbURL)
        try await client.connect()
        let engine = SyncEngine(config: config, client: client, store: store)
        engine.onEvent = { print($0) }
        let actions = try await engine.sync(dryRun: dryRun)
        if dryRun {
            print(say("Geplante Aktionen: \(actions.count)"))
            for action in actions { print("  \(action)") }
        } else if actions.isEmpty {
            print(say("✓ Alles synchron."))
        } else {
            print(say("✓ Sync abgeschlossen (\(actions.count) Aktionen)."))
        }
        await client.disconnect()
    }
}

struct Enroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add another device's public key to the server's authorized_keys"
    )

    @Argument(help: "Öffentliche Schlüsselzeile, z. B. \"ssh-ed25519 AAAA… iphone\"")
    var publicKey: [String]

    func run() async throws {
        let config = try SpindConfig.load()
        let client = StorageBoxClient(config: config)
        try await client.connect()
        defer { Task { await client.disconnect() } }
        let added = try await DeviceEnrollment.addAuthorizedKey(
            publicKey.joined(separator: " "), client: client
        )
        if added {
            print("✓ Eingetragen. Das Gerät verbindet sich mit: "
                  + "\(config.username)@\(config.host), Port \(config.port).")
        } else {
            print(say("Schlüssel war bereits eingetragen – nichts zu tun."))
        }
    }
}
