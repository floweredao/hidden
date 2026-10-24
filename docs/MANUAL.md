# Manual

Everything Hidden Bar can do, including the parts with no UI.

## Basics

- **Left-click the arrow** (`<` / `>`): expand or collapse the hidden section.
- **Right-click** (or Control-click) **the arrow**: with the always-hidden
  section enabled, show/hide that section and its separator; otherwise, the
  context menu.
- **Option-click the arrow** or **click a separator** (`|`, left or right
  button, the always-hidden one included): context menu with Preferences…
  (⇧⌘P), Disable/Enable Auto Collapse (⌘T), Check for Updates… and Quit.
  A line at the top of the menu appears only when hiding is not working, with
  a way to fix it.
- **Open Hidden Bar again** (Finder, Spotlight, Launchpad) while it runs: opens
  Preferences.
- **⌘-drag** icons in the menu bar to move them across the separator: icons to
  the separator's left are hidden when collapsed.

### macOS 27, direct download build

**Direct build, default:** collapsing turns off each hidden app's "Allow in
the Menu Bar" switch (System Settings › Menu Bar) through cfprefsd, which
MenuBarAgent applies live; expanding turns them back on. Icons are hidden
completely. The Focus icon and the purple screen-capture dot stay visible
while collapsed (measured on macOS 27.0.1); the mic/camera capsule has not been
verified yet, so do not rely on it either way. The arrow is the boundary: ⌘-drag
icons to its left to hide them, to its right to keep them visible. The rest of the bar stays put on
each toggle. The first collapse shows an Open panel: select
`group.com.apple.controlcenter.plist` and click Allow (macOS protects other
apps' data). Switch it off with
`defaults write com.dwarvesv.minimalbar hidesWithMenuBarSettings -bool NO`.

With that off, macOS 27 collapses into macOS's own « menu (every build). The
`|` separator is the boundary, as on macOS 26: ⌘-drag the icons to hide to its
left, and the always-hidden `|` further left still. Collapsing makes `|` just
shorter than the longest item macOS 27 accepts, so the bar runs out of room and
macOS moves every icon left of it into the « menu at the left of the bar, one
click away. Nothing is restricted, so the Focus icon, the mic/camera capsule,
Now Playing and Live Activities stay. No Accessibility permission is needed.

To hide icons completely instead (assessment mode, described below, which
takes those indicators with it), run
`defaults write com.dwarvesv.minimalbar hidesIntoSystemOverflow -bool NO` and
relaunch.

With that off, the direct (non-App Store) build hides icons natively on macOS 27, and the
**arrow itself is the boundary**: there is no `|` separator. ⌘-drag icons to
the arrow's left to hide them when collapsed, to its right to keep them
visible. The always-hidden separator still appears (while expanded) when that
section is enabled, and goes with its section when you right-click the arrow
to hide it. Clicking it, with either button, opens the context menu. Apps launched while expanded show up at once; apps launched while
collapsed stay hidden until you expand.

- Needs **Accessibility** permission (System Settings › Privacy & Security ›
  Accessibility) to see where your icons are. Without it the bar stays
  expanded.
- Hiding is per app: an app with several icons hides or shows them together.
- macOS's own items (clock, Wi-Fi, Sound, Control Center) always stay visible.
  Older-style extras hosted by SystemUIServer (Time Machine, ...) follow the
  arrow like apps do.
- Assessment mode only (not the default above): while Hidden Bar hides any
  icon, macOS also hides the Focus icon, the
  mic/camera/screen-recording capsule, Now Playing and Live Activities, and
  clicking the clock does not open Notification Center. This comes with the
  only hiding mechanism macOS 27 offers (assessment mode); no allow list keeps
  them. The small colored dot in the screen's top-right corner stays. With
  **Show Focus and mic/camera indicators when expanded** (on by default),
  expanding hides nothing, so they come back; the always-hidden section then
  shows while expanded too. Turn it off to keep that section hidden while
  expanded, at the cost of the indicators.
- Run Hidden Bar from `/Applications`; macOS only recognizes that copy as
  Hidden Bar, and a copy elsewhere hides its own arrow.
- **Without dragging:** Preferences › **Menu Bar Items…** lists every app with
  a menu bar icon and a pop-up for its section: *By Position* (where you
  ⌘-dragged it, the default), *Shown*, *Hidden* or *Always Hidden*. It works
  with the keyboard and VoiceOver, takes effect at once (collapsed or not), and
  a choice wins over the icon's position. Choosing *By Position* again undoes
  it. Not available in the App Store build or before macOS 27.
- If hiding cannot work (no Accessibility permission, or the system cannot
  hide), the reason shows in Preferences and at the top of the context menu,
  with a way to fix it.

## Preferences window

| Setting | What it does |
|---|---|
| Start Hidden Bar when I log in | Login item via System Settings (macOS 13+ `SMAppService`); revocable in System Settings > General > Login Items |
| Show preferences on launch | Open this window at app start |
| Auto collapse | Re-hide automatically after the chosen delay |
| Global shortcut | System-wide expand/collapse hotkey (F-keys display as F18, not Fn18) |
| Enable always hidden section | A second zone whose icons stay hidden even when expanded; shown or hidden by right-clicking the arrow |
| Menu Bar Items… | (macOS 27 direct build) Choose each app's section from a list instead of ⌘-dragging |
| Show Focus and mic/camera indicators when expanded | (macOS 27 assessment mode only; not shown in the default allow-list mode, where Focus stays visible anyway) Expanding hides nothing, so macOS's indicators show; the always-hidden section shows while expanded too |
| Use full menu bar on expanding | App becomes briefly "regular" while expanded (helps on tight menubars) |

> **Always-hidden section on macOS 27 (default allow-list mode):** icons in the
> always-hidden zone are switched off only while that section is hidden. Expand
> with the section hidden (right-click the arrow) and they stay off; show the
> section and they come back. Collapsing hides every hidden-zone icon, always-hidden
> ones included. Nothing is moved off-screen, so an icon is never stuck: show the
> section, or quit Hidden Bar, and every switch is restored.

## Behaviors you get for free

- **It won't collapse mid-use**: while your pointer is anywhere in the menu bar,
  the auto-collapse countdown defers and restarts; it resumes when you leave.
- **Self-repair**: if the arrow or separator was ⌘-dragged off the bar (which
  used to make the app unreachable forever), they come back on next launch.
- **Display changes**: plugging in or removing monitors re-sizes the hidden zone
  for the widest attached screen automatically.

## Hidden settings (Terminal)

All via `defaults`; quit and relaunch the app after changing them.

```sh
# expand by hovering the menu bar for ~0.5s (off by default)
defaults write com.dwarvesv.minimalbar hoverToExpand -bool true

# auto-collapse delay in seconds (the UI offers a fixed list; any value works)
defaults write com.dwarvesv.minimalbar numberOfSecondForAutoHide -float 5

# force the app language regardless of system order (issue #287)
defaults write com.dwarvesv.minimalbar AppleLanguages '(en)'
```

To undo any of them: `defaults delete com.dwarvesv.minimalbar <key>`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Icons I want visible got hidden after an update | ⌘-drag them to the right of the arrow (or the separator in the older modes) |
| Login item missing after denying it once | System Settings > General > Login Items: re-enable Hidden Bar, then toggle the pref off/on |
| A ghost "LauncherApplication" login item from old versions | Launch the current version once; it deauthorizes the legacy item automatically |
| App language stuck | See the `AppleLanguages` command above, or System Settings > General > Language & Region > Applications |
| Nothing hides on macOS 27 | Open the context menu (Option-click the arrow): the top line says why. Typical causes: the Open panel for `group.com.apple.controlcenter.plist` was cancelled, or the app has no entry in System Settings › Menu Bar yet |
| A new or just-launched app's icon shows up hidden, or visible while collapsed | See "Why new icons start hidden" below; expand once, then ⌘-drag it to the right of the arrow |

### Why new icons start hidden

macOS always inserts a brand-new menu-bar icon at the far-left slot, which is
inside the hidden zone to the left of the arrow, so a freshly launched or
updated app can appear hidden. This is macOS positioning behavior, not Hidden
Bar moving your icon: no app can reposition another app's menu-bar icon. On
macOS 27 an app also needs an entry in System Settings › Menu Bar before it
can be switched off, and macOS creates that entry itself, so a just-launched
app may stay visible until you expand and collapse again. The one-time fix is
to ⌘-drag the icon to the right of the arrow; macOS remembers that placement
per app, or pick its section under Preferences › **Menu Bar Items…**.

## Requirements

macOS 13 Ventura or later. Pre-Ventura (10.13 - 12.x): use
[v1.10](https://github.com/dwarvesf/hidden/releases/tag/v1.10), the last release
on the old autostart mechanism.
