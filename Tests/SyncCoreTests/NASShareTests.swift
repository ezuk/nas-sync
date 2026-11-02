import Foundation
import Testing
@testable import SyncCore

@Suite struct NASShareTests {
    private let share = NASShare(config: NASConfig(ssh: "me@nas.local", path: "/volume1/homes/me"))
    private let home = NASShare.Mount(path: "/Volumes/home", address: URL(string: "smb://me@NAS._smb._tcp.local/home"))

    @Test func findsAFolderOnAShareThatStartsPartwayDown() {
        let path = share.localPath(of: "backups/a.git", mounts: [home]) { $0 == "/Volumes/home/backups/a.git" }
        #expect(path == "/Volumes/home/backups/a.git")
    }

    @Test func prefersTheLongestMatch() {
        let whole = "/Volumes/home/homes/me/backups/a.git"
        let path = share.localPath(of: "backups/a.git", mounts: [home]) { $0 == whole || $0 == "/Volumes/home/backups/a.git" }
        #expect(path == whole)
    }

    @Test func ignoresVolumesFromOtherMachines() {
        let other = NASShare.Mount(path: "/Volumes/other", address: URL(string: "smb://me@elsewhere.local/home"))
        #expect(share.localPath(of: "backups/a.git", mounts: [other]) { _ in true } == nil)
    }

    @Test func reportsNothingWhenTheFolderIsMissing() {
        #expect(share.localPath(of: "backups/a.git", mounts: [home]) { _ in false } == nil)
    }

    @Test func aFolderOnThisMacNeedsNoShare() {
        let local = NASShare(config: NASConfig(ssh: nil, path: "/Volumes/Backups/"))
        #expect(local.localPath(of: "a.git", mounts: []) { $0 == "/Volumes/Backups/a.git" } == "/Volumes/Backups/a.git")
    }

    @Test func picksTheShareToConnectTo() {
        #expect(share.shareURL?.absoluteString == "smb://me@nas.local/home")
        #expect(NASShare(config: NASConfig(ssh: "me@nas.local", path: "/volume2/backups/mac")).shareURL?.absoluteString == "smb://me@nas.local/backups")
        #expect(NASShare(config: NASConfig(ssh: "me@nas.local", path: "/volume1/homes/you")).shareURL?.absoluteString == "smb://me@nas.local/homes")
        #expect(NASShare(config: NASConfig(ssh: "nas.local", path: "/srv/backups")).shareURL?.absoluteString == "smb://nas.local")
        #expect(NASShare(config: NASConfig(ssh: nil, path: "/Volumes/Backups")).shareURL == nil)
    }
}
