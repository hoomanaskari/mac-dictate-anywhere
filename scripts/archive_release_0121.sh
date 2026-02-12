#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Dictate Anywhere.xcodeproj"
SCHEME_NAME="Dictate Anywhere"
ARCHIVE_PATH="${1:-/tmp/DictateAnywhere-0.12.1.xcarchive}"

echo "Resolving Swift packages..."
xcodebuild -resolvePackageDependencies -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" >/dev/null

echo "Applying FluidAudio 0.12.1 compatibility patch..."
"$ROOT_DIR/scripts/patch_fluidaudio_0121.sh"

echo "Creating Release archive at: $ARCHIVE_PATH"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  archive \
  -archivePath "$ARCHIVE_PATH"

echo "Archive succeeded: $ARCHIVE_PATH"
