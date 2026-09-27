# Corres visual system: Obsidian and Ivory

Adopted September 27, 2026, replacing the earlier porcelain, champagne and sculpture system. Earlier directions (Paper & Seal, Jewel & Glass, the first Obsidian pass) are kept as reference boards in the "Corres Redesign Direction" design canvas.

## Principles

Quiet luxury: restraint over decoration. One accent. Serif only for display. Depth comes from light and hairlines, not bevels or ornaments. The interface is typography-led; content sits on opaque surfaces, and glass is reserved for controls that float above it, the way iOS itself uses it. Dimensional finish (brushed metal) appears only in the app mark and the one primary button per screen.

"Clear and 4K" means every visual is vector or a color: SF Symbols, SwiftUI paths, asset-catalog colors. Hairlines are exactly one physical pixel (`1 / displayScale`). Nothing is rasterized with `drawingGroup`. The app icon is rendered from the same vector view the app draws (`Scripts/RenderIcon.swift`), never upscaled.

## Themes

Both themes follow the iPhone's appearance by default; Settings can pin one.

| Token (asset colour) | Ivory (light) | Obsidian (dark) |
| --- | --- | --- |
| `canvas` | #F6F3EC | #0A0A0C |
| `surface` | #FFFFFF | #141417 |
| `surfaceRaised` | #FBF9F4 | #1C1C20 |
| `ink` | #141312 | #F2F3F5 |
| `secondary` | #5E5A54 | #A1A3AA |
| `tertiary` | #6F6A63 | #8A8C93 |
| `line` | ink at 10% | white at 9% |
| `corresAccent` (sapphire) | #2F5D9E | #8FB4E8 |
| `accentInk` (on accent) | #FFFFFF | #0E1116 |
| `avatarFill` | #EDE9E1 | #1E1F23 |

Flag is #C2410C in both themes (5.18:1 on white). Swipe tints are fixed darks at 4.5:1 or better against their white icons.

## Type

New York (system serif) for display: large titles (set natively via `UINavigationBar` large-title attributes), the Brief greeting and sentence, conversation subjects, the wordmark. SF Pro for everything you read in lists or act on. Section eyebrows are small tracked uppercase (`eyebrow()`). All sizes are Dynamic Type text styles.

## Components

- **Surface:** opaque `surface`, 22pt continuous corners, one-pixel `line`, a soft long shadow (stronger on Obsidian).
- **Primary button:** brushed titanium on Obsidian, polished ink on Ivory (`CorresButtonStyle`, `CorresMetalCapsuleStyle`). At most one per screen.
- **Glass:** `corresGlass(in:)` uses Liquid Glass on iOS 26 and a material with a hairline before that, or an opaque raised surface under Reduce Transparency. Used for the conversation action bar, reply chips, and banners.
- **Rows:** unread dot, round monogram, sender and time, subject, preview. In Needs You and Waiting, a sapphire reason line: a sparkle means Apple Intelligence decided, an arrow means a rule did. Plus a due chip. No disclosure chevrons.
- **Account button:** the Google profile photo in its own circle, never inside another control's glass; a two-letter monogram when there's no photo.

## Mark and icon

A titanium outer C holding a sapphire inner C and a single point: an exchange with room left for the other person. It is drawn with SwiftUI `Canvas` paths and gradients. On the icon it fills about two-thirds of the tile, is optically centered (shifted right, because an open C reads left-heavy), and sits on an obsidian field with a cool top light and a faint sapphire bloom.

## Motion and accessibility

Motion is limited to short press responses, sheet and banner transitions, and content fades. No ambient loops or count-ups. Reduce Motion removes movement but keeps state changes. Increase Contrast thickens hairlines. Reduce Transparency replaces glass with opaque surfaces. Every custom control has a label; rows combine into one VoiceOver element, with unread as its value.

## Before calling a screen finished

Check it in both themes, at normal and accessibility text sizes, with VoiceOver, on real mail with long subjects and HTML newsletters, and on a physical iPhone.
