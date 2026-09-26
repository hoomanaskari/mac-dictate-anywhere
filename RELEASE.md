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

### 2. Prepare and verify the candidate

Add release notes at `sparkle-releases/DictateAnywhere-<version>.md`, run the test suite, and review all changes included in the release. Do not expose a new appcast until its downloads are public.

### 3. Build, notarize, and generate release artifacts

If you have not done it yet, create your local release script:

```bash
cp scripts/release-macos.template.sh scripts/release-macos.sh
chmod +x scripts/release-macos.sh
```

If `scripts/release-macos.sh` already exists, compare its archive command with
the current template before packaging. The script is ignored and does not
update automatically; it must pass `DISTRIBUTION_BUILD` to default performance
tracing off in the distributed app. Local Release benchmarks remain traced.

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
VERSION="2.11.0"

spctl -a -vv "dist/Dictate Anywhere.app"
xcrun stapler validate "dist/DictateAnywhere-${VERSION}.dmg"
```

Expected results:

- the app is accepted as `Notarized Developer ID`
- the DMG has a stapled ticket

### 5. Commit and tag the verified artifacts and source

After all artifact checks pass, review the staged source, release notes, and generated appcast. Do not commit DMG, ZIP, or delta binaries. Then commit and tag the release locally:

```bash
VERSION="2.11.0"

git commit -m "Release v${VERSION}"
git tag "v${VERSION}"
git push origin "refs/tags/v${VERSION}"
```

### 6. Publish and verify the release assets

Create the GitHub release from the tag with the notarized DMG, Sparkle ZIP, and every delta referenced by the new appcast item. Use the versioned release notes. Verify that the release is public and each referenced asset is reachable and matches the local artifact.

### 7. Expose the update feed

Only after asset verification succeeds, push `main`:

```bash
git push origin main
```

Verify the public appcast against the local file, including version/build, download links, Sparkle signatures, and deltas. Verify tag and main agree with the intended source commit.

The appcast is served from:

`https://raw.githubusercontent.com/hoomanaskari/mac-dictate-anywhere/main/appcast.xml`

## Troubleshooting

**No EdDSA key found**: Run `"$SPARKLE_BIN/generate_keys"` to create one, or import with `generate_keys -f private-eddsa-key.pem`.

**Sparkle rejects the update**: Ensure `SUPublicEDKey` in `Dictate Anywhere/Info.plist` matches the key used to sign.

**`notarytool-profile` is missing**: Run `xcrun notarytool store-credentials "notarytool-profile"` and verify it with `xcrun notarytool history --keychain-profile "notarytool-profile"`.

**The DMG opens but Gatekeeper still warns**: Re-run `xcrun stapler validate dist/DictateAnywhere-<version>.dmg`. If validation fails, do not upload the DMG.

**Tag push fails with "matches more than one"**: Use `git push origin refs/tags/vX.Y.Z`.
