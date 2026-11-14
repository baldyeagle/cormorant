# Brand assets

- `cormorant-head-source.png` — original artwork, Brandt's cormorant head on white.
- `cormorant-head.png` — same, with the white keyed out to transparency.
- `cormorant-mark-512.png` — cropped, transparent, 512px.
- `make-icons.swift` — regenerates the app icon set and favicons from the source:

```
swift assets/brand/make-icons.swift assets/brand/cormorant-head-source.png /tmp/icons
```

Then copy:

- `AppIcon*.png` into `apps/ios/Cormorant/Assets.xcassets/AppIcon.appiconset/` (the light and dark ones are written without alpha, as the App Store requires)
- `CormorantMark*.png` into `apps/ios/Cormorant/Assets.xcassets/CormorantMark.imageset/` (the launch screen and the blank tab share it, at 128pt)
- `cormorant-mark-512.png` and `cormorant-head.png` into this folder
- `favicon-*.png` and `apple-touch-icon.png` into `apps/site/public/`

The icon backgrounds are Vialumi's white and gray-950 (`#030712`). They must match the `LaunchBackground` color in the asset catalog: the wash is drawn on that color, and iOS grows the icon into the launch screen on launch.

## Launch screen

`apps/ios/Cormorant/LaunchScreen.storyboard`: the mark centered on the whole screen, over `LaunchWash` filling it. `LaunchWash` is the app's wash (`SpaceWashPainter`) at its first frame in the icon's cyan, light and dark, so the app's first frame is the same picture. After changing the painter or its colors, regenerate it:

```
swiftc -parse-as-library -o /tmp/make-launch-wash assets/brand/make-launch-wash.swift \
    apps/ios/Cormorant/Support/SpaceWashPainter.swift
/tmp/make-launch-wash apps/ios/Cormorant/Assets.xcassets/LaunchWash.imageset
```

iOS caches launch screens: a changed one may only show after deleting the app, or restarting the simulator.
