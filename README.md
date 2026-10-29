# NAS Sync

A small macOS menu bar app that backs up folders and GitHub repos to a NAS share, but only when you're on your home Wi-Fi.

- **Folders** are mirrored one way to the NAS as they change. Deleted or replaced files aren't lost: they move to a dated `_archive` folder on the NAS and are removed after a set number of days.
- **GitHub repos** are backed up on a schedule as compressed git bundles, with daily/weekly/monthly retention. Local clones are backed up from your Mac, so unpushed commits and local branches are included. Repos with no local clone are mirrored from GitHub.
- **Home only.** Away from home it does nothing and says so. At home it mounts the NAS (using the password saved in your Keychain) and tells you plainly if it can't.
- **Battery aware.** On battery it waits if the charge is low, but never longer than you allow.
- **A text config.** Everything is set in one TOML file that you, or an LLM, can edit. The app reloads it when saved and points out mistakes with line numbers.
- **Quiet.** Notifications only when something breaks, recovers, or goes stale.

It's meant as a code base you can build and adapt, not a packaged product. There are no signed releases.

## Requirements

- macOS 26 or later
- Xcode 26 or later (Swift 6)
- An SMB share on your NAS, with its password saved in your login Keychain (connect once in Finder and tick "Remember this password")
- For GitHub backups: `git` (the one from Xcode's command-line tools is fine) and an SSH key that can read your repos

## Build and run

1. Clone the repo.
2. Copy `App/Local.xcconfig.example` to `App/Local.xcconfig` and set your own team ID and bundle ID. This file is ignored by git.
3. Open `App/NASSync.xcodeproj` in Xcode and run the **NAS Sync** scheme.
   Or from a terminal:
   ```sh
   xcodebuild -project App/NASSync.xcodeproj -scheme "NAS Sync" -configuration Release -derivedDataPath build/DerivedData build
   open "build/DerivedData/Build/Products/Release/NAS Sync.app"
   ```
4. On first launch, allow Location (macOS only shares the Wi-Fi name with apps that have it) and notifications. Settings opens and offers to create a starter config at `~/.config/nas-sync/config.toml`.

The Xcode project is generated from `App/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). If you change `project.yml`, run `xcodegen generate` in `App/`.

To keep the app across rebuilds, move `NAS Sync.app` to `/Applications` and turn on **Launch at login** in Settings.

## Config

A short example. The starter config the app creates explains every setting.

```toml
[home]
wifi = "MyHomeWiFi"                 # only sync on this network

[nas]
url = "smb://nas.local/backup"      # the password lives in your Keychain

[folders]                           # defaults for every [[folder]]
archive_days = 90
stale_after = "24h"

[[folder]]
name = "Documents"
source = "~/Documents"
dest = "Mac/Documents"              # folder inside the share
exclude = ["**/node_modules"]

[github]
every = "24h"
around = "03:00"
dest = "github-backups"
scan = ["~/Code"]                   # local clones found here
remote_only = ["someone/repo"]      # repos with no local clone
groups = { "my-org" = "my-org", "*" = "other" }
```

Archives land on the NAS as `github-backups/bundles/<group>/<repo>/YYMMDD-owner-repo.bundle.xz`. To restore one:

```sh
swift run nas-sync unpack 260403-owner-repo.bundle.xz    # or xz -d, if you have it
git clone 260403-owner-repo.bundle repo
```

## Safety

- One way only: nothing on your Mac is ever changed.
- A run stops before changing anything if the source folder is missing or empty, or if it would archive more files than `max_delete_percent` / `max_delete_files` allow. You can allow it once from the menu.
- Files are copied under a temporary name and renamed into place, so a half-copied file never replaces a good one.
- Before writing, the app checks that the destination is really on the expected SMB share and not an empty folder left under `/Volumes`.
- GitHub archives are verified with `git bundle verify` and checked by size and SHA-256 after copying. Repos that disappear from GitHub, or whose local clone disappears, are never pruned.

## Command-line tool

`swift build` builds `nas-sync`, which uses the same engine:

```sh
swift run nas-sync validate                    # check the config
swift run nas-sync status                      # what the app is doing (add --json for scripts)
swift run nas-sync run folders --dry-run       # show what a full check would copy and archive
swift run nas-sync run folders --dry-run --allow-mass-delete -v   # list everything, even past the safety limits
swift run nas-sync run github --dry-run -v     # show which repos would be backed up and why
swift run nas-sync diagnose                    # step through mounting the NAS
```

## Development

```sh
swift test                                     # unit tests (uses throwaway folders and git repos)
```

In a Debug build, `"NAS Sync.app/Contents/MacOS/NAS Sync" --render-samples <folder>` renders every screen with sample data to PNG files, without starting any syncing.

Code layout:

- `Sources/SyncCore`: config parsing, folder mirroring, GitHub backups, mounting, scheduling and the engine that ties them together.
- `Sources/nas-sync`: the command-line tool.
- `App`: the SwiftUI menu bar app.

## License

MIT. See [LICENSE](LICENSE).
