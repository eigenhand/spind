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

import Foundation
import SwiftUI
// NSFileProviderDomain ist nicht als Sendable ausgezeichnet, wandert hier
// aber durch Closures. @preconcurrency sagt: Das Modul stammt aus der Zeit
// vor der strengen Nebenläufigkeit — nicht jede Übergabe ist ein Fehler.
@preconcurrency import FileProvider
import Network
import UserNotifications
import ServiceManagement
import SpindCore

/// Aus der Info.plist (Build-Einstellung SPIND_APP_GROUP in
/// Config.xcconfig) — damit im Quelltext keine Team-ID klebt.
let appGroupID = (Bundle.main.object(forInfoDictionaryKey: "SpindAppGroup") as? String)
    ?? "dev.eigenhand.spind.group"

enum SyncStatus: Equatable {
    case notConfigured
    case idle(lastSync: Date?)
    case syncing
    case paused
    case offline
    case error(String)
}

/// A file transfer currently in flight, rendered with a progress bar.
struct FileTransfer: Identifiable, Equatable {
    let id: String            // path key
    let direction: TransferDirection
    var transferred: UInt64
    var total: UInt64

    var fraction: Double {
        total > 0 ? Double(transferred) / Double(total) : 0
    }

    static func == (lhs: FileTransfer, rhs: FileTransfer) -> Bool {
        lhs.id == rhs.id && lhs.transferred == rhs.transferred && lhs.total == rhs.total
    }
}

/// One row in the activity log.
struct ActivityEntry: Identifiable {
    enum Kind {
        case upload, download, deleteLocal, deleteRemote, folder, move, share, edit, conflict, storage, info

        var symbol: String {
            switch self {
            case .upload: return "arrow.up"
            case .download: return "arrow.down"
            case .deleteLocal, .deleteRemote: return "trash"
            case .folder: return "folder.badge.plus"
            case .move: return "arrow.turn.down.right"
            case .share: return "link"
            case .edit: return "pencil.and.outline"
            case .conflict: return "exclamationmark.triangle"
            case .storage: return "internaldrive"
            case .info: return "info"
            }
        }

        var tint: Color {
            switch self {
            case .upload: return .blue
            case .download: return .green
            case .deleteLocal, .deleteRemote: return .red
            case .folder: return .indigo
            case .move: return .purple
            case .share: return .cyan
            case .edit: return .mint
            case .conflict: return .orange
            case .storage: return .teal
            case .info: return .gray
            }
        }

        var label: String {
            switch self {
            case .upload: return String(localized: "Hochgeladen")
            case .download: return String(localized: "Heruntergeladen")
            case .deleteLocal: return String(localized: "Lokal gelöscht")
            case .deleteRemote: return String(localized: "Auf der Box gelöscht")
            case .folder: return String(localized: "Ordner angelegt")
            case .move: return String(localized: "Verschoben – ohne Neuübertragung")
            case .share: return String(localized: "Freigabe erstellt – Zugang im Clipboard")
            case .edit: return String(localized: "Im Browser geöffnet – Link im Clipboard")
            case .conflict: return String(localized: "Konflikt – beide Versionen behalten")
            case .storage: return String(localized: "Speicher optimiert")
            case .info: return ""
            }
        }
    }

    let id = UUID()
    let date: Date
    let kind: Kind
    let name: String
    let detail: String?
}

@MainActor
final class SyncController: ObservableObject {
    static let shared = SyncController()

    @Published var status: SyncStatus = .idle(lastSync: nil)
    @Published var isOnline = true
    @Published var entries: [ActivityEntry] = []
    @Published var transfers: [FileTransfer] = []
    @Published var isPaused = false
    /// Anzahl der Löschungen, die die Sicherheitsbremse gestoppt hat – die
    /// Oberfläche fragt damit einmalig nach.
    @Published var pendingBulkDeletions: Int?
    private var bulkDeletionConfirmed = false
    /// A second, complete copy of everything in a plain folder. Off by
    /// default: the Finder volume is the point of Spind, and files there
    /// cost space only once they are opened. Whoever wants everything on
    /// this Mac says so — anything else fills the disk unasked, and a
    /// photo library arriving from a phone fills it fast.
    @Published var folderSyncEnabled: Bool = SyncController.storedFolderSync {
        didSet {
            UserDefaults.standard.set(folderSyncEnabled, forKey: "folderSyncEnabled")
            if folderSyncEnabled { syncNow() }
        }
    }

    /// Installations from before this default keep what they had: they
    /// have been mirroring all along, and switching that off behind their
    /// back would quietly stop a folder people rely on.
    private static var storedFolderSync: Bool {
        if let chosen = UserDefaults.standard.object(forKey: "folderSyncEnabled") as? Bool {
            return chosen
        }
        let existingInstall = FileManager.default.fileExists(
            atPath: SpindConfig.defaultConfigURL.path
        )
        UserDefaults.standard.set(existingInstall, forKey: "folderSyncEnabled")
        return existingInstall
    }
    @Published var pollInterval: Int = UserDefaults.standard
        .object(forKey: "pollInterval") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(pollInterval, forKey: "pollInterval") }
    }
    @Published var autoFreeEnabled: Bool = UserDefaults.standard
        .object(forKey: "autoFreeEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(autoFreeEnabled, forKey: "autoFreeEnabled") }
    }
    @Published var autoFreeDays: Int = UserDefaults.standard
        .object(forKey: "autoFreeDays") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(autoFreeDays, forKey: "autoFreeDays") }
    }

    private(set) var config: SpindConfig?
    private var store: MetadataStore?
    private var watcher: FolderWatcher?
    private var continuation: AsyncStream<Void>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    private var optimizerTask: Task<Void, Never>?
    private var groupWatcher: FolderWatcher?
    private var fpManager: NSFileProviderManager?
    private var pathMonitor: NWPathMonitor?
    private var processLock: ProcessLock?
    private var started = false

    init(demo: Bool = false) {
        if demo {
            config = try? SpindConfig.load()
            injectDemoData()
        } else {
            start()
        }
    }

    var localRootURL: URL? {
        config.map { URL(fileURLWithPath: ($0.localRoot as NSString).expandingTildeInPath) }
    }

    var driveURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/Spind-Spind")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var statusText: String {
        switch status {
        case .notConfigured:
            return String(localized: "Nicht konfiguriert")
        case .idle(let last):
            if let last {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                return String(localized: "Synchron – Stand \(formatter.string(from: last))")
            }
            return String(localized: "Bereit")
        case .syncing:
            return String(localized: "Synchronisiere …")
        case .paused:
            return String(localized: "Pausiert")
        case .offline:
            return String(localized: "Offline – wartet auf Netzwerk")
        case .error(let message):
            return String(localized: "Fehler: \(message)")
        }
    }

    var statusSymbol: String {
        switch status {
        case .notConfigured: return "exclamationmark.icloud"
        case .idle: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .paused: return "pause.circle"
        case .offline: return "icloud.slash"
        case .error: return "xmark.icloud"
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        guard let config = try? SpindConfig.load() else {
            status = .notConfigured
            return
        }
        // Zwei gleichzeitig laufende Synchronisierungen können Daten
        // beschädigen — lieber gar nicht starten.
        guard let lock = ProcessLock(path: ProcessLock.defaultPath) else {
            status = .error(
                "Spind läuft bereits. Beende die andere Instanz (oder den "
                + "Hintergrunddienst »spind watch«) und starte neu."
            )
            return
        }
        processLock = lock
        self.config = config
        let dbURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/spind/state.sqlite")
        guard let store = try? MetadataStore(databaseURL: dbURL) else {
            status = .error("Metadaten-DB konnte nicht geöffnet werden")
            return
        }
        self.store = store
        pinHostKeyIfNeeded()

        // Ein Sync-Client gehört in den Autostart — einmal eingerichtet,
        // soll er einfach immer laufen. Einmalige Selbst-Aktivierung;
        // wer den Schalter in den Einstellungen ausmacht, bleibt aus.
        if !UserDefaults.standard.bool(forKey: "didAutoEnableLoginItem") {
            do {
                try SMAppService.mainApp.register()
                logInfo("Autostart aktiviert – Spind startet ab jetzt bei der Anmeldung.")
            } catch {
                logInfo("Autostart nicht aktivierbar: \(error.localizedDescription)")
            }
            UserDefaults.standard.set(true, forKey: "didAutoEnableLoginItem")
        }

        // Den Sync-Ordner legt die Engine an — und nur, solange es noch
        // keinen Basiszustand gibt. Ihn hier blind zu erzeugen würde den
        // Schutz aushebeln, der nach einem versehentlichen Wegverschieben
        // den Platz für die Reparatur freihält.
        let localRoot = (config.localRoot as NSString).expandingTildeInPath

        let (events, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation

        let watcher = FolderWatcher(path: localRoot) { continuation.yield(()) }
        watcher.start()
        self.watcher = watcher

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.pollInterval ?? 30
                try? await Task.sleep(for: .seconds(seconds))
                self?.continuation?.yield(())
            }
        }

        loopTask = Task { [weak self] in
            await self?.runOnce()
            for await _ in events {
                try? await Task.sleep(for: .seconds(2))
                self?.processMaterializeRequests()
                self?.processShareRequests()
                self?.processEditRequests()
                self?.processVersionRequests()
                await self?.runOnce()
            }
        }

        setupFileProvider(config: config)
        startNetworkMonitor()
        // Keep "Shared by Me" badges truthful across restarts and
        // external changes.
        if KeychainHelper.load(account: HetznerAPI.tokenAccount) != nil {
            refreshSharedBadges()
        }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }

        // "Free up space" like a cloud drive: check twice a day.
        optimizerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            while !Task.isCancelled {
                if self?.autoFreeEnabled == true {
                    await self?.runStorageOptimizer(manual: false)
                }
                try? await Task.sleep(for: .seconds(12 * 3600))
            }
        }

        // Debug hook: SPIND_TEST_VERSIONS=<rel> opens the history window.
        if let list = ProcessInfo.processInfo.environment["SPIND_TEST_VERSIONS"] {
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
            ), let data = try? JSONEncoder().encode(
                list.split(separator: ",").map(String.init)
            ) {
                try? data.write(
                    to: container.appendingPathComponent("spind/versions-request"),
                    options: .atomic
                )
            }
        }

        // Debug hook: SPIND_TEST_EDIT=<rel> simulates the Finder editor
        // action (E2E without clicks).
        if let list = ProcessInfo.processInfo.environment["SPIND_TEST_EDIT"] {
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
            ), let data = try? JSONEncoder().encode(
                list.split(separator: ",").map(String.init)
            ) {
                try? data.write(
                    to: container.appendingPathComponent("spind/edit-request"),
                    options: .atomic
                )
            }
        }

        // Debug hook: SPIND_TEST_CREATE_SHARE=<folder>:<rw|ro> creates a
        // share without the dialog (E2E without clicks).
        if let spec = ProcessInfo.processInfo.environment["SPIND_TEST_CREATE_SHARE"] {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            let folder = parts.first ?? ""
            let readonly = parts.count < 2 || parts[1] != "rw"
            let shareConfig = config
            Task { [weak self] in
                do {
                    let result = try await ShareManager.createShare(
                        folderRelativePath: folder, syncUser: config.username,
                        config: shareConfig, readonly: readonly
                    )
                    await MainActor.run { [weak self] in
                        self?.appendToLogFile("test-share: \(result.directLink)")
                        self?.noteShareCreated(folder)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.appendToLogFile("test-share fehlgeschlagen: \(error)")
                    }
                }
            }
        }

        // Debug hook: SPIND_TEST_REVOKE_SHARE=<folder> revokes a share
        // without the dialog (E2E without clicks).
        if let folder = ProcessInfo.processInfo.environment["SPIND_TEST_REVOKE_SHARE"] {
            let shareConfig = config
            Task { [weak self] in
                do {
                    guard let share = try await ShareManager.findShare(
                        folder: folder, syncUser: config.username
                    ) else {
                        await MainActor.run { [weak self] in
                            self?.appendToLogFile("test-revoke: keine Freigabe für \(folder)")
                        }
                        return
                    }
                    try await ShareManager.revoke(
                        share, syncUser: config.username, config: shareConfig
                    )
                    await MainActor.run { [weak self] in
                        self?.appendToLogFile("test-revoke: \(folder) widerrufen (\(share.username))")
                        self?.refreshSharedBadges()
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.appendToLogFile("test-revoke fehlgeschlagen: \(error)")
                    }
                }
            }
        }

        // Debug hook: SPIND_TEST_SHARE=<rel> simulates the Finder share
        // action (E2E without clicks).
        if let list = ProcessInfo.processInfo.environment["SPIND_TEST_SHARE"] {
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
            ), let data = try? JSONEncoder().encode(
                list.split(separator: ",").map(String.init)
            ) {
                try? data.write(
                    to: container.appendingPathComponent("spind/share-request"),
                    options: .atomic
                )
            }
        }

        // Debug hook: SPIND_TEST_FEED=<rel1,rel2> injects paths into the
        // change feed (refresh stale Finder entries without real changes).
        if let list = ProcessInfo.processInfo.environment["SPIND_TEST_FEED"] {
            appendChangeFeed("feed-updated", paths: list.split(separator: ",").map(String.init))
            Task { [weak self] in
                try? await self?.fpManager?.signalEnumerator(for: .workingSet)
            }
        }

        // Debug hook: SPIND_TEST_MATERIALIZE=<rel1,rel2> simulates the
        // extension's materialization request (E2E without Finder clicks).
        if let list = ProcessInfo.processInfo.environment["SPIND_TEST_MATERIALIZE"] {
            let paths = list.split(separator: ",").map(String.init)
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
            ), let data = try? JSONEncoder().encode(paths) {
                try? data.write(
                    to: container.appendingPathComponent("spind/materialize-request"),
                    options: .atomic
                )
            }
        }

        // Debug hook: SPIND_OPTIMIZE_DAYS=<n> runs one eviction pass with
        // that threshold shortly after launch (E2E testing without waiting
        // 30 days).
        if let override = ProcessInfo.processInfo.environment["SPIND_OPTIMIZE_DAYS"],
           let days = Int(override) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                let result = await StorageOptimizer.freeSpace(olderThanDays: days)
                self?.appendToLogFile(
                    "optimize-test(\(days)d): \(result.evictedCount) entladen, "
                    + "\(result.evictedBytes) Bytes, \(result.skippedCount) übersprungen"
                    + (result.lastError.map { " | letzter Fehler: \($0)" } ?? "")
                )
            }
        }
    }

    /// Evicts long-unused local copies from the Finder volume.
    /// Returns a human-readable summary.
    @discardableResult
    func runStorageOptimizer(manual: Bool) async -> String {
        let result = await StorageOptimizer.freeSpace(olderThanDays: autoFreeDays)
        if result.evictedCount > 0 {
            let summary = "\(StorageOptimizer.formatBytes(result.evictedBytes)) freigegeben (\(result.evictedCount) Dateien)"
            withAnimation(.spring(duration: 0.35)) {
                entries.insert(
                    ActivityEntry(date: Date(), kind: .storage, name: summary, detail: nil),
                    at: 0
                )
            }
            appendToLogFile("Speicher optimiert: \(summary), \(result.skippedCount) übersprungen")
            if !manual {
                notify("Spind – Speicher optimiert", summary)
            }
            return summary
        }
        if manual {
            return result.skippedCount > 0
                ? "Nichts freigegeben – \(result.skippedCount) Dateien in Benutzung/angepinnt"
                : "Alles bereits optimiert"
        }
        return ""
    }

    /// Offline is a state, not an error: pause syncing while the network
    /// is down and catch up the moment it returns.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, online != self.isOnline else { return }
                self.isOnline = online
                if online {
                    if self.status == .offline {
                        self.status = .idle(lastSync: nil)
                    }
                    self.syncNow()
                } else {
                    self.status = .offline
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    /// Downloads placeholders the extension asked for ("Auf dem Computer
    /// behalten"): reading a dataless file forces full materialization.
    private func processMaterializeRequests() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }
        let requestURL = container.appendingPathComponent("spind/materialize-request")
        guard let data = try? Data(contentsOf: requestURL),
              let paths = try? JSONDecoder().decode([String].self, from: data),
              !paths.isEmpty
        else { return }
        try? FileManager.default.removeItem(at: requestURL)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/Spind-Spind")
        logInfo("Behalten: lade \(paths.count) Datei(en) herunter …")
        Task.detached(priority: .utility) { [weak self] in
            var loaded = 0
            for path in paths {
                let fileURL = root.appendingPathComponent(path)
                if let handle = try? FileHandle(forReadingFrom: fileURL) {
                    _ = try? handle.read(upToCount: 1)
                    try? handle.close()
                    loaded += 1
                }
            }
            let count = loaded
            await MainActor.run { [weak self] in
                self?.logInfo("Behalten: \(count) Datei(en) lokal verfügbar")
            }
        }
    }

    /// Accumulates changed paths for the extension's change enumerator.
    private func appendChangeFeed(_ name: String, paths: [String]) {
        guard !paths.isEmpty, let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }
        let url = container.appendingPathComponent("spind/\(name)")
        var list = (try? JSONDecoder().decode(
            [String].self, from: Data(contentsOf: url)
        )) ?? []
        list.append(contentsOf: paths)
        if let data = try? JSONEncoder().encode(Array(Set(list)).sorted()) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Creates folder shares requested via the Finder context menu.
    private func processShareRequests() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }
        let requestURL = container.appendingPathComponent("spind/share-request")
        guard let data = try? Data(contentsOf: requestURL),
              let paths = try? JSONDecoder().decode([String].self, from: data),
              !paths.isEmpty
        else { return }
        try? FileManager.default.removeItem(at: requestURL)

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/Spind-Spind")
        let syncUser = config?.username ?? ""
        for path in paths {
            // Shares are folder-scoped: a file share becomes its folder.
            var folder = path
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory
            )
            if !isDirectory.boolValue {
                folder = (path as NSString).deletingLastPathComponent
            }
            // Open the share dialog (status, access options, copyable
            // links, revocation).
            ShareWindowManager.open(folder: folder, controller: self)
        }
        _ = syncUser
    }

    func noteShareCreated(_ name: String) {
        recordShare(name)
        refreshSharedBadges()
    }

    /// Rewrites the shared-folder badge list and tells Finder to refresh
    /// every folder whose share state changed — including folders whose
    /// share was just revoked (they must lose their badge).
    func refreshSharedBadges() {
        let user = config?.username ?? ""
        let before = ShareManager.loadSharedFolderList().filter { !$0.isEmpty }
        Task { [weak self] in
            guard let after = try? await ShareManager.refreshSharedFolders(syncUser: user)
            else { return }
            let affected = Array(Set(before).union(after))
            await MainActor.run { [weak self] in
                guard let self, !affected.isEmpty else { return }
                self.appendChangeFeed("feed-updated", paths: affected)
                Task { try? await self.fpManager?.signalEnumerator(for: .workingSet) }
            }
        }
    }

    /// Opens files in the browser editor (Finder → "Im Browser gemeinsam
    /// bearbeiten") and puts the link on the clipboard so it can be sent
    /// to whoever should join.
    private func processEditRequests() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }
        let requestURL = container.appendingPathComponent("spind/edit-request")
        guard let data = try? Data(contentsOf: requestURL),
              let paths = try? JSONDecoder().decode([String].self, from: data),
              !paths.isEmpty, let config
        else { return }
        try? FileManager.default.removeItem(at: requestURL)

        // Der Browser-Editor erreicht die Dateien über einen Hetzner-
        // Subaccount — auf allgemeinen SFTP-Servern gibt es den nicht.
        guard config.isHetznerBox else {
            notify(
                "Spind – Bearbeiten nicht verfügbar",
                "Gemeinsames Bearbeiten gibt es nur mit einer Hetzner Storage "
                + "Box. Öffne die Datei stattdessen aus dem Spind-Laufwerk."
            )
            return
        }

        for path in paths {
            let name = (path as NSString).lastPathComponent
            guard WopiToken.isEditable(name) else {
                logInfo("»\(name)« kann nicht im Browser bearbeitet werden")
                notify(
                    "Spind – Bearbeiten nicht möglich",
                    "»\(name)« ist kein Office-Dokument. Unterstützt werden u. a. .odt, .docx, .xlsx, .pptx und .txt."
                )
                continue
            }
            logInfo("Öffne »\(name)« im Browser-Editor …")
            Task { [weak self] in
                do {
                    let url = try await CollaboraService.editorLink(
                        forRelativePath: path, config: config
                    )
                    await MainActor.run { [weak self] in
                        NSWorkspace.shared.open(url)
                        ShareManager.copyToClipboard(url.absoluteString)
                        self?.recordEdit(name)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.logInfo("Editor fehlgeschlagen: \(error.localizedDescription)")
                        self?.notify("Spind – Bearbeiten fehlgeschlagen", error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Opens the version history window (Finder → "Versionsverlauf
    /// anzeigen").
    private func processVersionRequests() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }
        let requestURL = container.appendingPathComponent("spind/versions-request")
        guard let data = try? Data(contentsOf: requestURL),
              let paths = try? JSONDecoder().decode([String].self, from: data),
              !paths.isEmpty
        else { return }
        try? FileManager.default.removeItem(at: requestURL)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/Spind-Spind")
        for path in paths {
            // Verlauf gibt es je Datei — auf einem Ordner würde das Fenster
            // dauerhaft "noch keine Fassungen" zeigen und ewig warten lassen.
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory
            )
            if isDirectory.boolValue {
                notify(
                    "Spind – Versionsverlauf",
                    "»\((path as NSString).lastPathComponent)« ist ein Ordner. "
                    + "Den Verlauf gibt es je Datei – rechtsklicke eine einzelne Datei."
                )
                continue
            }
            VersionsWindowManager.open(path: path, controller: self)
        }
    }

    private func recordEdit(_ name: String) {
        withAnimation(.spring(duration: 0.35)) {
            entries.insert(
                ActivityEntry(date: Date(), kind: .edit, name: name, detail: nil),
                at: 0
            )
        }
        appendToLogFile("Browser-Editor geöffnet: \(name)")
    }

    private func recordShare(_ name: String) {
        withAnimation(.spring(duration: 0.35)) {
            entries.insert(
                ActivityEntry(date: Date(), kind: .share, name: name, detail: nil),
                at: 0
            )
        }
        appendToLogFile("Freigabe erstellt: \(name)")
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
        )
    }

    /// Tears everything down and starts fresh — used after settings change.
    /// TOFU: den Server-Schlüssel beim ersten Kontakt holen und anpinnen —
    /// ab dann weist der Client jeden anderen Schlüssel ab.
    private func pinHostKeyIfNeeded() {
        guard var config, config.hostPublicKey == nil else { return }
        Task { [weak self] in
            guard let key = try? await HostKey.scan(host: config.host, port: config.port)
            else { return }
            config.hostPublicKey = key
            try? config.save()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.config = config
                self.setupFileProvider(config: config)
                self.logInfo("Server-Schlüssel angepinnt: \(String(key.prefix(28)))…")
            }
        }
    }

    func reload() {
        loopTask?.cancel()
        pollTask?.cancel()
        signalTask?.cancel()
        optimizerTask?.cancel()
        watcher?.stop()
        groupWatcher?.stop()
        pathMonitor?.cancel()
        pathMonitor = nil
        continuation?.finish()
        watcher = nil
        groupWatcher = nil
        transfers.removeAll()
        started = false
        status = .idle(lastSync: nil)
        start()
    }

    // MARK: - File Provider

    private func setupFileProvider(config: SpindConfig) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }
        do {
            let dir = container.appendingPathComponent("spind")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let keySource = (config.privateKeyPath as NSString).expandingTildeInPath
            let keyDest = dir.appendingPathComponent("key")
            if FileManager.default.fileExists(atPath: keyDest.path) {
                try FileManager.default.removeItem(at: keyDest)
            }
            try FileManager.default.copyItem(atPath: keySource, toPath: keyDest.path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: keyDest.path
            )
            var extensionConfig = config
            extensionConfig.privateKeyPath = keyDest.path
            try extensionConfig.save(to: dir.appendingPathComponent("config.json"))
        } catch {
            logInfo("File-Provider-Setup fehlgeschlagen: \(error.localizedDescription)")
            return
        }

        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier("spind"),
            displayName: "Spind"
        )
        // Kein Papierkorb-Sync — sonst fragt das System den Trash-Container
        // an, kassiert unseren Fehler und meldet Sync-Probleme.
        if #available(macOS 15.0, *) {
            domain.supportsSyncingTrash = false
        }
        fpManager = NSFileProviderManager(for: domain)

        // The extension touches a marker after every write through the
        // Finder volume — react immediately instead of waiting for the poll.
        if let continuation {
            let markerDir = container.appendingPathComponent("spind")
            let watcher = FolderWatcher(path: markerDir.path) { continuation.yield(()) }
            watcher.start()
            groupWatcher = watcher
        }
        // Rettungsanker: baut das Finder-Laufwerk komplett neu auf (Domain
        // entfernen + neu anlegen). Nicht destruktiv — die lokale Replik
        // entsteht frisch aus der Box. Nötig z. B. wenn fileproviderd eine
        // Domain in kaputtem Zustand festhält.
        let resetRequested = ProcessInfo.processInfo.arguments.contains("--reset-domain")
            || UserDefaults.standard.bool(forKey: "resetDomainOnNextLaunch")
        if resetRequested {
            UserDefaults.standard.removeObject(forKey: "resetDomainOnNextLaunch")
            logInfo("Finder-Laufwerk wird neu aufgebaut …")
            NSFileProviderManager.remove(domain) { [weak self] removeError in
                Task { @MainActor in
                    if let removeError {
                        self?.logInfo("Domain-Entfernen: \(removeError.localizedDescription)")
                    }
                    self?.addFileProviderDomain(domain)
                }
            }
        } else {
            addFileProviderDomain(domain)
        }

        signalTask = Task { [weak self] in
            let manager = NSFileProviderManager(for: domain)
            while !Task.isCancelled {
                let seconds = self?.pollInterval ?? 30
                try? await Task.sleep(for: .seconds(seconds))
                try? await manager?.signalEnumerator(for: .workingSet)
            }
        }
    }

    private func addFileProviderDomain(_ domain: NSFileProviderDomain) {
        NSFileProviderManager.add(domain) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.logInfo("File-Provider-Domain: \(error.localizedDescription)")
                    return
                }
                self?.logInfo("File-Provider-Domain aktiv.")
                // One-time after the v2 metadata change: make the system
                // re-read all item metadata (capabilities, content policy)
                // so pre-existing files become evictable too.
                // Keep in sync with the metadataVersion salt in
                // FileProviderItem (currently v3).
                if !UserDefaults.standard.bool(forKey: "reimportedForV3") {
                    NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer) { error in
                        if error == nil {
                            UserDefaults.standard.set(true, forKey: "reimportedForV3")
                        }
                    }
                }
            }
        }
    }

    /// Für den Knopf in den Einstellungen: beim nächsten Start wird das
    /// Finder-Laufwerk neu aufgebaut, dann startet die App sich neu.
    /// Der Umweg über eine kurzlebige Shell lässt die Prozesssperre der
    /// alten Instanz erst frei werden, bevor die neue startet.
    func rebuildFinderVolume() {
        UserDefaults.standard.set(true, forKey: "resetDomainOnNextLaunch")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 2; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Actions

    func syncNow() {
        continuation?.yield(())
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            status = .paused
        } else {
            status = .idle(lastSync: nil)
            syncNow()
        }
    }

    private func runOnce() async {
        guard !isPaused, folderSyncEnabled, isOnline, let config, let store else { return }
        let wasError = { if case .error = status { return true } else { return false } }()
        status = .syncing
        // Nicht kleben lassen: scheitert der nächste Lauf an etwas anderem,
        // gehört der Bestätigen-Knopf nicht mehr ins Fenster.
        pendingBulkDeletions = nil
        do {
            let client = StorageBoxClient(config: config)
            try await client.connect()
            let engine = SyncEngine(config: config, client: client, store: store)
            // Einmalige Freigabe: die Bremse hat zugeschlagen und der Nutzer
            // hat die Löschungen im Fenster ausdrücklich bestätigt.
            if bulkDeletionConfirmed {
                engine.allowBulkDeletions = true
                bulkDeletionConfirmed = false
            }
            engine.onEvent = { [weak self] message in
                Task { @MainActor in self?.appendToLogFile(message) }
            }
            engine.onProgress = { [weak self] path, direction, done, total in
                Task { @MainActor in self?.updateTransfer(path, direction, done, total) }
            }
            engine.onAction = { [weak self] action in
                Task { @MainActor in self?.recordAction(action) }
            }
            let actions = try await engine.sync()
            await client.disconnect()
            transfers.removeAll()
            status = .idle(lastSync: Date())
            if !actions.isEmpty {
                // Feed every change into the extension's change feed so the
                // Finder volume updates without stale ghosts.
                var updated: [String] = []
                var deleted: [String] = []
                for action in actions {
                    switch action {
                    case .upload(let p), .download(let p), .conflict(let p),
                         .createLocalDir(let p), .createRemoteDir(let p):
                        updated.append(p)
                    case .deleteLocal(let p), .deleteRemote(let p):
                        deleted.append(p)
                    case .moveRemote(let from, let to), .moveLocal(let from, let to):
                        deleted.append(from)
                        updated.append(to)
                    }
                }
                appendChangeFeed("feed-updated", paths: updated)
                appendChangeFeed("feed-deleted", paths: deleted)
                try? await fpManager?.signalEnumerator(for: .workingSet)
                try? await fpManager?.signalEnumerator(for: .rootContainer)

                // Keep share pages current: refresh manifests of shared
                // folders that just changed.
                let changedPaths = updated + deleted
                let affectedShares = ShareManager.loadSharedFolderList().filter { shared in
                    !shared.isEmpty && changedPaths.contains {
                        $0 == shared || $0.hasPrefix(shared + "/")
                    }
                }
                if !affectedShares.isEmpty {
                    let shareConfig = config
                    Task.detached(priority: .utility) {
                        await ShareManager.refreshManifests(
                            folders: affectedShares, config: shareConfig
                        )
                    }
                }
            }
        } catch {
            transfers.removeAll()
            // Die Bremse ist kein Defekt, sondern eine Rückfrage: die
            // Oberfläche bietet dazu einen Bestätigen-Knopf an.
            if case SyncError.tooManyDeletions(let count, _) = error {
                pendingBulkDeletions = count
            }
            status = .error(error.localizedDescription)
            logInfo("Sync-Fehler: \(error.localizedDescription)")
            if !wasError && isOnline {
                notify("Spind – Sync-Fehler", error.localizedDescription)
            }
        }
    }

    /// Gibt die von der Bremse gestoppten Löschungen für genau einen Lauf frei.
    func confirmBulkDeletions() {
        bulkDeletionConfirmed = true
        pendingBulkDeletions = nil
        syncNow()
    }

    // MARK: - Log & progress bookkeeping

    private func updateTransfer(
        _ path: String, _ direction: TransferDirection, _ done: UInt64, _ total: UInt64
    ) {
        if let index = transfers.firstIndex(where: { $0.id == path }) {
            transfers[index].transferred = done
            transfers[index].total = total
        } else {
            transfers.append(FileTransfer(
                id: path, direction: direction, transferred: done, total: total
            ))
        }
    }

    private func recordAction(_ action: SyncAction) {
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        let entry: ActivityEntry
        switch action {
        case .upload(let path):
            transfers.removeAll { $0.id == path }
            entry = ActivityEntry(date: Date(), kind: .upload, name: name(path), detail: nil)
        case .download(let path):
            transfers.removeAll { $0.id == path }
            entry = ActivityEntry(date: Date(), kind: .download, name: name(path), detail: nil)
        case .deleteLocal(let path):
            entry = ActivityEntry(date: Date(), kind: .deleteLocal, name: name(path), detail: nil)
        case .deleteRemote(let path):
            entry = ActivityEntry(date: Date(), kind: .deleteRemote, name: name(path), detail: nil)
        case .createLocalDir(let path), .createRemoteDir(let path):
            entry = ActivityEntry(date: Date(), kind: .folder, name: name(path), detail: nil)
        case .moveRemote(let from, let to), .moveLocal(let from, let to):
            entry = ActivityEntry(
                date: Date(), kind: .move,
                name: "\(name(from)) → \(name(to))", detail: nil
            )
        case .conflict(let path):
            entry = ActivityEntry(date: Date(), kind: .conflict, name: name(path), detail: nil)
            notify(
                "Spind – Konflikt",
                "»\(name(path))« wurde auf beiden Seiten geändert. Beide Versionen wurden behalten."
            )
        }
        withAnimation(.spring(duration: 0.35)) {
            entries.insert(entry, at: 0)
            if entries.count > 30 {
                entries.removeLast(entries.count - 30)
            }
        }
    }

    private func logInfo(_ message: String) {
        entries.insert(
            ActivityEntry(date: Date(), kind: .info, name: message, detail: nil),
            at: 0
        )
        appendToLogFile(message)
    }

    private func appendToLogFile(_ message: String) {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/spind-app.log")
        // Rotation: ab 5 MB wandert das Log nach .old (eine Generation
        // genügt zum Nachschauen) — sonst wächst es jahrelang unbemerkt.
        if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 5_000_000 {
            let old = logURL.deletingPathExtension().appendingPathExtension("old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
        let line = "\(Date())  \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    // MARK: - Preview support

    func injectDemoData() {
        status = .syncing
        transfers = [
            FileTransfer(id: "Fotos/Urlaub-2026.zip", direction: .upload,
                         transferred: 48_234_496, total: 104_857_600),
            FileTransfer(id: "Projekte/Entwurf.sketch", direction: .download,
                         transferred: 9_437_184, total: 12_582_912),
        ]
        entries = [
            ActivityEntry(date: Date().addingTimeInterval(-40), kind: .download,
                          name: "Rechnung März.pdf", detail: nil),
            ActivityEntry(date: Date().addingTimeInterval(-140), kind: .upload,
                          name: "Notizen.md", detail: nil),
            ActivityEntry(date: Date().addingTimeInterval(-360), kind: .folder,
                          name: "Steuern 2026", detail: nil),
            ActivityEntry(date: Date().addingTimeInterval(-500), kind: .conflict,
                          name: "Budget.numbers", detail: nil),
            ActivityEntry(date: Date().addingTimeInterval(-1200), kind: .deleteRemote,
                          name: "Alt.txt", detail: nil),
        ]
    }
}
