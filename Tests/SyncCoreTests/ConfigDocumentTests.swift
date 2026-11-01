import Foundation
import Testing
@testable import SyncCore

@Suite struct ConfigDocumentTests {
    let home = URL(filePath: "/home/test")

    let base = """
    # My config
    [home]
    wifi = "Home"   # only here

    [nas]
    ssh = "me@nas.local"
    path = "/volume1/me"             # base folder

    [folders]
    quiet_period = "30s"             # settle
    # at_most_every = "1h"           # at most this often
    exclude = [
      ".DS_Store",  # mac
      "*.tmp",
    ]

    [[folder]]
    name = "Docs"
    source = "~/Documents"
    dest = "Mac/Docs"                # inside path
    # exclude = ["**/node_modules"]  # added to the defaults

    # [github]
    # every = "24h"                  # how often
    # exclude = ["vendor/*"]

    """

    @Test func changesOnlyTheEditedLineAndKeepsItsComment() throws {
        var doc = ConfigDocument(text: base)
        try doc.set("path", in: .named("nas"), to: .string("/volume2/me"))
        let before = ConfigDocument.lines(base), after = ConfigDocument.lines(doc.text)
        #expect(before.count == after.count)
        let changed = zip(before, after).filter { $0 != $1 }
        #expect(changed.count == 1)
        #expect(changed.first?.1 == "path = \"/volume2/me\"             # base folder")
    }

    @Test func uncommentsACommentedOutSetting() throws {
        var doc = ConfigDocument(text: base)
        try doc.set("at_most_every", in: .named("folders"), to: .string("2h"))
        #expect(doc.text.contains("\nat_most_every = \"2h\"             # at most this often\n"))
        #expect(!doc.text.contains("# at_most_every"))
        #expect(doc.check(home: home).errors.isEmpty)
    }

    @Test func doesNotUncommentAnotherSectionsSetting() throws {
        var doc = ConfigDocument(text: base)
        doc.addFolder(name: "Two", source: "~/Two", dest: "Mac/Two")
        try doc.set("exclude", in: .folder(1), to: .strings(["*.psd"]))
        #expect(doc.text.contains("# exclude = [\"vendor/*\"]"))
        #expect(doc.text.contains("# exclude = [\"**/node_modules\"]"))
        let config = try #require(doc.check(home: home).config)
        #expect(config.allFolders[1].ownExclude == ["*.psd"])
    }

    @Test func addsAndRemovesSettings() throws {
        var doc = ConfigDocument(text: base)
        try doc.set("port", in: .named("nas"), to: .integer(2222))
        #expect(doc.text.contains("path = \"/volume1/me\"             # base folder\nport = 2222\n"))
        try doc.set("port", in: .named("nas"), to: nil)
        #expect(doc.text == base)
        // Removing something that isn't there changes nothing.
        try doc.set("rsync", in: .named("nas"), to: nil)
        #expect(doc.text == base)
    }

    @Test func rewritesMultiLineListsOneItemPerLine() throws {
        var doc = ConfigDocument(text: base)
        try doc.set("exclude", in: .named("folders"), to: .strings([".DS_Store", "node_modules/"]))
        #expect(doc.text.contains("exclude = [\n  \".DS_Store\",\n  \"node_modules/\",\n]\n"))
        let config = try #require(doc.check(home: home).config)
        #expect(config.folderDefaults.exclude == [".DS_Store", "node_modules/"])
    }

    @Test func bringsBackACommentedOutSection() throws {
        var doc = ConfigDocument(text: base)
        try doc.set("every", in: .named("github"), to: .string("12h"))
        #expect(doc.text.contains("\n[github]\nevery = \"12h\"                    # how often\n# exclude = [\"vendor/*\"]"))
        let gh = try #require(doc.check(home: home).config?.github)
        #expect(gh.every == .hours(12))
    }

    @Test func addsAMissingSectionInTheUsualOrder() throws {
        var doc = ConfigDocument(text: "[home]\nwifi = \"x\"\n\n[nas]\npath = \"/v\"\n\n[[folder]]\nname = \"a\"\nsource = \"~/a\"\ndest = \"a\"\n")
        try doc.set("hold_below_percent", in: .named("battery"), to: .integer(10))
        #expect(doc.text.contains("path = \"/v\"\n\n[battery]\nhold_below_percent = 10\n\n[[folder]]"))
        #expect(doc.check(home: home).config?.battery.holdBelowPercent == 10)
    }

    @Test func addsAndRemovesFolders() throws {
        var doc = ConfigDocument(text: base)
        let i = doc.addFolder(name: "Photos \"2024\"", source: "~/Pictures", dest: "Mac/Photos")
        #expect(i == 1)
        #expect(doc.folderCount == 2)
        // The comment under the first folder stays with it.
        #expect(doc.text.contains("# exclude = [\"**/node_modules\"]  # added to the defaults\n\n[[folder]]\nname = \"Photos \\\"2024\\\"\""))
        let config = try #require(doc.check(home: home).config)
        #expect(config.allFolders.map(\.name) == ["Docs", "Photos \"2024\""])

        try doc.removeFolder(0)
        #expect(doc.folderCount == 1)
        #expect(!doc.text.contains("name = \"Docs\""))
        #expect(doc.text.contains("# [github]"))
        #expect(doc.check(home: home).config?.allFolders.map(\.name) == ["Photos \"2024\""])
    }

    @Test func writesInlineTablesAndEscapes() throws {
        var doc = ConfigDocument(text: base + "[github]\nscan = []\n")
        try doc.set("groups", in: .named("github"), to: .stringTable([.init("acme", "work"), .init("*", "other")]))
        #expect(doc.text.contains("groups = { \"acme\" = \"work\", \"*\" = \"other\" }"))
        try doc.set("exclude", in: .named("folders"), to: .strings(["Icon\r", "a\"b"]))
        let config = try #require(doc.check(home: home).config)
        #expect(config.folderDefaults.exclude == ["Icon\r", "a\"b"])
        #expect(config.githubSettings?.group(forOwner: "ACME") == "work")
    }

    @Test func reportsLines() {
        let doc = ConfigDocument(text: base)
        #expect(doc.line(of: "path", in: .named("nas")) == 7)
        #expect(doc.line(of: "dest", in: .folder(0)) == 20)
        #expect(doc.line(of: .folder(0)) == 17)
        #expect(doc.line(of: "every", in: .named("github")) == nil)
    }

    @Test func starterFilesAreValid() {
        let starter = ConfigDocument(text: StarterConfig.text(wifi: "Home"))
        #expect(starter.check(home: home).errors.isEmpty)
        // The first-run file needs a NAS login and folder before it's valid.
        let setup = ConfigDocument(text: StarterConfig.setupText(wifi: "Home"))
        #expect(setup.check(home: home).errors.map(\.message) == ["Missing 'nas.path'."])
        #expect(setup.folderCount == 0)
        var filled = setup
        try? filled.set("ssh", in: .named("nas"), to: .string("me@ds.local"))
        try? filled.set("path", in: .named("nas"), to: .string("/volume1/me"))
        #expect(filled.check(home: home).errors.isEmpty)
        #expect(filled.text.contains("\nssh = \"me@ds.local\""))
    }
}

@Suite struct ConfigSettingsTests {
    let home = URL(filePath: "/home/test")
    let head = "[home]\nwifi = \"W\"\n[nas]\npath = \"/v\"\n"

    @Test func githubOffKeepsItsSettings() throws {
        let r = ConfigLoader.parse(head + "[github]\nenabled = false\nevery = \"6h\"\nscan = [\"~/Code\"]\n", home: home)
        #expect(r.errors.isEmpty, "\(r.issues)")
        let c = try #require(r.config)
        #expect(c.github == nil)
        #expect(c.githubSettings?.enabled == false)
        #expect(c.githubSettings?.every == .hours(6))
    }

    @Test func folderCanTurnOffASharedLimit() throws {
        let r = ConfigLoader.parse(head + "[folders]\nat_most_every = \"1h\"\n[[folder]]\nname = \"a\"\nsource = \"~/a\"\ndest = \"a\"\nat_most_every = \"off\"\n", home: home)
        #expect(r.errors.isEmpty, "\(r.issues)")
        let c = try #require(r.config)
        #expect(c.folderDefaults.atMostEvery == .hours(1))
        #expect(c.folders[0].atMostEvery.seconds == 0)
        #expect(c.folders[0].overrides == ["at_most_every"])
    }

    @Test func pausedFoldersDontSyncButStillOwnTheirFolder() throws {
        let text = head + "[[folder]]\nname = \"a\"\nsource = \"~/a\"\ndest = \"x\"\nenabled = false\n[[folder]]\nname = \"b\"\nsource = \"~/b\"\ndest = \"x/b\"\n"
        let r = ConfigLoader.parse(text, home: home)
        #expect(r.errors.count == 1)
        #expect(r.errors.first?.message.contains("write into the same NAS folder") == true)
        let ok = ConfigLoader.parse(text.replacingOccurrences(of: "dest = \"x/b\"", with: "dest = \"y\""), home: home)
        let c = try #require(ok.config)
        #expect(c.folders.map(\.name) == ["b"])
        #expect(c.allFolders.map(\.name) == ["a", "b"])
        #expect(c.allFolders[0].enabled == false)
    }

    @Test func newGitHubSettings() throws {
        let r = ConfigLoader.parse(head + "[github]\nrepos = [\"~/Desktop/thesis\"]\nnew_repos = \"ignore\"\non_remote_delete = \"prune\"\n", home: home)
        #expect(r.errors.isEmpty, "\(r.issues)")
        let gh = try #require(r.config?.github)
        #expect(gh.repos.map { $0.path } == ["/home/test/Desktop/thesis"])
        #expect(gh.newRepos == .ignore)
        #expect(gh.onRemoteDelete == .prune)
        #expect(ConfigLoader.parse(head + "[github]\n", home: home).config?.github?.newRepos == .prompt)
        #expect(!ConfigLoader.parse(head + "[github]\non_remote_delete = \"maybe\"\n", home: home).errors.isEmpty)
        #expect(!ConfigLoader.parse(head + "[github]\nrepos = [\"relative/path\"]\n", home: home).errors.isEmpty)
    }

    @Test func oldKeepSectionIsOnlyAWarning() throws {
        let r = ConfigLoader.parse(head + "[github]\nevery = \"1d\"\n\n[github.keep]\ndaily = 3\n", home: home)
        #expect(r.errors.isEmpty, "\(r.issues)")
        #expect(r.issues.contains { $0.severity == .warning && $0.message.contains("[github.keep] is no longer used") })
        #expect(r.config?.github != nil)
    }
}
