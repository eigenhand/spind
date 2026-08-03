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

import SwiftUI
import AppKit

@main
struct SpindApp: App {
    @StateObject private var controller = SyncController.shared

    init() {
        let isPreview = ProcessInfo.processInfo.environment["SPIND_PREVIEW"] != nil
        NSApplication.shared.setActivationPolicy(isPreview ? .regular : .accessory)
        if isPreview {
            Self.openPreviewWindow()
        }
        // Sparkle früh starten, damit die Hintergrund-Prüfung läuft.
        UpdaterManager.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(controller: controller)
        } label: {
            Image(systemName: controller.statusSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
        }
    }

    /// Debug-only: renders panel + settings in a normal window so the UI
    /// can be screenshotted without clicking the menu bar item.
    private static func openPreviewWindow() {
        DispatchQueue.main.async {
            let controller = SyncController(demo: true)
            let view = HStack(alignment: .top, spacing: 24) {
                PanelView(controller: controller)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                SettingsView(controller: controller)
            }
            .padding(24)
            .frame(minWidth: 940, minHeight: 620, alignment: .top)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Spind Preview"
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let screen = NSScreen.main {
                    let frame = screen.visibleFrame
                    window.setFrame(
                        NSRect(x: frame.minX + 20, y: frame.maxY - 780,
                               width: 960, height: 760),
                        display: true
                    )
                }
            }
        }
    }
}
