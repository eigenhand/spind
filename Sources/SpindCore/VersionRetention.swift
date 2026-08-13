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

/// Which versions stay and which may go.
///
/// A version is a complete copy, so saving space here does not mean
/// compressing but thinning out. The older, the coarser the grid: every
/// version from today, one per day this month, one per week this year,
/// one per month before that. The history reaches much further back
/// than the previous "newest twenty-five" and takes less room doing it.
///
/// Every kept version stays an ordinary file on the server.
public enum VersionRetention {
    /// Within the first day everything stays — that is the window in
    /// which someone thinks "that was me just now, undo it". Only a
    /// program that saves every minute runs into the cap.
    public static let burstCap = 25
    /// Last line of defence across all tiers: with a 2 GB file even a
    /// thin chain costs real space.
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

    /// One key per time bucket. Versions sharing a key are
    /// interchangeable — the newest of them stays.
    private static func bucket(
        for date: Date, now: Date, index: Int, calendar: Calendar
    ) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .weekOfYear, .yearForWeekOfYear], from: date
        )
        switch tier(age: now.timeIntervalSince(date)) {
        case .recent:
            // No bucketing: every version gets its own slot.
            return "recent-\(index)"
        case .daily:
            return "day-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        case .weekly:
            return "week-\(parts.yearForWeekOfYear ?? 0)-\(parts.weekOfYear ?? 0)"
        case .monthly:
            return "month-\(parts.year ?? 0)-\(parts.month ?? 0)"
        }
    }

    /// The versions that may be deleted.
    ///
    /// - Parameter versions: descending by date, newest first.
    /// - Returns: a subset of `versions`. The newest version is **never**
    ///   among them — as long as there is one at all, one is left.
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

        // Last line of defence: whatever exceeds the ceiling falls off the
        // back — the newest versions are the ones people actually look for.
        if kept.count > maxPerFile {
            drop.append(contentsOf: kept.dropFirst(maxPerFile))
        }
        return drop
    }
}
