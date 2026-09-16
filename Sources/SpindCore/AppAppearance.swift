// Spind — Copyright (C) 2026 Christoph Lindl-Guk
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
#if os(macOS)
import AppKit
#endif

/// Hell oder dunkel.
///
/// Die Vorgabe folgt dem System, und das ist mehr als Bequemlichkeit: macOS und iOS
/// schalten zur Daemmerung um, und wer das eingestellt hat, will es ueberall. Die
/// beiden festen Werte sind fuer die Faelle, in denen jemand es besser weiss.
public enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// `nil` heisst: das System entscheidet.
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
    /// Am Mac reicht `.preferredColorScheme` nicht: Das Menueleisten-Fenster und die
    /// Panels haengen an der Erscheinung der Anwendung, nicht an einer einzelnen
    /// Ansicht. `NSApp.appearance` faerbt alles auf einmal — und `nil` gibt es an
    /// das System zurueck.
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
