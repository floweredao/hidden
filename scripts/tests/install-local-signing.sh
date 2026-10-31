#!/bin/bash
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose: they expand when the stub runs
# Runs scripts/install-local.sh on a Mac with no Apple Development identity (no Apple account in
# Xcode) and checks that it still builds and installs, signed ad hoc. Every macOS tool is stubbed on
# PATH and HOME is a temp folder, so it touches nothing outside that folder and never quits a running
# Hidden Bar.
#
#   scripts/tests/install-local-signing.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Copy the script so its .work folder lands in the temp folder, not the checkout.
mkdir -p "$T/root/scripts" "$T/bin" "$T/home/.Trash" "$T/apps"
cp "$REPO/scripts/install-local.sh" "$T/root/scripts/"

stub() { printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }

# A keychain with no code-signing identities.
stub security 'echo "     0 valid identities found"'
stub xcodebuild '
echo "$*" >"$HOME/xcodebuild.args"
while [ $# -gt 0 ]; do [ "$1" = -derivedDataPath ] && dd=$2; shift; done
mkdir -p "$dd/Build/Products/Release-Direct/Hidden Bar.app/Contents"'
stub codesign 'exit 0'
stub defaults 'exit 0'
stub pgrep '[ -e "$HOME/running" ]'
stub open 'touch "$HOME/running"'
stub ditto 'cp -R "$1" "$2"'
stub pkill 'exit 0'
stub sleep 'exit 0'

if ! env -u HIDDEN_TEAM HOME="$T/home" PATH="$T/bin:$PATH" HIDDEN_INSTALL_DIR="$T/apps" \
    HIDDEN_BACKUP_DIR="$T/backups" bash "$T/root/scripts/install-local.sh" >"$T/out.log" 2>&1; then
  cat "$T/out.log" >&2
  echo "FAIL: install-local.sh exited non-zero without an Apple Development identity" >&2
  exit 1
fi

args=$(cat "$T/home/xcodebuild.args")
case " $args " in
  *" CODE_SIGN_IDENTITY=- "*) ;;
  *) echo "FAIL: build was not signed ad hoc: $args" >&2; exit 1 ;;
esac
if grep -qE 'DEVELOPMENT_TEAM=[^ ]' <<<"$args"; then
  echo "FAIL: build still names a team: $args" >&2; exit 1
fi
[ -d "$T/apps/Hidden Bar.app" ] || { echo "FAIL: nothing installed" >&2; exit 1; }
grep -q 'ad hoc' "$T/out.log" || { cat "$T/out.log" >&2; echo "FAIL: no ad-hoc notice" >&2; exit 1; }
echo "PASS: installs signed ad hoc without an Apple Development identity"
