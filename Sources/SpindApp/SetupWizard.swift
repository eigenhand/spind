// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import SpindCore

/// Guided first-time setup.
///
/// Without it, anyone who does not use a terminal fails: the SSH key has
/// to exist before anything works at all, and "Choose …" can only pick
/// what is already there. So the assistant creates it itself and leads
/// step by step to a tested connection.
@MainActor
enum SetupWizardManager {
    private static var window: NSWindow?

    static func open(controller: SyncController) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SetupWizardView(controller: controller) {
            window?.close()
            window = nil
        }
        let hosting = NSHostingController(rootView: view)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Spind einrichten"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SetupWizardView: View {
    @ObservedObject var controller: SyncController
    var dismiss: () -> Void

    @State private var step = 0
    @State private var keyPath = "~/.ssh/spind_storagebox"
    @State private var publicKey = ""
    @State private var keyBusy = false
    @State private var keyMessage: String?
    @State private var copied = false

    @State private var host = ""
    @State private var user = ""
    @State private var port = 22
    @State private var portEdited = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    @State private var localRoot = NSHomeDirectory() + "/Spind"
    @State private var showingFolderPicker = false

    private let titles = [
        String(localized: "Willkommen"), String(localized: "Schlüssel"),
        String(localized: "Verbindung"), String(localized: "Ordner"),
        String(localized: "Fertig"),
    ]
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(22) }
                .frame(height: 330)
            Divider()
            footer
        }
        .frame(width: 540)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.15, green: 0.45, blue: 0.95),
                                 Color(red: 0.25, green: 0.75, blue: 0.95)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Spind einrichten").font(.system(size: 15, weight: .semibold))
                Text("Schritt \(step + 1) von \(titles.count) · \(titles[step])")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcomeStep
        case 1: keyStep
        case 2: connectionStep
        case 3: folderStep
        default: doneStep
        }
    }

    /// The assistant does not simply stop: it says what exists now, where
    /// it lives and what the next sensible move would be.
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Eingerichtet – Spind läuft", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green).font(.callout.weight(.semibold))
            Label {
                Text("Oben in der **Menüleiste** wohnt Spind ab jetzt – ein Klick zeigt Status, Übertragungen und Aktivität.")
            } icon: { Image(systemName: "menubar.arrow.up.rectangle") }
            Label {
                Text("Im Finder erscheint das Laufwerk **Spind** in der Seitenleiste – beim ersten Mal kann das eine Minute dauern. Dateien dort belegen erst Platz, wenn du sie öffnest.")
            } icon: { Image(systemName: "sidebar.left") }
            Label {
                Text("**Rechtsklick** auf Dateien und Ordner im Spind-Laufwerk: Ordner teilen, Versionsverlauf, auf dem Computer behalten, Platz freigeben.")
            } icon: { Image(systemName: "cursorarrow.click.2") }
            Label {
                Text("Spind startet ab jetzt **automatisch bei der Anmeldung** – abstellbar in den Einstellungen.")
            } icon: { Image(systemName: "power") }
            Label {
                Text("Zum **Teilen** brauchst du einmalig einen Hetzner-API-Token – der Weg dorthin steht in Einstellungen → Teilen.")
            } icon: { Image(systemName: "link") }
        }
        .labelStyle(WizardHintLabelStyle())
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Spind verbindet deinen Mac mit deinem eigenen Speicher – wie ein Cloud-Laufwerk, nur ohne fremde Cloud.")
            Text("Was du brauchst:").font(.callout.weight(.semibold))
            Label("Eine Hetzner Storage Box – oder einen beliebigen Server, "
                  + "der SFTP spricht", systemImage: "externaldrive")
            Label("Bei der Storage Box aktiviert: SSH-Zugang und externe "
                  + "Erreichbarkeit (Hetzner Console)", systemImage: "network")
            Text("Ordner-Freigaben und gemeinsames Bearbeiten gibt es nur mit einer Storage Box – Sync, Versionen und Finder-Laufwerk funktionieren mit jedem Server. Den Rest übernehme ich.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Hetzner Console öffnen",
                 destination: URL(string: "https://console.hetzner.com")!)
        }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Spind meldet sich mit einem Schlüsselpaar an, nicht mit einem Passwort. Das ist sicherer, und dein Box-Passwort bleibt unangetastet.")
                .fixedSize(horizontal: false, vertical: true)

            if publicKey.isEmpty {
                HStack {
                    Button {
                        generateKey()
                    } label: {
                        HStack(spacing: 6) {
                            if keyBusy { ProgressView().controlSize(.small) }
                            Text("Schlüsselpaar jetzt erzeugen")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyBusy)
                    Text("wird abgelegt unter \(keyPath)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Schlüssel liegt bereit", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
                Text("Jetzt den öffentlichen Teil in der Hetzner Console bei deiner Storage Box hinterlegen – dort unter »SSH-Schlüssel«.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(publicKey)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(3).truncationMode(.middle)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(publicKey, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Kopiert!" : "Schlüssel kopieren",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    Link("Hetzner Console öffnen",
                         destination: URL(string: "https://console.hetzner.com")!)
                }
            }
            if let keyMessage {
                Text(keyMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Für die Storage Box stehen die Angaben in der Hetzner Console; bei einem eigenen Server kennst du sie selbst.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Adresse", text: $host,
                          prompt: Text("u123456.your-storagebox.de oder sftp.example.org"))
                    .onChange(of: host) { _, newValue in
                        // Automatic port as long as nobody intervenes:
                        // Storage Box 23, alle anderen 22.
                        if !portEdited {
                            port = SpindConfig.defaultPort(forHost:
                                newValue.trimmingCharacters(in: .whitespaces))
                        }
                    }
                TextField("Benutzername", text: $user, prompt: Text("u123456"))
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .onChange(of: port) { _, newValue in
                        if newValue != SpindConfig.defaultPort(forHost:
                            host.trimmingCharacters(in: .whitespaces)) {
                            portEdited = true
                        }
                    }
                    .frame(maxWidth: 180)
            }
            .formStyle(.columns)
            HStack(spacing: 10) {
                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().controlSize(.small) }
                        Text("Verbindung testen")
                    }
                }
                .disabled(testing || host.isEmpty || user.isEmpty)
                if let testResult {
                    Label(testResult.text,
                          systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(testResult.ok ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Zuletzt: Wo sollen die Dateien auf deinem Mac liegen? Dieser Ordner wird mit der Storage Box abgeglichen.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text((localRoot as NSString).abbreviatingWithTildeInPath)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Wählen …") { showingFolderPicker = true }
            }
            Text("Zusätzlich erscheint Spind als Laufwerk in der Finder-Seitenleiste. Dort liegen alle Dateien, belegen aber erst Platz, wenn du sie öffnest.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { localRoot = url.path }
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 && step < 4 {
                Button("Zurück") { step -= 1 }
            }
            Spacer()
            if step < 4 {
                Button("Später") { dismiss() }
            }
            Button(buttonTitle) {
                switch step {
                case 3: finish()
                case 4: dismiss()
                default: step += 1
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue || saving)
        }
        .padding(14)
    }

    private var buttonTitle: String {
        switch step {
        case 3: return saving ? "Speichere …" : "Einrichten"
        case 4: return "Los geht's"
        default: return "Weiter"
        }
    }

    private var canContinue: Bool {
        switch step {
        case 1: return !publicKey.isEmpty
        case 2: return testResult?.ok == true
        default: return true
        }
    }

    // MARK: - Actions

    private func generateKey() {
        keyBusy = true
        keyMessage = nil
        let expanded = (keyPath as NSString).expandingTildeInPath
        Task.detached {
            let existingPublic = try? String(
                contentsOfFile: expanded + ".pub", encoding: .utf8
            )
            if let existingPublic, !existingPublic.isEmpty {
                await MainActor.run {
                    publicKey = existingPublic.trimmingCharacters(in: .whitespacesAndNewlines)
                    keyMessage = "Ein Schlüssel war bereits vorhanden und wird weiterverwendet."
                    keyBusy = false
                }
                return
            }
            let directory = (expanded as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = [
                "-t", "ed25519", "-f", expanded, "-N", "", "-C", "spind",
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let created = try? String(contentsOfFile: expanded + ".pub", encoding: .utf8)
            await MainActor.run {
                if let created, !created.isEmpty {
                    publicKey = created.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    keyMessage = "Der Schlüssel konnte nicht erzeugt werden. "
                        + "Prüfe die Schreibrechte für \(directory)."
                }
                keyBusy = false
            }
        }
    }

    private func testConnection() {
        testing = true
        testResult = nil
        let config = SpindConfig(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: user.trimmingCharacters(in: .whitespaces),
            privateKeyPath: keyPath, remoteRoot: ".", localRoot: localRoot
        )
        Task {
            do {
                let client = StorageBoxClient(config: config)
                try await client.connect()
                let items = try await client.listDirectory(".")
                await client.disconnect()
                testResult = (true, "Verbindung steht – \(items.count) Einträge gefunden")
            } catch {
                testResult = (false, hint(for: error))
            }
            testing = false
        }
    }

    /// Translate errors into instructions instead of passing them on.
    private func hint(for error: Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("authent") {
            return "Anmeldung abgelehnt. Ist der Schlüssel aus Schritt 2 in der "
                + "Hetzner Console hinterlegt und SSH für den Zugang aktiviert?"
        }
        if text.contains("privatekeyunreadable") {
            return "Der Schlüssel wurde nicht gefunden. Gehe zurück zu Schritt 2."
        }
        if text.contains("timed out") || text.contains("connection refused")
            || text.contains("network") {
            return "Keine Verbindung. Prüfe die Adresse und ob »externe "
                + "Erreichbarkeit« in der Hetzner Console aktiv ist."
        }
        return "Verbindung fehlgeschlagen: \(error.localizedDescription)"
    }

    private func finish() {
        saving = true
        var config = SpindConfig(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: user.trimmingCharacters(in: .whitespaces),
            privateKeyPath: keyPath, remoteRoot: ".", localRoot: localRoot
        )
        Task {
            // Pin the host key right at setup — from now on any other
            // key is refused.
            config.hostPublicKey = try? await HostKey.scan(
                host: config.host, port: config.port
            )
            try? config.save()
            controller.reload()
            saving = false
            step = 4
        }
    }
}

/// Rows of the closing screen: symbol aligned to the top, text multi-line.
struct WizardHintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon
                .frame(width: 20)
                .foregroundStyle(.blue)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
