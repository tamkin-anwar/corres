# Corres visual system

## Required finish, reaffirmed September 18, 2026

The user's ten CleanMyMac references set the visual quality standard for Corres. "Clear and 4K" means exceptionally sharp text and edges, dimensional custom artwork, convincing material thickness, coherent lighting, controlled reflections, soft contact shadows, and readable layered surfaces. A larger screenshot or a simple gradient does not by itself meet this standard. The initial shell establishes structure; its current artwork is not the final quality benchmark.

The original references are retained read-only in `/Users/tamkinanwar/Documents/GitHub/Anwar Creative Studio/Inspiration/Design Language/CleanMyMac Design/`. The latest attachments are 3024 x 1964 originals; the earlier conversation supplied smaller previews. Use original files for close inspection. Preserve Corres's own identity and composition.

The user authorizes any suitable language or library needed to achieve this finish. Keep native Apple-first behavior. SwiftUI remains the shell; choose additional rendering technology or authored 3D assets when a concrete visual requirement justifies them. The current stack is not a visual ceiling. Record dependencies, licensing, performance costs, and fallback behavior before adoption.

Acceptance requires:

- Native text and vector controls that remain sharp at device scale.
- Sculpted focal artwork with consistent light direction, bevels, highlights, material depth, and clean silhouettes at small sizes.
- Raster artwork exported for its actual display size at 2x/3x, without enlargement from insufficient source resolution; 4K presentation exports rendered from appropriate masters.
- Material depth visible without sacrificing text contrast, calm hierarchy, or touch-target clarity.
- Inspection at 100 percent resolution in light and dark appearances, followed by simulator and physical-device checks.
- Motion that preserves clarity, respects accessibility settings, and is profiled on target hardware. Static reference images do not establish an animation specification.

Do not call visual parity achieved based solely on compilation, vector use, export dimensions, or component renders.

## Direction: considered correspondence

Warm porcelain, deep ink, a champagne edge, and editorial serif headlines. Depth comes from restrained lighting and material boundaries. The two opposing open arcs form a correspondence mark: sender and recipient with space between them. No envelope app mark, mascot, sparkle, or decorative AI orb.

The native vector artwork scales to Retina and high-resolution presentation without enlarged bitmap edges. This is the concrete interpretation of the requested high-definition finish, not a claim that an iPhone screen has a 4K layout.

## Tokens

| Role | Light | Dark |
| --- | --- | --- |
| Canvas | #F4F2ED | #10171C |
| Raised surface | #FFFEFA | #1A252D |
| Primary text | #192D39 | #F3F0E8 |
| Secondary text | #5B6870 | #B6C1C7 |
| Accent | #274D61 | #B4D1DF |
| Separator | #DADDD9 | #394750 |

Champagne #D7C4A0 belongs on dark hero surfaces as an occasional highlight. Never use it for small text on porcelain. Standard spacing is 8, 16, 24, and 32 points. Cards use a 26-point continuous visual rhythm; the Brief hero uses 30. Readable content caps at 680 points. Fixed heights are reserved for controls and decorative artwork, not body copy.

Large titles and section headings use the system serif design. Functional text uses native semantic styles and Dynamic Type. Monospaced captions distinguish dates and quiet metadata. Custom paths serve the four navigation destinations; standard platform actions use SF Symbols.

## Material hierarchy

1. Canvas: matte porcelain or midnight, no continuous animation.
2. Conversation: opaque raised surface with a fine edge and shallow shadow.
3. Brief: deep ink with a single directional light, a champagne label, and a sculpted vector mark.
4. Navigation and sheets: native system materials and behavior.

Motion is reserved for a short 160 ms press response. No ambient loops, shimmering mail rows, count-up animations, or attention-seeking badges. Reduced Motion removes scale changes. Increased Contrast strengthens card borders. Reduced Transparency removes decorative card shadow treatment; primary content already uses opaque backgrounds.

## Inspection required before calling the design finished

Check compact iPhone portrait and landscape, normal and accessibility text sizes, light/dark, increased contrast, Reduce Motion, VoiceOver focus order, search presentation, keyboard dismissal, tab labels, and long real-world subjects. Capture native simulator screenshots at device resolution, then inspect on hardware. Verify body contrast numerically and visually. Native app icon and App Store exports are a separate final asset task.

## Implemented material pass

The welcome and Brief screens now use an original pair of champagne-metal and titanium open forms. Cached geometry and directional lighting are rendered with SwiftUI Canvas, with no continuous animation. A separate export-quality mesh produces the 3840 x 3840 presentation master. The app uses a smaller mesh; device rendering cost remains to be measured.

Inset edges, soft contact shadows, custom destination badges, and raised correspondent initials connect the focal artwork to the functional interface. Brief count cards are navigation actions. Conversation lists retain lazy row creation. Native text remains independent of the artwork and wraps vertically in the introduction.
