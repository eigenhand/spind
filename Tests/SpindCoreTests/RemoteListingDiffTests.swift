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

/// Der Vergleich zweier Verzeichnislisten.
///
/// SFTP hat keinen Kanal fuer Aenderungen — wer wissen will, was anderswo passiert
/// ist, muss nachsehen und mit dem letzten bekannten Stand vergleichen. Diese sieben
/// Zeilen entscheiden daraufhin, was heruntergeladen und was **geloescht** wird.
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
            current: ["a.txt": file(10), "neu.txt": file(5)])
        XCTAssertEqual(change.updated, ["neu.txt"])
        XCTAssertTrue(change.deleted.isEmpty)
    }

    /// Jede Eigenschaft zaehlt. Eine Datei, die gleich gross bleibt, sich aber
    /// geaendert hat, ist der haeufige Fall bei Textdateien — bliebe sie unbemerkt,
    /// stuende auf dem anderen Rechner stillschweigend die alte Fassung.
    func testEveryPropertyIsPartOfTheComparison() {
        let before = ["a.txt": file(10, 1_000)]
        XCTAssertEqual(RemoteListingDiff.compare(previous: before,
                                                 current: ["a.txt": file(11, 1_000)]).updated,
                       ["a.txt"], "Andere Groesse.")
        XCTAssertEqual(RemoteListingDiff.compare(previous: before,
                                                 current: ["a.txt": file(10, 2_000)]).updated,
                       ["a.txt"], "Anderer Zeitstempel bei gleicher Groesse.")
        XCTAssertEqual(RemoteListingDiff.compare(
            previous: before,
            current: ["a.txt": RemoteEntry(isDirectory: true, size: 10, modified: 1_000)]).updated,
                       ["a.txt"], "Aus der Datei wurde ein Ordner.")
    }

    func testWhatIsGoneCountsAsDeleted() {
        let change = RemoteListingDiff.compare(
            previous: ["a.txt": file(10), "b.txt": file(20)],
            current: ["a.txt": file(10)])
        XCTAssertEqual(change.deleted, ["b.txt"])
        XCTAssertTrue(change.updated.isEmpty)
    }

    /// Beide Listen sind sortiert. Ohne feste Reihenfolge waere jeder Vergleich in
    /// einem Test zufaellig — Dictionaries geben ihre Schluessel nicht zweimal gleich
    /// heraus.
    func testBothListsComeOutSorted() {
        let change = RemoteListingDiff.compare(
            previous: ["z.txt": file(1), "a.txt": file(1), "m.txt": file(1)],
            current: ["neu-z.txt": file(2), "neu-a.txt": file(2)])
        XCTAssertEqual(change.updated, ["neu-a.txt", "neu-z.txt"])
        XCTAssertEqual(change.deleted, ["a.txt", "m.txt", "z.txt"])
    }

    /// **Der gefaehrliche Fall**, und er steht als Warnung in der Dokumentation der
    /// Funktion: Was in `current` fehlt, gilt als geloescht. Eine leere Liste nach
    /// einem Verbindungsfehler erklaert damit den ganzen Ordner fuer verschwunden.
    ///
    /// Der Test aendert daran nichts — die Funktion *soll* das tun, sie bekommt nur
    /// niemals eine Liste aus einem fehlgeschlagenen Aufruf. Er haelt den Vertrag
    /// fest, damit niemand ihn beim naechsten Umbau versehentlich bricht.
    func testAnEmptyCurrentListingDeclaresEverythingDeleted() {
        let change = RemoteListingDiff.compare(
            previous: ["a.txt": file(1), "b.txt": file(2)], current: [:])
        XCTAssertEqual(change.deleted, ["a.txt", "b.txt"])
    }

    /// Andersherum der harmlose Fall: der erste Lauf kennt nichts und findet alles.
    func testAnEmptyPreviousStateMakesEverythingNew() {
        let change = RemoteListingDiff.compare(
            previous: [:], current: ["a.txt": file(1), "b.txt": file(2)])
        XCTAssertEqual(change.updated, ["a.txt", "b.txt"])
        XCTAssertTrue(change.deleted.isEmpty)
    }
}
