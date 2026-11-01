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
        ssh = "me@nas.local"             # SSH login; set up key login with ssh-copy-id
        # port = 22
        path = "/volume1/homes/me"       # base folder on the NAS; every dest is inside it
        # rsync = "/opt/homebrew/bin/rsync"  # rsync 3 on this Mac (brew install rsync)
        # remote_rsync = "/usr/bin/rsync"    # rsync on the NAS

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
        exclude = [".DS_Store", "._*", "*.tmp", "~$*", "@eaDir", "#recycle"]

        [[folder]]
        name = "Documents"
        source = "~/Documents"
        dest = "Mac/Documents"           # folder inside path on the NAS
        # exclude = ["**/node_modules"]  # added to the defaults
        # enabled = false                # pauses this folder without removing it

        # [github]
        # enabled = true                  # false pauses repo backups and keeps these settings
        # every = "24h"
        # around = "03:00"                # preferred time; catches up if missed
        # dest = "github-backups"
        # scan = ["~/Documents/GitHub"]   # local clones found here
        # repos = []                      # clones outside the scan folders; a GitHub remote is optional
        # new_repos = "prompt"            # ask in the menu; or "include" or "ignore"
        # exclude = ["someone/big-fork", "vendor/*"]
        # remote_only = []                # owner/repo with no local clone
        # groups = { "*" = "other" }      # owner to NAS folder
        # on_remote_delete = "keep"       # branches deleted at the source stay on the NAS; or "prune"

        """
    }

    /// The file the Settings window starts from on first launch: the starter file with the NAS login and
    /// base folder left for you to fill in, and no folders yet. It isn't saved until it's valid.
    public static func setupText(wifi: String) -> String {
        var lines = text(wifi: wifi).components(separatedBy: "\n")
        lines = lines.map { line in
            if line.hasPrefix("ssh = ") { return "# ssh = \"me@nas.local\"           # SSH login; set up key login with ssh-copy-id" }
            if line.hasPrefix("path = ") { return "# path = \"/volume1/homes/me\"       # base folder on the NAS; every dest is inside it" }
            return line
        }
        // Drop the sample folder; the form adds real ones.
        if let start = lines.firstIndex(of: "[[folder]]") {
            var end = start + 1
            while end < lines.count, !lines[end].isEmpty { end += 1 }
            lines.removeSubrange(start..<min(end + 1, lines.count))
        }
        return lines.joined(separator: "\n")
    }
}
