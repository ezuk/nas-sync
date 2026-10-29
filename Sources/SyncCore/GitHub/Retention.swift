import Foundation

/// Archive names and the daily/weekly/monthly/quarterly retention rules.
/// Matches the format and rules of the original `github-backup` tool so existing archives carry over.
public enum ArchiveNaming {
    public static let suffix = ".bundle.xz"

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// `YYMMDD-owner-repo.bundle.xz`
    public static func name(owner: String, repo: String, date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d%02d%02d-%@-%@%@", (c.year ?? 0) % 100, c.month ?? 0, c.day ?? 0, owner, repo, suffix)
    }

    /// The date encoded at the start of an archive name, at local midnight.
    public static func date(fromName name: String) -> Date? {
        let chars = Array(name)
        guard chars.count >= 7, chars[6] == "-", chars[0..<6].allSatisfy(\.isNumber),
              let yy = Int(String(chars[0..<2])), let mm = Int(String(chars[2..<4])), let dd = Int(String(chars[4..<6])),
              (1...12).contains(mm), (1...31).contains(dd) else { return nil }
        var comps = DateComponents(year: 2000 + yy, month: mm, day: dd)
        comps.hour = 0
        guard let date = calendar.date(from: comps),
              calendar.component(.day, from: date) == dd else { return nil }
        return date
    }
}

public struct ArchiveFile: Sendable, Equatable {
    public var name: String
    public var date: Date
    public var size: Int64

    public init(name: String, date: Date, size: Int64 = 0) {
        self.name = name
        self.date = date
        self.size = size
    }
}

public enum Retention {
    /// Splits archives into kept and deleted. Never deletes every archive.
    public static func apply(_ archives: [ArchiveFile], policy: RetentionPolicy, now: Date) -> (keep: [ArchiveFile], delete: [ArchiveFile]) {
        guard !archives.isEmpty else { return ([], []) }
        let sorted = archives.sorted { $0.date > $1.date }
        var keep: [String] = []
        var remaining = sorted

        func take(_ a: ArchiveFile) { keep.append(a.name) }

        // Newest N.
        for a in remaining.prefix(policy.daily) { take(a) }
        remaining.removeAll { keep.contains($0.name) }

        // One per week, within the last 4 weeks.
        var seenWeeks: Set<String> = []
        var weeks = 0
        for a in remaining where now.timeIntervalSince(a.date) <= 28 * 86400 {
            let key = weekKey(a.date)
            if !seenWeeks.contains(key), weeks < policy.weekly {
                take(a)
                seenWeeks.insert(key)
                weeks += 1
            }
        }
        remaining.removeAll { keep.contains($0.name) }

        // One per month, within the last 90 days.
        var seenMonths: Set<String> = []
        var months = 0
        for a in remaining where now.timeIntervalSince(a.date) <= 90 * 86400 {
            let c = ArchiveNaming.calendar.dateComponents([.year, .month], from: a.date)
            let key = "\(c.year ?? 0)-\(c.month ?? 0)"
            if !seenMonths.contains(key), months < policy.monthly {
                take(a)
                seenMonths.insert(key)
                months += 1
            }
        }
        remaining.removeAll { keep.contains($0.name) }

        // One aged 60 to 365 days.
        var quarters = 0
        for a in remaining {
            let age = now.timeIntervalSince(a.date)
            if age >= 60 * 86400, age <= 365 * 86400, quarters < policy.quarterly {
                take(a)
                quarters += 1
            }
        }

        var kept = sorted.filter { keep.contains($0.name) }
        if kept.count > policy.max { kept = Array(kept.prefix(policy.max)) }
        if kept.isEmpty, let newest = sorted.first { kept = [newest] }
        let keptNames = Set(kept.map(\.name))
        return (kept, sorted.filter { !keptNames.contains($0.name) })
    }

    /// Python's `%Y-%W`: weeks start on Monday, days before the first Monday are week 0.
    static func weekKey(_ date: Date) -> String {
        let cal = ArchiveNaming.calendar
        let year = cal.component(.year, from: date)
        let yday = (cal.ordinality(of: .day, in: .year, for: date) ?? 1) - 1
        let weekdayMondayZero = (cal.component(.weekday, from: date) + 5) % 7
        return "\(year)-\((yday + 7 - weekdayMondayZero) / 7)"
    }
}
