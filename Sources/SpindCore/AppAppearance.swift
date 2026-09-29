// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Light or dark.
///
/// The default follows the system, and that is more than convenience: macOS and iOS
/// switch at dusk, and whoever set that up wants it everywhere. The two fixed values are
/// for the cases where somebody knows better.
public enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// `nil` means: the system decides.
    public var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    public var label: String {
        switch self {
        case .system: return String(localized: "Wie das System")
        case .light:  return String(localized: "Hell")
        case .dark:   return String(localized: "Dunkel")
        }
    }

    #if os(macOS)
    /// On the Mac `.preferredColorScheme` is not enough: the menu bar window and the
    /// panels hang on the appearance of the application, not on a single view.
    /// `NSApp.appearance` colours everything at once — and `nil` hands it back to the
    /// system.
    @MainActor
    public func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
    }
    #endif
}
