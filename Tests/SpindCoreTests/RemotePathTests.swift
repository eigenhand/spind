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

/// Namen, die vom Server kommen.
///
/// Der Server ist nicht immer unserer: eine geteilte Box traegt fremde Ordner, und
/// Spind spricht mit jedem SFTP-Host. Aus so einem Namen wird ein lokaler Pfad, und
/// ein ".." darin laeuft geradewegs aus dem Sync-Ordner heraus.
///
/// Sechs Zeilen Code an zwei Stellen — dem Sync-Motor und der File-Provider-
/// Erweiterung. Bis hierher war keine davon geprueft.
final class RemotePathTests: XCTestCase {

    // MARK: Was durchkommt

    func testOrdinaryNamesPass() {
        XCTAssertTrue(RemotePath.isSafe("Rechnung.pdf"))
        XCTAssertTrue(RemotePath.isSafe("Projekte/2026/Notizen.md"))
        XCTAssertTrue(RemotePath.isSafe("Ordner mit Leerzeichen/Datei.txt"))
        XCTAssertTrue(RemotePath.isSafe("Müller & Söhne/Angebot.docx"))
        XCTAssertTrue(RemotePath.isSafe("a"))
    }

    /// Nur eine **ganze** Komponente zaehlt. Ein Name, der zufaellig zwei Punkte
    /// enthaelt, ist ein gewoehnlicher Name — und wer ihn sperrt, macht die Datei
    /// unerreichbar, ohne irgendetwas sicherer zu machen.
    func testDotsInsideANameAreOrdinary() {
        XCTAssertTrue(RemotePath.isSafe("..versteckt"))
        XCTAssertTrue(RemotePath.isSafe("Datei..txt"))
        XCTAssertTrue(RemotePath.isSafe("endet.mit.."))
        XCTAssertTrue(RemotePath.isSafe("Ordner/..name/Datei"))
        XCTAssertTrue(RemotePath.isSafe("."), "Ein einzelner Punkt fuehrt nirgendwohin.")
    }

    // MARK: Was nicht durchkommt

    /// Der Fall, um den es geht: an "~/Spind" ein "../../evil.txt" angehaengt landet
    /// in "/Users".
    func testAParentComponentIsRefusedWhereverItStands() {
        XCTAssertFalse(RemotePath.isSafe(".."))
        XCTAssertFalse(RemotePath.isSafe("../evil.txt"))
        XCTAssertFalse(RemotePath.isSafe("../../evil.txt"))
        XCTAssertFalse(RemotePath.isSafe("Ordner/../../evil.txt"))
        XCTAssertFalse(RemotePath.isSafe("Ordner/.."))
        XCTAssertFalse(RemotePath.isSafe("a/b/../c"))
    }

    /// Doppelte Schraegstriche duerfen die Pruefung nicht aushebeln: "a//../b" hat
    /// eine leere Komponente in der Mitte, und ein naiver Vergleich ueber alle
    /// Teilstuecke koennte darueber stolpern.
    func testEmptyComponentsDoNotHideAParent() {
        XCTAssertFalse(RemotePath.isSafe("a//../b"))
        XCTAssertFalse(RemotePath.isSafe("//../"))
    }

    func testTheEmptyNameAndEmbeddedNullAreRefused() {
        XCTAssertFalse(RemotePath.isSafe(""))
        XCTAssertFalse(RemotePath.isSafe("Datei\0.txt"))
        XCTAssertFalse(RemotePath.isSafe("\0"))
    }

    // MARK: Was die Pruefung *nicht* tut

    /// Ein fuehrender Schraegstrich kommt durch, und das ist kein Versehen: beide
    /// Aufrufer haengen den Namen an einen Wurzelpfad, und dabei bleibt er innerhalb.
    /// Der Test steht hier, damit die Entscheidung sichtbar ist — wer die Pruefung
    /// spaeter woanders benutzt, wo ein absoluter Pfad absolut bliebe, liest hier,
    /// dass sie ihn nicht abfaengt.
    func testAnAbsoluteLookingNameIsNotRefusedHere() {
        XCTAssertTrue(RemotePath.isSafe("/etc/passwd"))
    }
}
