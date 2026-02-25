# Setapp Distribution Research for Dictate Anywhere

*Research date: February 25, 2026*

## Can Dictate Anywhere be submitted to Setapp?

**Yes.** The app is a strong candidate. It is a native macOS Swift/SwiftUI app that meets all known technical and content requirements.

## Can it remain open source on GitHub?

**Yes.** Setapp explicitly allows multi-channel distribution with no exclusivity requirements.

> "We never put any limitations on where and how you distribute your apps. Setapp is just another revenue source you can benefit from." — Setapp FAQ

**Precedent:** Open-source apps like [Numi](https://github.com/nikolaeu/numi) (MIT license, 6,300+ GitHub stars) are already distributed on Setapp while maintaining public GitHub repositories.

## Technical Requirements Checklist

| Requirement | Status | Notes |
|---|---|---|
| Native macOS app | PASS | Pure Swift/SwiftUI, Xcode project |
| Code signing (Developer ID) | Needs setup | Must be signed with a Developer ID certificate |
| Notarization | Needs setup | Must be notarized by Apple |
| Universal binary (arm64 + x86_64) | Needs verification | Ensure builds for both architectures |
| Latest macOS compatibility | PASS | Targets macOS 14.0+ |
| No in-app purchases | PASS | All features included |
| No advertising | PASS | No ads |
| Not a demo/trial version | PASS | Full-featured app |

## Integration Work Required

1. **Integrate the Setapp Framework** — Add [Setapp Framework](https://github.com/MacPaw/Setapp-framework) via SPM, CocoaPods, or Carthage. Initialize `SetappManager` at app launch.
2. **Create a `-setapp` bundle ID** — e.g., `com.pixelforty.dictate-anywhere-setapp`
3. **Disable Sparkle auto-updater** — Setapp handles updates; the existing `SoftwareUpdater.swift` must be conditionally disabled in the Setapp build.
4. **Remove/disable any licensing code** — Not applicable (app is currently free).
5. **Add Setapp public key** — Downloaded from your Setapp developer account, embedded in the app bundle.

Estimated effort: A few hours for a native macOS app.

## Revenue Model

| Aspect | Details |
|---|---|
| Base split | **70% to developer** / 30% to Setapp |
| Partner bonus | +20% if you bring users to Setapp (up to **90% total**) |
| Calculation | Per-user, per-billing-cycle, proportional to app usage and price tier |
| Average customer lifetime | 24 months |
| No fees to join | No upfront costs |
| Minimum commitment | 1-year term |

**Price tiers:** Since Dictate Anywhere is currently free, you would need to establish a list price outside of Setapp (e.g., on your website, ~$15-30 one-time) to determine your price tier multiplier.

**How it works:** The fewer apps a user uses, the bigger your share. If a user only uses your app, you get the full 70% of their subscription fee.

## How to Submit

1. **Contact Setapp** — Email developers@setapp.com or use [setapp.com/developers](https://setapp.com/developers)
2. **Onboarding** — Receive access to a Setapp developer account
3. **Integration** — Integrate Setapp Framework, set up bundle ID, disable Sparkle
4. **Review** — Setapp reviews for quality, functionality, security, and compliance
5. **Launch** — Published in the Setapp catalog (~30,000 unique impressions in first days)

## Considerations

- **~600MB model download on first launch:** Document this for Setapp reviewers. Not prohibited, but they will want to understand the behavior.
- **Accessibility & Microphone permissions:** Legitimate for the app's functionality; should pass review with clear explanations.
- **MIT license compatibility:** MIT allows commercial distribution and sublicensing without restriction. Fully compatible with Setapp distribution.
- **Dual distribution:** The Setapp build (with framework + separate bundle ID) and the open-source GitHub version can coexist without conflict.

## Sources

- [Setapp Developer Portal](https://setapp.com/developers)
- [Setapp Technical Requirements](https://docs.setapp.com/docs/preparing-your-application-for-setapp)
- [Setapp Revenue Distribution](https://docs.setapp.com/docs/distributing-revenue)
- [Setapp FAQ](https://docs.setapp.com/docs/faq)
- [Setapp Integration Requirements](https://docs.setapp.com/docs/integration-requirements)
- [Setapp Framework on GitHub](https://github.com/MacPaw/Setapp-framework)
- [Setapp Submission/Review](https://docs.setapp.com/docs/submitting-apps-for-review)
- [Setapp Distribution Models](https://docs.setapp.com/docs/distribution-models-overview)
