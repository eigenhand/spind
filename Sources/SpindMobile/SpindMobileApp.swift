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

import BackgroundTasks
import SwiftUI
import FileProvider
import SpindCore

let appGroupID = (Bundle.main.object(forInfoDictionaryKey: "SpindAppGroup") as? String)
    ?? "group.dev.eigenhand.spind"

/// Konfiguration und Schlüssel wohnen in der App-Gruppe — nur dort kommt
/// auch die File-Provider-Extension heran.
enum MobileStore {
    static var directory: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )?.appendingPathComponent("spind", isDirectory: true)
    }
    static var configURL: URL? { directory?.appendingPathComponent("config.json") }
    static var keyURL: URL? { directory?.appendingPathComponent("key") }
    static var publicKeyURL: URL? { directory?.appendingPathComponent("key.pub") }

    static func loadConfig() -> SpindConfig? {
        guard let url = configURL else { return nil }
        return try? SpindConfig.load(from: url)
    }

    /// Der einmal erzeugte Schlüssel überlebt jeden App-Neustart — sonst
    /// wäre jeder bei Hetzner hinterlegte öffentliche Teil sofort wertlos.
    static func existingPublicLine() -> String? {
        guard let url = publicKeyURL,
              let line = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Erzeugt ein Schlüsselpaar und speichert es SOFORT — nicht erst beim
    /// Verbindungstest, damit Kopieren → App weg → Hinterlegen sicher ist.
    static func generateAndStoreKey() throws -> String {
        guard let dir = directory, let keyURL = keyURL, let pubURL = publicKeyURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let pair = SSHKeyGen.generate(comment: "spind-iphone")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pair.privateOpenSSH.write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyURL.path
        )
        try pair.publicLine.write(to: pubURL, atomically: true, encoding: .utf8)
        return pair.publicLine
    }

    /// Übernimmt einen gescannten Kopplungscode: Schlüssel und Zugang
    /// landen in der App-Gruppe, die Dateien-App bekommt ihren Eintrag.
    static func applyPairing(_ code: PairingCode) throws {
        guard let dir = directory, let keyURL = keyURL,
              let pubURL = publicKeyURL, let configURL = configURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try code.privateKey.write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyURL.path
        )
        try code.publicLine.write(to: pubURL, atomically: true, encoding: .utf8)
        var config = SpindConfig(
            host: code.host, port: code.port, username: code.username,
            privateKeyPath: keyURL.path, remoteRoot: ".", localRoot: "~"
        )
        config.hostPublicKey = code.hostPublicKey
        try config.save(to: configURL)
    }
}

/// Übersetzt Verbindungs-Fehler in Handlungsanweisungen statt Fehlercodes.
func connectionHint(for error: Error) -> String {
    let text = String(describing: error).lowercased()
    if text.contains("authent") || text.contains("sshclienterror") {
        return "Anmeldung abgelehnt. Ist der öffentliche Schlüssel bei der "
            + "Box hinterlegt und SSH-Support aktiviert?"
    }
    if text.contains("nioconnection") || text.contains("timed out")
        || text.contains("refused") || text.contains("network") {
        return "Keine Verbindung zum Server. Stimmen Adresse und Port, und ist "
            + "»externe Erreichbarkeit« für die Box aktiv? In manchen WLANs "
            + "hilft testweise Mobilfunk."
    }
    return error.localizedDescription
}

@main
struct SpindMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var lock = AppLock.shared
    @State private var config = MobileStore.loadConfig()

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let config {
                    StatusView(config: config) {
                        self.config = MobileStore.loadConfig()
                    }
                    .onAppear {
                        // Bei jedem Start neu anmelden — schadet nie und heilt
                        // verlorene Registrierungen (App-Update, Neuinstallation).
                        SpindDomain.register()
                    }
                } else {
                    OnboardingView {
                        config = MobileStore.loadConfig()
                    }
                }
                // Deckt alles zu, solange nicht entsperrt ist — bewusst kein
                // Blatt, das sich wegschieben ließe.
                if lock.locked { LockView() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await SpindDomain.refresh()
                    if let config { await PhotoBackup.shared.run(config: config) }
                }
            case .background:
                lock.lock()
                PhotoBackup.shared.pause()
                SpindDomain.scheduleBackgroundRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(SpindDomain.refreshTaskID)) {
            await SpindDomain.refresh()
            if let config = MobileStore.loadConfig() {
                await PhotoBackup.shared.run(config: config, limited: true)
            }
            await MainActor.run { SpindDomain.scheduleBackgroundRefresh() }
        }
    }
}

// MARK: - Einrichtung

struct OnboardingView: View {
    var onFinished: () -> Void

    @State private var publicLine: String?
    @State private var host = ""
    @State private var user = ""
    @State private var port = 22
    @State private var portEdited = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var copied = false
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("Spind bringt deine Hetzner Storage Box – oder jeden "
                             + "SFTP-Server – in die Dateien-App deines iPhones.")
                    } icon: {
                        Image(systemName: "externaldrive.badge.icloud")
                            .foregroundStyle(.blue)
                    }
                }

                Section {
                    Button {
                        showingPairing = true
                    } label: {
                        Label("Per QR-Code vom Mac verbinden", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("Schnellster Weg: In der Mac-App unter Einstellungen → "
                         + "Verbindung → »Gerät verbinden« einen Code erzeugen und "
                         + "hier scannen. Alles andere entfällt dann.")
                }

                Section("1 · Schlüssel") {
                    if let publicLine {
                        Label("Schlüssel liegt bereit", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(publicLine)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(3)
                            .truncationMode(.middle)
                        Button {
                            UIPasteboard.general.string = publicLine
                            copied = true
                        } label: {
                            Label(copied ? "Kopiert!" : "Öffentlichen Schlüssel kopieren",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Text("In der Hetzner Console bei deiner Storage Box unter "
                             + "»SSH-Schlüssel« einfügen – oder auf anderen Servern "
                             + "in ~/.ssh/authorized_keys.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button("Schlüsselpaar erzeugen") {
                            publicLine = try? MobileStore.generateAndStoreKey()
                        }
                    }
                }
                .onAppear {
                    // Vorhandenen Schlüssel wiederverwenden — NIE stillschweigend
                    // einen neuen erzeugen, sonst wird der bereits bei Hetzner
                    // hinterlegte öffentliche Teil wertlos.
                    if publicLine == nil {
                        publicLine = MobileStore.existingPublicLine()
                    }
                }

                Section("2 · Verbindung") {
                    TextField("u123456.your-storagebox.de oder sftp.example.org", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: host) { _, newValue in
                            if !portEdited {
                                port = SpindConfig.defaultPort(forHost:
                                    newValue.trimmingCharacters(in: .whitespaces))
                            }
                        }
                    TextField("Benutzername", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", value: $port, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onChange(of: port) { _, newValue in
                                if newValue != SpindConfig.defaultPort(forHost:
                                    host.trimmingCharacters(in: .whitespaces)) {
                                    portEdited = true
                                }
                            }
                    }
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if testing { ProgressView().padding(.trailing, 4) }
                            Text("Verbindung testen")
                        }
                    }
                    .disabled(testing || publicLine == nil || host.isEmpty || user.isEmpty)
                    if let testResult {
                        Label(testResult.text,
                              systemImage: testResult.ok
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(testResult.ok ? .green : .red)
                    }
                }

                Section {
                    Button("Fertig – in der Dateien-App aktivieren") { finish() }
                        .disabled(testResult?.ok != true)
                } footer: {
                    Text("Danach erscheint Spind in der Dateien-App unter "
                         + "»Durchsuchen«. Dateien laden erst beim Öffnen.")
                }
            }
            .navigationTitle("Spind einrichten")
            .sheet(isPresented: $showingPairing) {
                PairingView(onPaired: {
                    showingPairing = false
                    onFinished()
                }, dismiss: { showingPairing = false })
            }
        }
    }

    private func currentConfig() -> SpindConfig? {
        guard let keyURL = MobileStore.keyURL else { return nil }
        return SpindConfig(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: user.trimmingCharacters(in: .whitespaces),
            privateKeyPath: keyURL.path,
            remoteRoot: ".",
            localRoot: "~"
        )
    }

    private func testConnection() {
        testing = true
        testResult = nil
        Task {
            do {
                guard let config = currentConfig() else { return }
                let client = StorageBoxClient(config: config)
                try await client.connect()
                let items = try await client.listDirectory(config.remoteRoot)
                await client.disconnect()
                testResult = (true, "Verbindung steht – \(items.count) Einträge gefunden")
            } catch {
                testResult = (false, connectionHint(for: error))
            }
            testing = false
        }
    }

    private func finish() {
        guard let config = currentConfig(), let configURL = MobileStore.configURL
        else { return }
        do {
            try config.save(to: configURL)
            SpindDomain.register()
            onFinished()
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }
}

// MARK: - Status

struct StatusView: View {
    let config: SpindConfig
    var onReset: () -> Void

    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var confirmReset = false
    @State private var keyCopied = false
    @State private var refreshing = false
    @ObservedObject private var lock = AppLock.shared
    @ObservedObject private var backup = PhotoBackup.shared

    private let beat = Timer
        .publish(every: SpindDomain.foregroundInterval, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                filesSection
                photoSection
                recoverySection
                lockSection
                keySection
                resetSection
            }
            .navigationTitle("Spind")
            // Solange die App offen ist, wird im kurzen Takt nachgesehen.
            // Der Timer der Hauptschleife ruht im Hintergrund von selbst —
            // dort übernimmt das Aufwecken durch iOS.
            .onReceive(beat) { _ in
                Task { await SpindDomain.refresh() }
            }
            .task { backup.countWaiting() }
            .confirmationDialog(
                "Einrichtung zurücksetzen?", isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Zurücksetzen", role: .destructive) { reset() }
                Button("Abbrechen", role: .cancel) {}
            }
        }
    }

    // Einzelne Abschnitte: als ein Ausdruck ist der Aufbau zu groß, der
    // Übersetzer gibt beim Typprüfen auf.

    private var connectionSection: some View {
        Section("Verbindung") {
            LabeledContent("Server", value: config.host)
            LabeledContent("Benutzer", value: config.username)
            LabeledContent("Port", value: String(config.port))
            Button {
                test()
            } label: {
                HStack {
                    if testing { ProgressView().padding(.trailing, 4) }
                    Text("Verbindung testen")
                }
            }
            .disabled(testing)
            if let testResult {
                Label(testResult.text,
                      systemImage: testResult.ok
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(testResult.ok ? .green : .red)
            }
        }
    }

    private var filesSection: some View {
        Section {
            Label {
                // Ein einzelnes Literal, damit SwiftUI das Markdown rendert.
                Text("Deine Dateien findest du in der **Dateien-App** unter »Durchsuchen« → **Spind**. Sie laden erst beim Öffnen und belegen sonst keinen Platz.")
            } icon: {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.blue)
            }
            Button {
                refreshing = true
                Task {
                    await SpindDomain.refresh()
                    try? await Task.sleep(for: .seconds(2))
                    refreshing = false
                }
            } label: {
                HStack {
                    if refreshing { ProgressView().padding(.trailing, 4) }
                    Text("Jetzt nach Änderungen sehen")
                }
            }
            .disabled(refreshing)
            Button("Dateien-App-Eintrag neu anlegen") {
                SpindDomain.register()
            }
        } footer: {
            Text("Solange diese App offen ist, sieht Spind alle "
                 + "\(Int(SpindDomain.foregroundInterval)) Sekunden nach. "
                 + "Im Hintergrund entscheidet iOS, wann es die App dafür "
                 + "kurz aufweckt – das kann dauern. Ein SFTP-Server kann "
                 + "von sich aus nicht Bescheid geben; in der Dateien-App "
                 + "holt ein Zug nach unten den Stand sofort.")
        }
    }

    private var photoSection: some View {
        Section {
            NavigationLink {
                PhotoBackupView(config: config)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fotos")
                        Text(photoSubtitle)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                } icon: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
            }
        }
    }

    /// Der laufende Upload soll auch von hier aus zu sehen sein, ohne dass
    /// man erst hineingehen muss.
    private var photoSubtitle: String {
        if let run = backup.run {
            return "Sichert \(run.done) von \(run.total) …"
        }
        guard backup.settings.enabled else { return "Aus" }
        if let waiting = backup.waiting, waiting > 0 {
            return "\(waiting) warten"
        }
        return backup.settings.layout.path(
            for: Date(), folder: backup.settings.folder, fileName: "…"
        )
    }

    @ViewBuilder
    private var lockSection: some View {
        if lock.available {
            Section {
                Toggle("Mit \(lock.methodName) öffnen", isOn: $lock.enabled)
            } footer: {
                Text("Fragt beim Öffnen der App nach. Schützt Zugang, Papierkorb "
                     + "und Verlauf – **nicht** die Dateien selbst: die stehen "
                     + "weiter in der Dateien-App.")
            }
        }
    }

    private var recoverySection: some View {
        Section {
            NavigationLink {
                TrashView(config: config)
            } label: {
                Label("Papierkorb", systemImage: "arrow.uturn.backward.circle")
            }
            NavigationLink {
                RemoteBrowserView(config: config)
            } label: {
                Label("Versionsverlauf", systemImage: "clock.arrow.circlepath")
            }
        } header: {
            Text("Wiederherstellen")
        } footer: {
            Text("Beides liegt auf dem Server: Gelöschtes und frühere "
                 + "Fassungen sind hier auch dann zu finden, wenn dieses "
                 + "iPhone die Datei nie geladen hat.")
        }
    }

    @ViewBuilder
    private var keySection: some View {
        if let publicLine = MobileStore.existingPublicLine() {
            Section {
                Text(publicLine)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3)
                    .truncationMode(.middle)
                Button {
                    UIPasteboard.general.string = publicLine
                    keyCopied = true
                } label: {
                    Label(keyCopied ? "Kopiert!" : "Öffentlichen Schlüssel kopieren",
                          systemImage: keyCopied ? "checkmark" : "doc.on.doc")
                }
            } header: {
                Text("Öffentlicher Schlüssel")
            } footer: {
                Text("Diesen Schlüssel kannst du bei weiteren Boxen oder "
                     + "Servern hinterlegen – er bleibt auf diesem iPhone "
                     + "immer derselbe.")
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("Einrichtung zurücksetzen …", role: .destructive) {
                confirmReset = true
            }
        } footer: {
            Text("Entfernt Zugang und Schlüssel von diesem iPhone. "
                 + "Auf dem Server ändert sich nichts.")
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let client = StorageBoxClient(config: config)
                try await client.connect()
                let items = try await client.listDirectory(config.remoteRoot)
                await client.disconnect()
                testResult = (true, "Verbindung steht – \(items.count) Einträge gefunden")
            } catch {
                testResult = (false, connectionHint(for: error))
            }
            testing = false
        }
    }

    private func reset() {
        SpindDomain.remove()
        if let dir = MobileStore.directory {
            try? FileManager.default.removeItem(at: dir)
        }
        onReset()
    }
}

// MARK: - File-Provider-Domain

enum SpindDomain {
    static let domain: NSFileProviderDomain = {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier("spind"),
            displayName: "Spind"
        )
        // Spind synct keinen Papierkorb (Löschungen sichert der
        // Versionsverlauf serverseitig). Ohne diese Deklaration fragt
        // iOS den Trash-Container trotzdem an, kassiert jedes Mal einen
        // Fehler — und zeigt dauerhaft das Sync-Warnzeichen.
        if #available(iOS 18.0, *) {
            domain.supportsSyncingTrash = false
        }
        return domain
    }()

    static func register(attempt: Int = 1) {
        NSFileProviderManager.add(domain) { error in
            appLog("Domain add (Versuch \(attempt)): \(error.map { String(describing: $0) } ?? "ok")")
            // Direkt nach (Neu-)Installation räumt iOS alte Domains noch
            // asynchron ab — der Add prallt dann mit EPERM dagegen.
            if error != nil, attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    register(attempt: attempt + 1)
                }
            }
        }
    }

    static func remove() {
        NSFileProviderManager.remove(domain) { _ in }
    }

    // MARK: - Nachsehen, was sich geändert hat

    static let refreshTaskID = (Bundle.main.object(
        forInfoDictionaryKey: "SpindRefreshTaskID"
    ) as? String) ?? "dev.eigenhand.spind.refresh"

    /// Takt, in dem die geöffnete App nachsehen lässt.
    static let foregroundInterval: TimeInterval = 10

    /// Stupst die Extension an, beim Server nachzufragen. SFTP kennt keine
    /// Push-Nachricht: Ohne dieses Anstupsen erfährt das iPhone von einer
    /// Löschung am Mac erst, wenn jemand den Ordner in der Dateien-App von
    /// Hand neu lädt.
    static func refresh() async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        // Die Marke sagt der Extension: Das ist eine gewollte Nachschau,
        // nicht das System, das den Arbeitssatz durchzählt.
        if let url = MobileStore.directory?
            .appendingPathComponent(SpindGroupFile.sweepRequest) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? Data().write(to: url, options: .atomic)
        }
        try? await manager.signalEnumerator(for: .workingSet)
        try? await manager.signalEnumerator(for: .rootContainer)
    }

    /// Fünf Minuten sind der Wunsch, keine Zusage: iOS entscheidet selbst,
    /// wann es die App kurz aufweckt — nach Akku, Netz und danach, wie oft
    /// die App sonst benutzt wird. Es können auch Stunden werden.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Diagnose im Simulator: /tmp des Simulators ist das /tmp des Macs.
func appLog(_ message: String) {
    #if targetEnvironment(simulator)
    let url = URL(fileURLWithPath: "/tmp/spind-app.log")
    let line = "\(Date())  \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
    #endif
}
