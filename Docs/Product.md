# Corres product specification

Status: foundation preview, September 17, 2026.

## Positioning

Corres. Email, considered. Know what needs you.

A premium executive communication layer for founders, operators, consultants, and client-facing professionals whose correspondence carries decisions, commitments, relationships, and money. A flagship alongside Artha under Anwar Creative Studio. The studio is the maker; Corres has its own product identity.

## Information hierarchy

1. Brief provides a grounded account of what needs attention.
2. Needs You collects explicit decisions, replies, confirmations, and commitments.
3. Waiting tracks an outstanding response from another person.
4. Mail remains a complete, predictable path to correspondence.

Read/unread and attention are separate concepts. Reading a message never means a commitment is complete. A conversation can always be reclassified. Future inferred states must expose evidence and allow correction. A generated summary must link to the source conversation and show freshness. Uncertainty must remain visible; no inference may hide ordinary mail.

## Foundation acceptance

Launch without credentials. Read the introduction and enter a clearly labeled sample space. Open every destination. Search by sender, subject, organization, or excerpt. Open a conversation and change its attention state. The destination lists and Brief counts update from one source of truth. Restore the previous state by selecting it again. Appearance persists between launches; sample changes do not. Failures never present a successful save. All actions remain on this device.

## Gmail-first V1, subsequent milestones

1. Verify native foundation: real simulator and device QA, VoiceOver, large text, contrast, transitions, performance, and final icon assets. App Icon, launch screen, and a WCAG contrast sweep done (2026-09-21); real simulator/device VoiceOver and max-Dynamic-Type QA still needed — this Mac's simulator has an unresolved crash (see Docs/Verification.md).
2. Implement protected local persistence with migrations, recovery tests, account isolation, and explicit sign-out purge. Base layer done (2026-09-21): SwiftData-backed repository, versioned migration plan, an explicit reset-to-clean-state action. Still open: on-disk file-protection verification, bounded caches, and real per-account purge once Gmail accounts exist.
3. Add a Gmail adapter and system-browser OAuth. Test revoked access, expired tokens, account switching, and cancellation. Sign-in done (2026-09-21) via GoogleSignIn-iOS, read-only scope, Preferences → Connect Gmail. Not yet done: the actual Gmail adapter/sync (real mail does not reach Needs You/Waiting/Brief yet), and the revoked/expired/switching/cancellation test pass.
4. Full and incremental sync, inbox and sent threads, reconciliation, retries, deletion, and stale-history recovery.
5. Durable drafts, safe compose/reply, attachments, and explicit sending. Never silently retry an ambiguous send.
6. Source-backed attention and Brief with clear processing controls. Cloud inference remains opt-in and separately reviewed.
7. Background updates, default mail entitlement application, TestFlight hardening, and App Store privacy review.

Mac follows iPhone quality and reliability. Outlook, iPad-specific layouts, and other providers follow later. Shared Swift domain code prepares for this without prematurely claiming support.

## Release gates

No public release until send reliability, offline consistency, HTML isolation, accessibility, account deletion, OAuth review, and privacy disclosures are verified. The current build has no final App Store icon, signing team, entitlement, billing, or production credentials. Prior pricing and domain/name research remain provisional business decisions, not implemented commitments or verified legal clearance.
