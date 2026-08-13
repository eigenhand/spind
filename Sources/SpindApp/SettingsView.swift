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
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SpindCore

struct SettingsView: View {
    @ObservedObject var controller: SyncController

    var body: some View {
        TabView {
            ConnectionSettings(controller: controller)
                .tabItem { Label("Verbindung", systemImage: "network") }
            SharingSettings(controller: controller)
                .tabItem { Label("Teilen", systemImage: "link") }
            GeneralSettings(controller: controller)
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
        }
        .frame(width: 500)
    }
}

// MARK: - Verbindung

struct ConnectionSettings: View {
    @ObservedObject var controller: SyncController

    @State private var host = ""
    @State private var port = 23
    @State private var username = ""
    @State private var keyPath = "~/.ssh/spind_storagebox"
    @State private var remoteRoot = "."
    @State private var localRoot = "~/Spind"

    @State private var showingKeyPicker = false
    @State private var showingFolderPicker = false
    @State private var publicKeyCopied = false
    @State private var excludedPaths: [String] = []
    @State private var newExclusion = ""
    // Angepinnter Server-Schlüssel: bleibt erhalten, solange Host und Port
    // unverändert sind; bei neuem Ziel wird er verworfen und frisch geholt.
    @State private var loadedHostKey: String?
    @State private var loadedEndpoint = ""
    @State private var showingEnroll = ProcessInfo.processInfo.environment["SPIND_PREVIEW_ENROLL"] != nil
    @State private var enrollKey = ""
    @State private var enrollBusy = false
    @State private var enrollResult: String?
    @State private var pairingImage: NSImage?
    @State private var forOtherPerson = false
    @State private var personLabel = ""
    @State private var personFolder = ""
    @State private var personReadonly = false
    @State private var enrollStage: EnrollStage = .choose

    enum TestState: Equatable {
        case idle, running
        case success(String)
        case failure(String)
    }
    @State private var testState: TestState = .idle

    private var portValid: Bool { (1...65535).contains(port) }

    var body: some View {
        VStack(spacing: 0) {
            settingsForm
            Divider()
            actionBar
        }
        .frame(height: 580)
        .sheet(isPresented: $showingEnroll) { enrollSheet }
        .onAppear(perform: loadCurrent)
        .fileImporter(
            isPresented: $showingKeyPicker,
            allowedContentTypes: [.item]
        ) { result in
            if case .success(let url) = result { keyPath = url.path }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                localRoot = url.path
                if url.path == FileManager.default.homeDirectoryForCurrentUser.path,
                   !excludedPaths.contains("Downloads") {
                    excludedPaths.append("Downloads")
                }
            }
        }
    }

    /// Test und Speichern kleben am Fensterrand – sie dürfen nie aus dem
    /// Sichtfeld scrollen (DAU-Befund: „Wo speichere ich das jetzt?").
    private var actionBar: some View {
        HStack {
            Button {
                testConnection()
            } label: {
                HStack(spacing: 6) {
                    if testState == .running {
                        ProgressView().controlSize(.small)
                    }
                    Text("Verbindung testen")
                }
            }
            .disabled(testState == .running || host.isEmpty || username.isEmpty || !portValid)

            testResultView

            Spacer()

            Button("Speichern") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(host.isEmpty || username.isEmpty || !portValid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// QR-Kopplung. Eigenes Gerät: Schlüssel ans eigene Konto hängen, voller
    /// Zugriff. Andere Person: eigener Subaccount mit eigenem Ordner — sie
    /// sieht nur diesen, und der Zugang ist einzeln widerrufbar.
    private func makePairingCode() {
        enrollBusy = true
        enrollResult = nil
        Task {
            do {
                let config = currentConfig()
                let pair = SSHKeyGen.generate(
                    comment: forOtherPerson ? "spind-\(personLabel)" : "spind-geraet"
                )
                let code: PairingCode
                if forOtherPerson {
                    code = try await PersonEnrollment.createAccess(
                        folder: personFolder, label: personLabel,
                        readonly: personReadonly, pair: pair, config: config
                    )
                } else {
                    let client = StorageBoxClient(config: config)
                    try await client.connect()
                    try await DeviceEnrollment.addAuthorizedKey(pair.publicLine, client: client)
                    await client.disconnect()
                    code = PairingCode(config: config, pair: pair)
                }
                pairingImage = Self.qrImage(for: try code.encoded())
                enrollStage = .code
            } catch {
                enrollResult = "✗ \(error.localizedDescription)"
            }
            enrollBusy = false
        }
    }

    private static func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    enum EnrollStage { case choose, personDetails, code, paste }

    /// Eine Frage pro Bild: erst WER, dann Details, dann NUR der Code.
    private var enrollSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if enrollStage != .choose {
                    Button {
                        enrollStage = enrollStage == .code && forOtherPerson
                            ? .personDetails : .choose
                        pairingImage = nil
                        enrollResult = nil
                    } label: {
                        Label("Zurück", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Schließen") { closeEnroll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            switch enrollStage {
            case .choose: enrollChoose
            case .personDetails: enrollPersonDetails
            case .code: enrollCode
            case .paste: enrollPaste
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func closeEnroll() {
        showingEnroll = false
        enrollStage = .choose
        pairingImage = nil
        enrollResult = nil
        enrollKey = ""
    }

    private func choiceCard(
        symbol: String, tint: Color, title: String, subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if enrollBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(enrollBusy)
    }

    private var enrollChoose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wen möchtest du verbinden?")
                .font(.headline)
            choiceCard(
                symbol: "iphone", tint: .blue,
                title: "Mein eigenes Gerät",
                subtitle: "iPhone oder zweiter Mac – voller Zugriff auf alle deine Dateien."
            ) {
                forOtherPerson = false
                makePairingCode()
            }
            choiceCard(
                symbol: "person.badge.key", tint: .purple,
                title: "Eine andere Person",
                subtitle: "Bekommt einen eigenen Ordner und sieht nur diesen. Jederzeit widerrufbar."
            ) {
                forOtherPerson = true
                enrollStage = .personDetails
            }
            if let enrollResult {
                Text(enrollResult).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Ich habe schon einen Schlüssel zum Eintragen …") {
                enrollResult = nil
                enrollStage = .paste
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private var enrollPersonDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zugang für eine andere Person")
                .font(.headline)
            Text("Spind legt dafür einen eigenen Ordner und einen eigenen "
                 + "Zugang auf der Storage Box an.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $personLabel, prompt: Text("Anna"))
                TextField("Ordner", text: $personFolder, prompt: Text("Projekte/Anna"))
                Toggle("Darf nur lesen, nicht ändern", isOn: $personReadonly)
            }
            .formStyle(.columns)
            if let enrollResult {
                Text(enrollResult).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button {
                    makePairingCode()
                } label: {
                    HStack(spacing: 6) {
                        if enrollBusy { ProgressView().controlSize(.small) }
                        Text("Zugang anlegen")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(enrollBusy
                    || personLabel.trimmingCharacters(in: .whitespaces).isEmpty
                    || personFolder.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var enrollCode: some View {
        VStack(spacing: 14) {
            Text(forOtherPerson
                 ? "Zugang für »\(personLabel)« ist bereit"
                 : "Bereit zum Scannen")
                .font(.headline)
            if let pairingImage {
                Image(nsImage: pairingImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Auf dem neuen Gerät Spind öffnen", systemImage: "1.circle")
                Label("»Per QR-Code verbinden« antippen", systemImage: "2.circle")
                Label("Diesen Code scannen – fertig", systemImage: "3.circle")
            }
            .font(.callout)
            Label("Der Code ist ein Schlüssel: nur direkt vom Bildschirm "
                  + "scannen lassen, nicht verschicken oder speichern.",
                  systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Fertig") { closeEnroll() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    private var enrollPaste: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schlüssel eintragen")
                .font(.headline)
            Text("Für Geräte, die ihren Schlüssel selbst erzeugt haben: "
                 + "öffentlichen Schlüssel hier einfügen, Spind trägt ihn auf "
                 + "dem Server ein.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $enrollKey)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if let enrollResult {
                Text(enrollResult).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button {
                    enroll()
                } label: {
                    HStack(spacing: 6) {
                        if enrollBusy { ProgressView().controlSize(.small) }
                        Text("Eintragen")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(enrollBusy || enrollKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func enroll() {
        enrollBusy = true
        enrollResult = nil
        let line = enrollKey
        Task {
            do {
                let config = currentConfig()
                let client = StorageBoxClient(config: config)
                try await client.connect()
                let added = try await DeviceEnrollment.addAuthorizedKey(line, client: client)
                await client.disconnect()
                enrollResult = added
                    ? "✓ Eingetragen. Das neue Gerät verbindet sich jetzt mit: "
                      + "Adresse \(config.host), Benutzer \(config.username), Port \(config.port)."
                    : "Dieser Schlüssel ist bereits eingetragen – alles gut."
            } catch {
                enrollResult = "✗ \(error.localizedDescription)"
            }
            enrollBusy = false
        }
    }

    private var settingsForm: some View {
        Form {
            Section("Storage Box") {
                TextField("Host", text: $host, prompt: Text("u123456.your-storagebox.de"))
                    .textContentType(.URL)
                TextField("Benutzer", text: $username, prompt: Text("u123456 oder u123456-sub1"))
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .frame(maxWidth: 220)
                if !portValid {
                    Label("Der Port muss zwischen 1 und 65535 liegen – Storage Boxen nutzen 23.",
                          systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Privater Schlüssel") {
                    HStack(spacing: 8) {
                        Text((keyPath as NSString).abbreviatingWithTildeInPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Wählen …") { showingKeyPicker = true }
                            .controlSize(.small)
                    }
                }
                if let publicKey {
                    LabeledContent("Öffentlicher Schlüssel") {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(publicKey, forType: .string)
                            publicKeyCopied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                publicKeyCopied = false
                            }
                        } label: {
                            Label(
                                publicKeyCopied ? "Kopiert!" : "Kopieren",
                                systemImage: publicKeyCopied ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Authentifizierung")
            } footer: {
                Text("Spind verbindet sich ausschließlich per SSH-Schlüssel – ein Passwort wird nie gespeichert. Hinterlege den öffentlichen Schlüssel in der Hetzner Console bei deiner Storage Box (SSH-Support aktivieren).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Weitere Geräte") {
                    Button("Gerät verbinden …") { showingEnroll = true }
                        .controlSize(.small)
                }
            } footer: {
                Text("Verbindet z. B. dein iPhone: Dort in Spind den öffentlichen Schlüssel kopieren (wandert per Zwischenablage automatisch hierher), hier einfügen – fertig. Kein Console-Umweg, keine zweite Box.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ordner") {
                TextField("Verzeichnis auf der Box", text: $remoteRoot, prompt: Text(". (= alles)"))
                LabeledContent("Lokaler Sync-Ordner") {
                    HStack(spacing: 8) {
                        Text((localRoot as NSString).abbreviatingWithTildeInPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Wählen …") { showingFolderPicker = true }
                            .controlSize(.small)
                    }
                }
            }

            Section {
                ForEach(excludedPaths, id: \.self) { path in
                    HStack {
                        Image(systemName: "nosign")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(path).font(.callout)
                        Spacer()
                        Button {
                            excludedPaths.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Ordner ausschließen (z. B. Downloads)", text: $newExclusion)
                        .onSubmit(addExclusion)
                    Button("Hinzufügen", action: addExclusion)
                        .controlSize(.small)
                        .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Vom Sync ausgeschlossen")
            } footer: {
                Text("Pfade relativ zum Sync-Ordner. Wählst du deinen kompletten Benutzerordner, sind »Library« und »Applications« immer ausgeschlossen und »Downloads« wird automatisch vorgeschlagen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private func addExclusion() {
        var value = newExclusion.trimmingCharacters(in: .whitespaces)
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty, !excludedPaths.contains(value) else { return }
        excludedPaths.append(value)
        newExclusion = ""
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle, .running:
            EmptyView()
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var publicKey: String? {
        let path = ((keyPath + ".pub") as NSString).expandingTildeInPath
        return try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadCurrent() {
        guard let config = controller.config ?? (try? SpindConfig.load()) else { return }
        host = config.host
        port = config.port
        username = config.username
        keyPath = config.privateKeyPath
        remoteRoot = config.remoteRoot
        localRoot = config.localRoot
        excludedPaths = config.excludedPaths
        loadedHostKey = config.hostPublicKey
        loadedEndpoint = "\(config.host):\(config.port)"
    }

    private func currentConfig() -> SpindConfig {
        SpindConfig(
            host: host, port: port, username: username,
            privateKeyPath: keyPath, remoteRoot: remoteRoot, localRoot: localRoot,
            excludedPaths: excludedPaths,
            hostPublicKey: "\(host):\(port)" == loadedEndpoint ? loadedHostKey : nil
        )
    }

    private func testConnection() {
        testState = .running
        let config = currentConfig()
        Task {
            do {
                let client = StorageBoxClient(config: config)
                try await client.connect()
                let items = try await client.listDirectory(config.remoteRoot)
                await client.disconnect()
                await MainActor.run {
                    testState = .success("Verbindung steht – \(items.count) Einträge gefunden")
                }
            } catch {
                await MainActor.run {
                    testState = .failure(shortError(error))
                }
            }
        }
    }

    private func shortError(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("authent") { return "Authentifizierung fehlgeschlagen – Key hinterlegt?" }
        if text.contains("privateKeyUnreadable") || text.contains("Could not read") {
            return "Privater Schlüssel nicht lesbar"
        }
        if text.count > 80 { return String(text.prefix(80)) + "…" }
        return text
    }

    private func save() {
        do {
            try currentConfig().save()
            controller.reload()
            testState = .success("Gespeichert – gilt sofort, das Finder-Laufwerk ab dem nächsten App-Start")
        } catch {
            testState = .failure("Speichern fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}

// MARK: - Teilen

struct SharingSettings: View {
    @ObservedObject var controller: SyncController

    @State private var token = KeychainHelper.load(account: HetznerAPI.tokenAccount) ?? ""
    @State private var tokenState: String?
    @State private var checking = false
    @State private var docServer = UserDefaults.standard.string(forKey: "docServerURL") ?? ""
    @State private var shares: [HetznerAPI.Subaccount] = []
    @State private var sharesLoading = false
    @State private var sharesError: String?
    @State private var pendingRevoke: HetznerAPI.Subaccount?

    var body: some View {
        Form {
            if controller.config?.isHetznerBox == false {
                Section {
                    Label {
                        Text("Ordner-Freigaben und gemeinsames Bearbeiten nutzen "
                             + "die Subaccount-API der Hetzner Storage Box. Mit "
                             + "»\(controller.config?.host ?? "")« als Ziel stehen "
                             + "sie nicht zur Verfügung – Sync, Versionsverlauf "
                             + "und Finder-Laufwerk funktionieren uneingeschränkt.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.callout)
                }
            } else {
            Section {
                SecureField("Hetzner-API-Token", text: $token)
                HStack {
                    Button {
                        saveAndValidate()
                    } label: {
                        HStack(spacing: 6) {
                            if checking { ProgressView().controlSize(.small) }
                            Text("Speichern & Prüfen")
                        }
                    }
                    .disabled(token.isEmpty || checking)
                    if let tokenState {
                        Text(tokenState).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } header: {
                Text("Hetzner-API")
            } footer: {
                Text("Zum Teilen legt Spind schreibgeschützte WebDAV-Unterzugänge für einzelne Ordner an. Dafür wird ein API-Token benötigt: Hetzner Console → Projekt → Sicherheit → API-Tokens → „Lesen & Schreiben“. Der Token wird ausschließlich im macOS-Schlüsselbund gespeichert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(
                    "Collabora-Server", text: $docServer,
                    prompt: Text("https://doc.example.de")
                )
                .onSubmit(saveDocServer)
                HStack {
                    Button("Übernehmen", action: saveDocServer)
                        .controlSize(.small)
                        .disabled(docServer == (UserDefaults.standard.string(forKey: "docServerURL") ?? ""))
                    if WopiToken.isConfiguredForEditing {
                        Label("bereit", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else if !WopiToken.isConfigured {
                        Text("Schlüssel fehlt im Schlüsselbund")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } header: {
                Text("Gemeinsam bearbeiten")
            } footer: {
                Text("Optional. Mit einem eigenen Collabora-Server bekommen Office-Dokumente in Freigaben einen »Bearbeiten«-Knopf und lassen sich gleichzeitig von mehreren Personen bearbeiten. Die Einrichtung steht in server/collabora/README.md — ohne Server bleibt der Rest von Spind vollständig nutzbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if sharesLoading {
                    ProgressView().controlSize(.small)
                } else if let sharesError {
                    Text(sharesError).font(.caption).foregroundStyle(.secondary)
                } else if shares.isEmpty {
                    Text("Keine aktiven Freigaben")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shares, id: \.id) { share in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ShareManager.folderPath(fromDescription: share.description)
                                     ?? share.description)
                                    .font(.callout)
                                Text("\(share.username) · \(share.readonly ? "nur Lesen" : "Lesen & Schreiben")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Widerrufen") { revoke(share) }
                                .controlSize(.small)
                        }
                    }
                }
                Button("Aktualisieren") { loadShares() }
                    .controlSize(.small)
                    .disabled(sharesLoading)
            } header: {
                Text("Aktive Freigaben")
            } footer: {
                Text("Neue Freigabe: Rechtsklick auf einen Ordner im Spind-Volume → »Ordner teilen«. Die Zugangsdaten landen im Clipboard.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
        .onAppear { if controller.config?.isHetznerBox != false { loadShares() } }
        .confirmationDialog(
            "Freigabe widerrufen?",
            isPresented: Binding(
                get: { pendingRevoke != nil },
                set: { if !$0 { pendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Widerrufen", role: .destructive) {
                if let share = pendingRevoke { revoke(share) }
                pendingRevoke = nil
            }
            Button("Abbrechen", role: .cancel) { pendingRevoke = nil }
        } message: {
            Text("Alle bereits verschickten Links zu diesem Ordner hören sofort auf "
                 + "zu funktionieren. Die Dateien selbst bleiben unverändert.")
        }
    }

    private func saveDocServer() {
        var value = docServer.trimmingCharacters(in: .whitespaces)
        while value.hasSuffix("/") { value.removeLast() }
        docServer = value
        UserDefaults.standard.set(value, forKey: "docServerURL")
    }

    private func saveAndValidate() {
        checking = true
        tokenState = nil
        KeychainHelper.save(token, account: HetznerAPI.tokenAccount)
        let user = controller.config?.username ?? ""
        Task {
            do {
                let api = try HetznerAPI()
                let box = try await api.findBox(forUser: user)
                await MainActor.run {
                    tokenState = "✓ Verbunden – Box \(box.username)"
                    checking = false
                }
                loadShares()
            } catch {
                await MainActor.run {
                    tokenState = "✗ \(error.localizedDescription)"
                    checking = false
                }
            }
        }
    }

    private func loadShares() {
        sharesLoading = true
        sharesError = nil
        let user = controller.config?.username ?? ""
        Task {
            do {
                let list = try await ShareManager.activeShares(syncUser: user)
                await MainActor.run {
                    shares = list
                    sharesLoading = false
                }
            } catch {
                await MainActor.run {
                    sharesError = error.localizedDescription
                    shares = []
                    sharesLoading = false
                }
            }
        }
    }

    private func revoke(_ share: HetznerAPI.Subaccount) {
        let user = controller.config?.username ?? ""
        let config = controller.config
        sharesLoading = true
        Task {
            do {
                try await ShareManager.revoke(share, syncUser: user, config: config)
                sharesError = nil
            } catch {
                sharesError = "Widerrufen fehlgeschlagen: \(error.localizedDescription)"
            }
            controller.refreshSharedBadges()
            loadShares()
        }
    }
}

// MARK: - Allgemein

struct GeneralSettings: View {
    @ObservedObject var controller: SyncController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmRebuild = false
    @State private var freeing = false
    @State private var freeResult: String?

    var body: some View {
        Form {
            Section("Synchronisierung") {
                Toggle("Ordner-Sync (\(controller.config?.localRoot ?? "~/Spind"))",
                       isOn: $controller.folderSyncEnabled)
                Picker("Nach Änderungen auf der Box suchen", selection: $controller.pollInterval) {
                    Text("alle 15 Sekunden").tag(15)
                    Text("alle 30 Sekunden").tag(30)
                    Text("jede Minute").tag(60)
                    Text("alle 5 Minuten").tag(300)
                }
            }

            Section {
                Toggle("Platz automatisch freigeben", isOn: $controller.autoFreeEnabled)
                Picker("Freigeben, wenn ungenutzt seit", selection: $controller.autoFreeDays) {
                    Text("7 Tagen").tag(7)
                    Text("14 Tagen").tag(14)
                    Text("30 Tagen").tag(30)
                    Text("90 Tagen").tag(90)
                }
                .disabled(!controller.autoFreeEnabled)
                HStack {
                    Button {
                        freeing = true
                        freeResult = nil
                        Task {
                            freeResult = await controller.runStorageOptimizer(manual: true)
                            freeing = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if freeing { ProgressView().controlSize(.small) }
                            Text("Jetzt Speicher freigeben")
                        }
                    }
                    .disabled(freeing)
                    if let freeResult {
                        Text(freeResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } header: {
                Text("Speicher (Finder-Volume)")
            } footer: {
                Text("Lange ungenutzte Dateien werden lokal entfernt und bleiben als Cloud-Platzhalter im Finder sichtbar – beim Öffnen lädt Spind sie automatisch wieder. Dateien mit »Geladen behalten« (Rechtsklick im Finder) und nicht hochgeladene Änderungen sind ausgenommen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Gelöschte Dateien") {
                    Button("Wiederherstellen …") {
                        DeletedFilesWindowManager.open(controller: controller)
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Sicherheitsnetz")
            } footer: {
                Text("Vor jedem Überschreiben oder Löschen sichert Spind die aktuelle Fassung auf der Box. Der Verlauf wird mit der Zeit ausgedünnt: heute jede Fassung, diesen Monat eine pro Tag, dieses Jahr eine pro Woche, davor eine pro Monat. Gelöschtes lässt sich hier mit einem Klick zurückholen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System") {
                Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("Finder-Laufwerk") {
                    Button("Neu aufbauen …") { confirmRebuild = true }
                        .controlSize(.small)
                }
                LabeledContent("Updates") {
                    Button("Jetzt nach Updates suchen") {
                        UpdaterManager.shared.checkForUpdates()
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
        .confirmationDialog(
            "Finder-Laufwerk neu aufbauen?",
            isPresented: $confirmRebuild, titleVisibility: .visible
        ) {
            Button("Neu aufbauen") { controller.rebuildFinderVolume() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Spind startet dabei einmal neu und baut das Laufwerk frisch "
                 + "aus der Storage Box auf. Deine Dateien bleiben unberührt – "
                 + "nur »Auf dem Computer behalten«-Markierungen gehen verloren. "
                 + "Hilft, wenn das Laufwerk im Finder hängt oder fehlt.")
        }
    }
}
