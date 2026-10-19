# Changelog

## Unreleased

### Fixed
- Clicking the always-hidden `|` separator, with either button, opens the context menu. On macOS 27 it is the only separator left in the bar, and it had no action, so right-clicking it to reach Preferences did nothing.
- Right-clicking the arrow shows and hides the always-hidden section again, as the in-app tutorial says. It had moved to Option-click in v1.11, and Option-click never worked on macOS 27, whose status-bar clicks arrive without modifier flags. Option-click now opens the context menu, and right-click still opens it when the always-hidden section is off.
- macOS 27: hiding the always-hidden section now takes its `|` separator with it, while expanded too, instead of leaving it in the bar.
- macOS 27: relaunching with the always-hidden section hidden no longer hides almost every icon; the section is hidden once the separator is back in place.
- macOS 27: turning the always-hidden section off no longer keeps its apps hidden while expanded.
- macOS 27: with the always-hidden section hidden, apps launched while expanded show up, and icons ⌘-dragged across the arrow while expanded count on the next collapse.
- macOS 27: Time Machine and other SystemUIServer extras stay visible when placed right of the arrow.
- macOS 27: collapsing no longer waits for every running app's Accessibility reply in turn.
- Launch: the bar is set up after the defaults and the layout direction are known, so the arrow no longer starts out pointing the wrong way, and a second copy that quits at once no longer creates status items first.
- The auto-collapse timer no longer loads the Preferences window into memory when Preferences was never opened.
- Display changes re-size the always-hidden zone while expanded too, not only while collapsed.
- Notch Overflow: "Show Notch Items" no longer disappears while an external display is focused, and one busy app can no longer freeze Hidden Bar while the list is built.
- Opening Hidden Bar again while it runs now shows Preferences.
- Preferences: the menu-bar illustration no longer sits under the taller macOS 26+ toolbar, and the window stays wide enough that "Always Hidden" is no longer cut off at the left edge.
- Preferences: the Notch Overflow checkbox now says Option-click, which opens the menu with "Show Notch Items" in every setup.
- The illustration's clock follows the system's date and time format.

### Added
- Korean localization.
- Fork version `1.11.1-fw.1` (build 16001); the About tab shows it with the source commit.
- `scripts/install-local.sh` builds, checks and installs the unsandboxed `Release-Direct` app.

## v1.11.1 (2026-09-18)

### Fixed
- macOS 27: the Preferences window showed a "Custom View" placeholder instead of the General/About tabs, and the label overlapped the window once clicked (#406).

## v1.11 (2026-09-18)

Requires macOS 13 Ventura or later. (Pre-Ventura users: stay on
[v1.10](https://github.com/dwarvesf/hidden/releases/tag/v1.10).)

### Added
- Opt-in hover-to-expand: set `defaults write com.dwarvesv.minimalbar hoverToExpand -bool true` to expand the bar when the pointer dwells in the menu bar.
- Right-clicking the expand/collapse arrow now opens the same context menu as the separator, so Preferences is reachable from the control you already click.

### Fixed
- macOS 27 (direct download build): hiding works again (#360) using macOS 27's native menu-bar visibility instead of widening the separator, which macOS 27 ejects from the bar. The arrow is the boundary: icons ⌘-dragged to its left hide when collapsed. Needs the Accessibility permission, and Hidden Bar must run from /Applications. Hiding is per app, and macOS's own items always stay visible. The App Store build is unchanged for now.
- Enabling the always-hidden section at runtime no longer creates an invisible (0pt) separator.
- Multi-display: the collapse width is now sized for the widest attached screen, so icons no longer leak on wider external monitors; the width re-applies on display hot-plug.
- Auto-collapse no longer fires while you are interacting with the menu bar (the timer defers and re-arms while the pointer is in the bar).
- The Preferences window no longer closes when auto-collapse fires with "use full menu bar on expanding" enabled (#170, #66, #151).
- Status items that were dragged off the bar are restored at launch instead of leaving the app unreachable.
- Fixed constraint and observer leaks in the tutorial view rebuild.
- Tutorial strings and F-key shortcut labels now render correctly (no more private-use glyphs).

### Changed
- Start-at-login now uses `SMAppService` (macOS 13+); the legacy launcher helper was removed and any leftover login item is deauthorized automatically on first launch.
- Pinned the HotKey dependency to an exact version and removed an unused file-access entitlement and dead code (no behavior change).

### Known / in progress
- macOS 27, App Store build: hiding still does not work (#360). Native hiding needs Accessibility reads that the App Sandbox blocks; an App Store approach is tracked separately.
- New menu-bar icons can appear in the hidden zone because macOS inserts them at the far left; ⌘-drag them to the right of the separator (see the manual). A built-in pin is part of the planned redesign.
