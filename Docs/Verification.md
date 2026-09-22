# Foundation verification

Final checks: September 18, 2026. Batch 1 App Store readiness sweep: September 21, 2026.

## Batch 13: header-alignment bug and the real cause of the lag (September 21, 2026)

- Reported directly on-device: the Mail screen's title block floating centered above a flush-left list, looking incoherent. Traced to a real, systemic bug present in all four places the app caps content at a 680pt reading width on wide screens: `.frame(maxWidth: 680).frame(maxWidth: .infinity)`, in that order, caps a box that's still only as wide as its own left-aligned text content, then centers that narrow box in whatever space remains via `.frame(maxWidth: .infinity)`'s own default center alignment, since capping first never made the box actually expand to fill available width. The list below looked flush-left only because `List` rows aren't subject to this pattern at all. Fixed by reversing the order and adding explicit leading alignment to the expanding frame: `.frame(maxWidth: .infinity, alignment: .leading).frame(maxWidth: 680)` expands to fill available width first (left-aligned), then caps that already-full-width box at 680pt, correctly centering the whole reading column only on screens wide enough for the cap to matter. All four occurrences fixed (`BriefView`, both `CorrespondenceList` content paths, `ConversationView`).
- The real, dominant cause of "incredibly laggy": `GmailAPIClient.fetchMessages` was fetching each message one at a time, sequentially awaited, not a SwiftUI rendering problem at all. A full sync can mean a couple hundred individual `users.messages.get` calls (two labels x up to 200 each after Batch 11's Sent-sync); at one real network round trip after another, this could plausibly take tens of seconds to complete, during which pull-to-refresh stays spinning and (depending on how often background sync runs) the app has real ongoing network/CPU work competing with whatever the person is actually trying to do. Replaced with a bounded-concurrency `TaskGroup` (8 concurrent fetches, not unbounded, to stay reasonable against Gmail's per-user rate limits), which should turn a largely-sequential wait into something close to a factor-of-8 wall-clock improvement for network-latency-bound work. Verified the pool logic itself with a standalone 237-item simulation: every id fetched exactly once, no duplicates, no drops, before touching the real network client.
- Considered, not adopted: Gmail's batch HTTP endpoint (bundling up to 100 calls into one multipart/mixed request) would reduce round trips further, but needs manual multipart response parsing with no first-party Swift support and its current recommendation status for new integrations wasn't conclusively confirmed by research. The bounded-`TaskGroup` fix already captures the large majority of the win at much lower implementation risk; left as a documented option, not pursued now.
- Verified with `xcodebuild` (`BUILD SUCCEEDED`) and `swift test` (28/28 passed, no Core changes this batch, the concurrency fix is App-layer network code not covered by the domain test suite). Not yet verified on-device: whether a real sync actually feels meaningfully faster, and whether the header alignment looks right in practice.

## Batch 12: three real on-device bugs (September 21, 2026)

Reported directly from on-device testing after Batches 1-5: sample/fictional mail still mixed into a connected Gmail account's real Brief/Needs You/Waiting counts and rows, with stale copy still claiming "no account connected"; a conversation-header avatar visibly overflowing/clipping its own rounded-rect background; and the app feeling "incredibly laggy," most noticeable on the conversation screen.

- **Sample/real data mixing.** `seedIfNeeded` seeds fictional sample threads on first launch, before any Gmail account connects; nothing ever removed them once a real account did connect, so they kept counting toward Needs You/Waiting and showing in Mail alongside real synced mail indefinitely, and Brief's "SAMPLE" badge and "Fictional mail. No account connected." caption stayed hardcoded regardless of connection state. Added `MailRepository.deleteSampleData()` (removes only `account == "sample"` threads, real mail untouched; domain-tested in both repositories: seeds sample data, upserts one real thread, deletes sample data, confirms only the real thread survives). Called once from Preferences' Connect Gmail action and once from `CorresApp`'s launch task (covers relaunching while already connected). Brief and Mail's header copy now read `auth?.account` instead of unconditionally claiming disconnected/fictional.
- **Avatar overflow.** `CorrespondentAvatar`'s body ended with its own internal `.frame(width: 44, height: 48)`; `ConversationView`'s header tried to shrink it by wrapping the view in an external `.frame(width: 34, height: 34)` instead. Confirmed via research this doesn't work in SwiftUI: an external `.frame()` only changes the layout box a view is given, it never rescales a view's own already-fixed internal content, so the 44x48 content kept rendering at its own size and visibly overflowed/clipped against the smaller declared box, exactly the artifact reported. Fixed by giving `CorrespondentAvatar` a `size: CGSize` parameter that drives its own internal frame and corner radius, and updating the one caller that wanted a smaller size to pass it in rather than override afterward.
- **Performance.** Confirmed via research that `NSRegularExpression(pattern:)` compilation is real, non-trivial work relative to matching, and doing it inside a computed property referenced directly in a SwiftUI `body` means recompiling on every re-render, which can fire many times per second during ordinary state changes elsewhere in an `@Observable` store the view reads. `HTMLMessageBody`'s remote-image-blocking regex was being recompiled on every call from two places, including `remoteImageCount`, called directly from `ConversationView`'s body. Now compiled once as a `static let`. Also fixed `HTMLMessageBody.updateUIView` doing the same underlying issue at a higher level: it was recomputing the full regex-based HTML rewrite and comparing against the *processed* output to decide whether to reload the WKWebView, meaning the expensive rewrite always ran first, before the cheap check that would have skipped it; now compares the cheap raw inputs (`html`, `blockRemoteImages`) first, and only touches the regex at all when one of them actually changed.
- Verified with `xcodebuild` (`BUILD SUCCEEDED`) and `swift test` (28/28 passed, 2 new tests). Not yet verified on-device: whether the lag is actually gone, and whether the avatar and sample-data fixes look right in practice.

## Batch 11: sent-thread sync and cursor-ordering review (September 21, 2026)

- Both the full listing (`fetchInitialInbox`) and incremental (`fetchIncremental`) sync paths now query `INBOX` and `SENT` separately and merge the results, since Gmail's `labelIds`/`labelId` filters are AND-scoped (multiple values narrow, they don't broaden), so there is no single-call way to ask for "either label." Closes a real gap: a thread that exists only in Sent (started by you, no inbound reply synced yet) was previously invisible to Corres entirely.
- Verified the numeric-vs-lexicographic `historyId` comparison (`GmailAPIClient.newerHistoryId`, used to reconcile the two label queries' returned cursors) with a standalone six-case script: `nil`/`nil`, one side `nil`, and same-magnitude and different-magnitude pairs, specifically covering the case a naive string comparison gets wrong ("99" vs "100", where "99" > "100" lexicographically but must lose numerically). All six passed.
- Reviewed, not changed: whether the history cursor write and the local upsert could be made transactionally atomic. Concluded no, deliberately: true atomicity needs the cursor moved into the SwiftData schema, reversing ADR 005's own choice to keep Gmail sync mechanics out of Core; the actual risk the current cursor-after-upsert ordering already avoids is real data loss (a crash between a cursor-first write and the upsert would silently skip re-fetching those messages forever), and the residual risk of the current ordering (a crash between upsert and the cursor write) is only redundant re-fetching, which `upsert` already treats as a no-op. Documented the reasoning in `Docs/Architecture.md` ADR 005 so this isn't silently re-litigated later without knowing why it's this way.
- Named, not fixed, a known limitation found while reasoning through sent-mail sync: a thread is one `Correspondence` per Gmail thread id, so a reply to a Corres-composed new message does not update that thread's content or attention when it actually arrives; the local placeholder `OutboxService` created stays as first written. Real fix needs either a smarter enrichment path for a placeholder record or a per-message (not per-thread) data model, both larger than this batch.
- Verified with `xcodebuild` (`BUILD SUCCEEDED`) and `swift test` (26/26 passed, no Core changes this batch). Not yet verified on-device: confirming a real Sent-only thread actually appears after a sync.

## Batch 10: durable outbox (September 21, 2026)

- Closed the outbox's last honestly-documented gap: a queued or failed send now survives the app being force-quit. `MailRepository` gained `outboxEntries`/`saveOutboxEntry`/`removeOutboxEntry`, backed by a new `PersistedOutboxEntry` SwiftData model (Draft stored as one JSON column, not several, since nothing queries by draft content at the persistence layer). `OutboxService.queueSend` persists a `.pending` record before the undo-window timer starts; `resumeAfterRelaunch()`, called once from `CorresApp`'s launch task, finishes sending anything still `.pending` (the app died before the window closed or was cancelled, so there is nothing left to offer undo for) and restores anything `.failed` so its Retry/Discard banner reappears.
- Found and fixed a real pre-existing bug while rewriting this, not part of the original ask: queueing a second send while a first was still mid-undo-window only cancelled the first's timer, which made it return without ever calling `commit`, silently dropping the first draft, contradicting the code's own comment claiming it "commits immediately." `OutboxService` now actually commits the superseded draft for real when this happens.
- Domain-tested (new `SwiftDataMailRepositoryTests` case): saves an `OutboxRecord`, opens a fresh repository instance on the same container (simulating relaunch), confirms it's still there with the right status and draft content, confirms re-saving the same id updates in place rather than duplicating, confirms removal actually removes it. All 26 domain tests pass (25 prior + 1 new).
- Verified with `xcodebuild` (`BUILD SUCCEEDED`) and `swift test` (26/26 passed). Not yet verified on-device: actually force-quitting the app mid-undo-window on a real send and confirming it resumes and sends correctly on next launch.

## Batch 9: brand-new compose now really sends (September 21, 2026)

- Closed the last "still local-only" gap from Batch 5: starting a new message from scratch (not a reply) now sends via `users.messages.send` whenever an account is connected, the same as replying/replying all/forwarding already did. `GmailAPIClient.send` now returns the real Gmail thread id the send response reports (a freshly assigned one, since there was no existing thread to join), which `OutboxService` uses to file the local record under `ThreadID(account: <real account>, providerID: <Gmail's real id>)` instead of a synthesized local UUID, via a new `realThreadID` parameter added to `MailStore.send`/`MailRepository.send`. A later sync of that same thread now recognizes it as already-known instead of duplicating it.
- Domain-tested: a new `CorresCoreTests` case sends a draft with an explicit `realThreadID` and confirms the created `Correspondence` is filed under exactly that id, not an invented one. All 25 domain tests pass (24 prior + 1 new); updated 6 existing test call sites for the new `MailRepository.send` parameter.
- Verified with `xcodebuild` (`BUILD SUCCEEDED`) and `swift test` (25/25 passed). Not yet verified on-device: sending a genuinely new message to a real address and confirming it both appears correctly in Gmail's Sent folder and reconciles (no duplicate) on the next sync.

## Batch 8: the Screener (September 21, 2026)

- New `SenderDecision` (`pending`/`approved`/`blocked`) stamped on `Correspondence` at insert time in `MailRepository.upsert`, sourced from any existing thread of that sender rather than a separate registry, and persisted through SwiftData (`PersistedCorrespondence.senderDecisionRaw`). Domain-tested (3 new tests, `CorresCoreTests.swift`, `SampleMailRepository`): an initial-sync insert auto-approves and is immediately visible in ordinary browsing; an incremental-sync insert from a never-seen sender is held `.pending`, excluded from ordinary browsing, but still found by an explicit search; approving or blocking cascades to every thread from that sender at once. All 24 domain tests pass (21 prior + 3 new).
- `GmailSyncService.fetch` now reports whether a sync used a full listing (first-ever sync, or any resync forced by an expired history cursor) versus an ordinary incremental one, and passes that through as `isInitialSync` to `upsert`, so reconnecting after a cursor expiry never re-quarantines an already-known sender.
- `ScreenerView` (new): groups pending threads by sender, one row per sender with Approve/Block, footer copy explaining the mechanic and that neither action touches the real Gmail account. `BriefView` gained a "New Senders" entry card, shown only when at least one sender is pending, matching Spark's placement of the same concept at the top of the inbox.
- Verified with `xcodebuild` (`BUILD SUCCEEDED`) and `swift test` (24/24 passed). Not yet verified: on-device confirmation that a real second, genuinely-new sender actually lands in the Screener after the account's baseline sync (needs a live test message from an address never emailed before, not yet attempted).

## Batch 7: real research grounding the product thesis (September 21, 2026)

Not a code change: revised `Docs/Product.md`'s Positioning section after researching what actually made Superhuman, HEY, and Shortwave category leaders (their own documentation and 2026 reviews, not assumption), into three named pillars (evidence over inference, recipient-controlled not sender-controlled, funded by the person not their data) and an explicit AI stance (Shortwave's draft/review boundary, not Superhuman's unsupervised-autonomy one). See `Docs/Product.md` for the full revision and sourcing; ADR 007 (Screener) and the AI-drafted-reply feature both trace directly back to this.

## Batch 6: conversation reading redesign, grounded in Mail/Spark (September 21, 2026)

Prompted by a direct on-device comparison against iOS Mail (screenshots of the same real HTML email open in both apps): the conversation screen was rebuilt against Mail's structure specifically, not redesigned from guesswork.

- Real root cause of the image/text clipping visible in that comparison: the HTML body was wrapped in a `corresSurface()` card with 24pt of padding plus a border. Real marketing HTML is a fixed-width table (Jomashop's is ~600pt); shrinking the available width below that makes the table clip instead of scale, which is what the cut-off address/footer text in the screenshots actually was, not a WKWebView or image-loading bug. Fixed by rendering the body edge to edge (no card, no border, no padding) exactly as Mail does, inside the same 680pt max-width column the rest of the app already uses on wide screens.
- Replaced the stacked avatar/name/organization/date header with one compact row (avatar, name, organization, time) plus a single evidence caption underneath, matching how Mail packs sender/to/time into one line above the body instead of a multi-line block.
- Removed the standalone "Keep it in the right place" card (four full-width buttons) from the scrolling body entirely. Mark-as/Pin/Snooze moved into menus in a new icon-only bottom action bar (Mark as, Pin, Snooze, Reply, Reply All, Forward, each a 44pt tap target with a VoiceOver label), matching Mail's compact icon toolbar instead of a full-width labeled button bar. All three attention-setting actions remain reachable a second way too, via the existing swipe actions on the Mail list, so nothing became harder to reach.
- Added message-to-message paging (chevron-up/chevron-down in the nav bar), matching Mail's in-pane next/previous. Introduced `ConversationRoute` (a `ThreadID` plus the ordered id list it was opened from) so paging stays inside whatever list the person actually tapped from, Brief's top-3, a filtered Mail view, or a search result, rather than jumping into an unrelated global order.
- Verified with `xcodebuild` (`BUILD SUCCEEDED`) after each step; the offline `Scripts/RenderDesign.swift` preview renderer was not used for this batch since it cannot render `List` or a real `WKWebView`, which is most of what changed. Still needs actual on-device visual confirmation (this Mac's simulator remains broken; see "Environment limitations" below) before this is verified rather than just compiled.

## Batch 6 follow-up: fixed the real cause of the broken email layout (September 21, 2026)

On-device testing of Batch 6 (same-day) surfaced a second, more serious layout bug in the same HTML email: giant, cut-off headline text and large empty gaps between sections, not present in iOS Mail's rendering of the identical message. The edge-to-edge fix above was necessary but not the real problem; the actual cause was `HTMLMessageBody`'s own `table { max-width: 100% !important; }` / `img { max-width: 100%; height: auto; }` CSS, present since the original build. That rule shrinks a table's outer width to fit the viewport while leaving the email's own explicit font sizes and inner column widths untouched, breaking their proportions relative to each other, exactly the giant/misaligned text observed.

Fixed by removing those overrides entirely and switching to the technique real mail/browser clients use for non-mobile-responsive content ("desktop site" viewport handling, as Safari does for pages that assume a fixed desktop width): the viewport meta tag changed from `width=device-width` to a generous fixed `width=1024`, letting the email lay out at (or near) its own natural width without forced reflow; `HTMLMessageBody.Coordinator.didFinish` then measures the actual rendered `document.body.scrollWidth`/`scrollHeight` via JS and applies a single uniform shrink (`UIScrollView.zoomScale`, never scaling a narrower-than-device email up) so every element's size stays correct relative to every other one, matching Mail's own behavior. Confirmed this specific "shrink-to-fit" viewport flag is known-unreliable in WKWebView since iOS 9.3, which is why the fix computes and applies the scale explicitly rather than trusting the browser to do it implicitly. Verified with `xcodebuild` (`BUILD SUCCEEDED`); still needs on-device confirmation against the same Jomashop email that surfaced it.

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
  match), uppercase `<IMG SRC=...>` (case-insensitive), and non-image HTML (no match); all passed.

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
