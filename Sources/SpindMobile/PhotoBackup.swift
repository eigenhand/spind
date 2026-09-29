// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Network
import Photos
import SwiftUI
import UIKit
import SpindCore

/// What gets backed up and where to. Lives in the app group so that an
/// app restart forgets nothing and uploads nothing twice.
struct PhotoBackupSettings: Codable {
    var enabled = false
    var folder = "Bilder"
    var layout: PhotoLayout = .yearMonth
    var includeVideos = false
    var wifiOnly = true
    /// When the newest saved item was taken.
    var lastUploaded: Date?
    /// Identifiers of the most recently saved items — only for the edge
    /// case of several shots carrying the same timestamp.
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

/// Photos from the iPhone into the Spind — filed by the date taken.
@MainActor
final class PhotoBackup: ObservableObject {
    static let shared = PhotoBackup()

    /// When iOS only wakes the app briefly in the background, it stays a
    /// handful — time is short there. In front it runs through, or the
    /// first backup of a large library would never reach the end.
    static let batchSize = 40

    /// The cancellation has to be readable from the concurrent tasks, not
    /// only from the main thread — hence a small shared switch instead of
    /// a property of the object.
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

    /// How many transfers run at the same time. Four keep a mobile or
    /// Wi-Fi link busy without crowding the box with connections —
    /// Hetzner caps how many there may be.
    static let parallelUploads = 4

    /// One shot, boiled down to the essentials: PhotoKit objects do not
    /// travel between tasks.
    struct Item: Sendable {
        let identifier: String
        let created: Date?
    }

    struct Outcome: Sendable {
        let item: Item
        let name: String?
        let error: String?
    }

    /// What several concurrent transfers have to share: which folders
    /// were created and which target names are taken.
    actor UploadCoordinator {
        private var claimed: Set<String> = []
        private var directories: Set<String> = []

        func claim(_ path: String) -> Bool { claimed.insert(path).inserted }
        func firstUse(of directory: String) -> Bool {
            directories.insert(directory).inserted
        }
    }

    /// A running pass, for the progress display.
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
    /// How many shots are still waiting — also without a running pass, so
    /// that one knows beforehand what is ahead.
    @Published private(set) var waiting: Int?

    var running: Bool { run != nil }

    private init() {
        settings = PhotoBackupSettings.load()
    }

    /// Counts what is due. Cheap: PHFetchResult loads only on demand.
    func countWaiting() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined else {
            waiting = nil
            return
        }
        waiting = fetchPending().count
    }

    // MARK: - The run

    /// Stops a running pass — the app moves to the background, where it
    /// would be frozen in a moment anyway.
    func pause() {
        cancellation.cancel()
    }

    /// "Only new from now on": everything present counts as done without
    /// being touched. The other way round (`false`), the next pass starts
    /// at the oldest shot again.
    func markExisting(asDone done: Bool) {
        settings.lastUploaded = done ? Date() : nil
        settings.recent = []
        countWaiting()
    }

    /// - Parameter limited: save only a handful (background wake-up).
    func run(config: SpindConfig, manual: Bool = false, limited: Bool = false) async {
        guard !running, settings.enabled || manual else { return }
        cancellation.reset()
        run = Run()
        defer {
            run = nil
            // The screen may go dark by itself again.
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
        // During a pass in front the screen must not go dark — in sleep
        // iOS freezes the app and the upload stalls.
        if !limited { UIApplication.shared.isIdleTimerDisabled = true }

        // Several connections instead of one: a single photo saturates
        // neither the line nor the server, most of the time is spent
        // waiting for round trips. The pool keeps the connections open —
        // the SSH handshake costs about a second and should not be paid
        // per picture.
        // Every transfer in flight holds its original as a file in
        // temporary storage. For photos that is a few megabytes, for
        // videos quickly half a gigabyte — then rather fewer at once, or
        // the space on the iPhone runs out.
        let slots = settings.includeVideos ? 2 : Self.parallelUploads
        let pool = StorageBoxConnectionPool(config: config, maxConnections: slots)
        defer { Task { await pool.drain() } }
        let coordinator = UploadCoordinator()

        // Write the state file at the end, not per picture.
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
                    // A single picture must not end the pass — next time
                    // it is up again.
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

    // MARK: - Selection

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
            // >= rather than >, or a second picture from the same second
            // slips through; `recent` guards against duplicates.
            conditions.append(NSPredicate(format: "creationDate >= %@", last as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: conditions)
        return PHAsset.fetchAssets(with: options)
    }

    /// Assembles the work list. `PHAsset` itself does not travel between
    /// tasks — only the identifier and the date taken, so that nobody has
    /// to worry about the thread safety of PhotoKit objects.
    private func collect(
        _ pending: PHFetchResult<PHAsset>, skipping known: Set<String>, limit: Int
    ) -> [Item] {
        var batch: [Item] = []
        var index = 0
        while batch.count < limit, index < pending.count {
            let asset = pending.object(at: index)
            index += 1
            // Edge case: same date taken as in the last pass.
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

    // MARK: - Transferring

    /// Runs **beside** the main thread: neither the interface nor the
    /// progress numbers are touched here, the result goes back as an
    /// `Outcome`.
    nonisolated private static func transfer(
        _ item: Item, settings: PhotoBackupSettings, config: SpindConfig,
        pool: StorageBoxConnectionPool, coordinator: UploadCoordinator
    ) async -> Outcome {
        do {
            // The PHAsset is fetched fresh here instead of being handed
            // around between tasks.
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

    /// Never overwrite anything: if the name exists, the picture gets a
    /// number. Two shots can carry the same filename — and with concurrent
    /// transfers a look at the server is not enough, because the other
    /// task has not put its file there yet. So the name is claimed with
    /// the coordinator as well.
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

    /// Fetches the original — for iCloud photos it is downloaded first.
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

    // MARK: - Prerequisites

    private func requestAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited { return true }
        guard current == .notDetermined else { return false }
        let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return granted == .authorized || granted == .limited
    }

    /// Mobile data costs money and battery — whoever minds waits for Wi-Fi.
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

    /// The path monitor reports repeatedly; exactly one resume is allowed.
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
