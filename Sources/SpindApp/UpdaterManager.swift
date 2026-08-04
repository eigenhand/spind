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

import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// Automatische Updates über Sparkle. Der Appcast liegt als Datei beim
/// jeweils neuesten GitHub-Release (SUFeedURL in der Info.plist), jede
/// DMG ist mit dem EdDSA-Schlüssel signiert (SUPublicEDKey).
///
/// Sparkle hängt nur am Xcode-Projekt (project.yml); beim reinen
/// SPM-Build (swift build/test) läuft ein No-op-Ersatz.
@MainActor
final class UpdaterManager {
    static let shared = UpdaterManager()

    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
    #else
    private init() {}

    func checkForUpdates() {}
    #endif

    /// Startet die Hintergrund-Prüfung — einmal beim App-Start aufrufen.
    func start() {}
}
