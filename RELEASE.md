# Release Workflow

## Prerequisites (One-Time Setup) — Already Done

- EdDSA signing keys generated and stored in macOS Keychain
- Public key set in `Dictate Anywhere/Info.plist` (`SUPublicEDKey`)
- Private key backed up as `private-eddsa-key.pem` (stored securely, not in repo)
- `create-dmg` installed via Homebrew
- Notarization credentials stored: `xcrun notarytool store-credentials "notarytool-profile"`

To import the private key on a new machine:

```bash
"$SPARKLE_BIN/generate_keys" -f private-eddsa-key.pem
```

---

## Releasing a New Version

Set the version once and use it throughout:

```bash
VERSION="2.1"  # change this for each release
```

Set the Sparkle bin path:

```bash
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/sparkle/Sparkle/bin/generate_appcast' -print -quit 2>/dev/null | xargs dirname)"
```

### Step 1: Bump the Version Number

In Xcode, update the target's build settings:

- **MARKETING_VERSION** → `$VERSION` (e.g., `2.1`) — user-facing version
- **CURRENT_PROJECT_VERSION** → increment by 1 (e.g., `2`) — Sparkle uses this to detect updates

### Step 2: Commit and Tag

```bash
git add .
git commit -m "Release v${VERSION}"
git tag "v${VERSION}"
git push && git push origin "refs/tags/v${VERSION}"
```

> **Note**: Use `refs/tags/v${VERSION}` to avoid ambiguity if a branch with the same name exists.

### Step 3: Archive the App

```bash
xcodebuild \
  -project "Dictate Anywhere.xcodeproj" \
  -scheme "Dictate Anywhere" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "/tmp/DictateAnywhere.xcarchive" \
  archive
```

### Step 4: Export the .app from the Archive

```bash
mkdir -p dist
rm -rf "dist/Dictate Anywhere.app"
cp -R "/tmp/DictateAnywhere.xcarchive/Products/Applications/Dictate Anywhere.app" dist/
```

### Step 5: Notarize the App

```bash
ditto -c -k --sequesterRsrc --keepParent "dist/Dictate Anywhere.app" "/tmp/DictateAnywhere-notarize.zip"

xcrun notarytool submit "/tmp/DictateAnywhere-notarize.zip" \
  --keychain-profile "notarytool-profile" \
  --wait

xcrun stapler staple "dist/Dictate Anywhere.app"
```

### Step 6: Create the DMG

```bash
rm -f "dist/Dictate Anywhere.dmg"

create-dmg \
  --volname "Dictate Anywhere" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Dictate Anywhere.app" 150 185 \
  --app-drop-link 450 185 \
  "dist/Dictate Anywhere.dmg" \
  "dist/Dictate Anywhere.app"
```

### Step 7: Notarize the DMG

```bash
xcrun notarytool submit "dist/Dictate Anywhere.dmg" \
  --keychain-profile "notarytool-profile" \
  --wait

xcrun stapler staple "dist/Dictate Anywhere.dmg"
```

### Step 8: Generate the Appcast

```bash
mkdir -p sparkle-releases
cp "dist/Dictate Anywhere.dmg" "sparkle-releases/DictateAnywhere-${VERSION}.dmg"

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/hoomanaskari/mac-dictate-anywhere/releases/download/v${VERSION}/" \
  --link "https://github.com/hoomanaskari/mac-dictate-anywhere" \
  -o appcast.xml \
  sparkle-releases/
```

### Step 9: Verify the Appcast

Open `appcast.xml` and confirm the new `<item>` has:

- Correct `sparkle:version` (build number) and `sparkle:shortVersionString` (marketing version)
- The correct `url` pointing to the GitHub release download
- The correct `length` (file size in bytes)

### Step 10: Push Appcast and Create GitHub Release

```bash
git add appcast.xml
git commit -m "Update appcast for v${VERSION}"
git push

gh release create "v${VERSION}" \
  "dist/DictateAnywhere-${VERSION}.dmg" \
  --title "Dictate Anywhere v${VERSION}" \
  --notes "Release notes here"
```

The DMG filename on the GitHub release **must** match the appcast URL: `DictateAnywhere-${VERSION}.dmg`

> **Important**: Do not use spaces in DMG filenames — GitHub converts them to dots, breaking download URLs.

The appcast is served from: `https://raw.githubusercontent.com/hoomanaskari/mac-dictate-anywhere/main/appcast.xml`

---

## Quick Reference

```bash
VERSION="2.1"
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/sparkle/Sparkle/bin/generate_appcast' -print -quit 2>/dev/null | xargs dirname)"

# Archive
xcodebuild -project "Dictate Anywhere.xcodeproj" -scheme "Dictate Anywhere" \
  -configuration Release -destination "generic/platform=macOS" \
  -archivePath "/tmp/DictateAnywhere.xcarchive" archive

# Export app
mkdir -p dist && rm -rf "dist/Dictate Anywhere.app"
cp -R "/tmp/DictateAnywhere.xcarchive/Products/Applications/Dictate Anywhere.app" dist/

# Notarize app
ditto -c -k --sequesterRsrc --keepParent "dist/Dictate Anywhere.app" "/tmp/DictateAnywhere-notarize.zip"
xcrun notarytool submit "/tmp/DictateAnywhere-notarize.zip" --keychain-profile "notarytool-profile" --wait
xcrun stapler staple "dist/Dictate Anywhere.app"

# Create DMG
rm -f "dist/Dictate Anywhere.dmg"
create-dmg --volname "Dictate Anywhere" --window-pos 200 120 --window-size 600 400 \
  --icon-size 100 --icon "Dictate Anywhere.app" 150 185 --app-drop-link 450 185 \
  "dist/Dictate Anywhere.dmg" "dist/Dictate Anywhere.app"

# Notarize DMG
xcrun notarytool submit "dist/Dictate Anywhere.dmg" --keychain-profile "notarytool-profile" --wait
xcrun stapler staple "dist/Dictate Anywhere.dmg"

# Generate appcast
mkdir -p sparkle-releases
cp "dist/Dictate Anywhere.dmg" "sparkle-releases/DictateAnywhere-${VERSION}.dmg"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/hoomanaskari/mac-dictate-anywhere/releases/download/v${VERSION}/" \
  --link "https://github.com/hoomanaskari/mac-dictate-anywhere" \
  -o appcast.xml sparkle-releases/

# Push appcast and create release
git add appcast.xml && git commit -m "Update appcast for v${VERSION}" && git push
gh release create "v${VERSION}" "dist/DictateAnywhere-${VERSION}.dmg" \
  --title "Dictate Anywhere v${VERSION}" --notes "Release notes here"
```

---

## Version Numbering

- `v2.0` → `v2.0.1` for bug fixes
- `v2.0` → `v2.1` for new features
- `v2.0` → `v3.0` for major changes

Remember: `CURRENT_PROJECT_VERSION` (build number) must always increase, regardless of version scheme.

---

## Troubleshooting

**"No EdDSA key found"**: Run `"$SPARKLE_BIN/generate_keys"` to create one, or import with `generate_keys -f private-eddsa-key.pem`.

**Sparkle rejects the update**: Ensure `SUPublicEDKey` in Info.plist matches the key used to sign. Run `"$SPARKLE_BIN/generate_keys"` to print the current public key.

**Update not appearing**: Verify `appcast.xml` is on the `main` branch. Check `sparkle:version` (build number) in the appcast is higher than the installed build number.

**Tag push fails with "matches more than one"**: Use `git push origin refs/tags/vX.Y` to disambiguate from branches.

**Notarization fails**: Ensure Hardened Runtime is enabled and the app is signed with a Developer ID certificate (not a development certificate).
