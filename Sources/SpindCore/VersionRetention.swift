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

/// Welche Fassungen bleiben und welche dürfen weg.
///
/// Eine Fassung ist eine vollständige Kopie — Platz sparen heißt hier also
/// nicht komprimieren, sondern ausdünnen. Je älter, desto grober das Raster:
/// heute jede, diesen Monat eine pro Tag, dieses Jahr eine pro Woche, davor
/// eine pro Monat. Damit reicht der Verlauf viel weiter zurück als die
/// bisherigen »die letzten 25« und belegt dabei weniger.
///
/// Jede behaltene Fassung bleibt eine gewöhnliche Datei auf dem Server.
public enum VersionRetention {
    /// Innerhalb des ersten Tages bleibt alles — das ist das Zeitfenster,
    /// in dem jemand „ich war das gerade, mach das rückgängig" denkt.
    /// Nur ein Programm, das im Minutentakt speichert, wird gedeckelt.
    public static let burstCap = 25
    /// Letzte Reißleine über alle Stufen: Bei einer 2-GB-Datei kostet auch
    /// eine dünne Kette noch echten Platz.
    public static let maxPerFile = 50

    private enum Tier {
        case recent, daily, weekly, monthly
    }

    private static func tier(age: TimeInterval) -> Tier {
        switch age {
        case ..<86_400: return .recent          // < 1 Tag
        case ..<2_592_000: return .daily        // < 30 Tage
        case ..<31_536_000: return .weekly      // < 1 Jahr
        default: return .monthly
        }
    }

    /// Ein Schlüssel je Zeitfach. Fassungen mit demselben Schlüssel sind
    /// austauschbar — die jüngste davon bleibt.
    private static func bucket(
        for date: Date, now: Date, index: Int, calendar: Calendar
    ) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .weekOfYear, .yearForWeekOfYear], from: date
        )
        switch tier(age: now.timeIntervalSince(date)) {
        case .recent:
            // Kein Zusammenfassen: jede Fassung ihr eigenes Fach.
            return "recent-\(index)"
        case .daily:
            return "day-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        case .weekly:
            return "week-\(parts.yearForWeekOfYear ?? 0)-\(parts.weekOfYear ?? 0)"
        case .monthly:
            return "month-\(parts.year ?? 0)-\(parts.month ?? 0)"
        }
    }

    /// Die Fassungen, die gelöscht werden dürfen.
    ///
    /// - Parameter versions: absteigend nach Datum, jüngste zuerst.
    /// - Returns: eine Teilmenge von `versions`. Die jüngste Fassung ist
    ///   **nie** dabei — solange es überhaupt eine gibt, bleibt eine übrig.
    public static func expendable(
        _ versions: [FileVersion], now: Date, calendar: Calendar = .current
    ) -> [FileVersion] {
        guard versions.count > 1 else { return [] }
        let ordered = versions.sorted { $0.date > $1.date }

        var seen: Set<String> = []
        var kept: [FileVersion] = []
        var drop: [FileVersion] = []
        var recentKept = 0

        for (index, version) in ordered.enumerated() {
            let isRecent = tier(age: now.timeIntervalSince(version.date)) == .recent
            if isRecent, recentKept >= burstCap, index > 0 {
                drop.append(version)
                continue
            }
            let key = bucket(for: version.date, now: now, index: index, calendar: calendar)
            if seen.insert(key).inserted {
                kept.append(version)
                if isRecent { recentKept += 1 }
            } else {
                drop.append(version)
            }
        }

        // Reißleine: Was über die Obergrenze hinausgeht, fällt von hinten
        // weg — die jüngsten Fassungen sind die, die jemand wirklich sucht.
        if kept.count > maxPerFile {
            drop.append(contentsOf: kept.dropFirst(maxPerFile))
        }
        return drop
    }
}
