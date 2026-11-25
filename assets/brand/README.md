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
- `CormorantMark*.png` into `apps/ios/Cormorant/Assets.xcassets/CormorantMark.imageset/` (the launch screen and the blank tab share it, at 128pt), and the 1x and 2x into `apps/macos/Cormorant/Assets.xcassets/CormorantMark.imageset/` (the Mac's empty page)
- `cormorant-mark-512.png` and `cormorant-head.png` into this folder
- `favicon-*.png` and `apple-touch-icon.png` into `apps/site/public/`
- `MacIcon-bird.png` into `apps/macos/Cormorant/AppIcon.icon/Assets/bird.png`. The Mac icon is an Icon Composer document: the bird on a fill that's white in light mode and `#030712` in dark, with glass, shadow and translucency off. macOS makes its own tinted and clear versions. To check a version, render it with `"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" apps/macos/Cormorant/AppIcon.icon --export-image --output-file /tmp/dark.png --platform macOS --rendition Dark --width 512 --height 512 --scale 1`

The icon backgrounds are Vialumi's white and gray-950 (`#030712`). They must match the `LaunchBackground` color in the asset catalog: the wash is drawn on that color, and iOS grows the icon into the launch screen on launch.

## Launch screen

`apps/ios/Cormorant/LaunchScreen.storyboard`: the mark centered on the whole screen, over `LaunchWash` filling it. `LaunchWash` is the app's wash (`SpaceWashPainter`, in CormorantKit) at its first frame in the icon's cyan, light and dark, so the app's first frame is the same picture. The wash lays itself out from its view's shape, so the image set has one for each shape the launch screen comes in: iPhone portrait, iPhone landscape (compact height) and iPad (one for both ways up, so 10-17% off either way). After changing the painter or its colors, regenerate them:

```
swiftc -parse-as-library -o /tmp/make-launch-wash assets/brand/make-launch-wash.swift \
    packages/CormorantKit/Sources/CormorantBrowser/Wash/SpaceWashPainter.swift
/tmp/make-launch-wash apps/ios/Cormorant/Assets.xcassets/LaunchWash.imageset
```

iOS caches launch screens: a changed one may only show after deleting the app, or restarting the simulator.
