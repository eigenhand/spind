// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import SpindCore

/// Comparing two directory listings.
///
/// SFTP has no channel for changes — whoever wants to know what happened elsewhere has
/// to look and compare against the last known state. These seven lines then decide what
/// gets downloaded and what gets **deleted**.
final class RemoteListingDiffTests: XCTestCase {

    private func file(_ size: Int64, _ modified: Double = 1_000) -> RemoteEntry {
        RemoteEntry(isDirectory: false, size: size, modified: modified)
    }

    func testNothingChangedMeansNothingToDo() {
        let state = ["a.txt": file(10), "b/": RemoteEntry(isDirectory: true, size: 0, modified: 1)]
        let change = RemoteListingDiff.compare(previous: state, current: state)
        XCTAssertTrue(change.isEmpty)
    }

    func testANewFileCountsAsUpdated() {
        let change = RemoteListingDiff.compare(
            previous: ["a.txt": file(10)],
            current: ["a.txt": file(10), "new.txt": file(5)])
        XCTAssertEqual(change.updated, ["new.txt"])
        XCTAssertTrue(change.deleted.isEmpty)
    }

    /// Every property counts. A file that stays the same size but has changed is the
    /// common case with text files — if it went unnoticed, the old version would
    /// silently stand on the other machine.
    func testEveryPropertyIsPartOfTheComparison() {
        let before = ["a.txt": file(10, 1_000)]
        XCTAssertEqual(RemoteListingDiff.compare(previous: before,
                                                 current: ["a.txt": file(11, 1_000)]).updated,
                       ["a.txt"], "A different size.")
        XCTAssertEqual(RemoteListingDiff.compare(previous: before,
                                                 current: ["a.txt": file(10, 2_000)]).updated,
                       ["a.txt"], "A different timestamp at the same size.")
        XCTAssertEqual(RemoteListingDiff.compare(
            previous: before,
            current: ["a.txt": RemoteEntry(isDirectory: true, size: 10, modified: 1_000)]).updated,
                       ["a.txt"], "The file became a folder.")
    }

    func testWhatIsGoneCountsAsDeleted() {
        let change = RemoteListingDiff.compare(
            previous: ["a.txt": file(10), "b.txt": file(20)],
            current: ["a.txt": file(10)])
        XCTAssertEqual(change.deleted, ["b.txt"])
        XCTAssertTrue(change.updated.isEmpty)
    }

    /// Both lists are sorted. Without a fixed order every comparison in a test would be
    /// a matter of chance — dictionaries do not hand out their keys the same way twice.
    func testBothListsComeOutSorted() {
        let change = RemoteListingDiff.compare(
            previous: ["z.txt": file(1), "a.txt": file(1), "m.txt": file(1)],
            current: ["new-z.txt": file(2), "new-a.txt": file(2)])
        XCTAssertEqual(change.updated, ["new-a.txt", "new-z.txt"])
        XCTAssertEqual(change.deleted, ["a.txt", "m.txt", "z.txt"])
    }

    /// **The dangerous case**, and it stands as a warning in the function's
    /// documentation: what is missing from `current` counts as deleted. An empty listing
    /// after a connection failure therefore declares the whole folder gone.
    ///
    /// The test changes nothing about that — the function is *supposed* to do it, it
    /// simply never receives a listing from a failed call. It holds the contract down so
    /// that nobody breaks it by accident in the next rebuild.
    func testAnEmptyCurrentListingDeclaresEverythingDeleted() {
        let change = RemoteListingDiff.compare(
            previous: ["a.txt": file(1), "b.txt": file(2)], current: [:])
        XCTAssertEqual(change.deleted, ["a.txt", "b.txt"])
    }

    /// The harmless case the other way round: the first run knows nothing and finds
    /// everything.
    func testAnEmptyPreviousStateMakesEverythingNew() {
        let change = RemoteListingDiff.compare(
            previous: [:], current: ["a.txt": file(1), "b.txt": file(2)])
        XCTAssertEqual(change.updated, ["a.txt", "b.txt"])
        XCTAssertTrue(change.deleted.isEmpty)
    }
}
