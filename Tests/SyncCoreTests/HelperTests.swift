import Foundation
import Testing
@testable import SyncCore

/// Every released helper version and its fingerprint. A changed script needs a new version and a new line here.
private let releasedHelpers = [
    1: "b4df6ae1131c96d02e38caadd5c12cc8fdc970ae75c5c48babfdf1511ce5056c",
    2: "8d8605de4f47203070189a2d83dc110ee52b8aadbcbfb08e61f5caf3206f357a",
    3: "2547dfa182ccc94274eaaa0faa38bbfd41f0b486ab07c0ed4381a5352034e421",
    4: "352adc377befdd16f826938447e3c6fffa732d6e29a3ed36259f505940711bb7",
]

/// A local folder standing in for the NAS.
private final class HelperSandbox {
    let root: URL
    let nas: NAS

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "nassync-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        nas = NAS(config: NASConfig(ssh: nil, path: root.path(percentEncoded: false)))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var helperRoot: URL { root.appending(path: ".nas-sync/helper") }
    var state: URL { root.appending(path: ".nas-sync") }

    /// The bundled script with its numbers changed.
    func script(version: Int = BundledHelper.identity.version, protocolVersion: Int = BundledHelper.identity.protocolVersion, extra: String = "") -> Data {
        var text = String(decoding: BundledHelper.source, as: UTF8.self)
        text = text.replacing(/HELPER_VERSION = \d+/, with: "HELPER_VERSION = \(version)")
        text = text.replacing(/PROTOCOL = \d+/, with: "PROTOCOL = \(protocolVersion)")
        return Data((text + extra).utf8)
    }

    func helper(_ source: Data) -> NASHelper { NASHelper(nas: nas, source: source, online: false)! }

    var versionFolders: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: helperRoot.path(percentEncoded: false))) ?? [])
            .filter { $0 != "current" }.sorted()
    }

    var activeFolder: String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: helperRoot.appending(path: "current").path(percentEncoded: false))
    }
}

@Suite struct BundledHelperTests {
    @Test func changedScriptNeedsNewVersion() {
        let identity = BundledHelper.identity
        #expect(releasedHelpers[identity.version] == identity.sha256,
                "The helper changed. Raise HELPER_VERSION, then add [\(identity.version): \"\(identity.sha256)\"] to releasedHelpers.")
    }

    @Test func parsesVersionNumbers() {
        #expect(BundledHelper.identity.version >= 1)
        #expect(BundledHelper.identity.protocolVersion >= 1)
        #expect(HelperIdentity(source: Data("nothing here".utf8)) == nil)
    }

    @Test func staysCompatibleWithPython38() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "nassync-helper-\(UUID().uuidString).py")
        try BundledHelper.source.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let parse = "import ast,sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3, 8))"
        let r = try Command.run(URL(filePath: "/usr/bin/python3"), ["-c", parse, file.path(percentEncoded: false)])
        #expect(r.status == 0, "\(r.stderr)")
    }
}

@Suite struct HelperPlanTests {
    private func id(_ version: Int, proto: Int = 1, sha: String = "a") -> HelperIdentity {
        HelperIdentity(version: version, protocolVersion: proto, sha256: sha)
    }

    @Test func decides() {
        #expect(HelperPlan.decide(installed: id(2), bundled: id(2)) == .useInstalled)
        #expect(HelperPlan.decide(installed: id(1), bundled: id(2)) == .install(.older))
        #expect(HelperPlan.decide(installed: id(2, sha: "b"), bundled: id(2)) == .install(.different))
        #expect(HelperPlan.decide(installed: id(3), bundled: id(2)) == .useInstalled)
        #expect(HelperPlan.decide(installed: id(3, proto: 2), bundled: id(2)) == .appTooOld)
        #expect(HelperPlan.decide(installed: id(1, proto: 2), bundled: id(2)) == .install(.older))
    }
}

@Suite(.serialized) struct HelperInstallTests {
    @Test func installsWhenMissingThenLeavesItAlone() throws {
        let box = try HelperSandbox()
        let helper = box.helper(BundledHelper.source)
        #expect(try helper.status().state == .needsInstall)
        #expect(box.activeFolder == nil, "status must not install anything")

        let first = try helper.ensure()
        #expect(first.state == .ready)
        #expect(first.change == .installed)
        #expect(first.installedVersion == BundledHelper.identity.version)
        #expect(first.checks.contains { $0.id == "python" && $0.status == .ok })
        let folder = box.activeFolder
        #expect(folder?.hasPrefix("\(BundledHelper.identity.version)-") == true)
        #expect(box.versionFolders == [folder!])

        let second = try helper.ensure()
        #expect(second.state == .ready)
        #expect(second.change == nil)
        #expect(box.activeFolder == folder)
    }

    @Test func updatesAnOlderVersionAndKeepsOnePrevious() throws {
        let box = try HelperSandbox()
        _ = try box.helper(box.script(version: 1)).ensure()
        let v1 = box.activeFolder!

        let two = try box.helper(box.script(version: 2)).ensure()
        #expect(two.state == .ready)
        #expect(two.change == .updated)
        #expect(two.reason == .older)
        #expect(two.installedVersion == 2)
        let v2 = box.activeFolder!
        #expect(v2.hasPrefix("2-"))
        #expect(Set(box.versionFolders) == [v1, v2])

        _ = try box.helper(box.script(version: 3)).ensure()
        let v3 = box.activeFolder!
        #expect(v3.hasPrefix("3-"))
        #expect(Set(box.versionFolders) == [v2, v3], "only the current and previous versions stay")
    }

    @Test func reinstallsWhenTheFingerprintDiffers() throws {
        let box = try HelperSandbox()
        _ = try box.helper(box.script(version: 5)).ensure()
        let report = try box.helper(box.script(version: 5, extra: "\n# edited\n")).ensure()
        #expect(report.state == .ready)
        #expect(report.change == .repaired)
        #expect(report.reason == .different)
    }

    @Test func repairsADamagedInstall() throws {
        let box = try HelperSandbox()
        let helper = box.helper(BundledHelper.source)
        _ = try helper.ensure()
        let script = box.helperRoot.appending(path: "current/nas-sync-helper.py")
        try Data("this is not python(".utf8).write(to: script)
        #expect(try helper.status().reason == .damaged)

        let report = try helper.ensure()
        #expect(report.state == .ready)
        #expect(report.change == .repaired)
        #expect(try Data(contentsOf: script) == BundledHelper.source)
    }

    @Test func leavesANewerCompatibleVersionInPlace() throws {
        let box = try HelperSandbox()
        _ = try box.helper(box.script(version: 9)).ensure()
        let folder = box.activeFolder

        let report = try box.helper(box.script(version: 8)).ensure()
        #expect(report.state == .ready)
        #expect(report.change == nil)
        #expect(report.installedVersion == 9)
        #expect(box.activeFolder == folder)
    }

    @Test func stopsAtANewerIncompatibleVersion() throws {
        let box = try HelperSandbox()
        _ = try box.helper(box.script(version: 9, protocolVersion: 2)).ensure()
        let folder = box.activeFolder

        let report = try box.helper(box.script(version: 8, protocolVersion: 1)).ensure()
        #expect(report.state == .appTooOld)
        #expect(box.activeFolder == folder)
        #expect(Diagnosis.forHelper(report)?.title == "The NAS helper is newer than this app")
    }

    @Test func aFailedUpdateKeepsTheWorkingVersion() throws {
        let box = try HelperSandbox()
        _ = try box.helper(box.script(version: 1)).ensure()
        let folder = box.activeFolder

        let broken = Data("HELPER_VERSION = 2\nPROTOCOL = 1\nthis is not python(\n".utf8)
        let report = try box.helper(broken).ensure()
        #expect(report.state == .failed)
        #expect(report.installedVersion == 1)
        #expect(report.error?.contains("wouldn't run") == true)
        #expect(box.activeFolder == folder)
        #expect(box.versionFolders == [folder!], "the failed upload is cleaned up")
        #expect(try box.helper(box.script(version: 1)).status().state == .ready)
        #expect(Diagnosis.forHelper(report)?.title == "The NAS helper couldn't be updated")
    }

    @Test func recordsChangesAndFailuresInActivity() throws {
        let box = try HelperSandbox()
        let installed = try box.helper(box.script(version: 1)).ensure()
        #expect(installed.runRecord(started: Date())?.summary == "Installed NAS helper version 1")
        #expect(installed.runRecord(started: Date())?.kind == .helper)
        let updated = try box.helper(box.script(version: 2)).ensure()
        #expect(updated.runRecord(started: Date())?.summary == "Updated NAS helper to version 2")
        #expect(updated.runRecord(started: Date())?.outcome == .success)
        let same = try box.helper(box.script(version: 2)).ensure()
        #expect(same.runRecord(started: Date()) == nil)
    }

    @Test func aLostConnectionIsNotAMissingHelper() throws {
        let nas = NAS(config: NASConfig(ssh: "nobody@127.0.0.1", port: 1, path: "/nowhere"))
        let helper = NASHelper(nas: nas, source: BundledHelper.source, online: false)!
        #expect(throws: HelperError.self) { try helper.ensure() }
        #expect(throws: HelperError.self) { try helper.status() }
    }

    // MARK: Tokens

    private func saveToken(_ box: HelperSandbox, owner: String, _ value: String, mode: Int = 0o600) throws {
        try FileManager.default.createDirectory(at: box.state, withIntermediateDirectories: true)
        let file = box.state.appending(path: "github-token-\(owner)")
        try Data((value + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path(percentEncoded: false))
    }

    private func check(_ report: HelperReport, _ id: String) -> HelperCheck? { report.checks.first { $0.id == id } }

    @Test func reportsMissingTokens() throws {
        let box = try HelperSandbox()
        let report = try box.helper(BundledHelper.source).ensure()
        #expect(check(report, "tokens")?.status == .failed)
    }

    @Test func spotsTokenProblemsWithoutPrintingTokens() throws {
        let box = try HelperSandbox()
        let secret = "github_pat_" + String(repeating: "x", count: 40) + "y"
        try saveToken(box, owner: "good", secret)
        try saveToken(box, owner: "twice", secret + secret)
        try saveToken(box, owner: "open", secret, mode: 0o644)
        try saveToken(box, owner: "blank", "")

        let report = try box.helper(BundledHelper.source).ensure()
        #expect(check(report, "token:good")?.status == .unknown)
        #expect(check(report, "token:twice")?.detail == "saved twice")
        #expect(check(report, "token:open")?.detail == "readable by others")
        #expect(check(report, "token:blank")?.detail == "empty")
        #expect(check(report, "tokens") == nil)

        let output = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!output.contains(secret))
        var tokensOnly = report
        tokensOnly.checks = report.checks.filter { $0.tokenOwner != nil }
        #expect(Diagnosis.forHelper(tokensOnly)?.title.hasPrefix("The GitHub token for ") == true)
    }

    // MARK: Diagnosis

    private func ready(_ checks: [HelperCheck]) -> HelperReport {
        HelperReport(state: .ready, installedVersion: 1, bundledVersion: 1, checks: checks)
    }

    @Test func explainsHealthProblems() {
        let good = [HelperCheck(id: "python", status: .ok, detail: "3.8"), HelperCheck(id: "token:acme", status: .ok, detail: "accepted")]
        #expect(Diagnosis.forHelper(ready(good)) == nil)

        #expect(Diagnosis.forHelper(ready([HelperCheck(id: "git-lfs", status: .failed, detail: "not found")]))?.title == "Git isn't ready on the NAS")
        #expect(Diagnosis.forHelper(ready([HelperCheck(id: "tokens", status: .failed, detail: "none")]))?.title == "The NAS has no GitHub token")

        let rejected = Diagnosis.forHelper(ready([HelperCheck(id: "token:acme", status: .failed, detail: "rejected")]))
        #expect(rejected?.title == "The GitHub token for acme needs attention")
        #expect(rejected?.explanation.contains("rejected") == true)
    }

    @Test func aCheckThatCouldntTellIsNotAProblem() {
        let offline = [HelperCheck(id: "token:acme", status: .unknown, detail: "couldn't reach GitHub: URLError")]
        #expect(Diagnosis.forHelper(ready(offline)) == nil)
        #expect(Diagnosis.forHelper(HelperReport(state: .needsInstall, installedVersion: nil, bundledVersion: 1)) == nil)
    }

    @Test func warnsBeforeATokenExpires() {
        let now = Date()
        let soon = HelperCheck(id: "token:acme", status: .ok, detail: "accepted", expires: now.addingTimeInterval(3 * 86400))
        #expect(Diagnosis.forHelper(ready([soon]), now: now)?.title == "The GitHub token for acme expires soon")
        let later = HelperCheck(id: "token:acme", status: .ok, detail: "accepted", expires: now.addingTimeInterval(60 * 86400))
        #expect(Diagnosis.forHelper(ready([later]), now: now) == nil)
    }
}
