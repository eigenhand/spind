// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import SpindCore

/// Which versions stay and which may go.
///
/// This arithmetic decides what gets deleted. A mistake in it is not a wrong button or
/// an ugly line, but the version somebody needed a moment ago — and it is gone. Of all
/// the untested places in Spind, this was the most expensive one.
///
/// The time zone is fixed. `Calendar.current` hangs on the machine's own, and the
/// boundary between two days then lies somewhere other than the test thinks: the same
/// run in Berlin and in Honolulu would come to different results, and one of the two
/// would be red.
final class VersionRetentionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // mid-January 2027
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// A version `ago` seconds old.
    private func version(_ ago: TimeInterval, id: String? = nil) -> FileVersion {
        let date = now.addingTimeInterval(-ago)
        return FileVersion(id: id ?? ISO8601DateFormatter().string(from: date),
                           date: date, size: 1_000, remotePath: "/x")
    }

    private func expendable(_ versions: [FileVersion]) -> [FileVersion] {
        VersionRetention.expendable(versions, now: now, calendar: utc)
    }

    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    // MARK: The promise

    /// It says so in the function's documentation: as long as there is any version at
    /// all, one is kept. The test for that is the most important one in this file.
    func testTheNewestVersionIsNeverExpendable() {
        for ages in [[0.0], [0, hour], [0, hour, 2 * hour],
                     [400 * day, 401 * day, 402 * day]] {
            let versions = ages.map { version($0) }
            let drop = expendable(versions)
            XCTAssertFalse(drop.contains { $0.id == versions[0].id },
                           "The newest version must never go — ages: \(ages)")
        }
    }

    func testASingleVersionIsNeverExpendable() {
        XCTAssertTrue(expendable([version(0)]).isEmpty)
        XCTAssertTrue(expendable([version(999 * day)]).isEmpty)
        XCTAssertTrue(expendable([]).isEmpty)
    }

    /// Nothing may disappear and nothing may be counted twice. If this test falls, the
    /// bookkeeping is wrong — and that is the kind of mistake where a version is deleted
    /// twice or never looked at.
    func testEveryVersionIsEitherKeptOrDroppedExactlyOnce() {
        let versions = (0..<80).map { version(Double($0) * 6 * hour) }
        let drop = expendable(versions)

        let droppedIDs = drop.map(\.id)
        XCTAssertEqual(Set(droppedIDs).count, droppedIDs.count, "A version twice in the list.")
        XCTAssertTrue(Set(droppedIDs).isSubset(of: Set(versions.map(\.id))))
    }

    // MARK: Today everything stays

    /// The window in which somebody thinks “that was me just now, undo it”.
    func testEverythingFromTodayStays() {
        let versions = (0..<10).map { version(Double($0) * hour) }
        XCTAssertTrue(expendable(versions).isEmpty)
    }

    /// Only a program that saves every minute runs into the cap — and then the oldest
    /// one goes, not the newest.
    func testBeyondTheBurstCapTheOldestOfTodayGoes() {
        let count = VersionRetention.burstCap + 10
        // All within one day, descending.
        let versions = (0..<count).map { version(Double($0) * 40 * 60) }
        let drop = expendable(versions)

        XCTAssertEqual(drop.count, 10)
        let keptIDs = Set(versions.map(\.id)).subtracting(drop.map(\.id))
        XCTAssertEqual(keptIDs.count, VersionRetention.burstCap)
        // The ten oldest are gone.
        for old in versions.suffix(10) {
            XCTAssertTrue(drop.contains { $0.id == old.id }, "The oldest must go.")
        }
        XCTAssertTrue(keptIDs.contains(versions[0].id))
    }

    // MARK: The grid grows coarser

    /// Within the month one per day survives, and it is the newest of that day.
    func testWithinTheMonthOnePerDaySurvivesAndItIsTheNewestOfThatDay() {
        // Three versions on the same day, five days ago — so inside the daily grid.
        //
        // The gaps are chosen small, and that is no accident: my first attempt took
        // 1, 10 and 20 hours, and two of them already fell on the previous day. The
        // test failed, the code was right. You do not test a daily grid with gaps that
        // skip a day.
        let early = version(5 * day + 5 * hour, id: "early")
        let middle = version(5 * day + 3 * hour, id: "middle")
        let late = version(5 * day + 1 * hour, id: "late")
        let newest = version(0, id: "newest")

        let drop = expendable([newest, late, middle, early]).map(\.id)
        XCTAssertEqual(Set(drop), ["early", "middle"],
                       "Of one day the newest version stays.")
    }

    /// Beyond the month the grid becomes a week wide.
    func testBeyondAMonthOnePerWeekSurvives() {
        // Two versions in the same week, a good forty days ago.
        //
        // 42 and 43 days and not 40 and 42: the calendar here starts the week on
        // **Sunday**, and exactly that boundary lies between the 40th and the 42nd day
        // before `now`. My first attempt jumped over it and accused the code of a
        // mistake it did not have. Worked out, not guessed.
        let a = version(42 * day, id: "a")   // Friday
        let b = version(43 * day, id: "b")   // Thursday of the same week
        let drop = expendable([version(0, id: "new"), a, b]).map(\.id)
        XCTAssertEqual(drop, ["b"], "Of one week the newer one stays.")
    }

    /// Beyond the year one per month.
    func testBeyondAYearOnePerMonthSurvives() {
        let a = version(400 * day, id: "a")
        let b = version(405 * day, id: "b")     // same month as a
        let c = version(500 * day, id: "c")     // a different month
        let drop = expendable([version(0, id: "new"), a, b, c]).map(\.id)
        XCTAssertEqual(drop, ["b"], "A different month stays, the duplicate does not.")
    }

    /// A day, a week, a month, a year — through every grid at once.
    func testAllTiersTogether() {
        let versions = [
            version(0),                 // today
            version(2 * hour),          // today
            version(3 * day),           // daily grid
            version(3 * day + hour),    // the same day
            version(45 * day),          // weekly grid
            version(400 * day),         // monthly grid
        ]
        let drop = expendable(versions)
        XCTAssertEqual(drop.count, 1, "Only the duplicate day falls away.")
        XCTAssertEqual(drop[0].id, versions[3].id)
    }

    // MARK: The last barrier

    /// Even a thin grid costs space with a 2 GB file. What goes beyond the ceiling falls
    /// off the back — at the front stand the ones somebody is looking for.
    func testTheCeilingDropsTheOldestOnes() {
        // One per month, far in the past: each has a bucket of its own.
        let versions = (0..<(VersionRetention.maxPerFile + 12)).map {
            version(400 * day + Double($0) * 31 * day, id: "m\($0)")
        }
        let drop = expendable(versions)
        let keptIDs = Set(versions.map(\.id)).subtracting(drop.map(\.id))

        XCTAssertEqual(keptIDs.count, VersionRetention.maxPerFile)
        XCTAssertTrue(keptIDs.contains("m0"), "The newest stays here too.")
        XCTAssertFalse(keptIDs.contains("m\(VersionRetention.maxPerFile + 11)"),
                       "The oldest falls off.")
    }

    // MARK: Disorder

    /// The order of the input must decide nothing — the function sorts for itself, and
    /// whoever relies on that should be able to read it here.
    func testTheOrderOfTheInputDoesNotMatter() {
        let versions = [version(3 * day, id: "a"), version(0, id: "new"),
                        version(3 * day + hour, id: "b")]
        XCTAssertEqual(expendable(versions).map(\.id), ["b"])
        XCTAssertEqual(expendable(versions.reversed()).map(\.id), ["b"])
        XCTAssertEqual(expendable(versions.shuffled()).map(\.id), ["b"])
    }

    /// A version with a date in the future — a skewed clock on a second machine is
    /// enough for that. It must not upset anything.
    func testAVersionFromTheFutureDoesNotBreakAnything() {
        let versions = [version(-2 * hour, id: "future"), version(0, id: "now"),
                        version(3 * day, id: "old")]
        XCTAssertTrue(expendable(versions).isEmpty)
    }
}
