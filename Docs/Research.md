# Studio and visual-reference review

Reviewed September 17, 2026. The earlier Corres conversation was read directly, including the established positioning. All 10 attached CleanMyMac screenshots were retrieved and visually inspected. Synced project sources and existing repositories were left unchanged.

## Current studio evidence

GitHub authenticated profile confirmed `tamkin-anwar`. Live repository metadata was inspected for [Artha](https://github.com/tamkin-anwar/artha), [Doorsong](https://github.com/tamkin-anwar/doorsong), and the [studio portfolio](https://github.com/tamkin-anwar/anwar-creative-studio-portfolio). Local checkouts were read for their detailed implementation. This was a representative review, not a full audit of every repository.

| Project | Evidence inspected | Lesson for Corres |
| --- | --- | --- |
| Artha | README, message domain model, portfolio description; live repo updated September 17 | Practical privacy, explicit approval for consequential AI actions, provider-independent stored content, concrete README claims |
| Jotfield | README, cloud contracts, motion module | Versioned interfaces, local-first boundaries, original iconography, reduced-motion branch |
| Doorsong | README and live repo metadata | Original craft supported by real implementation, a specific interaction identity |
| Studio portfolio | README, theme.css, projects.ts; live repo metadata | Semantic color/type/spacing tokens, editorial typography, quiet warm highlights, motion preferences |

The portfolio's current source also lists Tether and Stub. It describes Tether as synchronized shared viewing and Stub as collaborative film/TV lists. Those applications were not deeply audited. Existing studio projects primarily use web stacks; this review did not find an established SwiftUI architecture to inherit. Corres therefore establishes a native foundation while carrying forward the studio's product principles.

README convention: product purpose first, concrete functionality, technical shape, local running instructions, studio credit. Corres uses that voice and distinguishes implemented capabilities from future work.

## All 10 visual references

The initial previews were 2048 x 1330; the later supplied originals are 3024 x 1964. Their purpose is a finish benchmark. No screenshot pixels or CleanMyMac assets are included in the app.

| Screenshot time | Content | Quality principle extracted |
| --- | --- | --- |
| 5:09:43 PM | My Activity | Consistent panel edges, quiet metric hierarchy, meaningful depth |
| 5:09:33 PM | My Tools | Reusable card proportions and disciplined internal spacing |
| 5:09:25 PM | Cloud Cleanup | Sculpted focal asset, legible supporting actions |
| 5:09:18 PM | Space Lens | Tactile icon with coherent highlights and shadows |
| 5:09:06 PM | My Clutter | Materials feel unified across icon and supporting surface |
| 5:08:55 PM | Applications completion | Clear completion state and a dominant result |
| 5:08:48 PM | Performance | Strong silhouette readable at small and large sizes |
| 5:08:39 PM | Protection | Consistent light direction and layered icon construction |
| 5:08:27 PM | Cleanup results | Text explains outcomes instead of relying on illustrations |
| 5:08:10 PM | Smart Care | Summary organizes detail into a comprehensible next step |

Corres deliberately develops a different palette, silhouette, mark, navigation, and editorial hierarchy. The reference's saturated full-window colors, utility badge shapes, and scan-button composition are not part of Corres. Static screenshots cannot establish their animation behavior, so motion choices here are original.

## Primary technical references

- [Apple NavigationStack](https://developer.apple.com/documentation/swiftui/navigationstack): native navigation model.
- [Apple Reduce Motion environment](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion): user preference for motion.
- [Google Gmail synchronization](https://developers.google.com/workspace/gmail/api/guides/sync): full and incremental history, recovery.
- [Google Workspace user data policy](https://developers.google.com/workspace/workspace-api-user-data-developer-policy): future processing and verification requirements.

The earlier chat's model comparisons, competitor pricing, domain availability, and trademark claims were not treated as verified facts or architectural requirements.

## September 18 material refinement

- [Apple materials](https://developer.apple.com/design/human-interface-guidelines/materials) informs the separation of rich content surfaces from system navigation materials. Conversation cards remain opaque and readable.
- [SwiftUI Canvas](https://developer.apple.com/documentation/swiftui/canvas) supports the original decorative sculpture. It is hidden from accessibility and hit testing; controls remain semantic SwiftUI views.
- [SwiftUI shadow styles](https://developer.apple.com/documentation/swiftui/shadowstyle) supports the inset edges and shallow contact shadows.
- [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) informs cached geometry and lazy conversation lists. These choices still require device profiling.

The original champagne and titanium opposing forms use authored geometry with static lighting. Interface tessellation is separate from the denser 3840-pixel presentation export. No third-party rendering dependencies or copied artwork are included. Native typography and controls remain separate from decorative rendering. Brief summary cards now navigate to their respective conversations.
