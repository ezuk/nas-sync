import Foundation
import Testing
@testable import SyncCore

@Suite struct EnvironmentTests {
    @Test func quotesForTheRemoteShell() {
        #expect(NAS.quote("plain") == "'plain'")
        #expect(NAS.quote("it's here") == "'it'\\''s here'")
    }

    @Test func commandsForGettingAMirrorBack() {
        let ssh = NAS(config: NASConfig(ssh: "me@nas.local", path: "/volume1/me"))
        #expect(ssh.gitCloneURL("m/a.git") == "me@nas.local:/volume1/me/m/a.git")
        #expect(ssh.copyDownCommand("m/a.git", to: "a.git") == "rsync -rt --rsync-path=/usr/bin/rsync 'me@nas.local:/volume1/me/m/a.git/' 'a.git/'")
        let port = NAS(config: NASConfig(ssh: "me@nas.local", port: 5577, path: "/volume1/me"))
        #expect(port.gitCloneURL("m/a.git") == "ssh://me@nas.local:5577/volume1/me/m/a.git")
        #expect(port.copyDownCommand("m/a.git", to: "a.git") == "rsync -rt -e 'ssh -p 5577' --rsync-path=/usr/bin/rsync 'me@nas.local:/volume1/me/m/a.git/' 'a.git/'")
        let local = NAS(config: NASConfig(ssh: nil, path: "/Volumes/Backup"))
        #expect(local.copyDownCommand("m/a.git", to: "a.git") == "rsync -rt '/Volumes/Backup/m/a.git/' 'a.git/'")
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

    @Test(.enabled(if: Rsync.find() != nil)) func uploadFolderSendsPackedRefsLast() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "nassync-upload-\(UUID().uuidString)")
        let local = root.appending(path: "local")
        let nasRoot = root.appending(path: "nas")
        try fm.createDirectory(at: local.appending(path: "objects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: nasRoot.appending(path: "a.git"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("refs".utf8).write(to: local.appending(path: "packed-refs"))
        try Data("object".utf8).write(to: local.appending(path: "objects/a"))
        try Data("old".utf8).write(to: nasRoot.appending(path: "a.git/stale"))

        // Logs each rsync call, then runs the real one.
        let log = root.appending(path: "rsync.log").path(percentEncoded: false)
        let wrapper = root.appending(path: "rsync")
        let real = try #require(Rsync.find()).path(percentEncoded: false)
        try Data("#!/bin/sh\necho \"$*\" >> '\(log)'\nexec '\(real)' \"$@\"\n".utf8).write(to: wrapper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path(percentEncoded: false))

        let nas = NAS(config: NASConfig(ssh: nil, path: nasRoot.path(percentEncoded: false), rsync: wrapper.path(percentEncoded: false)))
        let sent = try nas.uploadFolder(local, to: "a.git")

        let calls = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").filter { $0.contains("--stats") }
        #expect(calls.count == 2)
        #expect(calls[0].contains("--exclude=/packed-refs") && !calls[0].contains("--delete-after"))
        #expect(calls[1].contains("--delete-after") && !calls[1].contains("--exclude"))
        #expect(sent == 10)
        let tree = try #require(try nas.listTree("a.git")).map(\.path)
        #expect(tree.contains("packed-refs") && tree.contains("objects/a") && !tree.contains("stale"))
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
