# Brand assets

- `cormorant-head-source.png` — original artwork, Brandt's cormorant head on white.
- `cormorant-head.png` — same, with the white keyed out to transparency.
- `cormorant-mark-512.png` — cropped, transparent, 512px.
- `make-icons.swift` — regenerates the app icon set and favicons from the source:

```
swift assets/brand/make-icons.swift assets/brand/cormorant-head-source.png /tmp/icons
```

Then copy `AppIcon*.png` into `apps/ios/Cormorant/Assets.xcassets/AppIcon.appiconset/` (strip alpha from the light and dark ones) and `favicon-*.png` / `apple-touch-icon.png` into `apps/site/public/`.
