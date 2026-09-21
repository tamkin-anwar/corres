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

Planned, not implemented: protected local database behind a repository, versioned migrations, bounded caches, and per-account deletion. Tokens belong in Keychain with device-only accessibility selected after a background-refresh threat review. Never put tokens or correspondence in UserDefaults, analytics, crash attachments, or application logs. Database, attachment, and backup protection need device verification before real mail is accepted.

Gmail calls should run directly from device where possible. No Corres server should retain message bodies by default. A future push relay should carry minimal account routing and wake-up information, not readable correspondence. Do not claim end-to-end encrypted email: ordinary Gmail transport does not provide that property.

Cloud AI is a separate opt-in processing path with purpose, provider, retention, and revocation disclosure. Mail contents are untrusted data, never instructions authorizing tools or sending. Suggestions must link to source evidence. No autonomous sending, clicking, payment, or calendar changes based on mail content.

## ADR 005: Gmail sync and mutation reliability

Planned: initial paginated sync, then a durable history cursor per account. Commit applied changes and cursor advancement atomically. An expired history cursor requires a controlled full resync rather than treating the mailbox as empty. Google documents incremental history and 404 recovery in its [sync guide](https://developers.google.com/workspace/gmail/api/guides/sync).

Use a durable outbox for mutations, explicit pending/failed states, bounded retries with jitter, and per-account serialization where ordering matters. Sending is a distinct operation: ambiguous network completion must be reconciled against provider state before another attempt. Do not assume arbitrary provider endpoints support idempotency keys. Preserve drafts through backgrounding and process termination.

Gmail scope selection and verification must be reviewed against the then-current [official scopes](https://developers.google.com/workspace/gmail/api/auth/scopes) and [Workspace data policy](https://developers.google.com/workspace/workspace-api-user-data-developer-policy). Device-first architecture is not a blanket exemption from Google's verification requirements.

## ADR 006: Safe rendering and accessibility

Accepted for this shell: plain native Text for sample bodies, no HTML or external resources. Planned for real mail: sanitize HTML, disable scripts, block remote images by default, isolate web content, validate URL schemes, and handle attachments as untrusted files. A tracking pixel must not load because a conversation was selected.

Use semantic text styles, spoken control labels, minimum 44-point actions, a solid-surface fallback, and no color-only state. Custom navigation paths are decorative alongside native labels. Press motion respects [Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion). Real VoiceOver and large-text inspection are release gates, not claims inferred from compilation.

## Planned production data flow

SwiftUI features -> main-actor store -> repository -> protected local database.

Gmail sync actor -> validated provider adapter -> database transaction -> observable snapshot. Outbox -> provider -> acknowledgment/reconciliation -> local state. Optional intelligence -> explicit processing policy -> source-linked suggestions. Views never call the network directly.
