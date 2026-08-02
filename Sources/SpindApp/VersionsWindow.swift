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

import SwiftUI
import AppKit
import SpindCore

/// Version history for one file: list, preview, restore.
@MainActor
enum VersionsWindowManager {
    private static var windows: [String: NSWindow] = [:]

    static func open(path: String, controller: SyncController) {
        if let window = windows[path] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = VersionsView(path: path, controller: controller) {
            windows[path]?.close()
            windows[path] = nil
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Versionen – \((path as NSString).lastPathComponent)"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        windows[path] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct VersionsView: View {
    let path: String
    @ObservedObject var controller: SyncController
    var dismiss: () -> Void

    @State private var versions: [FileVersion] = []
    @State private var loading = true
    @State private var busy: String?
    @State private var message: String?
    @State private var selection: FileVersion.ID?
    @State private var pendingRestore: FileVersion?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 420)
        .task { await load() }
        .confirmationDialog(
            "Diese Fassung wiederherstellen?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Wiederherstellen") {
                if let version = pendingRestore { Task { await restore(version) } }
                pendingRestore = nil
            }
            Button("Abbrechen", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Die aktuelle Fassung wird dabei als neue Version gesichert – "
                 + "du kannst also jederzeit zurück.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 17))
                    .foregroundStyle(.purple)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(loading ? "Lade Verlauf …" : "\(versions.count) frühere Fassungen")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if versions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("Noch keine früheren Fassungen")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Spind legt ab jetzt bei jeder Änderung automatisch eine Fassung an.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(versions, selection: $selection) { version in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.date.formatted(
                            .dateTime.day().month(.wide).year()
                                .hour().minute().second()
                        ))
                        .font(.callout)
                        Text(ByteCountFormatter.string(
                            fromByteCount: version.size, countStyle: .file
                        ))
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if busy == version.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Ansehen") { Task { await preview(version) } }
                            .controlSize(.small)
                        Button("Wiederherstellen") { pendingRestore = version }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 3)
                .tag(version.id)
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func withClient<T>(
        _ body: (StorageBoxClient, SpindConfig) async throws -> T
    ) async throws -> T {
        guard let config = controller.config else {
            throw CollaboraService.ServiceError.notConfigured
        }
        let client = StorageBoxClient(config: config)
        try await client.connect()
        defer { Task { await client.disconnect() } }
        return try await body(client, config)
    }

    private func load() async {
        loading = true
        do {
            versions = try await withClient { client, config in
                await VersionStore.list(relativePath: path, client: client, config: config)
            }
        } catch {
            message = "Verlauf nicht abrufbar: \(error.localizedDescription)"
        }
        loading = false
    }

    /// Downloads a version into a temp file and opens it — the current
    /// file stays untouched.
    private func preview(_ version: FileVersion) async {
        busy = version.id
        defer { busy = nil }
        let name = (path as NSString).lastPathComponent
        let stamp = version.date.formatted(.dateTime.year().month().day().hour().minute())
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: "-")
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("Spind-Versionen", isDirectory: true)
            .appendingPathComponent("\(stamp) – \(name)")
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try await withClient { client, _ in
                try await client.download(version.remotePath, to: target)
            }
            NSWorkspace.shared.open(target)
            message = "Fassung geöffnet (Kopie, ändert die Datei nicht)"
        } catch {
            message = "Ansehen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func restore(_ version: FileVersion) async {
        busy = version.id
        defer { busy = nil }
        do {
            try await withClient { client, config in
                var root = config.remoteRoot
                if root.hasSuffix("/") { root = String(root.dropLast()) }
                let remotePath = root.isEmpty ? path : root + "/" + path
                try await VersionStore.restore(
                    version: version, relativePath: path,
                    remotePath: remotePath, client: client, config: config
                )
            }
            controller.syncNow()
            message = "Wiederhergestellt – die vorherige Fassung wurde als neue Version gesichert"
            await load()
        } catch {
            message = "Wiederherstellen fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
