// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// E2E: Spind has to show up in the Files app and list real content
/// from the box. Prerequisite: Spind is installed, configured (the app
/// group holds config.json and key) and has been launched once, so that
/// the file provider domain is registered.
final class FilesIntegrationTests: XCTestCase {
    func testSpindListetBoxInhalteInDerDateienApp() throws {
        // Launch our own app first — it registers the domain on launch.
        let spind = XCUIApplication()
        spind.launch()
        sleep(2)

        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()

        // Tab "Durchsuchen"/"Browse" — zweimal antippen landet sicher auf
        // the root list with the storage locations.
        let browseTab = files.tabBars.buttons.element(boundBy: 2)
        XCTAssertTrue(browseTab.waitForExistence(timeout: 10), "Tab-Leiste fehlt")
        browseTab.tap()
        sleep(1)
        browseTab.tap()

        // Spind among the storage locations.
        let spindCell = files.cells.staticTexts["Spind"].firstMatch
        XCTAssertTrue(spindCell.waitForExistence(timeout: 15),
                      "Spind fehlt in der Dateien-App – Domain nicht registriert?")
        spindCell.tap()

        // iOS starts new providers switched off; on the first tap the
        // Files app asks in a dialog — confirm once.
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

        // Real content from the storage box (enumerated by the extension).
        let marker = files.staticTexts["big64.bin"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 45),
                      "Box-Inhalte erscheinen nicht – Enumeration fehlgeschlagen?")

        let attachment = XCTAttachment(screenshot: files.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
