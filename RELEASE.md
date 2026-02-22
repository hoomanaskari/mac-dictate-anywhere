# Release Workflow

## One-Time Setup: Sparkle EdDSA Keys

Generate the EdDSA key pair used to sign updates. The private key is stored in the macOS Keychain automatically.

```bash
# From the Sparkle package checkout (after first build):
./DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

This prints the **public key** — paste it into `Dictate Anywhere/Info.plist` as the value for `SUPublicEDKey`.

Back up the private key: **Keychain Access > login > search "Sparkle"** — export the item to a secure location.

---

## Release Steps

### 1. Bump Version

In Xcode, update the target's build settings:

- **Marketing Version** (`MARKETING_VERSION`) — e.g. `2.1.0`
- **Current Project Version** (`CURRENT_PROJECT_VERSION`) — increment the build number

### 2. Archive

```bash
xcodebuild \
  -project "Dictate Anywhere.xcodeproj" \
  -scheme "Dictate Anywhere" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "/tmp/DictateAnywhere.xcarchive" \
  archive
```

### 3. Export and Notarize

```bash
# Export the .app from the archive
xcodebuild -exportArchive \
  -archivePath "/tmp/DictateAnywhere.xcarchive" \
  -exportPath "/tmp/DictateAnywhereExport" \
  -exportOptionsPlist ExportOptions.plist

# Notarize (replace APPLE_ID / TEAM_ID or use keychain profile)
xcrun notarytool submit "/tmp/DictateAnywhereExport/Dictate Anywhere.app" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "2SQ9JNU8XE" \
  --password "APP_SPECIFIC_PASSWORD" \
  --wait

# Staple the notarization ticket
xcrun stapler staple "/tmp/DictateAnywhereExport/Dictate Anywhere.app"
```

### 4. Create DMG

```bash
create-dmg \
  --volname "Dictate Anywhere" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Dictate Anywhere.app" 150 185 \
  --app-drop-link 450 185 \
  "/tmp/DictateAnywhere.dmg" \
  "/tmp/DictateAnywhereExport/Dictate Anywhere.app"
```

### 5. Sign DMG with Sparkle (EdDSA)

```bash
./DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
  "/tmp/DictateAnywhere.dmg"
```

This outputs an `edSignature` and `length` — you'll need these for the appcast (or let `generate_appcast` handle it automatically).

### 6. Generate / Update appcast.xml

Place the DMG in a folder and run `generate_appcast` against it:

```bash
# Create a staging folder with the DMG
mkdir -p /tmp/appcast_staging
cp "/tmp/DictateAnywhere.dmg" /tmp/appcast_staging/

# Generate the appcast
./DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/hoomanaskari/mac-dictate-anywhere/releases/download/vX.Y.Z/" \
  /tmp/appcast_staging
```

This creates/updates an `appcast.xml` in the staging folder. Copy it to the repo root:

```bash
cp /tmp/appcast_staging/appcast.xml ./appcast.xml
```

### 7. Commit, Tag, Push

```bash
git add appcast.xml
git commit -m "Release vX.Y.Z"
git tag vX.Y.Z
git push && git push origin vX.Y.Z
```

### 8. Create GitHub Release

1. Go to https://github.com/hoomanaskari/mac-dictate-anywhere/releases
2. Create a new release from the tag `vX.Y.Z`
3. Upload the DMG as a release asset
4. Publish the release

The `appcast.xml` on `main` is now live at the `SUFeedURL` and Sparkle will pick up the new version on its next check.

---

## Version Numbering

- `vX.Y.Z` -> `vX.Y.(Z+1)` for bug fixes
- `vX.Y.Z` -> `vX.(Y+1).0` for new features
- `vX.Y.Z` -> `v(X+1).0.0` for breaking changes
