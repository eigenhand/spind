// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// Automatic updates through Sparkle. The appcast sits as a file with
/// the newest GitHub release (SUFeedURL in the Info.plist), every DMG is
/// signed with the EdDSA key (SUPublicEDKey).
///
/// Sparkle hangs off the Xcode project (project.yml) only; a plain SPM
/// build (swift build/test) runs a no-op stand-in.
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

    /// Starts the background check — call once at app launch.
    func start() {}
}
