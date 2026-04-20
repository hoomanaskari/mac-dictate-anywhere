# Release Workflow

The supported public release artifacts are:

- `DictateAnywhere-<version>.zip` for Sparkle
- `DictateAnywhere-<version>.dmg` for manual downloads from GitHub

Do not upload a `.pkg` unless it has been separately signed, notarized, and verified.

## One-Time Setup

### 1. Install the signing certificates in the login keychain

This Mac must have:

- your own `Developer ID Application` certificate
- your own `Developer ID Installer` certificate only if you ever want to ship a `.pkg`

You can verify them with:

```bash
security find-identity -v -p basic
```

### 2. Store Apple notarization credentials

Create the notarization profile used by your local release script:

```bash
xcrun notarytool store-credentials "notarytool-profile"
```

Then verify it works:

```bash
xcrun notarytool history --keychain-profile "notarytool-profile"
```

### 3. Ensure Sparkle signing is available

- `SUPublicEDKey` must stay in `Dictate Anywhere/Info.plist`
- the private EdDSA key must be present in your keychain for `generate_appcast`

To import the private key on a new machine:

```bash
"$SPARKLE_BIN/generate_keys" -f private-eddsa-key.pem
```

### 4. Install local tooling

```bash
brew install create-dmg
```

### 5. Set your local signing team

Create `Config/Signing.local.xcconfig` on your machine:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

This file is ignored by Git.

## Release Steps

### 1. Bump the version

In Xcode, update:

- `MARKETING_VERSION` to the new public version
- `CURRENT_PROJECT_VERSION` to a higher build number

### 2. Commit and tag

```bash
VERSION="2.2.9"

git add .
git commit -m "Release v${VERSION}"
git tag "v${VERSION}"
git push
git push origin "refs/tags/v${VERSION}"
```

### 3. Build, notarize, and generate release artifacts

If you have not done it yet, create your local release script:

```bash
cp scripts/release-macos.template.sh scripts/release-macos.sh
chmod +x scripts/release-macos.sh
```

Then run it:

```bash
./scripts/release-macos.sh
```

It does all of this:

- archives the Release app
- verifies the Developer ID Application signature
- notarizes and staples the app
- creates `dist/DictateAnywhere-<version>.zip`
- creates `dist/DictateAnywhere-<version>.dmg`
- notarizes and staples the DMG
- regenerates `appcast.xml` from the notarized zip

### 4. Verify the outputs before upload

```bash
VERSION="2.2.9"

spctl -a -vv "dist/Dictate Anywhere.app"
xcrun stapler validate "dist/DictateAnywhere-${VERSION}.dmg"
```

Expected results:

- the app is accepted as `Notarized Developer ID`
- the DMG has a stapled ticket

### 5. Commit the updated appcast

```bash
git add appcast.xml sparkle-releases "sparkle-releases/DictateAnywhere-${VERSION}.md"
git commit -m "Update appcast for v${VERSION}"
git push
```

### 6. Upload the release assets to the GitHub draft release

```bash
gh release upload "v${VERSION}" \
  "dist/DictateAnywhere-${VERSION}.zip" \
  "dist/DictateAnywhere-${VERSION}.dmg"
```

### 7. Publish the draft release

Open the draft release on GitHub and publish it after confirming the `.zip` and `.dmg` are attached.

The appcast is served from:

`https://raw.githubusercontent.com/hoomanaskari/mac-dictate-anywhere/main/appcast.xml`

## Troubleshooting

**No EdDSA key found**: Run `"$SPARKLE_BIN/generate_keys"` to create one, or import with `generate_keys -f private-eddsa-key.pem`.

**Sparkle rejects the update**: Ensure `SUPublicEDKey` in `Dictate Anywhere/Info.plist` matches the key used to sign.

**`notarytool-profile` is missing**: Run `xcrun notarytool store-credentials "notarytool-profile"` and verify it with `xcrun notarytool history --keychain-profile "notarytool-profile"`.

**The DMG opens but Gatekeeper still warns**: Re-run `xcrun stapler validate dist/DictateAnywhere-<version>.dmg`. If validation fails, do not upload the DMG.

**Tag push fails with "matches more than one"**: Use `git push origin refs/tags/vX.Y.Z`.
