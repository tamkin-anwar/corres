# Corres

A premium, Apple-first intelligent email client, built with SwiftUI as a calmer, more considered alternative to Gmail's clutter and Apple Mail's thin triage tools.

**Email, considered.** Corres treats your inbox as a communication system, not a chronological pile: instead of asking "what emails did I receive," it answers "what actually requires my attention." Needs You, Waiting, and Brief are first-class concepts, ahead of the traditional folder/label model.

Built by Anwar Creative Studio.

## Features

**Understanding your inbox, not just listing it**
- Brief: a situational-awareness summary ("6 need you, 3 are waiting on others, 2 deadlines are approaching"), not a message count
- Needs You: decisions, invitations, and promises to keep
- Waiting: conversations where you've already acted and are now expecting a response — including automatically, the moment you reply or forward
- A searchable Mail view for everything, in its place

**Correspondence, not just messages**
- Compose, reply, reply all, and forward, with the reply/forward action itself moving a conversation to Waiting and recording the evidence ("You replied just now. Waiting for their response.")
- Swipe-to-triage: mark handled, snooze (later today / tomorrow morning / next week), pin, or flag as Needs You, without opening the thread
- Snoozed conversations disappear from their curated Needs You/Waiting queue and from Brief's counts until they resurface, but stay visible in Mail and in search — snoozing never makes a conversation unfindable
- Pinned conversations stay at the top regardless of recency
- Reversible attention changes with visible evidence — nothing is silently reclassified

**Foundation**
- Local-first persistence (SwiftData): attention, pins, and snoozes survive relaunch, with a versioned migration plan and an explicit Reset Sample Data action
- Sample mode with six fictional conversations; no account or credentials required to explore
- Light, dark, and system appearance, with accessibility (Dynamic Type, Reduce Motion, Increase Contrast) built in from the start
- An original vector correspondence mark and hand-shaded sculptural artwork, rendered natively at Retina scale, no raster upscaling

Gmail sync, durable local persistence, sending reliability, and the Brief/Ask Corres intelligence layer are the next milestones — see [Docs/Product.md](Docs/Product.md).

## Tech stack
- SwiftUI, iOS 17 minimum, Swift 6 strict concurrency
- A small Swift package (`CorresCore`) holding the provider-independent domain layer, testable on macOS without a simulator
- Native `NavigationStack`/`TabView`/`List`, no third-party runtime dependencies
- Swift Testing for the domain test suite

## Why Corres
Existing clients mostly answer "what emails did I receive." Corres is built to answer "what actually requires my attention" — fast like Gmail's delivery, calm and considered like Spark, native like Apple Mail, without adopting any of their weaknesses. See [Docs/Product.md](Docs/Product.md) for the full product specification and [Docs/Architecture.md](Docs/Architecture.md) for the engineering decisions behind it.

## Running locally
Open `Corres.xcodeproj` in Xcode 16 or later, select the **Corres** scheme and a simulator or your own iPhone, then Run. The minimum deployment target is iOS 17. No external packages or project generator installation is required.

For a physical device, select your development team in Signing & Capabilities. The bundle identifier `studio.anwarcreative.corres` is provisional and must be registered with the studio's Apple developer account before distribution.

```bash
xcodebuild -project Corres.xcodeproj -scheme Corres \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

If adding source files, regenerate the checked-in Xcode project with `python3 Scripts/generate_project.py`.

## Running tests
```bash
swift test
```
The Swift package tests the domain layer (`CorresCore`) on macOS, independent of the iPhone simulator.

## Docs
[Product specification](Docs/Product.md) · [Architecture decisions](Docs/Architecture.md) · [Design system](Docs/Design.md) · [Studio and reference review](Docs/Research.md) · [Verification record](Docs/Verification.md)
