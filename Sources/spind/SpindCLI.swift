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

import ArgumentParser
import Foundation
import SpindCore

@main
struct SpindCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spind",
        abstract: "Sync a local folder with a Hetzner Storage Box",
        subcommands: [
            Setup.self, Check.self, List.self, Sync.self, Watch.self,
            Versions.self, Restore.self, Deleted.self,
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

    @Option(help: "SSH port")
    var port: Int = 23

    @Option(help: "Path to the ed25519 private key")
    var key: String = "~/.ssh/spind_storagebox"

    @Option(help: "Remote directory to sync")
    var remoteRoot: String = "/home/spind"

    @Option(help: "Local directory to sync")
    var localRoot: String = "~/Spind"

    func run() async throws {
        var config = SpindConfig(
            host: host, port: port, username: user,
            privateKeyPath: key, remoteRoot: remoteRoot, localRoot: localRoot
        )
        // Server-Schlüssel anpinnen (TOFU): ab jetzt wird jeder andere
        // Schlüssel abgewiesen.
        config.hostPublicKey = try? await HostKey.scan(host: host, port: port)
        if config.hostPublicKey == nil {
            print("⚠ Server-Schlüssel nicht abrufbar – wird beim ersten Kontakt angepinnt.")
        }
        try config.save()
        print("Konfiguration gespeichert: \(SpindConfig.defaultConfigURL.path)")
    }
}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Test the connection to the storage box")

    func run() async throws {
        let config = try SpindConfig.load()
        let client = StorageBoxClient(config: config)
        print("Verbinde zu \(config.username)@\(config.host):\(config.port) ...")
        try await client.connect()
        let items = try await client.listDirectory(".")
        print("✓ Verbunden. Wurzelverzeichnis enthält \(items.count) Einträge.")
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
            print("Keine früheren Fassungen für \(path)")
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
            print("Keine gelöschten Dateien im Verlauf.")
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
        print("\nWiederherstellen: spind restore <pfad> <fassung> — Fassungen zeigt »spind versions <pfad>«.")
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
            print("Fassung \(version) nicht gefunden")
            throw ExitCode(1)
        }
        var root = config.remoteRoot
        if root.hasSuffix("/") { root = String(root.dropLast()) }
        let remotePath = root.isEmpty ? path : root + "/" + path
        try await VersionStore.restore(
            version: target, relativePath: path,
            remotePath: remotePath, client: client, config: config
        )
        print("✓ \(path) auf Stand \(version) zurückgesetzt")
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

        func timestamp() -> String {
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
                    print("[\(timestamp())] ✓ \(actions.count) Aktionen")
                }
                await client.disconnect()
            } catch {
                print("[\(timestamp())] ✗ Sync-Fehler: \(error)")
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

        print("[\(timestamp())] spind watch gestartet: \(localRoot) ⇄ \(config.username)@\(config.host)")
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
            print("✗ launchctl bootstrap fehlgeschlagen (Code \(result))")
            throw ExitCode(1)
        }
        print("✓ Agent installiert und gestartet (\(Self.label))")
        print("  Binary: \(target.path)")
        print("  Log:    ~/Library/Logs/spind.log")
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
        print("✓ Agent entfernt")
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
            print("Geplante Aktionen: \(actions.count)")
            for action in actions { print("  \(action)") }
        } else if actions.isEmpty {
            print("✓ Alles synchron.")
        } else {
            print("✓ Sync abgeschlossen (\(actions.count) Aktionen).")
        }
        await client.disconnect()
    }
}
