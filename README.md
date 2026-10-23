# cormorant

Personal browser for iOS and macOS on WebKit. Arc-style Spaces, Browse for Me, whatever I want to add. Not a product.

## Layout

```
apps/
  ios/        iOS app (Xcode project, SwiftUI + UIKit chrome)
  macos/      macOS app (placeholder until the iOS app is usable)
  site/       cormorant.baldyeagle.dev (Astro)
packages/
  CormorantKit/   shared Swift package: Core, Blocking, AI, Sync
Cormorant.xcworkspace   opens both apps and the package
```

`docs/` is local-only and gitignored.

## Tooling

- `mise install` pins Node and Vite+.
- `vp run build` / `vp run test` fan out to Astro, `xcodebuild` and `swift test`.
- Xcode 27, iOS 26+ deployment target, team `BLF43JKMGW`, bundle `dev.baldyeagle.cormorant`.
