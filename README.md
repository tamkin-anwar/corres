# Corres

A premium, Apple-first email client for iPhone, built in SwiftUI. **Email, considered.**

Most mail apps answer "what did I receive?" Corres answers "what needs me?" Brief, Needs You and Waiting come first; every message is still in one chronological Mail list, and nothing is sorted out of reach.

Built by Anwar Creative Studio.

## What it does

**Attention first**
- **Brief:** a one-sentence summary built from the same counts and reasons the lists show, then the top Needs You conversations, who you're waiting on, and new senders to approve.
- **Needs You:** conversations that ask something of you, each with a one-line reason. It's grouped into Due soon and When you can. Press and hold any conversation to move it if Corres got it wrong.
- **Waiting:** conversations you replied to or moved there, with how long you've been waiting, counted from your reply.
- **Mail:** every account in one inbox, newest first, with Everything / Unread / People / Flagged / Updates views. Scrolling pages in older mail.
- **Screener:** mail from a new sender waits for Allow or Block before it reaches the other lists.

**A full Gmail client**
- Multiple Gmail accounts, merged or one at a time.
- Whole conversations: earlier messages appear as compact rows above the latest one, open in place, and long threads fold in the middle.
- Read, reply, reply all, forward and compose, with attachments and a short undo-send window.
- Undo after Archive or Trash: the conversation leaves instantly, and Gmail is told only after the 5-second window.
- Archive and Mark as Read right from a notification; notifications are grouped per conversation.
- Apple Mail's keyboard shortcuts on iPad and hardware keyboards (⌘R, ⌘⇧R, ⌘⇧F, ⌃⌘A, ⌘⌫, ⌘⇧L, ⌘⇧U, ⌃⌘S, ⌃⌘↑/↓), plus haptics that confirm sends, removals, snoozes and flags.
- Archive, trash, mark read or unread, flag (Gmail star) and labels, all applied in Gmail. Changes made in Gmail or iOS Mail flow back.
- Fast metadata-first sync in batches, push notifications through a content-free relay (`Server/push-relay`), and Gmail search beyond what's synced.
- Needs You and Waiting widgets for the Home Screen and Lock Screen, opening straight into a conversation; Siri, Shortcuts and Spotlight actions ("What needs me in Corres", open a list, new message).
- Saved snippets with `{first name}`, and dictation in Compose, transcribed on the iPhone.
- Snooze by typing a time ("in 3 days at 9am", "next friday") or picking a preset; custom short and long swipes.

**Intelligence, on this iPhone only**
- Rules sort first; Apple Intelligence (Foundation Models) refines Needs You on-device.
- A short summary of long emails. For very long ones it covers the opening and ending, and says so.
- Suggested reply directions that draft a full reply in your voice, for you to edit and send.
- Shorter / Warmer / More formal / Proofread rewrites of your own writing, with Undo.
- There's no cloud fallback. On iPhones without Apple Intelligence these features don't appear.

**Private by design**
- Sign-in is with Google directly. Corres stores only a revocable token, in the Keychain.
- Remote images and tracking pixels are blocked until you choose to show them. Read receipts are never sent.
- No advertising or analytics code. Removing an account removes its mail from the device.

## Scopes

`gmail.readonly`, `gmail.send`, `gmail.modify`. `gmail.send` is a Google "sensitive" scope; `gmail.readonly` and `gmail.modify` are "restricted", so a public release needs Google's OAuth verification plus an annual CASA security assessment. See ADR 005 in [Docs/Architecture.md](Docs/Architecture.md).

## Tech stack
- SwiftUI, iOS 17 minimum (Liquid Glass and Foundation Models features on iOS 26), Swift 6 strict concurrency.
- `CorresCore`: a Swift package holding the provider-independent domain and persistence layer (SwiftData), tested on macOS.
- One dependency: [GoogleSignIn-iOS](https://github.com/google/GoogleSignIn-iOS), for OAuth.
- Swift Testing for the domain suite.

## Running locally
Open `Corres.xcodeproj` in Xcode, select the **Corres** scheme and a simulator or your iPhone, then Run. For a device, set your team in Signing & Capabilities. Without a Gmail account, Corres opens with fictional sample mail.

```bash
xcodebuild -scheme Corres -destination 'generic/platform=iOS Simulator' build
```

The checked-in `Corres.xcodeproj` is the source of truth (it carries entitlements, the widget extension and embed phases that `Scripts/generate_project.py` predates, so don't regenerate from that script). Add new files through Xcode. The app icon and launch mark are rendered from the vector mark by `Scripts/RenderIcon.swift`.

## Running tests
```bash
swift test --build-path /tmp/corres-swift-build
```
The separate build path avoids a code-signing quirk when the repository lives in a synced folder.

## Docs
[Product specification](Docs/Product.md) · [Architecture decisions](Docs/Architecture.md) · [Design system](Docs/Design.md) · [Research](Docs/Research.md) · [Verification record](Docs/Verification.md)
