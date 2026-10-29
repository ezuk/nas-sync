import Foundation

/// A length of time written like "30s", "12h", "1h30m" or "2d".
public struct Interval: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var seconds: TimeInterval

    public init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    public static func hours(_ h: Double) -> Interval { Interval(seconds: h * 3600) }
    public static func minutes(_ m: Double) -> Interval { Interval(seconds: m * 60) }

    public init?(parsing text: String) {
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604_800]
        var total = 0.0
        var number = ""
        var sawUnit = false
        for c in text.lowercased() where c != " " {
            if c.isNumber || c == "." {
                number.append(c)
            } else if let unit = units[c], let value = Double(number) {
                total += value * unit
                number = ""
                sawUnit = true
            } else {
                return nil
            }
        }
        guard number.isEmpty, sawUnit, total > 0 else { return nil }
        seconds = total
    }

    public static func < (a: Interval, b: Interval) -> Bool { a.seconds < b.seconds }

    public var description: String {
        var s = Int(seconds)
        var parts: [String] = []
        for (unit, size) in [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)] where s >= size {
            parts.append("\(s / size)\(unit)")
            s %= size
        }
        return parts.isEmpty ? "0s" : parts.joined()
    }
}

/// A local time of day written like "03:00".
public struct TimeOfDay: Sendable, Hashable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public init?(parsing text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        hour = h
        minute = m
    }

    public var description: String { String(format: "%02d:%02d", hour, minute) }

    /// The most recent occurrence of this time at or before `date`.
    public func lastOccurrence(atOrBefore date: Date, calendar: Calendar = .current) -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: date)
        c.hour = hour
        c.minute = minute
        let today = calendar.date(from: c) ?? date
        return today <= date ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    /// The next occurrence of this time strictly after `date`.
    public func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date {
        let last = lastOccurrence(atOrBefore: date, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: last) ?? last
    }
}
