# Maintainer runbook

Build, verify, and release Hidden Bar. Assumes current Xcode on macOS 13+.

## Build

```sh
# CI-style build, no signing required
xcodebuild -project 'Hidden Bar.xcodeproj' -scheme 'Hidden Bar' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

# runnable local build (uses your Apple Development identity)
xcodebuild -project 'Hidden Bar.xcodeproj' -scheme 'Hidden Bar' \
  -configuration Debug build
```

To install a build on your own Mac, build `Release-Direct`, never `Release`.
`Release` is the sandboxed App Store configuration: on macOS 27 it hides
nothing at all, in either section.

```sh
xcodebuild -project 'Hidden Bar.xcodeproj' -scheme 'Hidden Bar' \
  -configuration Release-Direct build
codesign -d --entitlements - 'Hidden Bar.app' | grep app-sandbox  # must print nothing
```

`scripts/install-local.sh` does all of this in one step: it builds
`Release-Direct` into `.work/install-local`, stops if the app carries the
App Sandbox entitlement, exports the prefs domain to
`~/Library/Application Support/Hidden Bar Backups`, quits the running app,
moves `/Applications/Hidden Bar.app` to the Trash, installs and launches the
new build, and prints version, commit, signer, sandbox state and pid. It signs
with your first Apple Development identity, or ad hoc when there is none (no
Apple account needed; macOS then asks for Accessibility again after each
reinstall); set `HIDDEN_TEAM` to pick another team, `HIDDEN_INSTALL_DIR` or `HIDDEN_BACKUP_DIR` to change the folders.

A sandboxed build keeps its settings in
`~/Library/Containers/com.dwarvesv.minimalbar`, the direct build in
`~/Library/Preferences`, so switching between them loses the settings unless
you copy them across.

Both Debug builds above must exit 0 with **no** `MACOSX_DEPLOYMENT_TARGET` override; the floor is
13.0 in the project file. The single expected warning is the deliberately
deprecated `SMLoginItemSetEnabled(false)` call that cleans up legacy installs.

## Behavioral verification (no test target exists; this is the methodology)

The repo has no unit-test infrastructure; behavior is verified against the real
menu bar. Two building blocks make that scriptable:

1. **Truth signal**: the separator's AX size.
   `osascript -e 'tell application "System Events" to tell process "Hidden Bar" to get size of menu bar item 2 of menu bar 2'`
   reads ~20pt expanded vs ~2x-screen-width collapsed. Item 1 is the arrow.
2. **Real clicks, not AXPress**: `AXPress` on the arrow is a no-op because the
   action handler reads `NSApp.currentEvent` (nil under assistive synthesis;
   known accessibility defect). Post real `CGEvent` mouse clicks at the arrow's
   AX-reported coordinates instead.

Standard checks before any release:

- expand/collapse toggle flips the separator size both ways;
- with `numberOfSecondForAutoHide` set to 3, an expanded bar survives 2x the
  window while the pointer is parked in the menubar band, collapses within the
  window once the pointer leaves, and collapses normally if the pointer never
  entered;
- `hoverToExpand` off: no monitor log line, hover does nothing; on: dwell
  expands (synthesize a `mouseMoved` stream: cursor warping alone fires no
  events);
- autostart pref on -> `AutoStart: SMAppService.mainApp.status = 1` on stderr;
  off -> `= 0` (run the binary directly to capture stderr);
- localization tables stay parseable: `plutil -lint hidden/*.lproj/*.strings`.

When testing on a machine that runs Hidden Bar daily: export the prefs domain
first (`defaults export com.dwarvesv.minimalbar backup.plist`), quit the
installed app, test the dev build, then re-import and relaunch.

## Release

1. Verify the stack: every PR reviewed, builds green, behavioral checks above run.
2. Bump `MARKETING_VERSION` (all four Hidden Bar configurations) and
   `CURRENT_PROJECT_VERSION` in the project file.

   Fork versioning: this fork keeps upstream's `MARKETING_VERSION` (the
   numeric `CFBundleShortVersionString`, which Apple requires to be digits and
   periods only) and marks its own builds with `HIDDEN_FORK_VERSION`
   (`<upstream>-fw.<N>`, e.g. `1.11.1-fw.1`, Info.plist key `HBForkVersion`)
   and `CURRENT_PROJECT_VERSION` = upstream build x 1000 + N (`16001`), so a
   fork build always sorts above the upstream build it is based on. The
   **Record Git Commit** build phase stamps `HBGitCommit` (short hash, `-dirty`
   for uncommitted changes); the About tab shows
   `Version 1.11.1-fw.2 (16002 · <hash>)`.

   Updater (fork, `Release-Direct`/`Debug-Direct` only, compile condition
   `HIDDENBAR_UPDATER`): Sparkle 2 reads `SUFeedURL`
   (`HIDDEN_SU_FEED_URL` =
   `https://raw.githubusercontent.com/floweredao/hidden/develop/appcast.xml`)
   and accepts only archives signed with the EdDSA key whose public half is
   `SUPublicEDKey` (`HIDDEN_SU_PUBLIC_ED_KEY`). The private key lives only in
   the maintainer's login keychain (item `https://sparkle-project.org`, account
   `floweredao-hidden`, made by `generate_keys --account floweredao-hidden`); never export it into the repo. Upstream has
   no in-app updater and its releases are not in this feed, so nothing
   replaces a fork build with an upstream release. The App Store `Release`
   build never starts the updater (SPM still embeds Sparkle.framework there).
   Fork releases are signed with the maintainer's Apple Development
   certificate and are not notarized: notarization needs a Developer ID
   Application certificate and notary credentials, which this fork does not
   have.
3. Fork release (floweredao/hidden): write the notes as an HTML fragment,
   then, from a clean, committed tree:

   ```sh
   scripts/release.sh notes.html          # build, check, zip, EdDSA-sign, add the <item> to appcast.xml
   gh release create v<fork> .work/release/<fork>/Hidden-Bar-<fork>.zip --target <commit> --title "Hidden Bar <fork>" --notes-file <notes.md>
   ```

   Only after the zip is downloadable, commit `appcast.xml` and merge it to
   `develop`; the feed is served from there. Check with
   `curl -sL <feed> | grep sparkle:version` and by downloading the enclosure.
   Upstream-style release (dwarvesf): archive the GitHub build with the **Hidden Bar** scheme
   (`Release-Direct`), then notarize (Developer ID), staple, zip, and publish a
   GitHub release with notes listing closed issues. The **Hidden Bar App Store**
   scheme archives `Release`, the sandboxed App Store build, which cannot hide
   on macOS 27. v1.11 shipped that build to GitHub by mistake. Before zipping,
   confirm the app is unsandboxed:

   ```sh
   codesign -d --entitlements - 'Hidden Bar.app' | grep app-sandbox  # must print nothing
   ```
4. App Store (separate lane, **Hidden Bar App Store** scheme): the MAS listing
   has lagged GitHub since v1.8 (issues #281/#202); decide deliberately whether
   a release goes there too.
5. Homebrew cask (`brew install --cask hiddenbar`) follows the GitHub release
   artifact; notarization matters (issue #219).
6. Before any public release after the SMAppService migration: one
   upgrade-path run from a launcher-era build (v1.9 or older) verifying System
   Settings shows no ghost LauncherApplication login item.

## Stacked-PR hygiene

Feature stacks land as chained PRs (`develop <- A <- B`). Merge the base PR
first, then retarget the next PR's base to `develop` BEFORE merging it;
deleting a merged branch auto-closes dependents otherwise.

## Issue triage map

The live clusters and their code areas are documented at the end of
[ARCHITECTURE.md](ARCHITECTURE.md#known-architectural-limits): notch, macOS 27
mechanism break, and pointer-vs-open-menu limits. Memory reports (#361 et al.)
have so far not reproduced as leaks (constraint-leak fix landed; `leaks` clean
over toggle stress); re-check with a 24h+ uptime `footprint` sample before
chasing further.
