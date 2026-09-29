// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import SpindCore

/// Names that come from the server.
///
/// The server is not always ours: a shared box carries other people's folders, and
/// Spind talks to any SFTP host. Such a name becomes a local path, and a ".." in it
/// walks straight out of the sync folder.
///
/// Six lines of code in two places — the sync engine and the file provider extension.
/// Until now neither of them was checked.
final class RemotePathTests: XCTestCase {

    // MARK: What gets through

    func testOrdinaryNamesPass() {
        XCTAssertTrue(RemotePath.isSafe("Rechnung.pdf"))
        XCTAssertTrue(RemotePath.isSafe("Projekte/2026/Notizen.md"))
        XCTAssertTrue(RemotePath.isSafe("Ordner mit Leerzeichen/Datei.txt"))
        XCTAssertTrue(RemotePath.isSafe("Müller & Söhne/Angebot.docx"))
        XCTAssertTrue(RemotePath.isSafe("a"))
    }

    /// Only a **whole** component counts. A name that happens to contain two dots is an
    /// ordinary name — and blocking it makes the file unreachable without making
    /// anything safer.
    func testDotsInsideANameAreOrdinary() {
        XCTAssertTrue(RemotePath.isSafe("..hidden"))
        XCTAssertTrue(RemotePath.isSafe("file..txt"))
        XCTAssertTrue(RemotePath.isSafe("endswith.."))
        XCTAssertTrue(RemotePath.isSafe("folder/..name/file"))
        XCTAssertTrue(RemotePath.isSafe("."), "A single dot leads nowhere.")
    }

    // MARK: What does not get through

    /// The case this is about: "../../evil.txt" appended to "~/Spind" lands in "/Users".
    func testAParentComponentIsRefusedWhereverItStands() {
        XCTAssertFalse(RemotePath.isSafe(".."))
        XCTAssertFalse(RemotePath.isSafe("../evil.txt"))
        XCTAssertFalse(RemotePath.isSafe("../../evil.txt"))
        XCTAssertFalse(RemotePath.isSafe("folder/../../evil.txt"))
        XCTAssertFalse(RemotePath.isSafe("folder/.."))
        XCTAssertFalse(RemotePath.isSafe("a/b/../c"))
    }

    /// Double slashes must not defeat the check: "a//../b" has an empty component in the
    /// middle, and a naive comparison across all pieces could stumble over it.
    func testEmptyComponentsDoNotHideAParent() {
        XCTAssertFalse(RemotePath.isSafe("a//../b"))
        XCTAssertFalse(RemotePath.isSafe("//../"))
    }

    func testTheEmptyNameAndEmbeddedNullAreRefused() {
        XCTAssertFalse(RemotePath.isSafe(""))
        XCTAssertFalse(RemotePath.isSafe("file\0.txt"))
        XCTAssertFalse(RemotePath.isSafe("\0"))
    }

    // MARK: What the check does *not* do

    /// A leading slash gets through, and that is no oversight: both callers append the
    /// name to a root path, and in doing so it stays inside. The test stands here so
    /// that the decision is visible — whoever uses the check somewhere else later,
    /// where an absolute path would stay absolute, reads here that it does not catch it.
    func testAnAbsoluteLookingNameIsNotRefusedHere() {
        XCTAssertTrue(RemotePath.isSafe("/etc/passwd"))
    }
}
