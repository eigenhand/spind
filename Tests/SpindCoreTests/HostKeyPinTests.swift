// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import SpindCore

final class HostKeyPinTests: XCTestCase {
    private let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let keyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    private var store: URL!

    override func setUpWithError() throws {
        store = FileManager.default.temporaryDirectory
            .appendingPathComponent("spind-pin-\(UUID().uuidString)/config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
    }

    private func config(host: String = "u1.your-storagebox.de", port: Int = 23,
                        pin: String? = nil) -> SpindConfig {
        SpindConfig(host: host, port: port, username: "u1", privateKeyPath: "/k",
                    remoteRoot: ".", localRoot: "~", hostPublicKey: pin)
    }

    func testFirstUseWritesPinIntoStore() throws {
        let unpinned = config()
        try unpinned.save(to: store)
        XCTAssertNil(HostKey.pin(for: unpinned, storedAt: store))

        XCTAssertTrue(try HostKey.pinOnFirstUse(keyA, for: unpinned, storedAt: store))
        XCTAssertEqual(try SpindConfig.load(from: store).hostPublicKey, keyA)
        // A stale in-memory copy without pin still gets the stored one.
        XCTAssertEqual(HostKey.pin(for: unpinned, storedAt: store), keyA)
    }

    func testExistingPinIsNeverReplaced() throws {
        try config(pin: keyA).save(to: store)
        XCTAssertFalse(try HostKey.pinOnFirstUse(keyB, for: config(), storedAt: store))
        XCTAssertEqual(try SpindConfig.load(from: store).hostPublicKey, keyA)
    }

    func testOwnPinWinsOverStore() throws {
        try config(pin: keyA).save(to: store)
        XCTAssertEqual(HostKey.pin(for: config(pin: keyB), storedAt: store), keyB)
    }

    func testPinOfAnotherServerIsIgnored() throws {
        try config(host: "other.example.org", port: 22, pin: keyA).save(to: store)
        XCTAssertNil(HostKey.pin(for: config(), storedAt: store))
        XCTAssertFalse(try HostKey.pinOnFirstUse(keyB, for: config(), storedAt: store))

        try config(port: 2222).save(to: store)
        XCTAssertFalse(try HostKey.pinOnFirstUse(keyB, for: config(), storedAt: store))
        XCTAssertNil(try SpindConfig.load(from: store).hostPublicKey)
    }

    func testHostComparisonIgnoresCase() throws {
        try config(host: "U1.Your-Storagebox.de").save(to: store)
        XCTAssertTrue(try HostKey.pinOnFirstUse(keyA, for: config(), storedAt: store))
    }

    func testWithoutStoreOrFileThereIsNoPin() {
        XCTAssertNil(HostKey.pin(for: config(), storedAt: nil))
        XCTAssertNil(HostKey.pin(for: config(), storedAt: store))
        XCTAssertFalse((try? HostKey.pinOnFirstUse(keyA, for: config(), storedAt: store)) ?? true)
    }
}

final class HostKeyPinParsingTests: XCTestCase {
    func testValidPinParses() throws {
        let line = SSHKeyGen.generate(comment: "test").publicLine
        XCTAssertNoThrow(try StorageBoxClient.parsePin(line, host: "h"))
    }

    func testUnreadablePinFailsClosed() {
        for pin in ["", "garbage", "ssh-ed25519 !!!notbase64", "ssh-ed25519 AAAA"] {
            XCTAssertThrowsError(try StorageBoxClient.parsePin(pin, host: "h")) { error in
                guard case StorageBoxError.hostKeyPinUnreadable("h") = error else {
                    return XCTFail("unexpected error for \(pin): \(error)")
                }
            }
        }
    }
}
