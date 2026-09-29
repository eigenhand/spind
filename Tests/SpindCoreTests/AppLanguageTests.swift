// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

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
