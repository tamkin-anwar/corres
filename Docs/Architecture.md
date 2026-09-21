# Architecture and decisions

## ADR 001: Native iPhone foundation

Accepted: SwiftUI, iOS 17 minimum, Swift 6 concurrency, no third-party runtime dependencies. Native NavigationStack and TabView provide navigation semantics, safe areas, and platform behavior. The product uses its own surfaces and typography while preserving native controls. Core also builds as a small Swift package for tests. The Xcode app compiles the same Core sources directly; there is one implementation, not two copies.

Tradeoff: iOS 17 support constrains newer visual APIs. Prefer stable primitives and feature-gated enhancements over raising the minimum OS just for decoration. macOS and iPad-specific navigation are deferred.

## ADR 002: Provider-independent domain

Accepted: value types are Codable, Hashable, and Sendable. Thread identity is the pair of account and provider thread ID. Gmail data transfer objects, OAuth, persistence details, and inference outputs must not appear in SwiftUI views. MailRepository is asynchronous and Sendable. Actor isolation serializes sample mutations. The main-actor observable store publishes UI state and applies changes only after repository acknowledgment.

Attention is not a provider label and not a read receipt. Needs You, Waiting, quiet, and handled are Corres states. V1 must preserve manual overrides with provenance and versioning; later incoming replies can suggest reopening a handled item, but must not silently rewrite a manual decision.

## ADR 003: Explicit preview boundary

Accepted: the composition root injects SampleMailRepository. It contains six fictional conversations, no credentials, no network code, and no durable mail cache. Sample attention changes are intentionally transient. Appearance and first-run preference are the only UserDefaults values. The privacy manifest declares that use. Production Gmail must be another implementation, not an accidental fallback from a failed sign-in to fabricated mail.

Sample reasons are editorial fixtures, not live classifications or generated summaries. Brief derives counts from repository state, using an explicit clock in Core. Due-in-24h excludes past deadlines and handled items. Overdue attention will receive its own treatment in the connected product.

## ADR 004: Local-first privacy boundary

Implemented (2026-09-21): `SwiftDataMailRepository` (`@ModelActor`, its own isolated `ModelContext` per the documented Swift 6 concurrency pattern: `ModelContainer` is Sendable, `ModelContext` and model objects are not) is the app's real repository, replacing the ephemeral `SampleMailRepository` at the composition root. `PersistedCorrespondence` is a separate `@Model` type; persistence details still never reach `Correspondence`, `MailStore`, or any view, matching ADR 002's boundary. A versioned schema (`CorresSchemaV1`) and an (currently empty-stages) `SchemaMigrationPlan` exist from the start, since retrofitting a migration plan after a real schema change has already shipped is the failure mode this exists to avoid. `MailStore.resetSampleData()` gives an explicit, user-triggered return to a clean state (Preferences → Reset Sample Data), today's stand-in for per-account deletion until real Gmail accounts exist to scope a purge to.

Not yet done: explicit on-disk file-protection class verification (iOS's sandbox default file protection applies automatically, but that has not been specifically checked against this store), bounded caches, and attachment handling (no attachments exist yet). Never put tokens or correspondence in UserDefaults, analytics, crash attachments, or application logs. Backup protection needs device verification before real mail is accepted.

Gmail OAuth (2026-09-21): `GoogleAuthService` (App layer) wraps GoogleSignIn-iOS, requesting `gmail.readonly` only. Corres cannot send, delete, or modify anything in a real mailbox yet, matching the V1 progression order. The session itself (access/refresh tokens) is never represented as a value in Corres's own code; it lives entirely in GoogleSignIn's own Keychain-backed store, which already meets the "tokens belong in Keychain, device-only accessibility" requirement without a second, parallel implementation to get right. `GmailAccount` (Core) carries only the signed-in email for UI purposes. Real Gmail data does not flow into `Correspondence`/`MailStore` yet; that is sync (ADR 005), the next milestone.

Gmail calls should run directly from device where possible. No Corres server should retain message bodies by default. A future push relay should carry minimal account routing and wake-up information, not readable correspondence. Do not claim end-to-end encrypted email: ordinary Gmail transport does not provide that property.

Cloud AI is a separate opt-in processing path with purpose, provider, retention, and revocation disclosure. Mail contents are untrusted data, never instructions authorizing tools or sending. Suggestions must link to source evidence. No autonomous sending, clicking, payment, or calendar changes based on mail content.

## ADR 005: Gmail sync and mutation reliability

First pass done (2026-09-21): `GmailAPIClient` (App layer) fetches the 25 most recent INBOX messages via `users.messages.list` + `users.messages.get?format=full`, parses headers/MIME body (depth-first search for the first `text/plain` part, falling back to the snippet), and maps to `Correspondence`. `GmailSyncService` orchestrates fetch → `MailRepository.upsert`, triggered after sign-in and on pull-to-refresh. This is intentionally not real sync yet: no pagination beyond 25, no history cursor, one-way only (no read/label writes back to Gmail). `upsert` only ever inserts threads not already present; a real message's content is immutable once received, so there is nothing to "update," and an existing thread's manual attention/pin/snooze is never touched regardless of what a later fetch of the same thread would say (ADR 002).

Still planned: a durable history cursor per account for true incremental sync, replacing this fixed-recent-window approach. Commit applied changes and cursor advancement atomically. An expired history cursor requires a controlled full resync rather than treating the mailbox as empty. Google documents incremental history and 404 recovery in its [sync guide](https://developers.google.com/workspace/gmail/api/guides/sync).

Use a durable outbox for mutations, explicit pending/failed states, bounded retries with jitter, and per-account serialization where ordering matters. Sending is a distinct operation: ambiguous network completion must be reconciled against provider state before another attempt. Do not assume arbitrary provider endpoints support idempotency keys. Preserve drafts through backgrounding and process termination.

Gmail scope selection and verification must be reviewed against the then-current [official scopes](https://developers.google.com/workspace/gmail/api/auth/scopes) and [Workspace data policy](https://developers.google.com/workspace/workspace-api-user-data-developer-policy). Device-first architecture is not a blanket exemption from Google's verification requirements.

## ADR 006: Safe rendering and accessibility

Accepted for sample bodies: plain native Text, no HTML or external resources.

Real mail (2026-09-21): `HTMLMessageBody` (WKWebView) renders a synced message's real HTML when present, plain Text fallback otherwise. Done: JavaScript is always disabled (`allowsContentJavaScript = false`); mail content is untrusted and never needs to execute code to display correctly; every link tap is intercepted and opened in the system browser rather than navigating inline, after validating the scheme is http/https (blocks a `javascript:` or arbitrary custom-scheme link from doing something unexpected on tap). Not yet done, a known and deliberate gap, not an oversight: remote images are not blocked by default, so a tracking pixel can still load when a real conversation is opened. Blocking that (a `WKContentRuleList` excluding `data:` URIs, which are inline/safe) is the next hardening pass before this is a real privacy guarantee rather than a partial one. Attachments are not handled at all yet (no attachments exist in the synced data).

Use semantic text styles, spoken control labels, minimum 44-point actions, a solid-surface fallback, and no color-only state. Custom navigation paths are decorative alongside native labels. Press motion respects [Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion). Real VoiceOver and large-text inspection are release gates, not claims inferred from compilation.

## Planned production data flow

SwiftUI features -> main-actor store -> repository -> protected local database.

Gmail sync actor -> validated provider adapter -> database transaction -> observable snapshot. Outbox -> provider -> acknowledgment/reconciliation -> local state. Optional intelligence -> explicit processing policy -> source-linked suggestions. Views never call the network directly.
