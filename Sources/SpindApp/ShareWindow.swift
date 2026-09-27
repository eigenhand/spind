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

import SwiftUI
import AppKit
import SpindCore

/// Small share dialog in cloud-drive style: shows whether the folder is already
/// shared, creates read-only or read-write shares with an expiry, offers the
/// link and the credentials as two equal choices, extends and revokes.
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
        case notShared(used: Int)
        case creating
        case shared(ShareManager.ShareResult, HetznerAPI.Subaccount, used: Int)
        /// Credentials are neither in this Mac's Keychain nor in the folder.
        case sharedWithoutPassword(HetznerAPI.Subaccount, used: Int)
        case working(String)
        case failed(String)
    }

    /// Picker tag; 0 stands for "until revoked" because SwiftUI tags
    /// want a plain value.
    private static let untilRevoked = 0

    @State private var phase: Phase = .checking
    @State private var readonly = true
    @State private var validityDays = ShareRules.defaultValidityDays
    @State private var copied: String?
    @State private var pendingAction: String?

    private var folderName: String {
        folder.isEmpty ? "/" : (folder as NSString).lastPathComponent
    }

    private var syncUser: String { controller.config?.username ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
        .padding(20)
        .frame(width: 460)
        .task { await checkExisting() }
        .confirmationDialog(
            pendingAction == "reset" ? "Neues Passwort erzeugen?" : "Freigabe widerrufen?",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingAction == "reset" ? "Neues Passwort" : "Widerrufen",
                   role: .destructive) {
                let action = pendingAction
                pendingAction = nil
                Task { action == "reset" ? await resetPassword() : await revoke() }
            }
            Button("Abbrechen", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction == "reset"
                 ? "Der bisherige Link hört sofort auf zu funktionieren; wer ihn hat, braucht den neuen. Die Freigabe selbst und ihr Ablaufdatum bleiben."
                 : "Alle bereits verschickten Links hören sofort auf zu funktionieren. Die Dateien selbst bleiben unverändert.")
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
        case .shared(_, let share, _), .sharedWithoutPassword(let share, _):
            Label(share.readonly ? "Geteilt · nur Lesen" : "Geteilt · Lesen & Schreiben",
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

        case .notShared(let used):
            notSharedContent(used: used)

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

        case .shared(let result, let share, let used):
            sharedContent(result: result, share: share, used: used)

        case .sharedWithoutPassword(_, let used):
            VStack(alignment: .leading, spacing: 12) {
                Text("Dieser Ordner ist bereits geteilt, aber die Zugangsdaten sind weder auf diesem Mac noch im Ordner auf der Box auffindbar. Ein neues Passwort macht den bisherigen Link ungültig; die Freigabe selbst und ihr Ablaufdatum bleiben.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                usageLine(used: used)
                HStack {
                    Button(role: .destructive) {
                        pendingAction = "revoke"
                    } label: {
                        Text("Freigabe widerrufen")
                    }
                    Spacer()
                    Button("Neues Passwort erzeugen") {
                        pendingAction = "reset"
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        case .working(let message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message)
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

    private func notSharedContent(used: Int) -> some View {
        let full = ShareRules.remainingSlots(used: used) == 0
        return VStack(alignment: .leading, spacing: 12) {
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
            Picker("Gültig", selection: $validityDays) {
                ForEach(ShareRules.validityChoices, id: \.self) { choice in
                    validityLabel(choice).tag(choice ?? Self.untilRevoked)
                }
            }
            Text(validityDays == Self.untilRevoked
                 ? "Die Freigabe bleibt, bis du sie widerrufst. Jede Freigabe belegt eines von \(ShareRules.subaccountLimit) Unterkonten der Box."
                 : "Danach wird die Freigabe entfernt, sobald Spind läuft. Verlängern geht jederzeit, ohne dass der Link sich ändert.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            usageLine(used: used)
            if full {
                Label("Die Box hat keine freien Unterkonten mehr. Widerrufe eine Freigabe, die nicht mehr gebraucht wird.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Freigabe erstellen") { Task { await create() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(full)
            }
        }
    }

    private func sharedContent(
        result: ShareManager.ShareResult, share: HetznerAPI.Subaccount, used: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            copyRow(label: "Link (öffnet die Freigabe-Seite)", value: result.directLink, key: "link")
            Text("Der Link enthält das Passwort. Ein Messenger reicht es an seine Link-Vorschau weiter, und beim Empfänger bleibt es im Browser-Verlauf.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            copyRow(label: "Adresse", value: result.address, key: "address")
            copyRow(label: "Benutzer", value: result.username, key: "user")
            copyRow(label: "Passwort", value: result.password, key: "pass")
            // Two equal choices: the sensitivity differs per share, so the
            // decision belongs to the user, per share — not to a default
            // that the everyday case would work around anyway.
            HStack(spacing: 8) {
                Button {
                    ShareManager.copyToClipboard(result.linkText)
                    flashCopied("linkText")
                } label: {
                    Label(copied == "linkText" ? "Kopiert!" : "Link kopieren",
                          systemImage: copied == "linkText" ? "checkmark" : "link")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    ShareManager.copyToClipboard(result.credentialsText)
                    flashCopied("credentials")
                } label: {
                    Label(copied == "credentials" ? "Kopiert!" : "Zugangsdaten getrennt kopieren",
                          systemImage: copied == "credentials" ? "checkmark" : "key")
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            expiryLine(result: result, share: share)
            checkLine
            usageLine(used: used)
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
    }

    private func expiryLine(
        result: ShareManager.ShareResult, share: HetznerAPI.Subaccount
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let expiresOn = result.expiresOn {
                let day = expiresOn.formatted(date: .long, time: .omitted)
                Label("Wird ab dem \(day) entfernt, sobald Spind läuft.", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Gültig, bis du die Freigabe widerrufst.", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Nothing to extend on an open-ended share; shortening is
            // what "revoke" is for.
            if result.expiresOn != nil {
                Menu("Verlängern") {
                    ForEach(ShareRules.validityChoices, id: \.self) { choice in
                        Button {
                            Task { await extend(share, validFor: choice) }
                        } label: {
                            validityLabel(choice)
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    /// The expiry is only as good as the last check — no Mac running, no
    /// enforcement. Shown here, not buried in a document.
    private var checkLine: some View {
        let check = ShareManager.lastCheck
        return Group {
            if let error = check.error {
                let since = check.failingSince.map { relative($0) } ?? ""
                Label("Prüfung schlägt fehl, erstmals \(since): \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let date = check.date {
                Label("Ablauf zuletzt geprüft \(relative(date)) – von diesem Mac.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Ablauf noch nicht geprüft – Spind prüft ihn stündlich, solange es läuft.", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func usageLine(used: Int) -> some View {
        Text("\(used) von \(ShareRules.subaccountLimit) Unterkonten der Box belegt – Freigaben, verbundene Zugänge und Collabora zusammen.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func validityLabel(_ days: Int?) -> some View {
        switch days {
        case 30: Text("30 Tage")
        case 90: Text("90 Tage")
        case 365: Text("1 Jahr")
        case .some(let other): Text("\(other) Tage")
        case nil: Text("Bis zum Widerruf")
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func copyRow(label: LocalizedStringKey, value: String, key: String) -> some View {
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
        do {
            let lookup = try await ShareManager.lookup(folder: folder, syncUser: syncUser)
            guard let existing = lookup.share else {
                phase = .notShared(used: lookup.subaccountsUsed)
                return
            }
            var password = KeychainHelper.load(
                account: ShareManager.keychainAccount(for: existing.username)
            )
            if password == nil, let config = controller.config {
                // Made on another Mac: the page in the folder has them.
                password = await ShareManager.recoverPassword(existing, config: config)
            }
            if let password {
                phase = .shared(ShareManager.ShareResult(
                    folder: folderName, server: existing.server,
                    username: existing.username, password: password,
                    writable: !existing.readonly, expiresOn: existing.expiresOn
                ), existing, used: lookup.subaccountsUsed)
            } else {
                phase = .sharedWithoutPassword(existing, used: lookup.subaccountsUsed)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func create() async {
        phase = .creating
        let config = controller.config
        let days: Int? = validityDays == Self.untilRevoked ? nil : validityDays
        do {
            let result = try await ShareManager.createShare(
                folderRelativePath: folder, syncUser: syncUser,
                config: config, readonly: readonly, validFor: days
            )
            controller.noteShareCreated(folderName)
            await ShareManager.waitUntilReachable(result)
            // Re-read so the window shows what the box now holds.
            await checkExisting()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func extend(_ share: HetznerAPI.Subaccount, validFor days: Int?) async {
        phase = .working("Verlängere Freigabe …")
        do {
            try await ShareManager.extend(
                share, validFor: days, syncUser: syncUser, config: controller.config
            )
            await checkExisting()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func resetPassword() async {
        guard case .sharedWithoutPassword(let share, _) = phase else { return }
        phase = .working("Erzeuge neues Passwort …")
        do {
            let result = try await ShareManager.resetPassword(
                share, syncUser: syncUser, config: controller.config
            )
            await ShareManager.waitUntilReachable(result, timeout: 30)
            await checkExisting()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func revoke() async {
        guard let existing = try? await ShareManager.findShare(
            folder: folder, syncUser: syncUser
        ) else {
            await checkExisting()
            return
        }
        phase = .working("Widerrufe Freigabe …")
        do {
            try await ShareManager.revoke(
                existing, syncUser: syncUser, config: controller.config
            )
            controller.refreshSharedBadges()
            await checkExisting()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
