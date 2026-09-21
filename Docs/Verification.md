# Foundation verification

Final checks: September 18, 2026. Batch 1 App Store readiness sweep: September 21, 2026.

## Batch 1 sweep (September 21, 2026)

- Added the real App Icon: a flattened, alpha-free 1024x1024 PNG (`App/Assets.xcassets/AppIcon.appiconset`) built from the existing approved sculpture render (`Docs/Previews/sculpture-4k.png`), verified `hasAlpha: no` via `sips` — App Store rejects any icon with an alpha channel. Also added an `AccentColor` set and a `LaunchBackground` color set (light/dark) wired through a small merged `App/Info.plist` (`UILaunchScreen.UIColorName`), replacing the default blank-white launch screen.
- WCAG contrast audit of every color used as a *fixed white-foreground* background (swipe actions, button fills) — not the same check as the existing porcelain/ink text-contrast table below, which only covers text-on-canvas pairs. Found and fixed three real failures: `CorresPalette.accent` and `.secondary` are adaptive (they flip to light tones in dark mode for text-on-canvas use) but iOS swipe-action buttons always render white icons regardless of appearance, so using them as swipe tints put white-on-near-white in dark mode (Handled 1.6:1, Snooze 1.84:1, both against a 3:1 minimum for UI components). `champagne` failed in both appearances (1.71:1). Replaced with three new fixed, non-adaptive tokens (`swipeHandled` 0x2D5A70, `swipeSnooze` 0x4A5560, `swipePin` 0x8A6A3E) verified at 4.99-7.61:1 against white. `midnight` (used for the Needs You swipe action) was already fixed and safe at 14.26:1.
- Removed `role: .destructive` from the "Handled" swipe button — marking a conversation handled is not a delete action, and the role affects VoiceOver's announcement.
- Added missing/incorrect accessibility labels: the "Due soon" clock glyph and "Pinned" pin glyph on list rows had no label (would read as bare SF Symbol names or nothing); hid two purely decorative icons (the Brief card's sun glyph, the privacy section's lock glyph) that duplicated adjacent text.
- Fixed the welcome screen's "corres" wordmark from a hard-coded `size: 54` font (ignored Dynamic Type entirely) to a relative `.largeTitle` style, capped at `.xxxLarge` so accessibility text sizes don't break the fixed-width hero layout.
- Fixed the nav bar's icon+wordmark: the system's automatic toolbar layout was compressing "corres" down to a single truncated letter (fixed with `fixedSize()`), and the flat (non-sculpted) mark rendered both arcs in one flat color, reading as a generic sync icon rather than a brand mark — given the gold/silver two-tone the sculpture uses.
- Fixed real, reproduced on-device scroll jank: `CorrespondentAvatar` and `corresSurface()` each layered 2-3 uncached shadow/gradient passes recomputed every scroll frame; added `.drawingGroup()` to rasterize both once.
## Follow-up sweep (same day)

The Preferences theme fix above was necessary but not sufficient — a second, separate cause was
found: `.preferredColorScheme()` applied at the WindowGroup root does not reliably re-trait a
`.sheet()`/`.fullScreenCover()` that is already on screen when the value changes mid-presentation.
Applied the scheme directly on each independently-presented surface's own content
(PreferencesView, ComposeView, WelcomeView), each reading `@AppStorage("corres.appearance")`
itself rather than depending on inherited environment propagation across a presentation boundary.

Requested full sweep for the same class of bug turned up three more real issues, all fixed with
new domain test coverage:

- `MailQuery.filter` unconditionally hid snoozed threads everywhere, including the Mail tab (whose
  own subtitle promises "every conversation, in its place") and from search results — a snoozed
  thread became genuinely unfindable until it expired. Snooze now only hides a thread from its
  curated attention queue (Needs You/Waiting); it stays visible in Mail and in any active search.
- `ComposeView`'s discard-confirmation used "is anything non-empty" as its check, which is always
  true for a reply/forward (pre-filled quote) and always false for new — so canceling a forward
  never asked for confirmation even with real added content, while `.interactiveDismissDisabled`
  still blocked the swipe gesture in the same case (an inconsistent, self-contradicting state). Now
  compares the current draft against its own pre-filled starting point.
- Outbound recipient/subject were stored with untrimmed whitespace if typed with leading/trailing
  spaces; trimmed at the repository's actual commit point.

These fixes were verified by physical-device testing (Tamkin's iPhone) and code-level audit. The iOS Simulator on this Mac crashes on every Corres launch with an identical `MTLSimCommandQueue`/XPC signature both before and after a full Mac restart — see `corres-simulator-environment` — so VoiceOver rotor testing, Dynamic Type at maximum accessibility sizes, and Reduce Motion/Increase Contrast still need a real run-through, either on physical device or once the simulator issue clears.

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
