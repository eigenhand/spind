// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

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
