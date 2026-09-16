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
@testable import SpindCore

/// Welche Fassungen bleiben und welche gehen.
///
/// Diese Rechnung entscheidet, was geloescht wird. Ein Fehler darin ist nicht ein
/// falscher Knopf oder eine haessliche Zeile, sondern die Fassung, die jemand gerade
/// gebraucht haette — und sie ist dann weg. Von allen ungeprueften Stellen in Spind
/// war das die teuerste.
///
/// Die Zeitzone steht fest. `Calendar.current` haengt an der des Rechners, und die
/// Grenze zwischen zwei Tagen liegt dann woanders als der Test denkt: derselbe Lauf
/// in Berlin und in Honolulu kaeme zu verschiedenen Ergebnissen, und einer von beiden
/// waere rot.
final class VersionRetentionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // Mitte Januar 2027
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Eine Fassung, `ago` Sekunden alt.
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

    // MARK: Das Versprechen

    /// Steht so in der Dokumentation: solange es ueberhaupt eine Fassung gibt, bleibt
    /// eine. Der Test dafuer ist der wichtigste in dieser Datei.
    func testTheNewestVersionIsNeverExpendable() {
        for ages in [[0.0], [0, hour], [0, hour, 2 * hour],
                     [400 * day, 401 * day, 402 * day]] {
            let versions = ages.map { version($0) }
            let drop = expendable(versions)
            XCTAssertFalse(drop.contains { $0.id == versions[0].id },
                           "Die neueste Fassung darf nie weg — Alter: \(ages)")
        }
    }

    func testASingleVersionIsNeverExpendable() {
        XCTAssertTrue(expendable([version(0)]).isEmpty)
        XCTAssertTrue(expendable([version(999 * day)]).isEmpty)
        XCTAssertTrue(expendable([]).isEmpty)
    }

    /// Nichts darf verschwinden und nichts doppelt gezaehlt werden. Faellt dieser
    /// Test, stimmt die Buchfuehrung nicht — und das ist die Art Fehler, bei der eine
    /// Fassung zweimal geloescht oder gar nicht betrachtet wird.
    func testEveryVersionIsEitherKeptOrDroppedExactlyOnce() {
        let versions = (0..<80).map { version(Double($0) * 6 * hour) }
        let drop = expendable(versions)

        let droppedIDs = drop.map(\.id)
        XCTAssertEqual(Set(droppedIDs).count, droppedIDs.count, "Eine Fassung zweimal in der Liste.")
        XCTAssertTrue(Set(droppedIDs).isSubset(of: Set(versions.map(\.id))))
    }

    // MARK: Heute bleibt alles

    /// Das Fenster, in dem jemand denkt „das war ich gerade, zurueck damit".
    func testEverythingFromTodayStays() {
        let versions = (0..<10).map { version(Double($0) * hour) }
        XCTAssertTrue(expendable(versions).isEmpty)
    }

    /// Nur ein Programm, das im Minutentakt speichert, laeuft in die Obergrenze — und
    /// dann faellt das Aelteste weg, nicht das Neueste.
    func testBeyondTheBurstCapTheOldestOfTodayGoes() {
        let count = VersionRetention.burstCap + 10
        // Alle innerhalb eines Tages, absteigend.
        let versions = (0..<count).map { version(Double($0) * 40 * 60) }
        let drop = expendable(versions)

        XCTAssertEqual(drop.count, 10)
        let keptIDs = Set(versions.map(\.id)).subtracting(drop.map(\.id))
        XCTAssertEqual(keptIDs.count, VersionRetention.burstCap)
        // Die zehn aeltesten sind gegangen.
        for old in versions.suffix(10) {
            XCTAssertTrue(drop.contains { $0.id == old.id }, "Die aelteste muss gehen.")
        }
        XCTAssertTrue(keptIDs.contains(versions[0].id))
    }

    // MARK: Das Raster wird gröber

    /// Im Monatsfenster bleibt eine je Tag, und zwar die neueste dieses Tages.
    func testWithinTheMonthOnePerDaySurvivesAndItIsTheNewestOfThatDay() {
        // Drei Fassungen am selben Tag, fuenf Tage her — also im Tagesraster.
        //
        // Die Abstaende sind klein gewaehlt, und das ist kein Zufall: mein erster
        // Anlauf nahm 1, 10 und 20 Stunden, und damit lagen zwei davon schon auf dem
        // Vortag. Der Test fiel durch, der Code hatte recht. Ein Tagesraster prueft
        // man nicht mit Abstaenden, die einen Tag ueberspringen.
        let early = version(5 * day + 5 * hour, id: "frueh")
        let middle = version(5 * day + 3 * hour, id: "mitte")
        let late = version(5 * day + 1 * hour, id: "spaet")
        let newest = version(0, id: "neueste")

        let drop = expendable([newest, late, middle, early]).map(\.id)
        XCTAssertEqual(Set(drop), ["frueh", "mitte"],
                       "Von einem Tag bleibt die neueste Fassung.")
    }

    /// Jenseits des Monats wird das Raster eine Woche breit.
    func testBeyondAMonthOnePerWeekSurvives() {
        // Zwei Fassungen in derselben Woche, gut vierzig Tage her.
        //
        // 42 und 43 Tage und nicht 40 und 42: der Kalender hier beginnt die Woche am
        // **Sonntag**, und zwischen dem 40. und dem 42. Tag vor `now` liegt genau
        // diese Grenze. Mein erster Anlauf hat sie uebersprungen und dem Code einen
        // Fehler vorgeworfen, den er nicht hatte. Nachgerechnet statt geraten.
        let a = version(42 * day, id: "a")   // Freitag
        let b = version(43 * day, id: "b")   // Donnerstag derselben Woche
        let drop = expendable([version(0, id: "neu"), a, b]).map(\.id)
        XCTAssertEqual(drop, ["b"], "Von einer Woche bleibt die neuere.")
    }

    /// Jenseits des Jahres eine je Monat.
    func testBeyondAYearOnePerMonthSurvives() {
        let a = version(400 * day, id: "a")
        let b = version(405 * day, id: "b")     // selber Monat wie a
        let c = version(500 * day, id: "c")     // anderer Monat
        let drop = expendable([version(0, id: "neu"), a, b, c]).map(\.id)
        XCTAssertEqual(drop, ["b"], "Ein anderer Monat bleibt, der doppelte nicht.")
    }

    /// Ein Tag, eine Woche, ein Monat, ein Jahr — durch alle Raster auf einmal.
    func testAllTiersTogether() {
        let versions = [
            version(0),                 // heute
            version(2 * hour),          // heute
            version(3 * day),           // Tagesraster
            version(3 * day + hour),    // derselbe Tag
            version(45 * day),          // Wochenraster
            version(400 * day),         // Monatsraster
        ]
        let drop = expendable(versions)
        XCTAssertEqual(drop.count, 1, "Nur der doppelte Tag faellt weg.")
        XCTAssertEqual(drop[0].id, versions[3].id)
    }

    // MARK: Die letzte Schranke

    /// Auch ein duennes Raster kostet bei einer 2-GB-Datei Platz. Was ueber die
    /// Obergrenze hinausgeht, faellt hinten ab — vorne stehen die, die jemand sucht.
    func testTheCeilingDropsTheOldestOnes() {
        // Je ein Monat, weit in der Vergangenheit: jede hat ihren eigenen Eimer.
        let versions = (0..<(VersionRetention.maxPerFile + 12)).map {
            version(400 * day + Double($0) * 31 * day, id: "m\($0)")
        }
        let drop = expendable(versions)
        let keptIDs = Set(versions.map(\.id)).subtracting(drop.map(\.id))

        XCTAssertEqual(keptIDs.count, VersionRetention.maxPerFile)
        XCTAssertTrue(keptIDs.contains("m0"), "Die neueste bleibt auch hier.")
        XCTAssertFalse(keptIDs.contains("m\(VersionRetention.maxPerFile + 11)"),
                       "Die aelteste faellt ab.")
    }

    // MARK: Unordnung

    /// Die Reihenfolge der Eingabe darf nichts entscheiden — die Funktion sortiert
    /// selbst, und wer sich darauf verlaesst, soll es nachlesen koennen.
    func testTheOrderOfTheInputDoesNotMatter() {
        let versions = [version(3 * day, id: "a"), version(0, id: "neu"),
                        version(3 * day + hour, id: "b")]
        XCTAssertEqual(expendable(versions).map(\.id), ["b"])
        XCTAssertEqual(expendable(versions.reversed()).map(\.id), ["b"])
        XCTAssertEqual(expendable(versions.shuffled()).map(\.id), ["b"])
    }

    /// Eine Fassung mit einem Datum in der Zukunft — eine schiefe Uhr auf einem
    /// zweiten Rechner reicht dafuer. Sie darf nichts umwerfen.
    func testAVersionFromTheFutureDoesNotBreakAnything() {
        let versions = [version(-2 * hour, id: "zukunft"), version(0, id: "jetzt"),
                        version(3 * day, id: "alt")]
        XCTAssertTrue(expendable(versions).isEmpty)
    }
}
