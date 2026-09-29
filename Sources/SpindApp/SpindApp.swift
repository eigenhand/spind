// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import SpindCore
import AppKit

@main
struct SpindApp: App {
    @StateObject private var controller = SyncController.shared

    init() {
        // Before anything else: whatever is drawn afterwards should come into being
        // in the chosen language already. The menu bar window rebuilds itself every
        // time it opens, so the start here and the change at the picker are enough —
        // a menu bar app has no root view for a change to hang on.
        AppLanguage.apply(UserDefaults.standard.string(forKey: "uiLanguage")
            .flatMap(AppLanguage.init(rawValue:)) ?? .system)
        (UserDefaults.standard.string(forKey: "uiAppearance")
            .flatMap(AppAppearance.init(rawValue:)) ?? .system).apply()

        let isPreview = ProcessInfo.processInfo.environment["SPIND_PREVIEW"] != nil
        NSApplication.shared.setActivationPolicy(isPreview ? .regular : .accessory)
        if isPreview {
            Self.openPreviewWindow()
        }
        // Start Sparkle early so the background check runs.
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
