# Corres product specification

Status: foundation preview, September 17, 2026.

## Positioning

Corres. Email, considered. Know what needs you.

A premium executive communication layer for founders, operators, consultants, and client-facing professionals whose correspondence carries decisions, commitments, relationships, and money. A flagship alongside Artha under Anwar Creative Studio. The studio is the maker; Corres has its own product identity.

Revised 2026-09-21, after studying what actually made Superhuman, HEY, and Shortwave category leaders rather than guessing: none of them win by matching Gmail's feature list. Superhuman wins on obsessive, sub-100ms-feeling craft and a subscription-funded, no-free-tier stance, paid for a 1-on-1 concierge onboarding that solves its own steep learning curve rather than a mass self-serve funnel. HEY wins by inverting who controls the inbox: instead of "anyone can reach you, you sort it out after," HEY's Screener makes a sender earn entry before their mail ever reaches you, and blocks tracking pixels by default (Corres already does the latter; the former, gating first-time senders, is the next real differentiator to build, not a copy of HEY's UI but the same underlying instinct already applied consistently: attention is earned and evidenced, never assumed). Shortwave wins by using AI to triage and draft, never to decide or send unsupervised, exactly the boundary this document already drew in ADR 004 before this revision, now made a named pillar instead of a footnote.

Three pillars, each already load-bearing in the codebase, not aspirational:

1. **Evidence over inference.** Every state Corres shows (Needs You, Waiting, a future bundled sender group, a future AI-drafted reply) carries a visible, human-readable reason, never an opaque score, and nothing sends or reclassifies without the person's own review and approval (see `OutboxService`'s undo window and Retry/Discard-on-failure, and Attention's `reason` field, both already built this way).
2. **Recipient-controlled, not sender-controlled.** The instinct already shipped for remote images (blocked by default, revealed on request) generalizes to who reaches a person's attention at all: earning entry should be the default, not a settings toggle buried after the fact.
3. **Funded by the person using it, not by their data.** No ads, no data-broker relationship, ever; a subscription funds the product, stated as plainly as Superhuman and HEY both do, because it is the only business model compatible with pillar 1. Not yet implemented (no billing exists); stated now so later monetization decisions get measured against it rather than drifting.

AI is explicitly part of this, not opposed to it. The boundary ADR 004 already accepted is deliberately the Shortwave-not-Superhuman line: draft, bundle, and summarize, always reviewed and approved by the person before anything sends or gets acted on, never autonomous, always disclosed (purpose, provider, retention, revocation) and opt-in. Superhuman's own numbers make the distinction concrete: their Auto Drafts get sent unedited 60% of the time, which is real, useful autonomy for Superhuman's positioning and a real mismatch for Corres's "decisions and approvals stay in your hands" promise (already public, on the portfolio site). An AI-drafted reply belongs inside the same confirm/undo step every other send already goes through, not a shortcut around it.

## Information hierarchy

1. Brief provides a grounded account of what needs attention.
2. Needs You collects explicit decisions, replies, confirmations, and commitments.
3. Waiting tracks an outstanding response from another person.
4. Mail remains a complete, predictable path to correspondence.

Read/unread and attention are separate concepts. Reading a message never means a commitment is complete. A conversation can always be reclassified. Future inferred states must expose evidence and allow correction. A generated summary must link to the source conversation and show freshness. Uncertainty must remain visible; no inference may hide ordinary mail.

## Foundation acceptance

Launch without credentials. Read the introduction and enter a clearly labeled sample space. Open every destination. Search by sender, subject, organization, or excerpt. Open a conversation and change its attention state. The destination lists and Brief counts update from one source of truth. Restore the previous state by selecting it again. Appearance persists between launches; sample changes do not. Failures never present a successful save. All actions remain on this device.

## Gmail-first V1, subsequent milestones

1. Verify native foundation: real simulator and device QA, VoiceOver, large text, contrast, transitions, performance, and final icon assets. App Icon, launch screen, and a WCAG contrast sweep done (2026-09-21); real simulator/device VoiceOver and max-Dynamic-Type QA still needed; this Mac's simulator has an unresolved crash (see Docs/Verification.md).
2. Implement protected local persistence with migrations, recovery tests, account isolation, and explicit sign-out purge. Base layer done (2026-09-21): SwiftData-backed repository, versioned migration plan, an explicit reset-to-clean-state action. Still open: on-disk file-protection verification, bounded caches, and real per-account purge once Gmail accounts exist.
3. Add a Gmail adapter and system-browser OAuth. Test revoked access, expired tokens, account switching, and cancellation. Sign-in and a first sync pass done (2026-09-21) via GoogleSignIn-iOS, read-only scope, Preferences → Connect Gmail (adapter itself tracked under item 4). Not yet done: the revoked-access/expired-token/account-switching/cancellation test pass.
4. Full and incremental sync, inbox and sent threads, reconciliation, retries, deletion, and stale-history recovery. Incremental sync done (2026-09-21): a `historyId` cursor per account, capped full listing on first sync or an expired cursor, real sender/subject/body. Still open: sent-thread sync, reconciliation/retry beyond a single fetch attempt, and cursor advancement is not yet atomic with the local write it follows. See ADR 005.
5. Durable drafts, safe compose/reply, attachments, and explicit sending. Never silently retry an ambiguous send. Real sending done (2026-09-21) for replying/replying all/forwarding within an existing synced thread: a proper RFC 5322 message via `users.messages.send`, correct Gmail threading (`threadId` + In-Reply-To/References + matching Subject), and an instant-feeling optimistic send with an undo window and a Retry/Discard path on real failure (see ADR 005, `OutboxService`). Still open: a brand-new from-scratch compose stays local-only; attachments; and the outbox is in-memory, not durable across a force-quit mid-send.
6. Source-backed attention and Brief with clear processing controls. Cloud inference remains opt-in and separately reviewed.
7. Background updates, default mail entitlement application, TestFlight hardening, and App Store privacy review.

Mac follows iPhone quality and reliability. Outlook, iPad-specific layouts, and other providers follow later. Shared Swift domain code prepares for this without prematurely claiming support.

## Release gates

No public release until send reliability, offline consistency, HTML isolation, accessibility, account deletion, OAuth review, and privacy disclosures are verified. The current build has no final App Store icon, signing team, entitlement, billing, or production credentials. Prior pricing and domain/name research remain provisional business decisions, not implemented commitments or verified legal clearance.
