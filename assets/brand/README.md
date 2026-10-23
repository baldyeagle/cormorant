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

The icon backgrounds are Vialumi's white and gray-950 (`#030712`). They must match the `LaunchBackground` color in the asset catalog: the launch screen is that color with the mark centered, and iOS grows the icon into it on launch.
