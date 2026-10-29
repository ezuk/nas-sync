import Foundation
import Testing
@testable import SyncCore

@Suite struct TOMLTests {
    @Test func parsesTablesArraysAndValues() throws {
        let doc = try TOMLParser.parse("""
        # comment
        title = "x" # trailing
        n = 1_000
        f = 1.5
        ok = true
        list = [
          "a", # first
          'b',
        ]
        inline = { "a" = "1", b.c = 2 }

        [server]
        url = "smb://h/s"

        [[item]]
        name = "one"

        [[item]]
        name = "two"

        [item.sub]
        x = 1
        """)
        #expect(doc["title"]?.value == .string("x"))
        #expect(doc["n"]?.value == .integer(1000))
        #expect(doc["f"]?.value == .float(1.5))
        #expect(doc["ok"]?.value == .boolean(true))
        guard case .array(let list) = doc["list"]?.value else { Issue.record("list"); return }
        #expect(list.map(\.value) == [.string("a"), .string("b")])
        guard case .table(let inline) = doc["inline"]?.value, case .table(let b) = inline["b"]?.value else {
            Issue.record("inline"); return
        }
        #expect(b["c"]?.value == .integer(2))
        guard case .array(let items) = doc["item"]?.value, items.count == 2,
              case .table(let second) = items[1].value else { Issue.record("items"); return }
        #expect(second["name"]?.value == .string("two"))
        #expect(second["name"]?.line == 19)
        guard case .table(let sub) = second["sub"]?.value else { Issue.record("sub"); return }
        #expect(sub["x"]?.value == .integer(1))
    }

    @Test func handlesEscapesAndMultiline() throws {
        let doc = try TOMLParser.parse(#"""
        a = "Icon\r"
        b = "tab\there é"
        c = """
        line1
        line2"""
        d = '''raw\n'''
        """#)
        #expect(doc["a"]?.value == .string("Icon\r"))
        #expect(doc["b"]?.value == .string("tab\there é"))
        #expect(doc["c"]?.value == .string("line1\nline2"))
        #expect(doc["d"]?.value == .string("raw\\n"))
    }

    @Test func reportsErrorsWithLines() {
        #expect(throws: TOMLError(line: 2, message: "unexpected value; strings need quotes")) {
            try TOMLParser.parse("a = 1\nb = hello\n")
        }
        #expect(throws: TOMLError(line: 3, message: "'a' is set twice")) {
            try TOMLParser.parse("a = 1\n\na = 2\n")
        }
        #expect(throws: TOMLError.self) {
            try TOMLParser.parse("a = \"unterminated\n")
        }
    }

    @Test func handlesCRLF() throws {
        let doc = try TOMLParser.parse("a = 1\r\nb = 2\r\n")
        #expect(doc["b"]?.line == 2)
    }
}

@Suite struct GlobTests {
    @Test func namesMatchAtAnyDepth() {
        let g = Glob(".DS_Store")
        #expect(g.matches(".DS_Store"))
        #expect(g.matches("a/b/.DS_Store"))
        #expect(!g.matches("a/.DS_Store2"))
        #expect(Glob("*.tmp").matches("x/y/z.tmp"))
        #expect(Glob("~$*").matches("docs/~$report.docx"))
    }

    @Test func pathsAreAnchored() {
        #expect(Glob("vendor/*").matches("vendor/repo"))
        #expect(!Glob("vendor/*").matches("other/vendor/repo"))
        #expect(Glob("**/node_modules").matches("a/b/node_modules", isDirectory: true))
        #expect(Glob("**/node_modules").matches("node_modules"))
        #expect(Glob("a/**/z").matches("a/z"))
        #expect(Glob("a/**/z").matches("a/b/c/z"))
        #expect(Glob("owner/repo").matches("owner/repo"))
    }

    @Test func directoryOnly() {
        #expect(Glob("build/").matches("x/build", isDirectory: true))
        #expect(!Glob("build/").matches("x/build", isDirectory: false))
    }
}

@Suite struct TimeValueTests {
    @Test func intervals() {
        #expect(Interval(parsing: "30s")?.seconds == 30)
        #expect(Interval(parsing: "1h30m")?.seconds == 5400)
        #expect(Interval(parsing: "2d")?.seconds == 172_800)
        #expect(Interval(parsing: "12") == nil)
        #expect(Interval(parsing: "x") == nil)
        #expect(Interval(seconds: 5400).description == "1h30m")
    }

    @Test func timeOfDay() throws {
        let t = try #require(TimeOfDay(parsing: "03:00"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 2))!
        let last = t.lastOccurrence(atOrBefore: date, calendar: cal)
        #expect(cal.component(.day, from: last) == 9)
        let next = t.nextOccurrence(after: date, calendar: cal)
        #expect(cal.component(.day, from: next) == 10)
        #expect(TimeOfDay(parsing: "25:00") == nil)
    }
}

@Suite struct ConfigTests {
    let home = URL(filePath: "/home/test")

    static let sample = """
    [home]
    wifi = "MyWiFi"

    [nas]
    ssh = "me@nas.local"
    path = "/volume1/homes/me"

    [battery]
    hold_below_percent = 25

    [folders]
    archive_days = 60

    [[folder]]
    name = "Docs"
    source = "~/Documents"
    dest = "Mac/Docs"
    exclude = ["**/node_modules"]
    at_most_every = "1h"

    [github]
    every = "6h"
    around = "03:00"
    scan = ["~/Code"]
    exclude = ["vendor/*"]
    remote_only = ["owner/repo"]
    groups = { "Owner-A" = "a", "*" = "misc" }

    [github.keep]
    daily = 5
    """

    @Test func decodesFullConfig() throws {
        let result = ConfigLoader.parse(Self.sample, home: home)
        #expect(result.issues.isEmpty, "\(result.issues)")
        let config = try #require(result.config)
        #expect(config.home.wifi == "MyWiFi")
        #expect(config.nas.host == "nas.local")
        #expect(config.nas.ssh == "me@nas.local")
        #expect(config.nas.port == 22)
        #expect(config.nas.path == "/volume1/homes/me")
        #expect(config.nas.remoteRsync == "/usr/bin/rsync")
        #expect(config.battery.holdBelowPercent == 25)
        #expect(config.battery.butNotLongerThan == .hours(12))
        let folder = try #require(config.folders.first)
        #expect(folder.source.path == "/home/test/Documents")
        #expect(folder.dest == "Mac/Docs")
        #expect(folder.archiveDays == 60)
        #expect(folder.exclude.contains(".DS_Store"))
        #expect(folder.exclude.contains("**/node_modules"))
        #expect(folder.line == 14)
        #expect(folder.atMostEvery == .hours(1))
        let gh = try #require(config.github)
        #expect(gh.every == .hours(6))
        #expect(gh.scan.first?.path == "/home/test/Code")
        #expect(gh.group(forOwner: "owner-a") == "a")
        #expect(gh.group(forOwner: "someone") == "misc")
        #expect(gh.keep.daily == 5)
        #expect(gh.keep.max == 6)
        #expect(gh.dest == "github-backups")
    }

    @Test func reportsUnknownKeysAndBadValues() {
        let text = """
        [home]
        wifi = "W"
        wiifi = "typo"

        [nas]
        path = "relative"

        [folders]
        quiet_period = "soon"

        [[folder]]
        name = "A"
        source = "relative/path"
        dest = "../escape"
        """
        let result = ConfigLoader.parse(text, home: home)
        #expect(result.config == nil)
        let messages = result.issues.map(\.description)
        #expect(messages.contains("line 3: Unknown setting 'home.wiifi'."))
        #expect(messages.contains("line 6: nas.path must be a full path on the NAS, like /volume1/homes/me."))
        #expect(messages.contains { $0.hasPrefix("line 9: 'folders.quiet_period'") })
        #expect(messages.contains { $0.hasPrefix("line 13: folder 'A': source") })
        #expect(messages.contains { $0.hasPrefix("line 14: folder 'A': dest") })
    }

    @Test func explainsTheOldSMBSetting() {
        let result = ConfigLoader.parse("[home]\nwifi = \"W\"\n[nas]\nurl = \"smb://nas/home\"\n", home: home)
        #expect(result.issues.contains { $0.message.hasPrefix("nas.url (SMB) is no longer used") })
    }

    @Test func reportsMissingSections() {
        let result = ConfigLoader.parse("", home: home)
        #expect(result.issues.map(\.message).contains("Missing the [home] section."))
        #expect(result.issues.map(\.message).contains("Missing the [nas] section."))
    }

    @Test func detectsOverlappingDestinations() {
        let text = """
        [home]
        wifi = "W"
        [nas]
        path = "/n"
        [[folder]]
        name = "A"
        source = "/a"
        dest = "Backups"
        [[folder]]
        name = "B"
        source = "/b"
        dest = "Backups/B"
        """
        let result = ConfigLoader.parse(text, home: home)
        #expect(result.errors.contains { $0.message.contains("write into the same NAS folder") })
    }

    @Test func parseErrorHasLine() {
        let result = ConfigLoader.parse("[home]\nwifi = W\n", home: home)
        #expect(result.issues.first?.line == 2)
    }
}

@Suite struct StarterConfigTests {
    @Test func starterConfigIsValid() {
        let result = ConfigLoader.parse(StarterConfig.text(wifi: "Home \"5G\""))
        #expect(result.errors.isEmpty, "\(result.issues)")
        #expect(result.config?.home.wifi == "Home \"5G\"")
        #expect(result.config?.github == nil)
    }
}

@Suite struct ConfigEditorTests {
    let base = """
    [home]
    wifi = "Home"

    [nas]
    ssh = "me@nas.local"
    path = "/volume1/backup"

    """

    @Test func addsToSingleLineArray() throws {
        let text = base + "[github]\nscan = []\nremote_only = [\"a/b\"]   # no clone\n"
        let out = try ConfigEditor.addRemoteOnly("c/d", to: text)
        #expect(out.contains("remote_only = [\"a/b\", \"c/d\"]   # no clone"))
        #expect(try ConfigEditor.addRemoteOnly("c/d", to: out) == out)
    }

    @Test func addsToEmptyAndMultiLineArrays() throws {
        let empty = try ConfigEditor.addRemoteOnly("c/d", to: base + "[github]\nremote_only = []\n")
        #expect(empty.contains("remote_only = [\"c/d\"]"))
        let multi = try ConfigEditor.addRemoteOnly("c/d", to: base + "[github]\nremote_only = [\n  \"a/b\"\n]\n\n[github.keep]\nmax = 6\n")
        #expect(multi.contains("  \"a/b\",\n  \"c/d\",\n]"))
    }

    @Test func addsKeyWhenMissing() throws {
        let out = try ConfigEditor.addRemoteOnly("c/d", to: base + "[github]\nscan = []\n\n[github.keep]\nmax = 6\n")
        #expect(out.contains("scan = []\nremote_only = [\"c/d\"]\n\n[github.keep]"))
        #expect(throws: ConfigEditor.EditError.self) { try ConfigEditor.addRemoteOnly("c/d", to: base) }
    }
}
