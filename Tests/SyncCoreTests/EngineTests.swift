import Foundation
import Testing
@testable import SyncCore

/// A fake world: Wi-Fi, battery and a NAS that's just a local folder.
private final class FakeWorld: @unchecked Sendable {
    let root: URL
    let wifi = LockedBox<String?>("Home")
    let power = LockedBox(PowerState(onBattery: false, percent: 100))
    let reachable = LockedBox(true)

    init(folderSettings: String = "") throws {
        root = FileManager.default.temporaryDirectory.appending(path: "nassync-engine-\(UUID().uuidString)")
        for dir in [source, nas.appending(path: "Backup"), state, configURL.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try """
        [home]
        wifi = "Home"

        [nas]
        path = "\(nas.path(percentEncoded: false))"

        [battery]
        hold_below_percent = 30
        but_not_longer_than = "12h"

        [folders]
        quiet_period = "1s"
        nightly_check = "\(nightly)"
        \(folderSettings)

        [[folder]]
        name = "Docs"
        source = "\(source.path(percentEncoded: false))"
        dest = "Backup"
        """.write(to: configURL, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var source: URL { root.appending(path: "src") }
    var nas: URL { root.appending(path: "nas") }
    var state: URL { root.appending(path: "state") }
    var configURL: URL { root.appending(path: "config/config.toml") }
    /// A time that has always just passed, so the nightly check doesn't interfere.
    var nightly: String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(3600))
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    var environment: EngineEnvironment {
        EngineEnvironment(
            wifiName: { [wifi] in wifi.get() },
            power: { [power] in power.get() },
            connect: { [reachable] _ in reachable.get() ? .success(()) : .failure(.signIn("me@nas.local")) },
            diagnose: { _, _, _ in [NASCheck.Step(title: "NAS answers over SSH", state: .failed, detail: "refused")] }
        )
    }

    func write(_ rel: String, _ text: String) throws {
        let url = source.appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func nasFile(_ rel: String) -> String? {
        (try? Data(contentsOf: nas.appending(path: "Backup").appending(path: rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Adds a folder to the end of the config, keeping the same file.
    func appendFolder(_ name: String) throws {
        let dir = root.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = try FileHandle(forWritingTo: configURL)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data("""

        [[folder]]
        name = "\(name)"
        source = "\(dir.path(percentEncoded: false))"
        dest = "\(name)"

        """.utf8))
    }

    /// Saves a new battery threshold. Overwrites the file in place, or replaces it when given `.atomic`.
    func setHoldBelow(_ percent: Int, options: Data.WritingOptions = []) throws {
        let text = try String(contentsOf: configURL, encoding: .utf8)
        let updated = text.replacing(/hold_below_percent = \d+/, with: "hold_below_percent = \(percent)")
        try Data(updated.utf8).write(to: configURL, options: options)
    }

    /// Descriptors open on the config file and its folder. A replaced file still reports its old path.
    var configDescriptors: Int {
        let folder = "\(root.lastPathComponent)/config"
        let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return fds.compactMap(Int32.init).filter { fd in
            var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return false }
            let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            return path.hasSuffix(folder) || path.hasSuffix("\(folder)/config.toml")
        }.count
    }
}

@MainActor
private func waitUntil(_ seconds: Double = 15, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
    }
}

@MainActor
private func makeEngine(_ world: FakeWorld) throws -> Engine {
    let engine = Engine(configURL: world.configURL, store: try Store(directory: world.state), environment: world.environment)
    engine.locationAllowed = true
    return engine
}

@Suite(.serialized) @MainActor struct EngineTests {
    @Test func syncsAtHomeAndPicksUpChanges() async throws {
        let world = try FakeWorld()
        try world.write("a.txt", "A")
        let engine = try makeEngine(world)
        engine.start()
        defer { engine.stop() }

        await waitUntil { world.nasFile("a.txt") == "A" && engine.status.state == .upToDate }
        #expect(world.nasFile("a.txt") == "A")
        #expect(engine.status.state == .upToDate)
        #expect(engine.status.jobs.first?.lastSuccess != nil)
        #expect(StatusText.headline(engine.status).title.hasPrefix("Backed up"))

        try world.write("sub/b.txt", "B")
        await waitUntil { world.nasFile("sub/b.txt") == "B" }
        #expect(world.nasFile("sub/b.txt") == "B")
    }

    @Test func syncsChangesAtMostEveryInterval() async throws {
        let world = try FakeWorld(folderSettings: "at_most_every = \"1h\"")
        try world.write("a.txt", "A")
        let engine = try makeEngine(world)
        engine.start()
        defer { engine.stop() }

        await waitUntil { world.nasFile("a.txt") == "A" && engine.status.state == .upToDate }
        try world.write("b.txt", "B")
        await waitUntil { engine.status.jobs.first?.state == .queued }
        await waitUntil(2) { false }
        #expect(world.nasFile("b.txt") == nil)
        let job = try #require(engine.status.jobs.first)
        #expect(job.state == .queued)
        #expect(job.nextRun.map { $0.timeIntervalSinceNow > 3000 } == true)
        #expect(StatusText.jobLine(job).contains("next sync at"))
        #expect(engine.status.state == .upToDate)

        engine.syncFoldersNow()
        await waitUntil { world.nasFile("b.txt") == "B" }
        #expect(world.nasFile("b.txt") == "B")
    }

    @Test func waitsWhileAwayAndCatchesUpAtHome() async throws {
        let world = try FakeWorld()
        world.wifi.set("Cafe")
        try world.write("a.txt", "A")
        let engine = try makeEngine(world)
        engine.start()
        defer { engine.stop() }

        await waitUntil(2) { false }
        #expect(engine.status.state == .away)
        #expect(world.nasFile("a.txt") == nil)
        #expect(StatusText.headline(engine.status).detail.contains("Cafe"))

        world.wifi.set("Home")
        engine.evaluate()
        await waitUntil { world.nasFile("a.txt") == "A" }
        #expect(world.nasFile("a.txt") == "A")
    }

    @Test func holdsOffOnLowBatteryUntilRunAnyway() async throws {
        let world = try FakeWorld()
        try world.write("a.txt", "A")
        let store = try Store(directory: world.state)
        store.setDate(Date().addingTimeInterval(-3600), for: StoreKey.lastSuccess("Docs"))
        world.power.set(PowerState(onBattery: true, percent: 20))
        let engine = Engine(configURL: world.configURL, store: store, environment: world.environment)
        engine.locationAllowed = true
        engine.start()
        defer { engine.stop() }

        await waitUntil(2) { false }
        #expect(engine.status.state == .holdingOff)
        #expect(world.nasFile("a.txt") == nil)
        #expect(StatusText.headline(engine.status).title == "Holding off: battery at 20%")

        engine.runAnyway()
        await waitUntil { world.nasFile("a.txt") == "A" }
        #expect(world.nasFile("a.txt") == "A")
    }

    @Test func reportsConnectionFailureOnceAndRecovers() async throws {
        let world = try FakeWorld()
        world.reachable.set(false)
        try world.write("a.txt", "A")
        let engine = try makeEngine(world)
        let notices = LockedBox<[Notice]>([])
        engine.onNotice = { n in notices.set(notices.get() + [n]) }
        engine.start()
        defer { engine.stop() }

        await waitUntil { engine.status.connectError != nil }
        #expect(engine.status.state == .error)
        #expect(StatusText.headline(engine.status).title == "Can't reach the NAS")
        #expect(engine.status.connectSteps.last?.title == "NAS answers over SSH")
        engine.evaluate()
        #expect(notices.get().filter { $0.title == "Can't reach the NAS" }.count == 1)

        world.reachable.set(true)
        engine.retryConnection()
        await waitUntil { world.nasFile("a.txt") == "A" && engine.status.state == .upToDate }
        #expect(engine.status.connectError == nil)
        #expect(notices.get().contains { $0.title == "Backups are running again" })
    }

    @Test func blocksMassDeleteUntilAllowed() async throws {
        let world = try FakeWorld()
        for i in 0..<20 { try "x".write(to: world.nas.appending(path: "Backup/old\(i).txt"), atomically: true, encoding: .utf8) }
        try world.write("keep.txt", "K")
        let engine = try makeEngine(world)
        engine.start()
        defer { engine.stop() }

        await waitUntil { engine.status.jobs.first?.needsDeleteConfirmation == true }
        #expect(engine.status.state == .error, "\(engine.status.jobs) \((try? engine.store.recentRuns()) ?? [])")
        #expect(world.nasFile("old0.txt") == "x")
        // Blocked runs aren't retried on their own.
        let runs = try engine.store.recentRuns().count
        await waitUntil(2) { false }
        #expect(try engine.store.recentRuns().count == runs, "\((try? engine.store.recentRuns().map { "\($0.trigger) \($0.outcome) \($0.summary)" }) ?? [])")

        engine.allowMassDelete(job: "Docs")
        await waitUntil { world.nasFile("old0.txt") == nil && engine.status.state == .upToDate }
        #expect(world.nasFile("old0.txt") == nil)
        #expect(world.nasFile("keep.txt") == "K")
    }

    @Test func reloadsConfigEditedInPlace() async throws {
        let world = try FakeWorld()
        let engine = try makeEngine(world)
        engine.start()
        defer { engine.stop() }

        for count in 2...4 {
            try world.appendFolder("Extra\(count)")
            await waitUntil(5) { engine.config?.folders.count == count }
            #expect(engine.config?.folders.count == count)
        }

        for percent in [41, 42] {
            try world.setHoldBelow(percent)
            await waitUntil(5) { engine.status.holdBelowPercent == percent }
            #expect(engine.status.holdBelowPercent == percent)
        }

        // Emptying a file only changes its attributes.
        try Data().write(to: world.configURL)
        await waitUntil(5) { !engine.status.configValid }
        #expect(!engine.status.configValid)
    }

    @Test func keepsWatchingConfigAfterItIsReplaced() async throws {
        let world = try FakeWorld()
        let engine = try makeEngine(world)
        engine.start()
        defer { engine.stop() }

        for round in 1...3 {
            try world.setHoldBelow(40 + round, options: .atomic)
            await waitUntil(5) { engine.status.holdBelowPercent == 40 + round }
            #expect(engine.status.holdBelowPercent == 40 + round)

            try world.appendFolder("Extra\(round)")
            await waitUntil(5) { engine.config?.folders.count == 1 + round }
            #expect(engine.config?.folders.count == 1 + round)
        }

        // This append lands before the watch can move to the new file.
        try world.setHoldBelow(50, options: .atomic)
        try world.appendFolder("Extra4")
        await waitUntil(5) { engine.config?.folders.count == 5 }
        #expect(engine.config?.folders.count == 5)
        #expect(engine.status.holdBelowPercent == 50)

        try world.appendFolder("Extra5")
        await waitUntil(5) { engine.config?.folders.count == 6 }
        #expect(engine.config?.folders.count == 6)
    }

    @Test func watchesConfigThatAppearsLater() async throws {
        let world = try FakeWorld()
        let text = try Data(contentsOf: world.configURL)
        try FileManager.default.removeItem(at: world.configURL)
        let engine = try makeEngine(world)
        engine.start()
        defer { engine.stop() }
        #expect(!engine.status.configValid)

        for _ in 1...2 {
            try text.write(to: world.configURL)
            await waitUntil(5) { engine.status.configValid }
            #expect(engine.status.configValid)

            try world.appendFolder("Extra")
            await waitUntil(5) { engine.config?.folders.count == 2 }
            #expect(engine.config?.folders.count == 2)

            try FileManager.default.removeItem(at: world.configURL)
            await waitUntil(5) { !engine.status.configValid }
            #expect(!engine.status.configValid)
        }
    }

    @Test func closesConfigWatchesWhenDone() async throws {
        let world = try FakeWorld()
        let engine = try makeEngine(world)
        engine.start()
        #expect(world.configDescriptors == 2)

        for round in 1...5 {
            try world.setHoldBelow(40 + round, options: .atomic)
            await waitUntil(5) { engine.status.holdBelowPercent == 40 + round }
        }
        await waitUntil(2) { world.configDescriptors == 2 }
        #expect(world.configDescriptors == 2)

        engine.stop()
        await waitUntil(2) { world.configDescriptors == 0 }
        #expect(world.configDescriptors == 0)
    }
}
