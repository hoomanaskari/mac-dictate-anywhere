# Release Workflow

## 1. Build the App

1. Archive the app with `xcodebuild`:

```bash
xcodebuild \
  -project "Dictate Anywhere.xcodeproj" \
  -scheme "Dictate Anywhere" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "/tmp/DictateAnywhere.xcarchive" \
  archive
```

2. Create the DMG:

```bash
create-dmg \
  --volname "Dictate Anywhere" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Dictate Anywhere.app" 150 185 \
  --app-drop-link 450 185 \
  "dist/Dictate Anywhere.dmg" \
  "dist"
```

## 2. Commit Changes

```bash
git add .
git commit -m "Your changes description"
git push
```

## 3. Tag the New Version

```bash
git tag v1.1.0
git push origin v1.1.0
```

## 4. Upload the DMG

1. Go to https://github.com/hoomanaskari/mac-dictate-anywhere/releases
2. Edit the draft release created by the GitHub Action
3. Upload your DMG
4. Publish the release

## Version Numbering

- `v1.0.0` → `v1.0.1` for bug fixes
- `v1.0.0` → `v1.1.0` for new features
- `v1.0.0` → `v2.0.0` for breaking changes
