# Release Workflow

## Prerequisites (One-Time Setup)

### 1. Generate EdDSA Signing Keys

Sparkle uses EdDSA (ed25519) keys to sign updates. You only need **one key pair** for all your apps. The private key is stored in your macOS Keychain.

```bash
# Generate keys (or print the existing public key if already generated)
SPARKLE_BIN="$(xcodebuild -project 'Dictate Anywhere.xcodeproj' -scheme 'Dictate Anywhere' -showBuildSettings 2>/dev/null | grep -m1 BUILD_DIR | awk '{print $3}')"/../../SourcePackages/artifacts/sparkle/Sparkle/bin

"$SPARKLE_BIN/generate_keys"
```

This will output something like:

```
A]  key already exists; public key:
    <YOUR_PUBLIC_KEY_BASE64>

    Add the `SUPublicEDKey` property to your app's Info.plist:
    <key>SUPublicEDKey</key>
    <string><YOUR_PUBLIC_KEY_BASE64></string>
```

**Important**: Copy the base64 public key and paste it into `Dictate Anywhere/Info.plist` as the value for `SUPublicEDKey` (replacing `REPLACE_WITH_GENERATED_PUBLIC_KEY`).

### 2. Export Private Key for Backup

Back up your private key in case you need to sign from another machine:

```bash
"$SPARKLE_BIN/generate_keys" -x private-eddsa-key.pem
```

Store `private-eddsa-key.pem` somewhere secure (e.g., a password manager). **Never commit it to the repo.**

To import it on another machine:

```bash
"$SPARKLE_BIN/generate_keys" -f private-eddsa-key.pem
```

### 3. Install create-dmg (if not installed)

```bash
brew install create-dmg
```

---

## Releasing a New Version

### Step 1: Bump the Version Number

Update the version in Xcode:
- **MARKETING_VERSION** (e.g., `2.1`) — the user-facing version shown in the app
- **CURRENT_PROJECT_VERSION** (e.g., `2`) — the internal build number, must increase with each release

Sparkle uses `CFBundleVersion` (build number) to determine if an update is newer.

### Step 2: Commit and Tag

```bash
git add .
git commit -m "Release v2.1"
git tag v2.1
git push && git push origin v2.1
```

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
cp -R "/tmp/DictateAnywhere.xcarchive/Products/Applications/Dictate Anywhere.app" dist/
```

### Step 5: Notarize the App

```bash
# Create a zip for notarization
ditto -c -k --sequesterRsrc --keepParent "dist/Dictate Anywhere.app" "/tmp/DictateAnywhere-notarize.zip"

# Submit for notarization
xcrun notarytool submit "/tmp/DictateAnywhere-notarize.zip" \
  --keychain-profile "notarytool-profile" \
  --wait

# Staple the notarization ticket to the app
xcrun stapler staple "dist/Dictate Anywhere.app"
```

> **Note**: You need to have stored your Apple ID credentials first with:
> `xcrun notarytool store-credentials "notarytool-profile" --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID`

### Step 6: Create the DMG

```bash
# Remove any previous DMG
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

Sparkle's `generate_appcast` tool reads your DMG, signs it with the EdDSA key from your Keychain, and updates `appcast.xml` automatically.

```bash
# Create a directory for Sparkle releases
mkdir -p sparkle-releases

# Copy the DMG into it (filename should include the version)
cp "dist/Dictate Anywhere.dmg" "sparkle-releases/Dictate Anywhere 2.1.dmg"
```

Optionally, add release notes by creating a file with the same name but `.html` or `.md` extension:

```bash
# (Optional) Create release notes
cat > "sparkle-releases/Dictate Anywhere 2.1.html" << 'EOF'
<ul>
  <li>New feature: ...</li>
  <li>Bug fix: ...</li>
</ul>
EOF
```

Now generate the appcast:

```bash
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/hoomanaskari/mac-dictate-anywhere/releases/download/v2.1/" \
  --link "https://github.com/hoomanaskari/mac-dictate-anywhere" \
  -o appcast.xml \
  sparkle-releases/
```

This will:
- Read the DMG and extract version info from the app bundle
- Sign the DMG with your EdDSA private key from the Keychain
- Generate (or update) `appcast.xml` with a new `<item>` entry
- Create delta updates if previous versions exist in the directory

### Step 9: Verify the Appcast

Open `appcast.xml` and confirm it has a new `<item>` with:
- Correct `sparkle:version` and `sparkle:shortVersionString`
- A valid `sparkle:edSignature`
- The correct `url` pointing to your GitHub release download
- The correct `length` (file size in bytes)

You can also verify the signature manually:

```bash
"$SPARKLE_BIN/sign_update" --verify "dist/Dictate Anywhere.dmg" "SIGNATURE_FROM_APPCAST"
```

### Step 10: Commit and Push the Appcast

```bash
git add appcast.xml
git commit -m "Update appcast for v2.1"
git push
```

The `SUFeedURL` in Info.plist points to:
`https://raw.githubusercontent.com/hoomanaskari/mac-dictate-anywhere/main/appcast.xml`

So pushing to `main` makes the new version discoverable by Sparkle immediately.

### Step 11: Create the GitHub Release

1. Go to https://github.com/hoomanaskari/mac-dictate-anywhere/releases
2. Create a new release for tag `v2.1`
3. Upload `dist/Dictate Anywhere.dmg`
4. Add release notes
5. Publish the release

The DMG download URL in the appcast must match the GitHub release asset URL:
`https://github.com/hoomanaskari/mac-dictate-anywhere/releases/download/v2.1/Dictate%20Anywhere%202.1.dmg`

---

## Quick Reference

```bash
# Define Sparkle bin path
SPARKLE_BIN="$(xcodebuild -project 'Dictate Anywhere.xcodeproj' -scheme 'Dictate Anywhere' -showBuildSettings 2>/dev/null | grep -m1 BUILD_DIR | awk '{print $3}')"/../../SourcePackages/artifacts/sparkle/Sparkle/bin

# Full release sequence (after bumping version in Xcode):
VERSION="2.1"

xcodebuild -project "Dictate Anywhere.xcodeproj" -scheme "Dictate Anywhere" \
  -configuration Release -destination "generic/platform=macOS" \
  -archivePath "/tmp/DictateAnywhere.xcarchive" archive

mkdir -p dist
cp -R "/tmp/DictateAnywhere.xcarchive/Products/Applications/Dictate Anywhere.app" dist/

ditto -c -k --sequesterRsrc --keepParent "dist/Dictate Anywhere.app" "/tmp/DictateAnywhere-notarize.zip"
xcrun notarytool submit "/tmp/DictateAnywhere-notarize.zip" --keychain-profile "notarytool-profile" --wait
xcrun stapler staple "dist/Dictate Anywhere.app"

rm -f "dist/Dictate Anywhere.dmg"
create-dmg --volname "Dictate Anywhere" --window-pos 200 120 --window-size 600 400 \
  --icon-size 100 --icon "Dictate Anywhere.app" 150 185 --app-drop-link 450 185 \
  "dist/Dictate Anywhere.dmg" "dist/Dictate Anywhere.app"

xcrun notarytool submit "dist/Dictate Anywhere.dmg" --keychain-profile "notarytool-profile" --wait
xcrun stapler staple "dist/Dictate Anywhere.dmg"

mkdir -p sparkle-releases
cp "dist/Dictate Anywhere.dmg" "sparkle-releases/Dictate Anywhere ${VERSION}.dmg"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/hoomanaskari/mac-dictate-anywhere/releases/download/v${VERSION}/" \
  --link "https://github.com/hoomanaskari/mac-dictate-anywhere" \
  -o appcast.xml sparkle-releases/

git add appcast.xml && git commit -m "Update appcast for v${VERSION}" && git push
```

Then upload the DMG to the GitHub release for tag `v${VERSION}`.

---

## Version Numbering

- `v2.0` → `v2.0.1` for bug fixes
- `v2.0` → `v2.1` for new features
- `v2.0` → `v3.0` for major changes

---

## Troubleshooting

**"No EdDSA key found"**: Run `generate_keys` to create one, or import an existing key with `generate_keys -f private-key.pem`.

**Sparkle rejects the update**: Ensure `SUPublicEDKey` in Info.plist matches the key used to sign. Run `generate_keys -p` to print the public key.

**Update not appearing**: Check that `appcast.xml` is pushed to the `main` branch and the raw GitHub URL is accessible. Verify the `sparkle:version` in the appcast is higher than the version currently installed.

**Notarization fails**: Ensure Hardened Runtime is enabled and the app is signed with a Developer ID certificate (not just a development certificate).
