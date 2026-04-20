# Release Notes For Agents

- The DMG is the primary public release artifact for this project.
- If asked to publish or cut a release, do not publish anything unless the DMG has been notarized, stapled, and validated successfully.
- Always use `./scripts/release-macos.sh` for release packaging unless the user explicitly asks for a different flow.
- Treat the `.zip` as the Sparkle artifact. It matters less than the DMG for manual installs.
- Do not upload or publish a `.pkg` unless it has been separately signed, notarized, and verified.
- If DMG notarization, stapling, or validation fails, stop and do not publish the release.
