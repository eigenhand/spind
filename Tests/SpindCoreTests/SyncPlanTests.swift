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

import XCTest
import Crypto
import Citadel
@testable import SpindCore

/// Tests for the conflict logic of the comparison.
///
/// These cases were checked by hand against a real storage box first;
/// here they are held on to, so that a rebuild cannot break them
/// unnoticed. The planner works purely on dictionaries — no network
/// access, so it is fast and runs without a box.
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
        // plan() never talks to the server — the client stays unconnected.
        engine = SyncEngine(
            config: config, client: StorageBoxClient(config: config), store: store
        )
    }

    override func tearDownWithError() throws {
        engine = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - Helpers

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

    // MARK: - Basic cases

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

    // MARK: - The case "machine sat idle for a long time"

    func testVeralteterRechnerUeberschreibtNeuereFassungNicht() {
        // Unchanged locally since the last comparison, changed remotely.
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

    // MARK: - Conflicts: nothing may ever be lost

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

    // MARK: - Deletions without a counter-change

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

    // MARK: - Moving instead of transferring again

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
        // Two candidates of equal size vanish, one appears — the pairing
        // would be guesswork, so transfer instead.
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

    // MARK: - Umlauts (macOS stores decomposed, the server composed)

    func testZerlegteUndZusammengesetzteUmlauteGeltenAlsDieselbeDatei() {
        let decomposed = "Ma\u{0308}rz.txt"          // a + Trema
        let composed = "M\u{00E4}rz.txt"             // ä
        // Swift compares strings canonically, but the bytes on disk and
        // on the box differ — which is exactly the point here.
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

    // MARK: - Ordering of actions

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

/// Tests for the safeguards against mass deletion.
final class SSHKeyGenTests: XCTestCase {
    /// The format produced has to be readable by Citadel and yield the
    /// same public key as the public line.
    func testErzeugterSchluesselIstGueltigesOpenSSHFormat() throws {
        let pair = SSHKeyGen.generate(comment: "test")
        let parsed = try Curve25519.Signing.PrivateKey(sshEd25519: pair.privateOpenSSH)
        let publicBase64 = pair.publicLine.split(separator: " ")[1]
        let blob = Data(base64Encoded: String(publicBase64))!
        // Blob: len+"ssh-ed25519"+len+key → the last 32 bytes are the key.
        XCTAssertEqual(parsed.publicKey.rawRepresentation, blob.suffix(32))

        #if os(macOS)
        // Cross-check with the real OpenSSH: ssh-keygen -y must give the
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

    /// A dry run may only read: the switch detection reports the change
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

    /// "Readme.txt" and "readme.txt" are two files on the box, locally
    /// (APFS) usually one — both paths have to be spotted as a collision,
    /// and folder collisions cover the whole subtree via the prefix.
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

        // Across the local/remote boundary as well.
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

    /// A folder that exists on both sides at first contact (root change,
    /// lifted exclusion) has to be adopted into the base — otherwise a
    /// later local deletion is read as "new remotely" and the folder
    /// comes back.
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

        // Local deletion afterwards: has to arrive as a deletion, not as
        // Wiederbelebung (createLocalDir).
        let afterDelete = engine.plan(local: [:], remote: remoteDir, base: base)
        guard case .deleteRemote("ordner")? = afterDelete.first, afterDelete.count == 1 else {
            return XCTFail("Erwartet: [deleteRemote(ordner)], bekommen: \(afterDelete)")
        }
    }

    /// If a path is a folder locally and a file remotely (or the other
    /// way round), any transfer would delete one form — such paths have
    /// be spotted as a conflict and frozen.
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

    /// The deletion brake stops mass deletions but can be released for
    /// one run after an explicit confirmation (button in the window).
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

    /// If the sync folder is moved, the engine must not recreate it: the
    /// empty folder would stand in the way of moving it back, and
    /// everything would land one level too deep (this happened for real —
    /// the whole tree ended up inside a subfolder afterwards).
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

        // First run: no state yet → the folder may be created.
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
    /// The pairing code has to survive the QR round trip without loss —
    /// otherwise setup fails on the new device.
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
        // The key that travelled along must still be readable.
        XCTAssertNoThrow(try Curve25519.Signing.PrivateKey(sshEd25519: decoded.privateKey))

        XCTAssertNil(PairingCode.decode("völlig anderer QR-Inhalt"))
        XCTAssertNil(PairingCode.decode("spind1:nicht-base64!"))
    }

    /// Foreign or broken key lines must never reach authorized_keys.
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

    // MARK: - Detecting changes on the server

    private func entry(_ size: Int64, _ modified: Double = 100, dir: Bool = false)
        -> RemoteEntry {
        RemoteEntry(isDirectory: dir, size: size, modified: modified)
    }

    /// What was deleted on the Mac has to arrive on the iPhone as
    /// deleted — or the Files app shows ghosts for all eternity.
    func testGeloeschtesWirdAlsGeloeschtGemeldet() {
        let change = RemoteListingDiff.compare(
            previous: ["a.txt": entry(10), "b.txt": entry(20), "ordner": entry(0, dir: true)],
            current: ["a.txt": entry(10)]
        )
        XCTAssertEqual(change.deleted, ["b.txt", "ordner"])
        XCTAssertEqual(change.updated, [])
    }

    func testNeueUndGeaenderteDateienWerdenGemeldet() {
        let previous = ["a.txt": entry(10), "b.txt": entry(20)]
        // New, grown, and merely saved again (same size).
        XCTAssertEqual(
            RemoteListingDiff.compare(
                previous: previous, current: previous.merging(["c.txt": entry(1)]) { a, _ in a }
            ).updated, ["c.txt"]
        )
        XCTAssertEqual(
            RemoteListingDiff.compare(
                previous: previous, current: ["a.txt": entry(10), "b.txt": entry(99)]
            ).updated, ["b.txt"]
        )
        XCTAssertEqual(
            RemoteListingDiff.compare(
                previous: previous, current: ["a.txt": entry(10, 200), "b.txt": entry(20)]
            ).updated, ["a.txt"]
        )
    }

    /// Unchanged means unchanged: no report, no reloading.
    func testUnveraenderterOrdnerMeldetNichts() {
        let listing = ["a.txt": entry(10), "unter": entry(0, dir: true)]
        XCTAssertTrue(
            RemoteListingDiff.compare(previous: listing, current: listing).isEmpty
        )
    }

    /// An empty folder is a valid result — which is why the caller must
    /// only ever compare after a successful listing. This test
    /// holds on to how sharp this knife is.
    func testLeereAuflistungLoeschtAlles() {
        let change = RemoteListingDiff.compare(
            previous: ["a.txt": entry(10)], current: [:]
        )
        XCTAssertEqual(change.deleted, ["a.txt"])
    }

    /// File becomes folder (same name): that is a change, not a
    /// deletion — or the Files app loses the entry entirely.
    func testTypwechselIstEineAenderung() {
        let change = RemoteListingDiff.compare(
            previous: ["x": entry(10)], current: ["x": entry(0, dir: true)]
        )
        XCTAssertEqual(change.updated, ["x"])
        XCTAssertEqual(change.deleted, [])
    }

    // MARK: - Names from the server

    /// A listing is not ours to trust: a shared box carries other people's
    /// folders, and Spind talks to any SFTP host. ".." in a name would walk
    /// a download out of the sync folder.
    func testUnsichereNamenVomServerWerdenAbgelehnt() {
        for bad in ["..", "../x", "a/../../b", "../../evil.txt", "a/..", "", "a\0b"] {
            XCTAssertFalse(RemotePath.isSafe(bad), "muss abgelehnt werden: \(bad)")
        }
    }

    /// Two dots inside a name are ordinary. Rejecting them would break
    /// real files, which is its own kind of damage.
    func testHarmloseNamenMitPunktenBleibenErlaubt() {
        for good in ["..foo", "foo..", "file..txt", "a/b/c.txt", "Größe Straße.txt",
                     "a/./b", "…", "-rf"] {
            XCTAssertTrue(RemotePath.isSafe(good), "muss erlaubt bleiben: \(good)")
        }
    }

    /// Every remote command interpolates a path into a shell. The escape is
    /// checked against a real shell rather than against an expectation:
    /// whatever goes in has to come back out as exactly one argument.
    func testQuotingUeberstehtEineEchteShell() throws {
        let payloads = ["simple.txt", "with space.txt", "it's here.txt",
                        "a\"b\"c", "$HOME", "`id`", "$(id)", "; rm -rf /",
                        "&& echo broken", "new\nline", "Größe.txt", "*", "?", "~",
                        "\\backslash", "ümlaut ' mix"]
        for raw in payloads {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s " + StorageBoxClient.quote(raw)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(String(data: data, encoding: .utf8), raw,
                           "die Shell hat »\(raw)« anders verstanden")
        }
    }

    // MARK: - Filing photos

    private var august: Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 8; parts.day = 13; parts.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar.date(from: parts)!
    }

    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func testFotoLandetImRichtigenOrdner() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(
            PhotoLayout.yearMonth.path(for: august, folder: "Bilder",
                                       fileName: "IMG_1.HEIC",
                                       calendar: berlin, locale: german),
            "Bilder/2026/08/IMG_1.HEIC"
        )
        XCTAssertEqual(
            PhotoLayout.yearMonthName.path(for: august, folder: "Bilder",
                                           fileName: "IMG_1.HEIC",
                                           calendar: berlin, locale: german),
            "Bilder/2026/August/IMG_1.HEIC"
        )
        XCTAssertEqual(
            PhotoLayout.year.path(for: august, folder: "Bilder",
                                  fileName: "IMG_1.HEIC",
                                  calendar: berlin, locale: german),
            "Bilder/2026/IMG_1.HEIC"
        )
        XCTAssertEqual(
            PhotoLayout.flat.path(for: august, folder: "Bilder",
                                  fileName: "IMG_1.HEIC",
                                  calendar: berlin, locale: german),
            "Bilder/IMG_1.HEIC"
        )
    }

    /// The month has to be two digits, or every view sorts
    /// 10, 11, 12, 1, 2 … instead of in order.
    func testMonatIstZweistellig() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 3; parts.day = 1; parts.hour = 12
        let märz = berlin.date(from: parts)!
        XCTAssertEqual(
            PhotoLayout.yearMonth.components(for: märz, calendar: berlin,
                                             locale: Locale(identifier: "de_DE")),
            ["2026", "03"]
        )
    }

    /// The written-out month follows the language of the device.
    func testMonatsnameFolgtDerSprache() {
        XCTAssertEqual(PhotoLayout.monthName(5, locale: Locale(identifier: "de_DE")), "Mai")
        XCTAssertEqual(PhotoLayout.monthName(5, locale: Locale(identifier: "en_US")), "May")
    }

    // MARK: - Thinning the history

    private func version(_ daysAgo: Double, _ hoursAgo: Double = 0,
                         from reference: Date) -> FileVersion {
        let date = reference.addingTimeInterval(-(daysAgo * 86_400 + hoursAgo * 3_600))
        return FileVersion(id: "\(date.timeIntervalSince1970)", date: date,
                           size: 100, remotePath: "/v/\(date.timeIntervalSince1970)")
    }

    /// Fixed calendar and a fixed "now": day, week and month boundaries
    /// can only be checked with real dates, not by subtracting hours —
    /// otherwise a case slips over midnight and the test measures
    /// coincidence.
    private var kalender: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func tag(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day; parts.hour = hour
        return kalender.date(from: parts)!
    }

    private func fassung(_ date: Date) -> FileVersion {
        FileVersion(id: "\(date.timeIntervalSince1970)", date: date,
                    size: 100, remotePath: "/v/\(date.timeIntervalSince1970)")
    }

    private func bleiben(_ versions: [FileVersion], _ now: Date) -> Int {
        versions.count - VersionRetention.expendable(
            versions, now: now, calendar: kalender
        ).count
    }

    private var jetzt: Date { tag(2026, 8, 13) }

    /// As long as there are versions, at least one stays — even with a
    /// einzigen uralten.
    func testDieJuengsteFassungBleibtImmer() {
        let alt = [version(4000, from: jetzt)]
        XCTAssertTrue(VersionRetention.expendable(alt, now: jetzt).isEmpty)
        let viele = (0..<5).map { version(3000 + Double($0) * 40, from: jetzt) }
        let bleibt = Set(viele.map(\.id))
            .subtracting(VersionRetention.expendable(viele, now: jetzt).map(\.id))
        XCTAssertTrue(bleibt.contains(viele[0].id), "die jüngste wurde weggeräumt")
    }

    /// On the first day nothing is bucketed — that is the window for
    /// "that was me just now, undo it".
    func testAmErstenTagBleibtJedeFassung() {
        let heute = (0..<12).map { version(0, Double($0) * 2, from: jetzt) }
        XCTAssertEqual(VersionRetention.expendable(heute, now: jetzt).count, 0)
    }

    /// Only a program that saves every minute runs into the cap.
    func testDauerspeichernWirdGedeckelt() {
        let sturm = (0..<80).map { version(0, Double($0) * 0.1, from: jetzt) }
        let weg = VersionRetention.expendable(sturm, now: jetzt)
        XCTAssertEqual(sturm.count - weg.count, VersionRetention.burstCap)
        // The cap bites from the back: the newest survive.
        XCTAssertFalse(weg.contains { $0.id == sturm[0].id })
    }

    /// Older than a day: one per calendar day — the newest of that day.
    func testAelteresWirdAufEinenProTagGeduennt() {
        let alle = [
            fassung(tag(2026, 8, 11, 22)), fassung(tag(2026, 8, 11, 9)),
            fassung(tag(2026, 8, 11, 3)),
            fassung(tag(2026, 8, 10, 18)), fassung(tag(2026, 8, 10, 7)),
            fassung(tag(2026, 8, 9, 15)),
        ]
        XCTAssertEqual(bleiben(alle, jetzt), 3, "erwartet: eine je Kalendertag")
        let weg = VersionRetention.expendable(alle, now: jetzt, calendar: kalender)
        XCTAssertFalse(weg.contains { $0.date == tag(2026, 8, 11, 22) },
                       "die jüngste des Tages muss bleiben")
    }

    /// Older than a month: one per calendar week.
    func testAelteresAlsEinMonatWirdWoechentlich() {
        // 1-3 June 2026 is Mon-Wed of the same week, two months back.
        let woche = [fassung(tag(2026, 6, 3)), fassung(tag(2026, 6, 2)),
                     fassung(tag(2026, 6, 1))]
        XCTAssertEqual(bleiben(woche, jetzt), 1)
        // A week later is a bucket of its own.
        XCTAssertEqual(bleiben(woche + [fassung(tag(2026, 6, 10))], jetzt), 2)
    }

    /// Older than a year: one per calendar month.
    func testAelteresAlsEinJahrWirdMonatlich() {
        let monat = [fassung(tag(2024, 3, 20)), fassung(tag(2024, 3, 12)),
                     fassung(tag(2024, 3, 5))]
        XCTAssertEqual(bleiben(monat, jetzt), 1)
        XCTAssertEqual(bleiben(monat + [fassung(tag(2024, 4, 2))], jetzt), 2)
    }

    /// Even a thin chain gets a ceiling — with large files every version
    /// costs a full copy.
    func testObergrenzeGreiftUeberAlleStufen() {
        // One version per week across eight years.
        let jahre = (0..<400).map { version(40 + Double($0) * 7, from: jetzt) }
        let bleiben = jahre.count - VersionRetention.expendable(jahre, now: jetzt).count
        XCTAssertLessThanOrEqual(bleiben, VersionRetention.maxPerFile)
        XCTAssertGreaterThan(bleiben, 20, "so dünn sollte es dann doch nicht werden")
    }

    /// Nothing may appear twice in the deletion list — otherwise the
    /// second "rm" fails and the run looks broken.
    func testLoeschlisteIstUeberschneidungsfrei() {
        var alle = (0..<40).map { version(0, Double($0) * 0.5, from: jetzt) }
        alle += (0..<300).map { version(2 + Double($0) * 3, from: jetzt) }
        let weg = VersionRetention.expendable(alle, now: jetzt)
        XCTAssertEqual(Set(weg.map(\.id)).count, weg.count)
        XCTAssertEqual(Set(alle.map(\.id)).count, alle.count, "Testdaten selbst eindeutig")
    }

    /// A target folder with slashes, spaces or a dot in front must not
    /// keinen kaputten Pfad ergeben.
    func testZielordnerWirdAufgeraeumt() {
        XCTAssertEqual(
            PhotoLayout.flat.path(for: august, folder: "/Fotos/vom Handy/",
                                  fileName: "a.jpg", calendar: berlin,
                                  locale: Locale(identifier: "de_DE")),
            "Fotos/vom Handy/a.jpg"
        )
        XCTAssertEqual(
            PhotoLayout.flat.path(for: august, folder: "./", fileName: "a.jpg",
                                  calendar: berlin, locale: Locale(identifier: "de_DE")),
            "a.jpg"
        )
    }
}
