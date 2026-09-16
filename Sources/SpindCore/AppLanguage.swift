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

import Foundation

/// Die Sprache der Oberfläche.
///
/// iOS kennt dafür bereits eine Einstellung — sie steht in den Systemeinstellungen
/// unter der App und erzwingt einen Neustart. Diese hier wirkt sofort.
///
/// Getragen wird das vom Bündel: `Bundle.main` bekommt zur Laufzeit eine Unterklasse
/// untergeschoben, die jedes Nachschlagen in das gewählte `.lproj` umleitet. Damit
/// folgt alles derselben Wahl — `Text`, `String(localized:)`, und auch eine
/// Fehlermeldung, die tief in einem Modell entsteht und keine Umgebung sieht.
///
/// `.environment(\.locale, …)` an der Wurzel steht daneben und ersetzt das **nicht**.
/// Es tut zwei andere Dinge: Zahlen, Daten und Sortierung sehen aus wie in dieser
/// Sprache, und seine Änderung ist der Anstoß, auf den SwiftUI die Ansichten neu
/// baut — ohne ihn bliebe die alte Sprache stehen, bis der Nutzer irgendwohin tippt.
/// Ob es für sich genommen auch das Nachschlagen umstellen würde, ist hier nicht
/// geprüft; für den Text aus den Modellen reichte es ohnehin nicht.
///
/// Die Grenze bleibt: Systemdialoge, die nach Kamera oder Mikrofon fragen, gehören
/// nicht der App. Sie folgen der Sprache des Geräts, und dafür liegen die Texte
/// übersetzt in `InfoPlist.xcstrings`.
public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case german
    case english

    public var id: String { rawValue }

    /// `nil` heißt: das Gerät entscheidet.
    public var code: String? {
        switch self {
        case .system:  return nil
        case .german:  return "de"
        case .english: return "en"
        }
    }

    /// Die Locale für Zahlen, Daten und Sortierung. `nil` lässt die des Geräts stehen.
    public var locale: Locale? { code.map(Locale.init(identifier:)) }

    /// Jede Sprache nennt sich selbst — wer die Oberfläche gerade nicht versteht,
    /// erkennt „English“ auch dann, wenn ringsherum Deutsch steht. Nur die
    /// Systemzeile wird übersetzt, denn sie beschreibt keine Sprache, sondern eine
    /// Entscheidung.
    public var label: String {
        switch self {
        case .system:  return String(localized: "Sprache des Geräts")
        case .german:  return "Deutsch"
        case .english: return "English"
        }
    }

    /// Das Bündel, aus dem Text außerhalb von SwiftUI kommt — Fehlermeldungen etwa,
    /// die in einem Modell entstehen und keine Umgebung sehen. Fehlt die Sprache im
    /// Bündel, bleibt es beim Hauptbündel; ein fehlendes `.lproj` ist kein Grund,
    /// gar keinen Text mehr zu haben.
    public var bundle: Bundle {
        guard let code,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }

    // MARK: Anwenden

    /// Leitet jedes Nachschlagen in dieser App auf die gewählte Sprache um.
    ///
    /// Beim ersten Aufruf wird `Bundle.main` die Klasse getauscht. Das ist der
    /// Eingriff, den diese Funktion rechtfertigen muss: Es gibt keine unterstützte
    /// Stelle, an der sich die Sprache einer laufenden App umstellen lässt, und die
    /// Alternative wäre, jeden der jeden Aufruf im Quelltext ein Bündel
    /// mittragen zu lassen — und beim dreihundertersten zu vergessen.
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

/// Die untergeschobene Klasse. Sie beantwortet genau eine Frage anders als das
/// Original und reicht alles übrige weiter.
private final class SwitchableBundle: Bundle, @unchecked Sendable {
    /// `nil` heißt: das Gerät entscheidet, also das Original antworten lassen.
    nonisolated(unsafe) static var chosen: Bundle?

    override func localizedString(forKey key: String, value: String?, table: String?) -> String {
        guard let chosen = SwitchableBundle.chosen else {
            return super.localizedString(forKey: key, value: value, table: table)
        }
        return chosen.localizedString(forKey: key, value: value, table: table)
    }
}
