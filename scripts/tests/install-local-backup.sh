#!/bin/bash
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose: they expand when the stub runs
# Runs scripts/install-local.sh against a fake HOME with every macOS tool stubbed on PATH and checks
# that the preferences backup holds the plist the installed (unsandboxed) app reads, not a stale
# App Sandbox container plist. Runs on Linux or macOS; touches nothing outside a temp folder.
#
#   scripts/tests/install-local-backup.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
BUNDLE_ID=com.dwarvesv.minimalbar
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Copy the script so its .work folder lands in the temp folder, not the checkout.
mkdir -p "$T/root/scripts" "$T/bin" "$T/home/.Trash" "$T/apps"
cp "$REPO/scripts/install-local.sh" "$T/root/scripts/"

# Two synthetic plists with different content: the real prefs and a leftover sandbox container.
HOME_DIR="$T/home"
mkdir -p "$HOME_DIR/Library/Preferences" "$HOME_DIR/Library/Containers/$BUNDLE_ID/Data/Library/Preferences"
echo 'REAL-PREFERENCES' >"$HOME_DIR/Library/Preferences/$BUNDLE_ID.plist"
echo 'STALE-CONTAINER' >"$HOME_DIR/Library/Containers/$BUNDLE_ID/Data/Library/Preferences/$BUNDLE_ID.plist"

stub() { printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }

# `defaults export <domain> <file>` modelled on macOS: an absolute path names that file (".plist"
# optional); a bundle id resolves to the app's container plist when a container exists for it.
stub defaults '
echo "$*" >>"$HOME/defaults.log"
[ "$1" = export ] || exit 1
domain=$2 out=$3
case $domain in
  /*) src=${domain%.plist}.plist ;;
  *) src="$HOME/Library/Containers/$domain/Data/Library/Preferences/$domain.plist"
     [ -d "$HOME/Library/Containers/$domain" ] || src="$HOME/Library/Preferences/$domain.plist" ;;
esac
[ -f "$src" ] || { echo "Domain $domain does not exist" >&2; exit 1; }
cp "$src" "$out"'
stub xcodebuild '
while [ $# -gt 0 ]; do [ "$1" = -derivedDataPath ] && dd=$2; shift; done
mkdir -p "$dd/Build/Products/Release-Direct/Hidden Bar.app/Contents"'
stub codesign 'exit 0'
stub pgrep '[ -e "$HOME/running" ]'
stub open 'touch "$HOME/running"'
stub ditto 'cp -R "$1" "$2"'
stub osascript 'exit 0'
stub pkill 'exit 0'
stub sleep 'exit 0'

BACKUP="$T/backups"
if ! HOME="$HOME_DIR" PATH="$T/bin:$PATH" HIDDEN_TEAM=TESTTEAM HIDDEN_INSTALL_DIR="$T/apps" \
    HIDDEN_BACKUP_DIR="$BACKUP" bash "$T/root/scripts/install-local.sh" >"$T/out.log" 2>&1; then
  cat "$T/out.log" >&2
  echo "FAIL: install-local.sh exited non-zero" >&2
  exit 1
fi

shopt -s nullglob
backups=("$BACKUP/$BUNDLE_ID"-*.plist)
[ ${#backups[@]} -eq 1 ] || { echo "FAIL: expected one backup, found ${#backups[@]}" >&2; exit 1; }
echo "defaults called with: $(cat "$HOME_DIR/defaults.log")"
if [ "$(cat "${backups[0]}")" != REAL-PREFERENCES ]; then
  echo "FAIL: backup holds '$(cat "${backups[0]}")', expected the ~/Library/Preferences plist" >&2
  exit 1
fi
[ -d "$T/apps/Hidden Bar.app" ] || { echo "FAIL: app was not installed" >&2; exit 1; }
echo "PASS: backup holds ~/Library/Preferences/$BUNDLE_ID.plist"
