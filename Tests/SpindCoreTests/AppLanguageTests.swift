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

/// The language choice.
///
/// What is checked here is the choice itself, not the lookup: SpindCore is a module
/// without an app bundle, and the catalogues live with the apps. That both languages end
/// up in the built bundle is what `check-localizations.py` says on every push.
final class AppLanguageTests: XCTestCase {

    /// `system` means: the machine decides. If that falls over, the app picks a language
    /// for somebody who never picked one.
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

    /// Every language names itself — whoever does not currently understand the interface
    /// recognises “English” even when German stands all around it.
    func testEachLanguageNamesItselfInItsOwnTongue() {
        XCTAssertEqual(AppLanguage.german.label, "Deutsch")
        XCTAssertEqual(AppLanguage.english.label, "English")
    }

    /// The raw value sits in `UserDefaults` under `uiLanguage` and has to stay stable:
    /// renaming it would be a silent reset for everyone who has already chosen.
    func testTheStoredValuesStayWhatTheyAre() {
        XCTAssertEqual(AppLanguage.system.rawValue, "system")
        XCTAssertEqual(AppLanguage.german.rawValue, "german")
        XCTAssertEqual(AppLanguage.english.rawValue, "english")
        XCTAssertEqual(AppLanguage(rawValue: "english"), .english)
        XCTAssertNil(AppLanguage(rawValue: "klingon"))
    }

    /// Without a chosen language the main bundle answers — and not nothing.
    func testWithoutAChoiceTheMainBundleAnswers() {
        XCTAssertEqual(AppLanguage.system.bundle, Bundle.main)
    }

    func testEveryCaseIsOfferedInTheMenu() {
        XCTAssertEqual(AppLanguage.allCases, [.system, .german, .english])
    }
}
