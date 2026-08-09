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

import XCTest
import Crypto
import Citadel
@testable import SpindCore

/// Tests für die Konfliktlogik des Abgleichs.
///
/// Diese Fälle wurden zuvor von Hand gegen eine echte Storage Box
/// geprüft; hier sind sie festgehalten, damit ein Umbau sie nicht
/// unbemerkt kaputt macht. Der Planer arbeitet rein auf Wörterbüchern —
/// keine Netzwerkzugriffe, deshalb schnell und ohne Box lauffähig.
final class SyncPlanTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var engine: SyncEngine!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spind-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true
        )
        let config = SpindConfig(
            host: "example.your-storagebox.de",
            username: "uXXXXXX",
            privateKeyPath: "/dev/null",
            remoteRoot: ".",
            localRoot: temporaryDirectory.path
        )
        let store = try MetadataStore(
            databaseURL: temporaryDirectory.appendingPathComponent("state.sqlite")
        )
        // plan() spricht nie mit dem Server — der Client wird nicht verbunden.
        engine = SyncEngine(
            config: config, client: StorageBoxClient(config: config), store: store
        )
    }

    override func tearDownWithError() throws {
        engine = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - Hilfen

    private func local(_ path: String, size: Int64 = 10, mod: Double = 1000) -> LocalItem {
        LocalItem(relativePath: path, isDirectory: false, size: size, modTime: mod)
    }

    private func remote(_ path: String, size: UInt64 = 10, mod: Double = 1000) -> RemoteItem {
        RemoteItem(
            path: "./" + path, name: (path as NSString).lastPathComponent,
            isDirectory: false, size: size,
            modificationDate: Date(timeIntervalSince1970: mod)
        )
    }

    private func base(
        _ path: String, localSize: Int64 = 10, localMod: Double = 1000,
        remoteSize: Int64 = 10, remoteMod: Double = 1000
    ) -> FileState {
        FileState(
            path: path, isDirectory: false,
            localModTime: localMod, localSize: localSize,
            remoteModTime: remoteMod, remoteSize: remoteSize,
            lastSyncedAt: 1000
        )
    }

    private func describe(_ actions: [SyncAction]) -> [String] {
        actions.map { action in
            switch action {
            case .upload(let p): return "upload:\(p)"
            case .download(let p): return "download:\(p)"
            case .deleteLocal(let p): return "deleteLocal:\(p)"
            case .deleteRemote(let p): return "deleteRemote:\(p)"
            case .createLocalDir(let p): return "createLocalDir:\(p)"
            case .createRemoteDir(let p): return "createRemoteDir:\(p)"
            case .moveRemote(let from, let to): return "moveRemote:\(from)>\(to)"
            case .moveLocal(let from, let to): return "moveLocal:\(from)>\(to)"
            case .conflict(let p): return "conflict:\(p)"
            }
        }
    }

    // MARK: - Grundfälle

    func testNeueLokaleDateiWirdHochgeladen() {
        let actions = engine.plan(local: ["a.txt": local("a.txt")], remote: [:], base: [:])
        XCTAssertEqual(describe(actions), ["upload:a.txt"])
    }

    func testNeueEntfernteDateiWirdGeladen() {
        let actions = engine.plan(local: [:], remote: ["a.txt": remote("a.txt")], base: [:])
        XCTAssertEqual(describe(actions), ["download:a.txt"])
    }

    func testUnveraendertErzeugtKeineAktion() {
        let actions = engine.plan(
            local: ["a.txt": local("a.txt")],
            remote: ["a.txt": remote("a.txt")],
            base: ["a.txt": base("a.txt")]
        )
        XCTAssertTrue(actions.isEmpty, "Unveränderte Dateien dürfen nichts auslösen")
    }

    // MARK: - Der Fall „Rechner lag lange still"

    func testVeralteterRechnerUeberschreibtNeuereFassungNicht() {
        // Lokal unverändert seit dem letzten Abgleich, entfernt geändert.
        let actions = engine.plan(
            local: ["a.txt": local("a.txt", size: 10, mod: 1000)],
            remote: ["a.txt": remote("a.txt", size: 99, mod: 5000)],
            base: ["a.txt": base("a.txt")]
        )
        XCTAssertEqual(describe(actions), ["download:a.txt"],
                       "Ein stillgelegter Rechner darf nur laden, niemals hochladen")
    }

    func testLokaleAenderungWirdHochgeladen() {
        let actions = engine.plan(
            local: ["a.txt": local("a.txt", size: 42, mod: 5000)],
            remote: ["a.txt": remote("a.txt")],
            base: ["a.txt": base("a.txt")]
        )
        XCTAssertEqual(describe(actions), ["upload:a.txt"])
    }

    // MARK: - Konflikte: es darf nie etwas verloren gehen

    func testBeidseitigGeaendertErzeugtKonfliktStattVerlust() {
        let actions = engine.plan(
            local: ["a.txt": local("a.txt", size: 42, mod: 5000)],
            remote: ["a.txt": remote("a.txt", size: 99, mod: 6000)],
            base: ["a.txt": base("a.txt")]
        )
        XCTAssertEqual(describe(actions), ["conflict:a.txt"],
                       "Bei beidseitiger Änderung müssen beide Fassungen erhalten bleiben")
    }

    func testLokalGeloeschtUndEntferntGeaendertHoltDieDateiZurueck() {
        let actions = engine.plan(
            local: [:],
            remote: ["a.txt": remote("a.txt", size: 99, mod: 6000)],
            base: ["a.txt": base("a.txt")]
        )
        XCTAssertEqual(describe(actions), ["download:a.txt"],
                       "Löschen darf eine fremde Änderung nicht vernichten")
    }

    func testEntferntGeloeschtUndLokalGeaendertLaedtWiederHoch() {
        let actions = engine.plan(
            local: ["a.txt": local("a.txt", size: 42, mod: 6000)],
            remote: [:],
            base: ["a.txt": base("a.txt")]
        )
        XCTAssertEqual(describe(actions), ["upload:a.txt"],
                       "Eine lokale Änderung darf durch fremdes Löschen nicht verschwinden")
    }

    // MARK: - Löschungen ohne Gegenänderung

    func testLokalGeloeschtWirdEntferntGeloescht() {
        let actions = engine.plan(
            local: [:], remote: ["a.txt": remote("a.txt")], base: ["a.txt": base("a.txt")]
        )
        XCTAssertEqual(describe(actions), ["deleteRemote:a.txt"])
    }

    func testEntferntGeloeschtWirdLokalGeloescht() {
        let actions = engine.plan(
            local: ["a.txt": local("a.txt")], remote: [:], base: ["a.txt": base("a.txt")]
        )
        XCTAssertEqual(describe(actions), ["deleteLocal:a.txt"])
    }

    // MARK: - Verschieben statt neu übertragen

    func testVerschiebenWirdAlsUmbenennungErkannt() {
        let item = local("Archiv/gross.bin", size: 67_108_864, mod: 1000)
        let actions = engine.plan(
            local: ["Archiv/gross.bin": item],
            remote: ["gross.bin": remote("gross.bin", size: 67_108_864)],
            base: ["gross.bin": base("gross.bin", localSize: 67_108_864,
                                     remoteSize: 67_108_864)]
        )
        XCTAssertEqual(describe(actions), ["moveRemote:gross.bin>Archiv/gross.bin"],
                       "Verschieben darf keine Neuübertragung auslösen")
    }

    func testMehrdeutigeVerschiebungFaelltAufUebertragungZurueck() {
        // Zwei gleich große Kandidaten verschwinden, einer taucht auf —
        // die Zuordnung wäre geraten, also lieber übertragen.
        let actions = engine.plan(
            local: ["neu.bin": local("neu.bin", size: 100, mod: 1000)],
            remote: [
                "alt1.bin": remote("alt1.bin", size: 100),
                "alt2.bin": remote("alt2.bin", size: 100),
            ],
            base: [
                "alt1.bin": base("alt1.bin", localSize: 100, remoteSize: 100),
                "alt2.bin": base("alt2.bin", localSize: 100, remoteSize: 100),
            ]
        )
        let described = describe(actions)
        XCTAssertFalse(described.contains { $0.hasPrefix("moveRemote") },
                       "Bei mehrdeutiger Zuordnung darf nicht geraten werden")
        XCTAssertTrue(described.contains("upload:neu.bin"))
    }

    // MARK: - Umlaute (macOS speichert zerlegt, Server zusammengesetzt)

    func testZerlegteUndZusammengesetzteUmlauteGeltenAlsDieselbeDatei() {
        let decomposed = "Ma\u{0308}rz.txt"          // a + Trema
        let composed = "M\u{00E4}rz.txt"             // ä
        // Swift vergleicht Zeichenketten kanonisch, die Bytes auf Platte und
        // auf der Box unterscheiden sich aber — genau darum geht es hier.
        XCTAssertNotEqual(Array(decomposed.utf8), Array(composed.utf8),
                          "Testvoraussetzung: unterschiedliche Bytefolgen")
        XCTAssertEqual(Array(decomposed.canonicalPathKey.utf8),
                       Array(composed.canonicalPathKey.utf8),
                       "canonicalPathKey muss beide Schreibweisen vereinheitlichen")

        let actions = engine.plan(
            local: [decomposed.canonicalPathKey:
                        local(decomposed, size: 10, mod: 1000)],
            remote: [composed.canonicalPathKey: remote(composed, size: 10)],
            base: [:]
        )
        XCTAssertTrue(actions.isEmpty,
                      "Gleiche Datei in beiden Schreibweisen darf keinen Konflikt erzeugen")
    }

    // MARK: - Sortierung der Aktionen

    func testOrdnerWerdenVorInhaltAngelegtUndTiefZuerstGeloescht() {
        let actions = engine.plan(
            local: [
                "neu": LocalItem(relativePath: "neu", isDirectory: true, size: 0, modTime: 1),
                "neu/tief": LocalItem(relativePath: "neu/tief", isDirectory: true,
                                      size: 0, modTime: 1),
            ],
            remote: [:], base: [:]
        )
        XCTAssertEqual(describe(actions), ["createRemoteDir:neu", "createRemoteDir:neu/tief"],
                       "Übergeordnete Ordner müssen zuerst entstehen")
    }
}

/// Tests für die Schutzmechanismen gegen Massenlöschung.
final class SSHKeyGenTests: XCTestCase {
    /// Das erzeugte Format muss von Citadel gelesen werden können und
    /// denselben öffentlichen Schlüssel ergeben wie die public-Zeile.
    func testErzeugterSchluesselIstGueltigesOpenSSHFormat() throws {
        let pair = SSHKeyGen.generate(comment: "test")
        let parsed = try Curve25519.Signing.PrivateKey(sshEd25519: pair.privateOpenSSH)
        let publicBase64 = pair.publicLine.split(separator: " ")[1]
        let blob = Data(base64Encoded: String(publicBase64))!
        // Blob: len+"ssh-ed25519"+len+key → die letzten 32 Bytes sind der Schlüssel.
        XCTAssertEqual(parsed.publicKey.rawRepresentation, blob.suffix(32))

        #if os(macOS)
        // Gegenprobe mit dem echten OpenSSH: ssh-keygen -y muss dieselbe
        // public-Zeile ableiten.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spind-keygen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyURL = dir.appendingPathComponent("key")
        try pair.privateOpenSSH.write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyURL.path
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-y", "-f", keyURL.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ssh-keygen lehnt das Format ab")
        let derived = String(
            decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = pair.publicLine.split(separator: " ").prefix(2).joined(separator: " ")
        XCTAssertEqual(
            derived.split(separator: " ").prefix(2).joined(separator: " "), expected
        )
        #endif
    }
}

final class SafetyGuardTests: XCTestCase {
    func testWechselDesOrdnersVerwirftDenBasiszustand() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spind-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MetadataStore(databaseURL: dir.appendingPathComponent("s.sqlite"))

        XCTAssertFalse(try store.resetIfScopeChanged(fingerprint: "box|user|.|/a"),
                       "Der erste Lauf ist kein Wechsel")
        try store.upsert(FileState(path: "a.txt", isDirectory: false, lastSyncedAt: 1))
        XCTAssertEqual(try store.allStates().count, 1)

        XCTAssertTrue(try store.resetIfScopeChanged(fingerprint: "box|user|.|/anderer"),
                      "Ein anderer Sync-Ordner muss als Wechsel erkannt werden")
        XCTAssertTrue(try store.allStates().isEmpty,
                      "Nach einem Wechsel darf kein Zustand übrig bleiben, "
                      + "sonst wird alles als gelöscht gedeutet")
    }

    /// Ein Probelauf darf nur lesen: die Wechsel-Erkennung meldet den
    /// Scope-Wechsel, verwirft aber nichts.
    func testProbelaufVerwirftKeinenBasiszustand() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spind-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MetadataStore(databaseURL: dir.appendingPathComponent("s.sqlite"))
        try store.resetIfScopeChanged(fingerprint: "box|user|.|/a")
        try store.upsert(FileState(path: "a.txt", isDirectory: false, lastSyncedAt: 1))

        XCTAssertTrue(try store.scopeChanged(fingerprint: "box|user|.|/anderer"))
        XCTAssertFalse(try store.scopeChanged(fingerprint: "box|user|.|/a"))
        XCTAssertEqual(try store.allStates().count, 1,
                       "Die lesende Prüfung darf den Zustand nicht anfassen")
    }

    func testTeilbaumLoeschungEntferntKindeintraege() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spind-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MetadataStore(databaseURL: dir.appendingPathComponent("s.sqlite"))
        for path in ["ordner", "ordner/a.txt", "ordner/tief/b.txt", "anderer.txt"] {
            try store.upsert(FileState(path: path, isDirectory: false, lastSyncedAt: 1))
        }
        try store.deleteSubtree(path: "ordner")
        XCTAssertEqual(Set(try store.allStates().keys), ["anderer.txt"],
                       "Verwaiste Kindeinträge lösen sonst Löschungen auf der Gegenseite aus")
    }

    /// »Readme.txt« und »readme.txt« sind auf der Box zwei Dateien, lokal
    /// (APFS) meist eine — beide Pfade müssen als Kollision erkannt werden,
    /// Ordner-Kollisionen erfassen den ganzen Teilbaum über den Präfix.
    func testGrossKleinschreibungsKollisionWirdErkannt() {
        let remote = [
            "Readme.txt": RemoteItem(
                path: "/x/Readme.txt", name: "Readme.txt",
                isDirectory: false, size: 1, modificationDate: nil
            ),
            "readme.txt": RemoteItem(
                path: "/x/readme.txt", name: "readme.txt",
                isDirectory: false, size: 2, modificationDate: nil
            ),
            "eindeutig.txt": RemoteItem(
                path: "/x/eindeutig.txt", name: "eindeutig.txt",
                isDirectory: false, size: 3, modificationDate: nil
            ),
        ]
        let collisions = SyncEngine.caseCollisions(local: [:], remote: remote)
        XCTAssertEqual(collisions, ["Readme.txt", "readme.txt"])

        // Auch über die Grenze lokal/remote hinweg.
        let local = [
            "docs": LocalItem(relativePath: "docs", isDirectory: true, size: 0, modTime: 0)
        ]
        let remoteDir = [
            "Docs": RemoteItem(
                path: "/x/Docs", name: "Docs",
                isDirectory: true, size: 0, modificationDate: nil
            )
        ]
        XCTAssertEqual(
            SyncEngine.caseCollisions(local: local, remote: remoteDir),
            ["docs", "Docs"]
        )
    }

    /// Ein Ordner, der bei Erstkontakt auf beiden Seiten existiert
    /// (Wurzelwechsel, aufgehobener Ausschluss), muss in die Basis
    /// übernommen werden — sonst wird eine spätere lokale Löschung als
    /// »remote neu« gedeutet und der Ordner kommt wieder.
    func testBeidseitigerOrdnerWirdInDieBasisUebernommen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spind-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MetadataStore(databaseURL: dir.appendingPathComponent("s.sqlite"))
        let config = SpindConfig(
            host: "example.invalid", username: "u",
            privateKeyPath: "/dev/null", remoteRoot: "/x", localRoot: dir.path
        )
        let engine = SyncEngine(
            config: config, client: StorageBoxClient(config: config), store: store
        )
        let localDir = ["ordner": LocalItem(
            relativePath: "ordner", isDirectory: true, size: 0, modTime: 0
        )]
        let remoteDir = ["ordner": RemoteItem(
            path: "/x/ordner", name: "ordner",
            isDirectory: true, size: 0, modificationDate: nil
        )]

        let adoption = engine.plan(local: localDir, remote: remoteDir, base: [:])
        XCTAssertTrue(adoption.isEmpty, "Übernahme braucht keine Aktion")
        let base = try store.allStates()
        XCTAssertNotNil(base["ordner"], "Der Ordner muss jetzt in der Basis stehen")

        // Lokale Löschung danach: muss als Löschung ankommen, nicht als
        // Wiederbelebung (createLocalDir).
        let afterDelete = engine.plan(local: [:], remote: remoteDir, base: base)
        guard case .deleteRemote("ordner")? = afterDelete.first, afterDelete.count == 1 else {
            return XCTFail("Erwartet: [deleteRemote(ordner)], bekommen: \(afterDelete)")
        }
    }

    /// Ist ein Pfad lokal ein Ordner und remote eine Datei (oder umgekehrt),
    /// würde jede Übertragung die eine Form löschen — solche Pfade müssen
    /// als Konflikt erkannt und eingefroren werden.
    func testTypWechselDateiOrdnerWirdErkannt() {
        let local = [
            "projekt": LocalItem(relativePath: "projekt", isDirectory: true, size: 0, modTime: 0),
            "notiz.txt": LocalItem(relativePath: "notiz.txt", isDirectory: false, size: 5, modTime: 1),
            "beides-datei.txt": LocalItem(relativePath: "beides-datei.txt", isDirectory: false, size: 1, modTime: 1),
        ]
        let remote = [
            "projekt": RemoteItem(
                path: "/x/projekt", name: "projekt",
                isDirectory: false, size: 9, modificationDate: nil
            ),
            "notiz.txt": RemoteItem(
                path: "/x/notiz.txt", name: "notiz.txt",
                isDirectory: true, size: 0, modificationDate: nil
            ),
            "beides-datei.txt": RemoteItem(
                path: "/x/beides-datei.txt", name: "beides-datei.txt",
                isDirectory: false, size: 1, modificationDate: nil
            ),
        ]
        XCTAssertEqual(
            SyncEngine.typeConflicts(local: local, remote: remote),
            ["projekt", "notiz.txt"],
            "Nur die Typ-Abweichler, nicht das übereinstimmende Paar"
        )
        XCTAssertTrue(
            SyncEngine.typeConflicts(local: local, remote: [:]).isEmpty,
            "Fehlt die Gegenseite ganz, ist es ein normales Anlegen/Löschen"
        )
    }

    /// Die Lösch-Bremse stoppt Massenlöschungen, lässt sich aber nach
    /// ausdrücklicher Bestätigung (Knopf im Fenster) für einen Lauf lösen.
    func testLoeschBremseGreiftUndLaesstSichEinmaligLoesen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spind-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MetadataStore(databaseURL: dir.appendingPathComponent("s.sqlite"))
        let config = SpindConfig(
            host: "example.invalid", username: "u",
            privateKeyPath: "/dev/null", remoteRoot: "/x", localRoot: dir.path
        )
        let engine = SyncEngine(
            config: config, client: StorageBoxClient(config: config), store: store
        )
        let deletions: [SyncAction] = (0..<11).map { .deleteRemote("d\($0).txt") }

        XCTAssertThrowsError(
            try engine.checkDeletionVolume(deletions, known: 12),
            "11 von 12 Dateien zu löschen muss die Bremse auslösen"
        ) { error in
            guard case SyncError.tooManyDeletions(let count, let known) = error else {
                return XCTFail("Erwartet: tooManyDeletions, bekommen: \(error)")
            }
            XCTAssertEqual(count, 11)
            XCTAssertEqual(known, 12)
        }
        XCTAssertNoThrow(
            try engine.checkDeletionVolume(Array(deletions.prefix(10)), known: 12),
            "Bis zur Schwelle (max(10, bekannt/5)) läuft es ohne Rückfrage"
        )

        engine.allowBulkDeletions = true
        XCTAssertNoThrow(
            try engine.checkDeletionVolume(deletions, known: 12),
            "Nach der Bestätigung müssen die Löschungen durchgehen"
        )
    }

    /// Wird der Sync-Ordner verschoben, darf die Engine ihn nicht neu anlegen:
    /// der leere Ordner stünde sonst dem Zurückschieben im Weg und alles landete
    /// eine Ebene zu tief (real passiert — der komplette Baum wanderte danach in
    /// einen Unterordner).
    func testFehlenderSyncOrdnerWirdNichtNeuAngelegt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spind-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MetadataStore(databaseURL: dir.appendingPathComponent("s.sqlite"))
        let weg = dir.appendingPathComponent("SyncOrdner")   // existiert absichtlich nicht
        let config = SpindConfig(
            host: "example.invalid", username: "u",
            privateKeyPath: "/dev/null", remoteRoot: "/x", localRoot: weg.path
        )
        let engine = SyncEngine(
            config: config, client: StorageBoxClient(config: config), store: store
        )

        // Erster Lauf: noch kein Zustand → Ordner darf angelegt werden.
        _ = try engine.scanLocal()
        XCTAssertTrue(FileManager.default.fileExists(atPath: weg.path),
                      "Beim Einrichten muss der Ordner entstehen dürfen")

        try FileManager.default.removeItem(at: weg)
        try store.upsert(FileState(path: "a.txt", isDirectory: false, lastSyncedAt: 1))

        XCTAssertThrowsError(try engine.scanLocal()) { error in
            guard case SyncError.localRootMissing = error else {
                return XCTFail("Erwartet: localRootMissing, bekommen: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: weg.path),
                       "Der Platz muss frei bleiben, damit das Zurückschieben "
                       + "an der richtigen Stelle landet")
    }
}

final class PairingCodeTests: XCTestCase {
    /// Der Kopplungscode muss verlustfrei durch QR und zurück — sonst
    /// scheitert die Einrichtung am neuen Gerät.
    func testKopplungscodeUeberlebtHinUndRueckweg() throws {
        var config = SpindConfig(
            host: "u1.your-storagebox.de", port: 23, username: "u1-sub2",
            privateKeyPath: "/dev/null", remoteRoot: ".", localRoot: "~/Spind"
        )
        config.hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRen server"
        let pair = SSHKeyGen.generate(comment: "test")
        let text = try PairingCode(config: config, pair: pair).encoded()

        let decoded = try XCTUnwrap(PairingCode.decode(text))
        XCTAssertEqual(decoded.host, config.host)
        XCTAssertEqual(decoded.port, config.port)
        XCTAssertEqual(decoded.username, config.username)
        XCTAssertEqual(decoded.hostPublicKey, config.hostPublicKey)
        XCTAssertEqual(decoded.privateKey, pair.privateOpenSSH)
        // Der mitgereiste Schlüssel muss weiterhin einlesbar sein.
        XCTAssertNoThrow(try Curve25519.Signing.PrivateKey(sshEd25519: decoded.privateKey))

        XCTAssertNil(PairingCode.decode("völlig anderer QR-Inhalt"))
        XCTAssertNil(PairingCode.decode("spind1:nicht-base64!"))
    }

    /// Fremde oder kaputte Schlüsselzeilen dürfen nie in authorized_keys.
    func testNurEchteSchluesselzeilenWerdenAkzeptiert() throws {
        let ok = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRenC/PLKIL9nk6K/pxQgoiFC41wTNvoIncOxs gerät"
        XCTAssertEqual(try DeviceEnrollment.validated("  \(ok)\n"), ok)
        for bad in [
            "kein-schlüssel", "ssh-ed25519", "ssh-unknown AAAA test",
            "ssh-ed25519 ###keinbase64### test",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRenC a\nssh-ed25519 AAAA b",
        ] {
            XCTAssertThrowsError(try DeviceEnrollment.validated(bad), "akzeptiert: \(bad)")
        }
    }
}
