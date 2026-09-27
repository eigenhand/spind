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

/// The rules a folder share follows — pure functions, no network, so the
/// tests can pin them down. The Mac app applies them against the Hetzner
/// API; see SECURITY.md for why each rule exists.
public enum ShareRules {
    /// Hetzner allows this many sub-accounts per storage box. Every share
    /// is one, and so is every paired person and the Collabora account.
    public static let subaccountLimit = 100

    /// A share expires after this many days unless the owner chooses
    /// otherwise. The same number as the Collabora editor token, on purpose:
    /// one number is easier to explain than two.
    public static let defaultValidityDays = 30

    /// Choices offered when creating or extending a share; nil means
    /// "keep until revoked".
    public static let validityChoices: [Int?] = [30, 90, 365, nil]

    /// Label on the sub-account that carries the expiry day (yyyy-MM-dd, UTC).
    /// Labels rather than the description: structured, and changeable with
    /// a PUT that leaves the credentials — and thus every link already sent
    /// — intact. Hetzner label values allow letters, digits, `-`, `_` and `.`,
    /// which rules out an ISO timestamp with colons.
    public static let expiresLabel = "spind-expires-on"

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// The day a share created now with the given validity is removed from;
    /// nil validity means no expiry. Always the start of a UTC day, so the
    /// label round-trips exactly.
    public static func expiry(validFor days: Int?, from now: Date = Date()) -> Date? {
        guard let days else { return nil }
        let calendar = utcCalendar
        let target = calendar.date(byAdding: .day, value: days, to: now) ?? now
        return calendar.startOfDay(for: target)
    }

    public static func expiryDate(fromLabels labels: [String: String]) -> Date? {
        guard let value = labels[expiresLabel] else { return nil }
        return dayFormatter.date(from: value)
    }

    /// The labels to store for the given expiry; empty for "until revoked".
    public static func labels(expiresOn date: Date?) -> [String: String] {
        guard let date else { return [:] }
        return [expiresLabel: dayFormatter.string(from: date)]
    }

    /// Enforcement is a comparison against the start of the expiry day.
    public static func isExpired(_ expiresOn: Date?, now: Date = Date()) -> Bool {
        guard let expiresOn else { return false }
        return now >= expiresOn
    }

    /// Re-sharing a folder may only lengthen its life, never shorten it —
    /// nobody is thrown out earlier than they were told. "Until revoked"
    /// on either side wins.
    public static func extended(current: Date?, requested: Date?) -> Date? {
        guard let current, let requested else { return nil }
        return max(current, requested)
    }

    /// How many sub-accounts can still be created.
    public static func remainingSlots(used: Int) -> Int {
        max(0, subaccountLimit - used)
    }

    /// Reads the share credentials back out of the share page. The page
    /// carries its own Basic-Auth header as a JavaScript constant, and it
    /// lies inside the shared folder, which the owner reads over SFTP —
    /// so a second Mac can recover what the first one put in its Keychain.
    public static func credentials(fromSharePage html: String) -> (username: String, password: String)? {
        guard let range = html.range(of: #"const AUTH = "Basic ([A-Za-z0-9+/=]+)""#, options: .regularExpression)
        else { return nil }
        let match = html[range]
        guard let start = match.range(of: "Basic ")?.upperBound else { return nil }
        let encoded = match[start...].dropLast()
        guard let data = Data(base64Encoded: String(encoded)),
              let pair = String(data: data, encoding: .utf8),
              let colon = pair.firstIndex(of: ":")
        else { return nil }
        let username = String(pair[..<colon])
        let password = String(pair[pair.index(after: colon)...])
        guard !username.isEmpty, !password.isEmpty else { return nil }
        return (username, password)
    }
}
