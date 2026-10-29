import Foundation

/// A commented config to start from. Every key is optional except the ones in [home], [nas] and each [[folder]].
public enum StarterConfig {
    public static func text(wifi: String) -> String {
        """
        # NAS Sync config. The app reloads this file whenever it's saved.
        # Times look like "30s", "15m", "12h" or "2d". Paths may start with ~.

        [home]
        wifi = "\(wifi.replacingOccurrences(of: "\"", with: "\\\""))"   # only sync on this Wi-Fi network

        [nas]
        url = "smb://nas.local/backup"   # the password lives in your Keychain
        unmount_when_away = false

        [battery]
        hold_below_percent = 30          # on battery, wait if the charge is lower...
        but_not_longer_than = "12h"      # ...unless the last backup is older than this

        [folders]                        # defaults for every [[folder]]
        archive_days = 90                # keep deleted or replaced files this long
        stale_after = "24h"              # warn if no success for this long while home
        quiet_period = "30s"             # wait for changes to settle before copying
        # at_most_every = "1h"           # sync changes at most this often (default: as they happen)
        nightly_check = "03:00"          # compare everything once a day
        max_delete_percent = 20          # stop if a run would archive more than this...
        max_delete_files = 1000          # ...or this many files
        exclude = [".DS_Store", "._*", "*.tmp", "~$*"]

        [[folder]]
        name = "Documents"
        source = "~/Documents"
        dest = "Mac/Documents"           # folder on the NAS share
        # exclude = ["**/node_modules"]  # added to the defaults

        # [github]
        # every = "24h"
        # around = "03:00"                # preferred time; catches up if missed
        # dest = "github-backups"
        # scan = ["~/Documents/GitHub"]   # local clones found here
        # new_repos = "include"           # or "ignore"
        # exclude = ["someone/big-fork", "vendor/*"]
        # remote_only = []                # owner/repo with no local clone
        # groups = { "*" = "other" }      # owner to NAS folder
        #
        # [github.keep]
        # daily = 3
        # weekly = 1
        # monthly = 1
        # quarterly = 1
        # max = 6

        """
    }
}
