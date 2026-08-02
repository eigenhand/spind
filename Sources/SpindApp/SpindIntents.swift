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

import AppIntents

/// Shortcuts/Siri actions: automate Spind from the Kurzbefehle app,
/// Siri, or the command line (`shortcuts run …`).

struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Spind synchronisieren"
    static let description = IntentDescription(
        "Stößt sofort eine Synchronisierung mit der Storage Box an."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SyncController.shared.syncNow()
        return .result(dialog: "Synchronisierung gestartet.")
    }
}

struct FreeSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Spind-Speicher freigeben"
    static let description = IntentDescription(
        "Entlädt lange ungenutzte Dateien aus dem Finder-Volume; sie bleiben in der Cloud verfügbar."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = await SyncController.shared.runStorageOptimizer(manual: true)
        return .result(dialog: "\(summary)")
    }
}

struct SpindStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Spind-Status"
    static let description = IntentDescription("Meldet den aktuellen Sync-Status.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(SyncController.shared.statusText)")
    }
}

struct SpindShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: ["Synchronisiere \(.applicationName)"],
            shortTitle: "Synchronisieren",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: FreeSpaceIntent(),
            phrases: ["Gib Speicher in \(.applicationName) frei"],
            shortTitle: "Speicher freigeben",
            systemImageName: "internaldrive"
        )
        AppShortcut(
            intent: SpindStatusIntent(),
            phrases: ["Wie ist der \(.applicationName) Status"],
            shortTitle: "Status",
            systemImageName: "checkmark.icloud"
        )
    }
}
