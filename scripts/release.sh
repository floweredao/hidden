#!/bin/bash
# Build a fork release: the unsandboxed Release-Direct app, zipped, EdDSA-signed
# for Sparkle, with a new <item> added at the top of appcast.xml.
#
#   scripts/release.sh <release-notes.html>
#
# Writes .work/release/<fork version>/Hidden-Bar-<fork version>.zip and edits
# appcast.xml in place. It does not publish anything: upload the zip to the
# GitHub release v<fork version> first, then commit and push appcast.xml (see
# docs/RUNBOOK.md, "Release").
#
# The EdDSA private key stays in the login keychain (item "https://sparkle-project.org",
# account "floweredao-hidden", created once with `generate_keys --account floweredao-hidden`).
# Other Sparkle keys in the same keychain are left alone.
#   HIDDEN_SPARKLE_BIN   folder with generate_keys/sign_update (default: the build's SPM artifact)
#
# Environment overrides:
#   HIDDEN_TEAM          signing team ID (default: team of your first "Apple Development" identity)
#   HIDDEN_BUILD_ARGS    extra xcodebuild settings, e.g. "CURRENT_PROJECT_VERSION=16001" for a QA build
#   HIDDEN_NO_APPCAST=1  build, zip and sign only; leave appcast.xml alone
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOTES=${1:-}
APP_NAME="Hidden Bar.app"
REPO_URL=https://github.com/floweredao/hidden
APPCAST="$ROOT/appcast.xml"

step() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ -z "${HIDDEN_NO_APPCAST:-}" ]; then
  [ -n "$NOTES" ] && [ -f "$NOTES" ] || fail "usage: scripts/release.sh <release-notes.html>"
fi

TEAM=${HIDDEN_TEAM:-}
if [ -z "$TEAM" ]; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)
  [ -n "$identity" ] || fail "no Apple Development signing identity found; set HIDDEN_TEAM"
  TEAM=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject -nameopt multiline \
    | sed -n 's/^ *organizationalUnitName *= *//p' | head -n 1)
  [ -n "$TEAM" ] || fail "could not read the team ID of \"$identity\"; set HIDDEN_TEAM"
fi

WORK="$ROOT/.work/release"
DERIVED="$WORK/DerivedData"
mkdir -p "$WORK"

step "Building Release-Direct (team $TEAM)"
# shellcheck disable=SC2086
if ! xcodebuild -project "$ROOT/Hidden Bar.xcodeproj" -scheme 'Hidden Bar' \
    -configuration Release-Direct -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM" ${HIDDEN_BUILD_ARGS:-} \
    build >"$WORK/build.log" 2>&1; then
  tail -n 30 "$WORK/build.log" >&2
  fail "build failed; full log: $WORK/build.log"
fi
APP="$DERIVED/Build/Products/Release-Direct/$APP_NAME"
[ -d "$APP" ] || fail "build produced no app at $APP"

INFO="$APP/Contents/Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO"; }
FORK=$(read_key HBForkVersion)
SHORT=$(read_key CFBundleShortVersionString)
BUILD=$(read_key CFBundleVersion)
MIN_OS=$(read_key LSMinimumSystemVersion)
COMMIT=$(read_key HBGitCommit)

step "Checking $FORK ($BUILD, $COMMIT)"
case "$COMMIT" in *-dirty) fail "the build has uncommitted changes ($COMMIT); commit first" ;; esac
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'com.apple.security.app-sandbox'; then
  fail "the build carries the App Sandbox entitlement; it would hide nothing on macOS 27"
fi
codesign --verify --deep --strict "$APP" || fail "codesign verification failed"
[ -n "$(read_key SUFeedURL)" ] || fail "SUFeedURL is empty"
[ -n "$(read_key SUPublicEDKey)" ] || fail "SUPublicEDKey is empty"

SPARKLE_BIN=${HIDDEN_SPARKLE_BIN:-"$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"}
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
[ -x "$SIGN_UPDATE" ] && [ -x "$GENERATE_KEYS" ] || fail "Sparkle tools not found in $SPARKLE_BIN"

OUT="$WORK/$FORK"
ZIP="$OUT/Hidden-Bar-$FORK.zip"
mkdir -p "$OUT"
rm -f "$ZIP"
step "Zipping to $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

step "Signing the zip (EdDSA key from the login keychain)"
# The keychain item only trusts the generate_keys binary that created it, so
# sign_update reading it directly raises a keychain password prompt. Instead
# generate_keys exports the key into a private (0700) folder that is wiped as
# soon as signing ends, and sign_update reads it on stdin.
KEY_ACCOUNT=floweredao-hidden
KEY_DIR=$(umask 077; mktemp -d "$WORK/key.XXXXXX")
trap 'rm -P -f "$KEY_DIR/key" 2>/dev/null; rm -rf "$KEY_DIR"' EXIT
(umask 077; perl -e 'alarm 30; exec @ARGV' "$GENERATE_KEYS" --account "$KEY_ACCOUNT" -x "$KEY_DIR/key" >/dev/null 2>&1) \
  || fail "could not read the EdDSA key (account $KEY_ACCOUNT) from the keychain; approve generate_keys' keychain prompt with Always Allow"
SIGNATURE=$("$SIGN_UPDATE" --ed-key-file - "$ZIP" <"$KEY_DIR/key")
"$SIGN_UPDATE" --verify "$ZIP" "$(printf '%s' "$SIGNATURE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')" \
  --ed-key-file - <"$KEY_DIR/key" || fail "the new signature does not verify"
rm -P -f "$KEY_DIR/key"; rm -rf "$KEY_DIR"
printf '%s\n' "$SIGNATURE" >"$OUT/signature.txt"

if [ -n "${HIDDEN_NO_APPCAST:-}" ]; then
  echo "Built $ZIP ($SIGNATURE); appcast.xml left alone."
  exit 0
fi

grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST" 2>/dev/null \
  && fail "appcast.xml already lists build $BUILD"

step "Adding build $BUILD to appcast.xml"
ITEM="$OUT/item.xml"
{
  echo "    <item>"
  echo "      <title>Hidden Bar $FORK</title>"
  echo "      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
  echo "      <sparkle:version>$BUILD</sparkle:version>"
  echo "      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>"
  echo "      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>"
  echo "      <sparkle:fullReleaseNotesLink>$REPO_URL/releases/tag/v$FORK</sparkle:fullReleaseNotesLink>"
  echo "      <description><![CDATA["
  cat "$NOTES"
  echo "      ]]></description>"
  echo "      <enclosure url=\"$REPO_URL/releases/download/v$FORK/Hidden-Bar-$FORK.zip\" type=\"application/octet-stream\" $SIGNATURE />"
  echo "    </item>"
} >"$ITEM"

if [ ! -f "$APPCAST" ]; then
  cat >"$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hidden Bar (floweredao fork)</title>
    <link>$REPO_URL</link>
    <description>Updates for the floweredao fork of Hidden Bar.</description>
    <language>en</language>
  </channel>
</rss>
EOF
fi
# Newest item first, right after the channel header.
awk -v item="$ITEM" '
  { print }
  /<language>/ && !done { while ((getline line < item) > 0) print line; done = 1 }
' "$APPCAST" >"$APPCAST.tmp" && mv "$APPCAST.tmp" "$APPCAST"
xmllint --noout "$APPCAST" || fail "appcast.xml is not well-formed"

echo
echo "Zip:       $ZIP ($(stat -f %z "$ZIP") bytes)"
echo "Version:   $FORK (bundle $SHORT, build $BUILD, commit $COMMIT)"
echo "Signature: $SIGNATURE"
echo "Next:      gh release create v$FORK \"$ZIP\" --target <commit $COMMIT> ...; then commit and push appcast.xml"
