# Native design previews

These are native SwiftUI content renders at 3x, produced from the app's shared views. They are not iOS Simulator screenshots and omit system chrome. See [verification](../Verification.md) for limits.

- [Welcome, light](welcome-light.png)
- [Welcome, dark](welcome-dark.png)
- [Brief, light](brief-light.png)
- [Brief, dark](brief-dark.png)
- [Brief, narrow accessibility environment](brief-large-text.png)
- [Needs You](needs-you-light.png)
- [Waiting](waiting-light.png)
- [Sculpture, 3840 x 3840](sculpture-4k.png)

To regenerate on macOS from the project root:

```sh
swiftc -swift-version 6 -parse-as-library \
  Core/*.swift App/MailStore.swift DesignSystem/*.swift \
  Features/Destination.swift Features/BriefView.swift \
  Features/CorrespondenceList.swift Features/WelcomeView.swift \
  Scripts/RenderDesign.swift -o /tmp/corres-render
/tmp/corres-render "$PWD/Docs/Previews"
```
