# Foundation verification

Final checks: September 18, 2026. Batch 1 App Store readiness sweep: September 21, 2026.

## Batch 6: conversation reading redesign, grounded in Mail/Spark (September 21, 2026)

Prompted by a direct on-device comparison against iOS Mail (screenshots of the same real HTML email open in both apps): the conversation screen was rebuilt against Mail's structure specifically, not redesigned from guesswork.

- Real root cause of the image/text clipping visible in that comparison: the HTML body was wrapped in a `corresSurface()` card with 24pt of padding plus a border. Real marketing HTML is a fixed-width table (Jomashop's is ~600pt); shrinking the available width below that makes the table clip instead of scale, which is what the cut-off address/footer text in the screenshots actually was, not a WKWebView or image-loading bug. Fixed by rendering the body edge to edge (no card, no border, no padding) exactly as Mail does, inside the same 680pt max-width column the rest of the app already uses on wide screens.
- Replaced the stacked avatar/name/organization/date header with one compact row (avatar, name, organization, time) plus a single evidence caption underneath, matching how Mail packs sender/to/time into one line above the body instead of a multi-line block.
- Removed the standalone "Keep it in the right place" card (four full-width buttons) from the scrolling body entirely. Mark-as/Pin/Snooze moved into menus in a new icon-only bottom action bar (Mark as, Pin, Snooze, Reply, Reply All, Forward, each a 44pt tap target with a VoiceOver label), matching Mail's compact icon toolbar instead of a full-width labeled button bar. All three attention-setting actions remain reachable a second way too, via the existing swipe actions on the Mail list, so nothing became harder to reach.
- Added message-to-message paging (chevron-up/chevron-down in the nav bar), matching Mail's in-pane next/previous. Introduced `ConversationRoute` (a `ThreadID` plus the ordered id list it was opened from) so paging stays inside whatever list the person actually tapped from, Brief's top-3, a filtered Mail view, or a search result, rather than jumping into an unrelated global order.
- Verified with `xcodebuild` (`BUILD SUCCEEDED`) after each step; the offline `Scripts/RenderDesign.swift` preview renderer was not used for this batch since it cannot render `List` or a real `WKWebView`, which is most of what changed. Still needs actual on-device visual confirmation (this Mac's simulator remains broken; see "Environment limitations" below) before this is verified rather than just compiled.

## Batch 5: real Gmail sending (September 21, 2026)

- Replying, replying all, and forwarding within an existing, real synced thread now send for real via `users.messages.send`, instead of staying purely local-only (which a brand-new from-scratch compose still is, honestly, not yet in scope). Widened the OAuth scope from `gmail.readonly` alone to also request `gmail.send`; both are Google's "sensitive" tier (standard consent-screen review, not the CASA-audited "restricted" tier), verified against Google's own scope documentation and OAuth verification guidance. `GoogleAuthService.ensureSendScope()` requests the additional scope incrementally for an account connected before this shipped, rather than requiring a disconnect/reconnect.
- Correct Gmail threading requires the request's `threadId`, `In-Reply-To`/`References` headers matching the parent message's real `Message-ID`, and a matching `Subject`, confirmed against Gmail's own send/threading documentation. `Correspondence` gained `messageIdHeader` (the parent's real `Message-ID`, captured from sync) and `senderEmail` (the sender's actual address; `sender` alone is a display name and not a safe "To" value for a reply) to make this possible; both persist through SwiftData.
- `GmailMessageComposer` builds the raw RFC 5322 message and base64url-encodes it per the API's `raw` field contract. Verified with a standalone round-trip script: composed a reply (decoded output showed correct From/To/Subject/In-Reply-To/References headers and body) and a new message with a non-ASCII subject (decoded output showed correct RFC 2047 `=?UTF-8?B?...?=` encoding); both passed.
- `OutboxService` makes Send feel instant: the compose sheet dismisses the moment Send is tapped (the "premium, has to feel fast" bar this batch was explicitly asked to hit, researched against Superhuman's own public optimistic-UI/undo-send design writeups), and the real work happens after a short undo window shown in a banner. The Gmail call happens before any local state change, not after, so a real failure (network down, scope denied, etc.) surfaces as a Retry/Discard banner rather than a thread silently claiming a message went out that never did.
- Known, deliberately scoped gaps, not oversights: a brand-new compose (no reply-to thread) is still local-only; no attachments; the outbox is in-memory only and does not survive a force-quit during the undo window (a true durable, restart-recovering outbox is still planned per ADR 005); cursor/local-write atomicity for sync remains open from Batch 4.

## Batch 4: incremental sync and default image blocking (September 21, 2026)

- Replaced the fixed 25-message sync window with Gmail's History API. The first sync per account
  (or any sync after a stored cursor 404s as expired, which Gmail does to history IDs older than
  about a week) does a paginated full listing, capped at 200 messages (two pages of 100), and reads
  the account's current `historyId` from `users.getProfile`. Every sync after that calls
  `users.history.list?startHistoryId=...&historyTypes=messageAdded&labelId=INBOX`, fetching only
  messages added since the stored cursor, and advances the cursor to the response's own
  `historyId`. The cursor lives in `UserDefaults`, keyed by account email, in `GmailSyncService`,
  not in the SwiftData schema: it is a Gmail-specific sync detail, and ADR 002 keeps provider
  specifics out of the Core domain layer. Disconnecting an account or using Preferences' "Reset
  Sample Data" (which deletes every persisted thread, real synced mail included) both clear the
  cursor; without that, a reset would leave Mail silently empty of real mail until new mail arrived,
  since an incremental sync would find nothing new to fetch for messages it had already "seen"
  before the reset. Verified with `swift build` on the actual list/history/profile query
  construction and a manual read of Gmail's documented History API pagination and 404-on-expired
  behavior; not yet verified against a real inbox old enough to force the expired-cursor path.
- Default-blocked remote `<img src="http(s)://...">` tags in HTML mail (ADR 006's tracking-pixel
  requirement, deliberately deferred in Batch 3 to get images working at all first). Each matching
  `src` is rewritten to an inline 1x1 transparent GIF `data:` URI before the HTML ever reaches
  WKWebView, so no network request happens until the user taps "Show Images" on a banner that
  reports how many were blocked. Scoped narrowly to `<img src>` (not CSS `background-image`), which
  covers real-world tracking pixels with far less false-positive risk than rewriting arbitrary
  inline styles. `cid:`-referenced images are unaffected: GmailAPIClient already inlines those as
  `data:` URIs before this code runs, and the blocking regex only matches `http`/`https` sources.
  Verified with a standalone six-case Swift script covering plain remote `<img>`, single-quoted
  attributes, additional attributes before/after `src`, an already-inlined `data:` image (must not
  match), uppercase `<IMG SRC=...>` (case-insensitive), and non-image HTML (no match) — all passed.

## Batch 1 sweep (September 21, 2026)

- Added the real App Icon: a flattened, alpha-free 1024x1024 PNG (`App/Assets.xcassets/AppIcon.appiconset`) built from the existing approved sculpture render (`Docs/Previews/sculpture-4k.png`), verified `hasAlpha: no` via `sips` (App Store rejects any icon with an alpha channel). Also added an `AccentColor` set and a `LaunchBackground` color set (light/dark) wired through a small merged `App/Info.plist` (`UILaunchScreen.UIColorName`), replacing the default blank-white launch screen.
- WCAG contrast audit of every color used as a *fixed white-foreground* background (swipe actions, button fills), not the same check as the existing porcelain/ink text-contrast table below, which only covers text-on-canvas pairs. Found and fixed three real failures: `CorresPalette.accent` and `.secondary` are adaptive (they flip to light tones in dark mode for text-on-canvas use) but iOS swipe-action buttons always render white icons regardless of appearance, so using them as swipe tints put white-on-near-white in dark mode (Handled 1.6:1, Snooze 1.84:1, both against a 3:1 minimum for UI components). `champagne` failed in both appearances (1.71:1). Replaced with three new fixed, non-adaptive tokens (`swipeHandled` 0x2D5A70, `swipeSnooze` 0x4A5560, `swipePin` 0x8A6A3E) verified at 4.99-7.61:1 against white. `midnight` (used for the Needs You swipe action) was already fixed and safe at 14.26:1.
- Removed `role: .destructive` from the "Handled" swipe button: marking a conversation handled is not a delete action, and the role affects VoiceOver's announcement.
- Added missing/incorrect accessibility labels: the "Due soon" clock glyph and "Pinned" pin glyph on list rows had no label (would read as bare SF Symbol names or nothing); hid two purely decorative icons (the Brief card's sun glyph, the privacy section's lock glyph) that duplicated adjacent text.
- Fixed the welcome screen's "corres" wordmark from a hard-coded `size: 54` font (ignored Dynamic Type entirely) to a relative `.largeTitle` style, capped at `.xxxLarge` so accessibility text sizes don't break the fixed-width hero layout.
- Fixed the nav bar's icon+wordmark: the system's automatic toolbar layout was compressing "corres" down to a single truncated letter (fixed with `fixedSize()`), and the flat (non-sculpted) mark rendered both arcs in one flat color, reading as a generic sync icon rather than a brand mark, given the gold/silver two-tone the sculpture uses.
- Fixed real, reproduced on-device scroll jank: `CorrespondentAvatar` and `corresSurface()` each layered 2-3 uncached shadow/gradient passes recomputed every scroll frame; added `.drawingGroup()` to rasterize both once.
## Follow-up sweep (same day)

The Preferences theme fix above was necessary but not sufficient. A second, separate cause was
found: `.preferredColorScheme()` applied at the WindowGroup root does not reliably re-trait a
`.sheet()`/`.fullScreenCover()` that is already on screen when the value changes mid-presentation.
Applied the scheme directly on each independently-presented surface's own content
(PreferencesView, ComposeView, WelcomeView), each reading `@AppStorage("corres.appearance")`
itself rather than depending on inherited environment propagation across a presentation boundary.

Requested full sweep for the same class of bug turned up three more real issues, all fixed with
new domain test coverage:

- `MailQuery.filter` unconditionally hid snoozed threads everywhere, including the Mail tab (whose
  own subtitle promises "every conversation, in its place") and from search results: a snoozed
  thread became genuinely unfindable until it expired. Snooze now only hides a thread from its
  curated attention queue (Needs You/Waiting); it stays visible in Mail and in any active search.
- `ComposeView`'s discard-confirmation used "is anything non-empty" as its check, which is always
  true for a reply/forward (pre-filled quote) and always false for new, so canceling a forward
  never asked for confirmation even with real added content, while `.interactiveDismissDisabled`
  still blocked the swipe gesture in the same case (an inconsistent, self-contradicting state). Now
  compares the current draft against its own pre-filled starting point.
- Outbound recipient/subject were stored with untrimmed whitespace if typed with leading/trailing
  spaces; trimmed at the repository's actual commit point.

These fixes were verified by physical-device testing (Tamkin's iPhone) and code-level audit. The iOS Simulator on this Mac crashes on every Corres launch with an identical `MTLSimCommandQueue`/XPC signature both before and after a full Mac restart (see `corres-simulator-environment`), so VoiceOver rotor testing, Dynamic Type at maximum accessibility sizes, and Reduce Motion/Increase Contrast still need a real run-through, either on physical device or once the simulator issue clears.

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
