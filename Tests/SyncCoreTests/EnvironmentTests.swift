import Foundation
import Testing
@testable import SyncCore

@Suite struct EnvironmentTests {
    @Test func quotesForTheRemoteShell() {
        #expect(NAS.quote("plain") == "'plain'")
        #expect(NAS.quote("it's here") == "'it'\\''s here'")
    }

    @Test(.enabled(if: Rsync.find() != nil)) func localNASFileOperations() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nassync-nas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nas = NAS(config: NASConfig(ssh: nil, path: root.path(percentEncoded: false)))
        guard case .success = nas.check() else { Issue.record("local NAS check failed"); return }
        #expect(nas.rsyncTarget("a b") == root.path(percentEncoded: false) + "/a b")

        try nas.write(Data("hello".utf8), to: "x/y/file.txt")
        let tree = try #require(try nas.listTree("x"))
        #expect(tree.contains { $0.path == "y/file.txt" && $0.size == 5 && !$0.isDirectory })
        #expect(tree.contains { $0.path == "y" && $0.isDirectory })
        #expect(try nas.listTree("missing") == nil)
        try nas.remove(["x/y"])
        #expect(try nas.listTree("x")?.isEmpty == true)

        let missing = NAS(config: NASConfig(ssh: nil, path: root.appending(path: "nope").path(percentEncoded: false)))
        guard case .failure(.pathMissing) = missing.check() else { Issue.record("expected pathMissing"); return }
    }

    @Test func batteryRule() {
        let config = BatteryConfig(holdBelowPercent: 30, butNotLongerThan: .hours(12))
        let now = Date(timeIntervalSince1970: 100_000)
        let recent = now.addingTimeInterval(-3600)
        let old = now.addingTimeInterval(-13 * 3600)
        let low = PowerState(onBattery: true, percent: 24)
        #expect(BatteryRule.decide(power: low, lastSuccess: recent, config: config, now: now)
            == .holdOff(percent: 24, until: recent.addingTimeInterval(12 * 3600)))
        #expect(BatteryRule.decide(power: low, lastSuccess: old, config: config, now: now) == .run)
        #expect(BatteryRule.decide(power: low, lastSuccess: nil, config: config, now: now) == .run)
        #expect(BatteryRule.decide(power: PowerState(onBattery: true, percent: 30), lastSuccess: recent, config: config, now: now) == .run)
        #expect(BatteryRule.decide(power: PowerState(onBattery: false, percent: 5), lastSuccess: recent, config: config, now: now) == .run)
    }

    @Test func schedule() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 5, day: d, hour: h, minute: m))! }
        let three = TimeOfDay(hour: 3, minute: 0)

        #expect(Schedule.nextDue(lastSuccess: nil, every: .hours(24), around: three, now: at(1, 10), calendar: cal) == at(1, 10))
        #expect(Schedule.nextDue(lastSuccess: at(1, 3, 5), every: .hours(24), around: three, now: at(1, 10), calendar: cal) == at(2, 3))
        // A manual run in the afternoon doesn't push the next run out by a day.
        #expect(Schedule.nextDue(lastSuccess: at(1, 14), every: .hours(24), around: three, now: at(1, 15), calendar: cal) == at(2, 3))
        // Missed while asleep: due as soon as checked.
        #expect(Schedule.isDue(lastSuccess: at(1, 3), every: .hours(24), around: three, now: at(2, 9), calendar: cal))
        #expect(Schedule.nextDue(lastSuccess: at(1, 3), every: .hours(6), around: three, now: at(1, 4), calendar: cal) == at(1, 9))
        #expect(Schedule.nextDue(lastSuccess: at(1, 5), every: .hours(6), around: nil, now: at(1, 6), calendar: cal) == at(1, 11))
    }
}
