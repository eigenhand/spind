// Spind — Copyright (C) 2026 eigenhand
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

/// E2E: Spind muss in der Dateien-App auftauchen und echte Inhalte von
/// der Box auflisten. Voraussetzung: Spind ist installiert, konfiguriert
/// (App-Gruppe enthält config.json + key) und einmal gestartet worden,
/// damit die File-Provider-Domain registriert ist.
final class FilesIntegrationTests: XCTestCase {
    func testSpindListetBoxInhalteInDerDateienApp() throws {
        // Erst die eigene App starten — registriert die Domain bei Start.
        let spind = XCUIApplication()
        spind.launch()
        sleep(2)

        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()

        // Tab "Durchsuchen"/"Browse" — zweimal antippen landet sicher auf
        // der Wurzelliste mit den Speicherorten.
        let browseTab = files.tabBars.buttons.element(boundBy: 2)
        XCTAssertTrue(browseTab.waitForExistence(timeout: 10), "Tab-Leiste fehlt")
        browseTab.tap()
        sleep(1)
        browseTab.tap()

        // Spind unter den Speicherorten.
        let spindCell = files.cells.staticTexts["Spind"].firstMatch
        XCTAssertTrue(spindCell.waitForExistence(timeout: 15),
                      "Spind fehlt in der Dateien-App – Domain nicht registriert?")
        spindCell.tap()

        // Neue Anbieter startet iOS deaktiviert; beim ersten Antippen
        // fragt die Dateien-App per Dialog — einmal bestätigen.
        let activate = files.alerts.buttons.matching(
            NSPredicate(format: "label IN %@", ["Aktivieren", "Enable"])
        ).firstMatch
        if activate.waitForExistence(timeout: 5) {
            activate.tap()
            _ = files.staticTexts["big64.bin"].waitForExistence(timeout: 5)
            if files.cells.staticTexts["Spind"].firstMatch.exists {
                files.cells.staticTexts["Spind"].firstMatch.tap()
            }
        }

        // Echte Inhalte von der Storage Box (Enumeration über die Extension).
        let marker = files.staticTexts["big64.bin"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 45),
                      "Box-Inhalte erscheinen nicht – Enumeration fehlgeschlagen?")

        let attachment = XCTAttachment(screenshot: files.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
