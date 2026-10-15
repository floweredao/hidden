#!/bin/bash
# Build the unsandboxed Release-Direct app and install it over /Applications/Hidden Bar.app.
#
#   scripts/install-local.sh
#
# Environment overrides:
#   HIDDEN_TEAM         signing team ID (default: team of your first "Apple Development" identity)
#   HIDDEN_INSTALL_DIR  install folder (default: /Applications)
#   HIDDEN_BACKUP_DIR   preference backups (default: ~/Library/Application Support/Hidden Bar Backups)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/.work/install-local"
INSTALL_DIR=${HIDDEN_INSTALL_DIR:-/Applications}
BACKUP_DIR=${HIDDEN_BACKUP_DIR:-"$HOME/Library/Application Support/Hidden Bar Backups"}
BUNDLE_ID=com.dwarvesv.minimalbar
APP_NAME="Hidden Bar.app"
STAMP=$(date +%Y%m%d-%H%M%S)

step() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

TEAM=${HIDDEN_TEAM:-}
if [ -z "$TEAM" ]; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)
  [ -n "$identity" ] || fail "no Apple Development signing identity found; set HIDDEN_TEAM"
  TEAM=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject -nameopt multiline \
    | sed -n 's/^ *organizationalUnitName *= *//p' | head -n 1)
  [ -n "$TEAM" ] || fail "could not read the team ID of \"$identity\"; set HIDDEN_TEAM"
fi

step "Building Release-Direct (team $TEAM)"
mkdir -p "$WORK"
if ! xcodebuild -project "$ROOT/Hidden Bar.xcodeproj" -scheme 'Hidden Bar' \
    -configuration Release-Direct -derivedDataPath "$WORK/DerivedData" \
    CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM" \
    build >"$WORK/build.log" 2>&1; then
  tail -n 30 "$WORK/build.log" >&2
  fail "build failed; full log: $WORK/build.log"
fi
APP="$WORK/DerivedData/Build/Products/Release-Direct/$APP_NAME"
[ -d "$APP" ] || fail "build produced no app at $APP"

step "Checking the build is unsandboxed and validly signed"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'com.apple.security.app-sandbox'; then
  fail "the build carries the App Sandbox entitlement; it would hide nothing on macOS 27. Not installing."
fi
codesign --verify --deep --strict "$APP" || fail "codesign verification failed"

step "Backing up preferences to $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
defaults export "$BUNDLE_ID" "$BACKUP_DIR/$BUNDLE_ID-$STAMP.plist"

if pgrep -x "Hidden Bar" >/dev/null; then
  step "Quitting the running Hidden Bar"
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x "Hidden Bar" >/dev/null || break; sleep 0.5; done
  if pgrep -x "Hidden Bar" >/dev/null; then pkill -x "Hidden Bar"; sleep 1; fi
  ! pgrep -x "Hidden Bar" >/dev/null || fail "Hidden Bar is still running"
fi

TARGET="$INSTALL_DIR/$APP_NAME"
if [ -e "$TARGET" ]; then
  step "Moving the old app to the Trash"
  mv "$TARGET" "$HOME/.Trash/Hidden Bar $STAMP.app"
fi

step "Installing to $TARGET"
ditto "$APP" "$TARGET"

step "Launching"
open "$TARGET"
for _ in $(seq 1 20); do pgrep -x "Hidden Bar" >/dev/null && break; sleep 0.5; done

INFO="$TARGET/Contents/Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO" 2>/dev/null || echo "-"; }
echo
echo "Installed:  $TARGET"
echo "Version:    $(read_key HBForkVersion) (bundle $(read_key CFBundleShortVersionString), build $(read_key CFBundleVersion))"
echo "Commit:     $(read_key HBGitCommit)"
echo "Signed by:  $(codesign -dvv "$TARGET" 2>&1 | sed -n 's/^Authority=//p' | head -n 1) (team $(codesign -dv "$TARGET" 2>&1 | sed -n 's/^TeamIdentifier=//p'))"
echo "Sandbox:    $(codesign -d --entitlements - --xml "$TARGET" 2>/dev/null | grep -q app-sandbox && echo ON || echo off)"
echo "Running:    $(pgrep -x "Hidden Bar" >/dev/null && echo "yes (pid $(pgrep -x "Hidden Bar"))" || echo no)"
echo "Prefs backup: $BACKUP_DIR/$BUNDLE_ID-$STAMP.plist"
