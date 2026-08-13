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

/// Small share dialog in cloud-drive style: shows whether the folder is already
/// shared, creates read-only or read-write shares, offers copyable links
/// and revocation.
@MainActor
enum ShareWindowManager {
    private static var windows: [String: NSWindow] = [:]

    static func open(folder: String, controller: SyncController) {
        if let window = windows[folder] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let name = folder.isEmpty ? "Spind" : (folder as NSString).lastPathComponent
        let view = ShareView(folder: folder, controller: controller) {
            windows[folder]?.close()
            windows[folder] = nil
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "„\(name)“ teilen"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        windows[folder] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ShareView: View {
    let folder: String
    @ObservedObject var controller: SyncController
    var dismiss: () -> Void

    enum Phase {
        case checking
        case notShared
        case creating
        case shared(ShareManager.ShareResult, readonly: Bool)
        case sharedWithoutPassword(HetznerAPI.Subaccount)
        case revoking
        case failed(String)
    }

    @State private var phase: Phase = .checking
    @State private var readonly = true
    @State private var copied: String?
    @State private var pendingAction: String?

    private var folderName: String {
        folder.isEmpty ? "/" : (folder as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
        .padding(20)
        .frame(width: 440)
        .task { await checkExisting() }
        .confirmationDialog(
            pendingAction == "regenerate" ? "Neuen Zugangslink erzeugen?"
                                          : "Freigabe widerrufen?",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingAction == "regenerate" ? "Neu erzeugen" : "Widerrufen",
                   role: .destructive) {
                let action = pendingAction
                pendingAction = nil
                Task { action == "regenerate" ? await regenerate() : await revoke() }
            }
            Button("Abbrechen", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction == "regenerate"
                 ? "Der bisherige Link wird dabei ungültig. Wer ihn hat, kommt nicht mehr hinein."
                 : "Alle bereits verschickten Links hören sofort auf zu funktionieren. "
                   + "Die Dateien selbst bleiben unverändert.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(folderName)
                    .font(.system(size: 15, weight: .semibold))
                statusBadge
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch phase {
        case .shared(_, let readonly):
            Label(readonly ? "Geteilt · nur Lesen" : "Geteilt · Lesen & Schreiben",
                  systemImage: "link")
                .font(.caption)
                .foregroundStyle(.green)
        case .sharedWithoutPassword(let sub):
            Label(sub.readonly ? "Geteilt · nur Lesen" : "Geteilt · Lesen & Schreiben",
                  systemImage: "link")
                .font(.caption)
                .foregroundStyle(.green)
        default:
            Text("Nicht geteilt")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Prüfe Freigabe-Status …")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)

        case .notShared:
            VStack(alignment: .leading, spacing: 12) {
                Picker("Zugriff", selection: $readonly) {
                    Text("Nur Lesen").tag(true)
                    Text("Lesen & Schreiben").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(readonly
                     ? "Empfänger können Dateien ansehen und herunterladen – über den Link im Browser oder als eingebundenes Laufwerk."
                     : "Empfänger können Dateien auch ändern und hochladen. Bearbeiten funktioniert über die Laufwerk-Einbindung (Finder: ⌘K / Windows-Explorer); die Web-Ansicht bleibt lesend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Abbrechen") { dismiss() }
                    Button("Freigabe erstellen") { Task { await create() } }
                        .buttonStyle(.borderedProminent)
                }
            }

        case .creating:
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Erstelle Freigabe …")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Der Freigabe-Server wird eingerichtet – das kann bis zu zwei Minuten dauern. Der Link erscheint, sobald er wirklich erreichbar ist.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)

        case .shared(let result, _):
            VStack(alignment: .leading, spacing: 10) {
                copyRow(
                    label: "Link (öffnet die Freigabe-Seite)",
                    value: result.directLink, key: "link"
                )
                copyRow(label: "Benutzer", value: result.username, key: "user")
                copyRow(label: "Passwort", value: result.password, key: "pass")
                Button {
                    ShareManager.copyToClipboard(result.clipboardText)
                    flashCopied("all")
                } label: {
                    Label(copied == "all" ? "Kopiert!" : "Alles kopieren (mit Anleitung)",
                          systemImage: copied == "all" ? "checkmark" : "doc.on.doc")
                }
                Divider()
                HStack {
                    Button(role: .destructive) {
                        pendingAction = "revoke"
                    } label: {
                        Text("Freigabe widerrufen")
                    }
                    Spacer()
                    Button("Fertig") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }

        case .sharedWithoutPassword:
            VStack(alignment: .leading, spacing: 12) {
                Text("Dieser Ordner ist bereits geteilt. Das Passwort wurde auf diesem Gerät nicht gespeichert – erzeuge einen neuen Zugangslink, um ihn erneut weiterzugeben.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(role: .destructive) {
                        pendingAction = "revoke"
                    } label: {
                        Text("Freigabe widerrufen")
                    }
                    Spacer()
                    Button("Neuen Zugangslink erzeugen") {
                        pendingAction = "regenerate"
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        case .revoking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Widerrufe Freigabe …")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    // Avoid dead ends: if the API token is missing, the
                    // button leads straight to where it is entered.
                    if message.contains("API-Token") {
                        Button("Einstellungen öffnen") {
                            NSApp.sendAction(
                                Selector(("showSettingsWindow:")), to: nil, from: nil
                            )
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    Spacer()
                    Button("Schließen") { dismiss() }
                    Button("Erneut versuchen") {
                        phase = .checking
                        Task { await checkExisting() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func copyRow(label: String, value: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary.opacity(0.5))
                    )
                Button {
                    ShareManager.copyToClipboard(value)
                    flashCopied(key)
                } label: {
                    Image(systemName: copied == key ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Kopieren")
            }
        }
    }

    private func flashCopied(_ key: String) {
        copied = key
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == key { copied = nil }
        }
    }

    // MARK: - Actions

    private func checkExisting() async {
        // Shares are created through the storage box subaccount API — a
        // general SFTP server has no such mechanism.
        guard controller.config?.isHetznerBox != false else {
            phase = .failed(
                "Ordner-Freigaben gibt es nur mit einer Hetzner Storage Box. "
                + "Dein Ziel »\(controller.config?.host ?? "")« ist ein "
                + "allgemeiner SFTP-Server – Sync, Versionen und "
                + "Finder-Laufwerk funktionieren dort uneingeschränkt."
            )
            return
        }
        let user = controller.config?.username ?? ""
        do {
            if let existing = try await ShareManager.findShare(folder: folder, syncUser: user) {
                if let password = KeychainHelper.load(account: "share-pass-\(existing.username)") {
                    let server = existing.server
                    phase = .shared(ShareManager.ShareResult(
                        folder: folderName, server: server,
                        username: existing.username, password: password
                    ), readonly: existing.readonly)
                } else {
                    phase = .sharedWithoutPassword(existing)
                }
            } else {
                phase = .notShared
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func create() async {
        phase = .creating
        let user = controller.config?.username ?? ""
        let config = controller.config
        do {
            let result = try await ShareManager.createShare(
                folderRelativePath: folder, syncUser: user,
                config: config, readonly: readonly
            )
            controller.noteShareCreated(folderName)
            await ShareManager.waitUntilReachable(result)
            phase = .shared(result, readonly: readonly)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func revoke() async {
        guard let existing = try? await ShareManager.findShare(
            folder: folder, syncUser: controller.config?.username ?? ""
        ) else {
            phase = .notShared
            return
        }
        phase = .revoking
        do {
            try await ShareManager.revoke(
                existing, syncUser: controller.config?.username ?? "",
                config: controller.config
            )
            KeychainHelper.delete(account: "share-pass-\(existing.username)")
            controller.refreshSharedBadges()
            phase = .notShared
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func regenerate() async {
        await revoke()
        if case .notShared = phase {
            await create()
        }
    }
}
