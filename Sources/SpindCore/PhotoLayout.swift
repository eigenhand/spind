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

/// Wohin ein Foto einsortiert wird. Der Aufnahmezeitpunkt bestimmt die
/// Ordner — nicht der Zeitpunkt des Hochladens, sonst landet ein spät
/// nachgereichtes Bild im falschen Monat.
public enum PhotoLayout: String, Codable, CaseIterable, Sendable {
    /// Bilder/2026/08
    case yearMonth
    /// Bilder/2026/August
    case yearMonthName
    /// Bilder/2026
    case year
    /// Alles direkt in den Zielordner
    case flat

    public var label: String {
        switch self {
        case .yearMonth: return "Jahr / Monat (2026 / 08)"
        case .yearMonthName: return "Jahr / Monatsname (2026 / August)"
        case .year: return "Nur Jahr (2026)"
        case .flat: return "Alles in einen Ordner"
        }
    }

    /// Die Unterordner unterhalb des Zielordners.
    public func components(for date: Date, calendar: Calendar = .current,
                           locale: Locale = .current) -> [String] {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return [] }
        switch self {
        case .flat:
            return []
        case .year:
            return [String(year)]
        case .yearMonth:
            return [String(year), String(format: "%02d", month)]
        case .yearMonthName:
            return [String(year), Self.monthName(month, locale: locale)]
        }
    }

    /// Der vollständige Pfad relativ zur Wurzel des Spinds.
    public func path(for date: Date, folder: String, fileName: String,
                     calendar: Calendar = .current, locale: Locale = .current) -> String {
        var parts = folder
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        parts += components(for: date, calendar: calendar, locale: locale)
        parts.append(fileName)
        return parts.joined(separator: "/")
    }

    /// Ausgeschriebener Monat in der Sprache des Geräts, mit führender Zahl
    /// gäbe es Sortierprobleme — die Ordner stehen ohnehin unter dem Jahr.
    static func monthName(_ month: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let names = calendar.standaloneMonthSymbols
        guard month >= 1, month <= names.count else { return String(format: "%02d", month) }
        return names[month - 1]
    }
}
