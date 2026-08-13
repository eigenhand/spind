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

import Network
import Photos
import SwiftUI
import UIKit
import SpindCore

/// Was gesichert wird und wohin. Liegt in der App-Gruppe, damit ein
/// App-Neustart nichts vergisst und nichts doppelt hochlädt.
struct PhotoBackupSettings: Codable {
    var enabled = false
    var folder = "Bilder"
    var layout: PhotoLayout = .yearMonth
    var includeVideos = false
    var wifiOnly = true
    /// Aufnahmezeitpunkt des jüngsten gesicherten Objekts.
    var lastUploaded: Date?
    /// Kennungen der zuletzt gesicherten Objekte — nur für den Grenzfall
    /// mehrerer Aufnahmen mit demselben Zeitstempel.
    var recent: [String] = []

    static var url: URL? {
        MobileStore.directory?.appendingPathComponent("photos.json")
    }

    static func load() -> PhotoBackupSettings {
        guard let url, let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Self.self, from: data)
        else { return PhotoBackupSettings() }
        return settings
    }

    func save() {
        guard let url = Self.url, let directory = MobileStore.directory else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Fotos vom iPhone in den Spind — einsortiert nach Aufnahmedatum.
@MainActor
final class PhotoBackup: ObservableObject {
    static let shared = PhotoBackup()

    /// Wird die App nur kurz im Hintergrund geweckt, bleibt es bei einer
    /// Handvoll — dort ist die Zeit knapp bemessen. Vorn läuft es durch,
    /// sonst käme die erste Sicherung einer großen Mediathek nie ans Ende.
    static let batchSize = 40

    /// Der Abbruch muss aus den nebenläufigen Aufgaben heraus lesbar sein,
    /// nicht nur vom Hauptfaden — deshalb ein kleiner geteilter Schalter
    /// statt einer Eigenschaft des Objekts.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func reset() { lock.lock(); value = false; lock.unlock() }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    private let cancellation = Cancellation()

    /// Wie viele Übertragungen gleichzeitig laufen. Vier lasten eine
    /// Mobilfunk- oder WLAN-Strecke gut aus, ohne die Box mit Verbindungen
    /// zuzustellen — Hetzner begrenzt die Anzahl.
    static let parallelUploads = 4

    /// Eine Aufnahme, auf das Nötigste eingedampft: PhotoKit-Objekte reisen
    /// nicht zwischen den Aufgaben.
    struct Item: Sendable {
        let identifier: String
        let created: Date?
    }

    struct Outcome: Sendable {
        let item: Item
        let name: String?
        let error: String?
    }

    /// Was sich mehrere gleichzeitige Übertragungen teilen müssen: welche
    /// Ordner schon angelegt und welche Zielnamen schon vergeben sind.
    actor UploadCoordinator {
        private var claimed: Set<String> = []
        private var directories: Set<String> = []

        func claim(_ path: String) -> Bool { claimed.insert(path).inserted }
        func firstUse(of directory: String) -> Bool {
            directories.insert(directory).inserted
        }
    }

    /// Ein laufender Durchgang, für die Fortschrittsanzeige.
    struct Run: Equatable {
        var done = 0
        var total = 0
        var failed = 0
        var current: String?

        var fraction: Double {
            total > 0 ? Double(done) / Double(total) : 0
        }
    }

    @Published var settings: PhotoBackupSettings {
        didSet { settings.save() }
    }
    @Published private(set) var run: Run?
    @Published private(set) var status: String?
    /// Wie viele Aufnahmen noch warten — auch ohne laufenden Durchgang, damit
    /// man vorher weiß, was ansteht.
    @Published private(set) var waiting: Int?

    var running: Bool { run != nil }

    private init() {
        settings = PhotoBackupSettings.load()
    }

    /// Zählt, was anliegt. Billig: PHFetchResult lädt nur bei Bedarf.
    func countWaiting() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined else {
            waiting = nil
            return
        }
        waiting = fetchPending().count
    }

    // MARK: - Lauf

    /// Hält einen laufenden Durchgang an — die App wandert in den
    /// Hintergrund, dort wäre sie ohnehin gleich eingefroren.
    func pause() {
        cancellation.cancel()
    }

    /// „Nur neue ab jetzt": Alles Vorhandene gilt als erledigt, ohne es
    /// anzufassen. Umgekehrt (`false`) beginnt der nächste Durchgang wieder
    /// bei der ältesten Aufnahme.
    func markExisting(asDone done: Bool) {
        settings.lastUploaded = done ? Date() : nil
        settings.recent = []
        countWaiting()
    }

    /// - Parameter limited: nur eine Handvoll sichern (Hintergrund-Weckruf).
    func run(config: SpindConfig, manual: Bool = false, limited: Bool = false) async {
        guard !running, settings.enabled || manual else { return }
        cancellation.reset()
        run = Run()
        defer {
            run = nil
            // Bildschirm darf wieder von selbst zugehen.
            UIApplication.shared.isIdleTimerDisabled = false
            countWaiting()
        }

        guard await requestAccess() else {
            status = "Kein Zugriff auf die Fotos. In den iPhone-Einstellungen "
                + "unter Datenschutz → Fotos freigeben."
            return
        }
        if settings.wifiOnly, !manual, await !Self.onWiFi() {
            status = "Wartet auf WLAN."
            return
        }

        let pending = fetchPending()
        waiting = pending.count
        guard pending.count > 0 else {
            status = "Alles gesichert."
            return
        }
        // Während eines Durchgangs vorn soll der Bildschirm nicht zugehen —
        // im Ruhezustand friert iOS die App ein und der Upload steht.
        if !limited { UIApplication.shared.isIdleTimerDisabled = true }

        // Mehrere Verbindungen statt einer: Ein einzelnes Foto lastet
        // weder Leitung noch Server aus, die meiste Zeit wartet man auf
        // Laufzeiten hin und zurück. Der Pool hält die Verbindungen
        // offen — der SSH-Handschlag kostet rund eine Sekunde und soll
        // nicht pro Bild anfallen.
        // Jede laufende Übertragung hält ihr Original als Datei im
        // Zwischenspeicher. Bei Fotos sind das ein paar Megabyte, bei
        // Videos schnell ein halbes Gigabyte — dann lieber weniger
        // gleichzeitig, sonst läuft der Platz auf dem iPhone voll.
        let slots = settings.includeVideos ? 2 : Self.parallelUploads
        let pool = StorageBoxConnectionPool(config: config, maxConnections: slots)
        defer { Task { await pool.drain() } }
        let coordinator = UploadCoordinator()

        // Die Zustandsdatei erst am Ende schreiben, nicht pro Bild.
        var progress = settings
        let known = Set(progress.recent)
        let limit = limited ? Self.batchSize : Int.max
        let batch = collect(pending, skipping: known, limit: limit)
        var state = Run(done: 0, total: batch.count)
        run = state
        var done = 0
        var failed = 0
        let plan = settings

        await withTaskGroup(of: Outcome.self) { group in
            var next = 0
            func schedule() {
                guard next < batch.count, !cancellation.isSet else { return }
                let item = batch[next]
                next += 1
                group.addTask {
                    await Self.transfer(
                        item, settings: plan, config: config,
                        pool: pool, coordinator: coordinator
                    )
                }
            }
            for _ in 0..<slots { schedule() }

            while let outcome = await group.next() {
                if let failure = outcome.error {
                    // Ein einzelnes Bild darf den Lauf nicht beenden —
                    // das nächste Mal ist es wieder dran.
                    failed += 1
                    state.failed = failed
                    status = "Ein Bild ging nicht: \(failure)"
                } else {
                    done += 1
                    remember(outcome.item, in: &progress)
                    state.done = done
                    state.current = outcome.name
                }
                run = state
                schedule()
            }
        }

        settings = progress
        let left = pending.count - batch.count
        status = cancellation.isSet
            ? "\(done) gesichert, angehalten – der Rest folgt später."
            : (left > 0
               ? "\(done) gesichert, \(left) noch offen."
               : "\(done) gesichert – fertig.")
        if failed > 0 { status = (status ?? "") + " \(failed) übersprungen." }
        if done > 0 { await SpindDomain.refresh() }
    }

    // MARK: - Auswahl

    private func fetchPending() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var conditions: [NSPredicate] = []
        if !settings.includeVideos {
            conditions.append(NSPredicate(
                format: "mediaType == %d", PHAssetMediaType.image.rawValue
            ))
        } else {
            conditions.append(NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            ))
        }
        if let last = settings.lastUploaded {
            // >= statt >, sonst fällt ein zweites Bild aus derselben Sekunde
            // durchs Raster; gegen Doppelungen hilft `recent`.
            conditions.append(NSPredicate(format: "creationDate >= %@", last as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: conditions)
        return PHAsset.fetchAssets(with: options)
    }

    /// Stellt die Arbeitsliste zusammen. `PHAsset` selbst reist nicht
    /// zwischen den Aufgaben — nur Kennung und Aufnahmezeitpunkt, damit sich
    /// niemand um die Fadensicherheit von PhotoKit-Objekten sorgen muss.
    private func collect(
        _ pending: PHFetchResult<PHAsset>, skipping known: Set<String>, limit: Int
    ) -> [Item] {
        var batch: [Item] = []
        var index = 0
        while batch.count < limit, index < pending.count {
            let asset = pending.object(at: index)
            index += 1
            // Grenzfall: gleicher Aufnahmezeitpunkt wie beim letzten Lauf.
            if known.contains(asset.localIdentifier) { continue }
            batch.append(Item(identifier: asset.localIdentifier,
                              created: asset.creationDate))
        }
        return batch
    }

    private func remember(_ item: Item, in progress: inout PhotoBackupSettings) {
        if let date = item.created,
           progress.lastUploaded == nil || date > progress.lastUploaded! {
            progress.lastUploaded = date
        }
        progress.recent.append(item.identifier)
        if progress.recent.count > 200 {
            progress.recent.removeFirst(progress.recent.count - 200)
        }
    }

    // MARK: - Übertragen

    /// Läuft **neben** dem Hauptfaden: Weder die Oberfläche noch die
    /// Fortschrittszahlen werden hier angefasst, das Ergebnis geht als
    /// `Outcome` zurück.
    nonisolated private static func transfer(
        _ item: Item, settings: PhotoBackupSettings, config: SpindConfig,
        pool: StorageBoxConnectionPool, coordinator: UploadCoordinator
    ) async -> Outcome {
        do {
            // Das PHAsset wird hier frisch geholt statt zwischen den
            // Aufgaben herumgereicht.
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [item.identifier], options: nil
            ).firstObject else {
                return Outcome(item: item, name: nil, error: nil)
            }
            guard let (local, name) = try await export(asset) else {
                return Outcome(item: item, name: nil, error: nil)
            }
            defer {
                try? FileManager.default.removeItem(at: local.deletingLastPathComponent())
            }

            let relative = settings.layout.path(
                for: item.created ?? Date(), folder: settings.folder, fileName: name
            )
            let directory = (relative as NSString).deletingLastPathComponent
            var root = config.remoteRoot
            if root.hasSuffix("/") { root = String(root.dropLast()) }
            let remoteDirectory = root.isEmpty ? directory : root + "/" + directory
            let base = root.isEmpty ? relative : root + "/" + relative

            try await pool.withClient { client in
                if !directory.isEmpty,
                   await coordinator.firstUse(of: remoteDirectory) {
                    _ = try await client.run(
                        "mkdir -p -- " + StorageBoxClient.quote(remoteDirectory)
                    )
                }
                let target = try await freePath(
                    base, client: client, coordinator: coordinator
                )
                try await client.upload(local, to: target)
            }
            return Outcome(item: item, name: name, error: nil)
        } catch {
            return Outcome(item: item, name: nil, error: connectionHint(for: error))
        }
    }

    /// Nie etwas überschreiben: Gibt es den Namen schon, bekommt das Bild
    /// eine Zahl. Zwei Aufnahmen können denselben Dateinamen tragen — und
    /// bei gleichzeitigen Übertragungen reicht ein Blick auf den Server
    /// nicht, weil die andere Aufgabe ihre Datei noch gar nicht abgelegt
    /// hat. Deshalb wird der Name zusätzlich beim Koordinator belegt.
    nonisolated private static func freePath(
        _ path: String, client: StorageBoxClient, coordinator: UploadCoordinator
    ) async throws -> String {
        let base = (path as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        for number in 1...99 {
            let candidate = number == 1
                ? path
                : (ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            guard await coordinator.claim(candidate) else { continue }
            if (try? await client.stat(candidate)) == nil { return candidate }
        }
        return path
    }

    /// Holt das Original — bei iCloud-Fotos wird es dafür nachgeladen.
    nonisolated private static func export(_ asset: PHAsset) async throws -> (URL, String)? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = [.photo, .video, .fullSizePhoto, .fullSizeVideo]
        guard let resource = preferred.lazy
            .compactMap({ type in resources.first { $0.type == type } }).first
            ?? resources.first
        else { return nil }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(resource.originalFilename)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource, toFile: url, options: options
            ) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        return (url, resource.originalFilename)
    }

    // MARK: - Voraussetzungen

    private func requestAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited { return true }
        guard current == .notDetermined else { return false }
        let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return granted == .authorized || granted == .limited
    }

    /// Mobilfunk kostet Geld und Akku — wer das nicht will, wartet auf WLAN.
    static func onWiFi() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "dev.eigenhand.spind.path")
            let once = OneShot()
            monitor.pathUpdateHandler = { path in
                guard once.fire() else { return }
                monitor.cancel()
                continuation.resume(returning: !path.usesInterfaceType(.cellular)
                                    && path.status == .satisfied)
            }
            monitor.start(queue: queue)
        }
    }

    /// Der Pfad-Beobachter meldet mehrfach; fortgesetzt wird genau einmal.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}
