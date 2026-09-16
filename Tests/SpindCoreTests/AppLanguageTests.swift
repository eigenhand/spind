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

/// Die Sprachwahl.
///
/// Geprueft wird hier die Wahl selbst, nicht das Nachschlagen: SpindCore ist ein
/// Modul ohne App-Buendel, und die Kataloge liegen bei den Apps. Dass beide Sprachen
/// im gebauten Buendel landen, sagt `check-localizations.py` bei jedem Push.
final class AppLanguageTests: XCTestCase {

    /// `system` heisst: der Rechner entscheidet. Faellt das um, waehlt die App fuer
    /// jemanden eine Sprache, der nie eine gewaehlt hat.
    func testSystemMeansTheDeviceDecides() {
        XCTAssertNil(AppLanguage.system.code)
        XCTAssertNil(AppLanguage.system.locale)
    }

    func testTheTwoLanguagesCarryTheirCodes() {
        XCTAssertEqual(AppLanguage.german.code, "de")
        XCTAssertEqual(AppLanguage.english.code, "en")
        XCTAssertEqual(AppLanguage.german.locale?.identifier, "de")
        XCTAssertEqual(AppLanguage.english.locale?.identifier, "en")
    }

    /// Jede Sprache nennt sich in sich selbst — wer die Oberflaeche gerade nicht
    /// versteht, erkennt „English“ auch dann, wenn ringsherum Deutsch steht.
    func testEachLanguageNamesItselfInItsOwnTongue() {
        XCTAssertEqual(AppLanguage.german.label, "Deutsch")
        XCTAssertEqual(AppLanguage.english.label, "English")
    }

    /// Der Rohwert steht in `UserDefaults` unter `uiLanguage` und muss stabil
    /// bleiben: Eine Umbenennung waere fuer jeden, der schon gewaehlt hat, ein
    /// stilles Zuruecksetzen.
    func testTheStoredValuesStayWhatTheyAre() {
        XCTAssertEqual(AppLanguage.system.rawValue, "system")
        XCTAssertEqual(AppLanguage.german.rawValue, "german")
        XCTAssertEqual(AppLanguage.english.rawValue, "english")
        XCTAssertEqual(AppLanguage(rawValue: "english"), .english)
        XCTAssertNil(AppLanguage(rawValue: "klingon"))
    }

    /// Ohne gewaehlte Sprache antwortet das Hauptbuendel — und nicht nichts.
    func testWithoutAChoiceTheMainBundleAnswers() {
        XCTAssertEqual(AppLanguage.system.bundle, Bundle.main)
    }

    func testEveryCaseIsOfferedInTheMenu() {
        XCTAssertEqual(AppLanguage.allCases, [.system, .german, .english])
    }
}
