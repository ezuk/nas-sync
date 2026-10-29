import CoreWLAN
import Foundation
import IOKit.ps

public struct PowerState: Sendable, Equatable {
    public var onBattery: Bool
    /// 0 to 100, nil on machines without a battery.
    public var percent: Int?

    public init(onBattery: Bool, percent: Int?) {
        self.onBattery = onBattery
        self.percent = percent
    }

    public static func current() -> PowerState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerState(onBattery: false, percent: nil)
        }
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = source == kIOPSBatteryPowerValue
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return PowerState(onBattery: onBattery, percent: cap * 100 / max)
        }
        return PowerState(onBattery: onBattery, percent: nil)
    }
}

public enum BatteryRule {
    public enum Decision: Sendable, Equatable {
        case run
        /// Wait, but run anyway at `until` even if the battery stays low.
        case holdOff(percent: Int, until: Date)
    }

    /// Holds off only on battery, below the threshold, and while the last success is recent enough.
    public static func decide(power: PowerState, lastSuccess: Date?, config: BatteryConfig, now: Date) -> Decision {
        guard power.onBattery, let percent = power.percent, percent < config.holdBelowPercent,
              let lastSuccess else { return .run }
        let until = lastSuccess.addingTimeInterval(config.butNotLongerThan.seconds)
        return now < until ? .holdOff(percent: percent, until: until) : .run
    }
}

public enum WiFi {
    /// Current network name. nil when Wi-Fi is off, disconnected, or Location permission is missing.
    public static func currentName() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    public static var isPoweredOn: Bool {
        CWWiFiClient.shared().interface()?.powerOn() ?? false
    }
}

public enum Schedule {
    /// When the next run is due. With `around`, runs aim for that time of day; missed runs are due immediately.
    public static func nextDue(lastSuccess: Date?, every: Interval, around: TimeOfDay?, now: Date, calendar: Calendar = .current) -> Date {
        guard let lastSuccess else { return now }
        guard let around else { return lastSuccess.addingTimeInterval(every.seconds) }
        // Slots fall at `around` plus multiples of `every`. A run up to half an interval (max 12h) early still counts.
        let earliest = lastSuccess.addingTimeInterval(every.seconds - min(every.seconds / 2, 12 * 3600))
        if every.seconds >= 86400 { return around.nextOccurrence(after: earliest, calendar: calendar) }
        var slot = around.lastOccurrence(atOrBefore: earliest, calendar: calendar)
        while slot <= earliest { slot.addTimeInterval(every.seconds) }
        return slot
    }

    public static func isDue(lastSuccess: Date?, every: Interval, around: TimeOfDay?, now: Date, calendar: Calendar = .current) -> Bool {
        nextDue(lastSuccess: lastSuccess, every: every, around: around, now: now, calendar: calendar) <= now
    }
}
