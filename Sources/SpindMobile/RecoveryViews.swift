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

import QuickLook
import SwiftUI
import SpindCore

/// Trash and version history on the iPhone. Both live on the server:
/// what shows up here does not depend on whether this device ever
/// downloaded the file.
enum Recovery {
    static func withClient<T>(
        _ config: SpindConfig,
        _ body: (StorageBoxClient, SpindConfig) async throws -> T
    ) async throws -> T {
        let client = StorageBoxClient(config: config)
        try await client.connect()
        defer { Task { await client.disconnect() } }
        return try await body(client, config)
    }

    static func remotePath(_ relative: String, _ config: SpindConfig) -> String {
        var root = config.remoteRoot
        if root.hasSuffix("/") { root = String(root.dropLast()) }
        return root.isEmpty ? relative : root + "/" + relative
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

// MARK: - Trash

struct TrashView: View {
    let config: SpindConfig

    @State private var deleted: [VersionStore.DeletedFile] = []
    @State private var loading = true
    @State private var busy: String?
    @State private var message: String?
    @State private var pending: VersionStore.DeletedFile?

    var body: some View {
        List {
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(deleted) { file in
                NavigationLink {
                    VersionsView(config: config, path: file.relativePath, wasDeleted: true)
                } label: {
                    row(file)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        pending = file
                    } label: {
                        Label("Zurückholen", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.green)
                }
            }
        }
        .navigationTitle("Papierkorb")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading {
                ProgressView("Durchsuche den Verlauf …")
            } else if deleted.isEmpty && message == nil {
                ContentUnavailableView(
                    "Nichts zu retten",
                    systemImage: "checkmark.circle",
                    description: Text("Wird eine Datei gelöscht, die schon einmal "
                                      + "gesichert wurde, taucht sie hier auf und "
                                      + "lässt sich zurückholen.")
                )
            }
        }
        .refreshable { await load() }
        .task { if deleted.isEmpty { await load() } }
        .confirmationDialog(
            "»\(name(of: pending?.relativePath ?? ""))« zurückholen?",
            isPresented: Binding(
                get: { pending != nil }, set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Zurückholen") {
                if let file = pending { Task { await restore(file) } }
                pending = nil
            }
            Button("Abbrechen", role: .cancel) { pending = nil }
        } message: {
            Text("Die zuletzt gesicherte Fassung kommt an ihren alten Platz "
                 + "zurück – auf allen Geräten.")
        }
    }

    private func row(_ file: VersionStore.DeletedFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name(of: file.relativePath))
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle(file))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if busy == file.id { ProgressView() }
        }
    }

    private func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func subtitle(_ file: VersionStore.DeletedFile) -> String {
        var parts: [String] = []
        let folder = (file.relativePath as NSString).deletingLastPathComponent
        if !folder.isEmpty { parts.append(folder) }
        parts.append(Recovery.moment(file.latest.date))
        parts.append(Recovery.size(file.latest.size))
        if file.versionCount > 1 { parts.append("\(file.versionCount) Fassungen") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        message = nil
        do {
            deleted = try await Recovery.withClient(config) { client, config in
                await VersionStore.listDeleted(client: client, config: config)
            }
        } catch {
            message = connectionHint(for: error)
        }
        loading = false
    }

    private func restore(_ file: VersionStore.DeletedFile) async {
        busy = file.id
        defer { busy = nil }
        do {
            try await Recovery.withClient(config) { client, config in
                try await VersionStore.restore(
                    version: file.latest, relativePath: file.relativePath,
                    remotePath: Recovery.remotePath(file.relativePath, config),
                    client: client, config: config
                )
            }
            // So the file is back in the Files app right away.
            await SpindDomain.refresh()
            message = "»\(name(of: file.relativePath))« ist wieder da."
            await load()
        } catch {
            message = connectionHint(for: error)
        }
    }
}

// MARK: - Version history of one file

struct VersionsView: View {
    let config: SpindConfig
    let path: String
    var wasDeleted = false

    @State private var versions: [FileVersion] = []
    @State private var loading = true
    @State private var busy: String?
    @State private var message: String?
    @State private var pending: FileVersion?
    @State private var preview: URL?

    var body: some View {
        List {
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(versions) { version in
                Button {
                    Task { await open(version) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.date.formatted(
                                .dateTime.day().month(.wide).year().hour().minute()
                            ))
                            .foregroundStyle(.primary)
                            Text(Recovery.size(version.size))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if busy == version.id {
                            ProgressView()
                        } else {
                            Image(systemName: "eye").foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        pending = version
                    } label: {
                        Label("Wiederherstellen", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.green)
                }
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading {
                ProgressView("Lade Verlauf …")
            } else if versions.isEmpty && message == nil {
                ContentUnavailableView(
                    "Noch keine früheren Fassungen",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Spind sichert eine Fassung, bevor eine Datei "
                                      + "überschrieben oder gelöscht wird.")
                )
            }
        }
        .refreshable { await load() }
        .task { if versions.isEmpty { await load() } }
        .quickLookSheet($preview)
        .confirmationDialog(
            "Diese Fassung wiederherstellen?",
            isPresented: Binding(
                get: { pending != nil }, set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Wiederherstellen") {
                if let version = pending { Task { await restore(version) } }
                pending = nil
            }
            Button("Abbrechen", role: .cancel) { pending = nil }
        } message: {
            Text(wasDeleted
                 ? "Die Datei kommt an ihren alten Platz zurück – auf allen Geräten."
                 : "Die aktuelle Fassung wird vorher gesichert – du kannst also "
                   + "jederzeit zurück.")
        }
    }

    private func load() async {
        loading = true
        message = nil
        do {
            versions = try await Recovery.withClient(config) { client, config in
                await VersionStore.list(
                    relativePath: path, client: client, config: config
                )
            }
        } catch {
            message = connectionHint(for: error)
        }
        loading = false
    }

    /// Downloads the version for a preview — under its real name, or the
    /// preview cannot tell what kind of file it is.
    private func open(_ version: FileVersion) async {
        busy = version.id
        defer { busy = nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent((path as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true
            )
            try await Recovery.withClient(config) { client, _ in
                try await client.download(version.remotePath, to: target)
            }
            preview = target
        } catch {
            message = connectionHint(for: error)
        }
    }

    private func restore(_ version: FileVersion) async {
        busy = version.id
        defer { busy = nil }
        do {
            try await Recovery.withClient(config) { client, config in
                try await VersionStore.restore(
                    version: version, relativePath: path,
                    remotePath: Recovery.remotePath(path, config),
                    client: client, config: config
                )
            }
            await SpindDomain.refresh()
            message = "Fassung vom \(Recovery.moment(version.date)) ist jetzt die aktuelle."
            await load()
        } catch {
            message = connectionHint(for: error)
        }
    }
}

// MARK: - Picking a file for the history

/// A plain look at the server, only to pick a file. Working with files
/// is what the Files app is for.
struct RemoteBrowserView: View {
    let config: SpindConfig
    var relative: String = ""

    @State private var entries: [RemoteItem] = []
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        List {
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(entries, id: \.path) { entry in
                let child = relative.isEmpty ? entry.name : relative + "/" + entry.name
                NavigationLink {
                    if entry.isDirectory {
                        RemoteBrowserView(config: config, relative: child)
                    } else {
                        VersionsView(config: config, path: child)
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            if !entry.isDirectory {
                                Text(Recovery.size(Int64(entry.size)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                            .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                    }
                }
            }
        }
        .navigationTitle(relative.isEmpty
                         ? "Versionsverlauf"
                         : (relative as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading {
                ProgressView()
            } else if entries.isEmpty && message == nil {
                ContentUnavailableView("Dieser Ordner ist leer", systemImage: "folder")
            }
        }
        .refreshable { await load() }
        .task { if entries.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        message = nil
        do {
            let items = try await Recovery.withClient(config) { client, config in
                try await client.listDirectory(Recovery.remotePath(relative, config))
            }
            entries = items
                .filter { !$0.name.hasPrefix(".") }
                .sorted {
                    $0.isDirectory == $1.isDirectory
                        ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        : $0.isDirectory
                }
        } catch {
            message = connectionHint(for: error)
        }
        loading = false
    }
}

// MARK: - Preview

extension View {
    /// Shows a downloaded version in the system preview.
    func quickLookSheet(_ url: Binding<URL?>) -> some View {
        sheet(isPresented: Binding(
            get: { url.wrappedValue != nil },
            set: { if !$0 { url.wrappedValue = nil } }
        )) {
            if let target = url.wrappedValue {
                QuickLookView(url: target).ignoresSafeArea()
            }
        }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController, previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
