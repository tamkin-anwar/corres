# Foundation verification

Final checks: September 18, 2026.

## Passed

- The native iOS application builds for arm64 iPhone Simulator with Xcode 27, Swift 6, iOS 17 minimum, and signing disabled. The final build ends with `BUILD SUCCEEDED`.
- Seven Swift Testing domain tests pass with zero failures: deadline boundaries; attention-derived Brief counts; combined search/filter behavior; account isolation; concurrent mutations; reversible state and session reset; Codable identity/date round-trip.
- Eight native SwiftUI images were rendered at 3x: welcome and Brief in light/dark, a 320-point-wide Brief with the accessibility environment enabled, Needs You, Waiting, and a 3840 x 3840 sculpture presentation.
- Custom navigation glyphs are converted into template UIImages for TabView compatibility. Standalone component previews retain the same custom paths.
- Foundation palette contrast calculations (not remeasured across the newer gradient surfaces): light primary/canvas 12.72:1; light secondary/canvas 5.13:1; dark primary/canvas 15.88:1; dark secondary/surface 8.50:1; hero secondary/lightest gradient 5.84:1; champagne/lightest gradient 4.65:1. These are token checks, not a full accessibility audit.
- Privacy manifest describes only app-owned UserDefaults use, no tracking, and no collected data in this sample build.

## Scope of the previews

The files in `Previews/` render actual shared SwiftUI content with the macOS ImageRenderer. They are not iOS Simulator captures. They omit the native navigation and tab bars, keyboard, and platform presentation. macOS font metrics and Dynamic Type behavior differ from iOS. The narrow accessibility-environment render confirms the mark-removal branch and content wrapping, not full iPhone accessibility sizing. The full scrollable content is laid out on a tall canvas for review.

## Environment limitations

The simulator service could not be used. Automatic approval review failed because of an account usage-limit error when simulator access was requested. Xcode independently reports CoreSimulator 1051.55.0 is older than its required build 1171.7.0, and a CoreDevice plug-in symbol mismatch. These are host-environment diagnostics. The generic simulator SDK still compiled and linked the application.

Swift compiler plug-ins could not start their nested sandbox inside the existing restricted environment. Local build checks used `OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox'`; package tests used SwiftPM's `--disable-sandbox`, temporary module-cache locations, and the same compiler flag. The outer execution environment remained restricted. These are local verification accommodations, not committed project build settings.

Xcode emits an AppIntents metadata warning because this app has no AppIntents dependency. No application source warnings were emitted in the final build; domain tests produced no source warnings.

## Still required before production use

- Launch and interact on a working iOS Simulator and physical iPhone.
- Check all tabs, navigation/back behavior, preferences persistence, search, empty states, and attention changes through the UI.
- Verify actual iOS Dynamic Type including maximum sizes, VoiceOver, Increase Contrast, Reduce Motion, keyboard, landscape, and safe areas.
- Profile launch, scrolling, memory, and energy on hardware.
- Add final app-icon asset catalog, signing identity, localization, and distribution configuration.
- Implement and verify persistence, authentication, synchronization, and send reliability before accepting real email.

This foundation is compiled and domain-tested. It is not yet an App Store-ready email client or a completed simulator QA pass.
