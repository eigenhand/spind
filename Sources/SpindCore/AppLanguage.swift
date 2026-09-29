// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The language of the interface.
///
/// iOS and macOS already have a setting for this — it sits in the system settings under
/// the app and forces a restart. This one takes effect at once.
///
/// What carries it is the bundle: `Bundle.main` gets a subclass slipped underneath it at
/// runtime that redirects every lookup into the chosen `.lproj`. Everything then follows
/// the same choice — `Text`, `String(localized:)`, and an error message that arises deep
/// inside a model and sees no environment.
///
/// `.environment(\.locale, …)` at the root stands beside it and does **not** replace it.
/// It does two other things: numbers, dates and sorting look the way they do in that
/// language, and its change is the nudge on which SwiftUI rebuilds the views.
///
/// The limit stays: system dialogs asking for the camera or the microphone do not belong
/// to the app. They follow the device's language.
public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case german
    case english

    public var id: String { rawValue }

    /// `nil` means: the device decides.
    public var code: String? {
        switch self {
        case .system:  return nil
        case .german:  return "de"
        case .english: return "en"
        }
    }

    /// The locale for numbers, dates and sorting. `nil` leaves the device's in place.
    public var locale: Locale? { code.map(Locale.init(identifier:)) }

    /// Every language names itself — whoever does not currently understand the interface
    /// recognises “English” even when German stands all around it. Only the system line
    /// is translated, because it describes no language but a decision.
    public var label: String {
        switch self {
        case .system:  return String(localized: "Sprache des Geräts")
        case .german:  return "Deutsch"
        case .english: return "English"
        }
    }

    /// The bundle that text outside SwiftUI comes from — error messages, say, that arise
    /// in a model and see no environment. If the language is missing from the bundle, the
    /// main bundle remains; a missing `.lproj` is no reason to have no text at all.
    public var bundle: Bundle {
        guard let code,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }

    // MARK: Applying

    /// Redirects every lookup in this app to the chosen language.
    ///
    /// On the first call `Bundle.main` has its class swapped. That is the intervention
    /// this function has to justify: there is no supported place to change the language
    /// of a running app, and the alternative would be to have every call in the source
    /// carry a bundle along — and to forget it on one of them.
    @MainActor
    public static func apply(_ language: AppLanguage) {
        if !swapped {
            object_setClass(Bundle.main, SwitchableBundle.self)
            swapped = true
        }
        SwitchableBundle.chosen = language.code.flatMap {
            Bundle.main.path(forResource: $0, ofType: "lproj").flatMap(Bundle.init(path:))
        }
    }

    @MainActor private static var swapped = false
}

/// The class slipped underneath. It answers exactly one question differently from the
/// original and passes everything else along.
private final class SwitchableBundle: Bundle, @unchecked Sendable {
    /// `nil` means: the device decides, so let the original answer.
    nonisolated(unsafe) static var chosen: Bundle?

    override func localizedString(forKey key: String, value: String?, table: String?) -> String {
        guard let chosen = SwitchableBundle.chosen else {
            return super.localizedString(forKey: key, value: value, table: table)
        }
        return chosen.localizedString(forKey: key, value: value, table: table)
    }
}
