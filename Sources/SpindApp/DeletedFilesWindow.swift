// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import SpindCore

/// Recovery for deleted files: everything that still has versions in the
/// history but no live counterpart, restorable with one click.
@MainActor
enum DeletedFilesWindowManager {
    private static var window: NSWindow?

    static func open(controller: SyncController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DeletedFilesView(controller: controller) {
            window?.close()
            window = nil
        }
        let created = NSWindow(contentViewController: NSHostingController(rootView: view))
        created.title = "Gelöschte Dateien"
        created.styleMask = [.titled, .closable, .resizable]
        created.isReleasedWhenClosed = false
        created.center()
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct DeletedFilesView: View {
    @ObservedObject var controller: SyncController
    var dismiss: () -> Void

    @State private var deleted: [VersionStore.DeletedFile] = []
    @State private var loading = true
    @State private var busy: String?
    @State private var message: String?
    @State private var pendingRestore: VersionStore.DeletedFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 440)
        .task { await load() }
        .confirmationDialog(
            "»\((pendingRestore?.relativePath as NSString?)?.lastPathComponent ?? "")« wiederherstellen?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Wiederherstellen") {
                if let file = pendingRestore { Task { await restore(file) } }
                pendingRestore = nil
            }
            Button("Abbrechen", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Die letzte gesicherte Fassung kommt an ihren alten Platz zurück und wird beim nächsten Abgleich auch wieder lokal angelegt.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Gelöschte Dateien")
                    .font(.system(size: 14, weight: .semibold))
                Text(loading
                     ? "Durchsuche den Verlauf …"
                     : "\(deleted.count) wiederherstellbar")
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
        } else if deleted.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("Nichts zu retten – alles an seinem Platz")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Wird eine Datei gelöscht, die schon mal gesichert wurde, taucht sie hier auf und lässt sich zurückholen.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(deleted) { file in
                HStack(spacing: 10) {
                    Image(systemName: symbolForFile(
                        (file.relativePath as NSString).lastPathComponent
                    ))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((file.relativePath as NSString).lastPathComponent)
                            .font(.callout)
                            .lineLimit(1).truncationMode(.middle)
                        Text(rowSubtitle(file))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if busy == file.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Wiederherstellen") { pendingRestore = file }
                            .controlSize(.small)
                        if file.versionCount > 1 {
                            Button("Alle Fassungen …") {
                                VersionsWindowManager.open(
                                    path: file.relativePath, controller: controller
                                )
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
    }

    private func rowSubtitle(_ file: VersionStore.DeletedFile) -> String {
        var parts: [String] = []
        let folder = (file.relativePath as NSString).deletingLastPathComponent
        if !folder.isEmpty { parts.append(folder) }
        parts.append(file.latest.date.formatted(
            .dateTime.day().month(.abbreviated).hour().minute()
        ))
        parts.append(ByteCountFormatter.string(
            fromByteCount: file.latest.size, countStyle: .file
        ))
        if file.versionCount > 1 { parts.append("\(file.versionCount) Fassungen") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Aktualisieren") { Task { await load() } }
                .disabled(loading)
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
        message = nil
        do {
            deleted = try await withClient { client, config in
                await VersionStore.listDeleted(client: client, config: config)
            }
        } catch {
            message = "Verlauf nicht abrufbar: \(error.localizedDescription)"
        }
        loading = false
    }

    private func restore(_ file: VersionStore.DeletedFile) async {
        busy = file.id
        defer { busy = nil }
        do {
            try await withClient { client, config in
                var root = config.remoteRoot
                if root.hasSuffix("/") { root = String(root.dropLast()) }
                let remotePath = root.isEmpty
                    ? file.relativePath
                    : root + "/" + file.relativePath
                try await VersionStore.restore(
                    version: file.latest, relativePath: file.relativePath,
                    remotePath: remotePath, client: client, config: config
                )
            }
            controller.syncNow()
            message = "»\((file.relativePath as NSString).lastPathComponent)« wiederhergestellt"
            await load()
        } catch {
            message = "Wiederherstellen fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
