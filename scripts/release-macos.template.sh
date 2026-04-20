#!/usr/bin/env bash
set -euo pipefail

# Copy this file to scripts/release-macos.sh, set your local signing values,
# and keep scripts/release-macos.sh untracked.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Dictate Anywhere.xcodeproj"
SCHEME="Dictate Anywhere"
CONFIGURATION="${CONFIGURATION:-Release}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
SPARKLE_RELEASES_DIR="${SPARKLE_RELEASES_DIR:-$ROOT_DIR/sparkle-releases}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
TEAM_ID="${TEAM_ID:-}"
DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-}"
ARCHIVE_PATH="${ARCHIVE_PATH:-/tmp/DictateAnywhere.xcarchive}"
TEMP_DIR="$(mktemp -d /tmp/dictate-release.XXXXXX)"
MOUNT_POINT=""
APP_NAME="Dictate Anywhere.app"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-}"
REPOSITORY_LINK="${REPOSITORY_LINK:-}"

cleanup() {
  if [[ -n "$MOUNT_POINT" ]] && mount | grep -F "on $MOUNT_POINT " >/dev/null 2>&1; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

log() {
  printf '\n==> %s\n' "$1"
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_value() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "Missing required value: $name"
}

require_identity() {
  local identity="$1"
  security find-identity -v -p basic | grep -F "$identity" >/dev/null || fail "Missing signing identity: $identity"
}

find_sparkle_bin_dir() {
  local generate_appcast_path
  generate_appcast_path="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Sparkle/bin/generate_appcast' -print -quit 2>/dev/null || true)"
  [[ -n "$generate_appcast_path" ]] || return 1
  dirname "$generate_appcast_path"
}

require_notary_profile() {
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "Missing notarization profile '$NOTARY_PROFILE'. Run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\""
}

resign_path() {
  local path="$1"
  codesign \
    --force \
    --sign "$DEVELOPER_ID_APP" \
    --timestamp \
    --options runtime \
    --preserve-metadata=identifier,entitlements,requirements,flags \
    "$path"
}

resign_sparkle_helpers() {
  local sparkle_dir="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
  [[ -d "$sparkle_dir" ]] || return 0

  resign_path "$sparkle_dir/Autoupdate"
  resign_path "$sparkle_dir/XPCServices/Downloader.xpc"
  resign_path "$sparkle_dir/XPCServices/Installer.xpc"
  resign_path "$sparkle_dir/Updater.app"
  resign_path "$APP_PATH/Contents/Frameworks/Sparkle.framework"
  resign_path "$APP_PATH"
}

normalize_appcast_links() {
  DOWNLOAD_URL_PREFIX="$DOWNLOAD_URL_PREFIX" REPOSITORY_LINK="$REPOSITORY_LINK" perl -0pi -e '
    my $download_url_prefix = $ENV{DOWNLOAD_URL_PREFIX};
    my $repository_link = $ENV{REPOSITORY_LINK};
    (my $raw_base = $repository_link) =~ s{^https://github\.com/}{https://raw.githubusercontent.com/};
    $raw_base .= "/main";
    s{https://github\.com/[^/]+/[^/]+/releases/download/v[^/]+/(DictateAnywhere-([0-9.]+)\.zip)}{"$download_url_prefix/v$2/$1"}ge;
    s{https://raw\.githubusercontent\.com/[^/]+/[^/]+/main/DictateAnywhere-([0-9.]+)\.md}{"$raw_base/sparkle-releases/DictateAnywhere-$1.md"}ge;
  ' "$APPCAST_PATH"
}

read_build_setting() {
  local key="$1"
  awk -F ' = ' -v key="$key" '$1 ~ key { print $2; exit }' <<<"$BUILD_SETTINGS"
}

require_command xcodebuild
require_command xcrun
require_command ditto
require_command codesign
require_command spctl
require_command create-dmg
require_command hdiutil

require_value "NOTARY_PROFILE" "$NOTARY_PROFILE"
require_value "TEAM_ID" "$TEAM_ID"
require_value "DEVELOPER_ID_APP" "$DEVELOPER_ID_APP"
require_value "DOWNLOAD_URL_PREFIX" "$DOWNLOAD_URL_PREFIX"
require_value "REPOSITORY_LINK" "$REPOSITORY_LINK"

require_identity "$DEVELOPER_ID_APP"
require_notary_profile

SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-$(find_sparkle_bin_dir || true)}"
[[ -n "$SPARKLE_BIN_DIR" ]] || fail "Could not find Sparkle's generate_appcast. Open the project in Xcode once or resolve Swift packages first."
[[ -x "$SPARKLE_BIN_DIR/generate_appcast" ]] || fail "generate_appcast not found at $SPARKLE_BIN_DIR"

log "Reading release version"
BUILD_SETTINGS="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings)"
MARKETING_VERSION="$(read_build_setting "MARKETING_VERSION")"
CURRENT_PROJECT_VERSION="$(read_build_setting "CURRENT_PROJECT_VERSION")"
[[ -n "$MARKETING_VERSION" ]] || fail "Could not read MARKETING_VERSION"
[[ -n "$CURRENT_PROJECT_VERSION" ]] || fail "Could not read CURRENT_PROJECT_VERSION"

ZIP_ASSET="$DIST_DIR/DictateAnywhere-${MARKETING_VERSION}.zip"
DMG_ASSET="$DIST_DIR/DictateAnywhere-${MARKETING_VERSION}.dmg"
APP_PATH="$DIST_DIR/$APP_NAME"
APPCAST_PATH="$ROOT_DIR/appcast.xml"
APP_NOTARY_ZIP="$TEMP_DIR/DictateAnywhere-notary.zip"

log "Archiving signed app"
rm -rf "$ARCHIVE_PATH"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive

log "Preparing dist folder"
mkdir -p "$DIST_DIR"
rm -rf "$APP_PATH" "$ZIP_ASSET" "$DMG_ASSET"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME" "$DIST_DIR/"

log "Re-signing Sparkle helper tools"
resign_sparkle_helpers

log "Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH" >/dev/null 2>&1

log "Submitting app for notarization"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$APP_NOTARY_ZIP"
xcrun notarytool submit "$APP_NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
spctl -a -vv "$APP_PATH"

log "Creating Sparkle zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_ASSET"

log "Creating DMG"
create-dmg \
  --volname "Dictate Anywhere" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "$APP_NAME" 150 185 \
  --app-drop-link 450 185 \
  "$DMG_ASSET" \
  "$APP_PATH"

log "Submitting DMG for notarization"
xcrun notarytool submit "$DMG_ASSET" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_ASSET"
xcrun stapler validate "$DMG_ASSET"

log "Verifying mounted DMG app"
MOUNT_POINT="$TEMP_DIR/dmg-mount"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_ASSET" -mountpoint "$MOUNT_POINT" -nobrowse -quiet
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/$APP_NAME"
spctl -a -vv "$MOUNT_POINT/$APP_NAME"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

log "Updating Sparkle feed"
mkdir -p "$SPARKLE_RELEASES_DIR"
cp "$ZIP_ASSET" "$SPARKLE_RELEASES_DIR/"
"$SPARKLE_BIN_DIR/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX/v${MARKETING_VERSION}/" \
  --embed-release-notes \
  --link "$REPOSITORY_LINK" \
  -o "$APPCAST_PATH" \
  "$SPARKLE_RELEASES_DIR"
normalize_appcast_links

printf '\nRelease artifacts ready:\n'
printf '  App version: %s (%s)\n' "$MARKETING_VERSION" "$CURRENT_PROJECT_VERSION"
printf '  ZIP: %s\n' "$ZIP_ASSET"
printf '  DMG: %s\n' "$DMG_ASSET"
printf '  Appcast: %s\n' "$APPCAST_PATH"
