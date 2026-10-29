# Cormorant

Personal WebKit browser for iPhone (first), macOS (second), iPad (later), replacing Arc / Arc Search for its owner, Austin Baldwin. Not a product: no accounts, no telemetry, no analytics, no server. AI features use the user's own API keys. Arc-style Spaces and "Browse for Me" are the reference points; AI usefulness is the differentiator.

## Layout

```
apps/ios/            Xcode 27 project: Cormorant app + CormorantShare extension + CormorantUITests
apps/macos/          placeholder until the iOS app is daily-usable
apps/site/           cormorant.baldyeagle.dev (Astro 7 + Tailwind 4, deployed with Wrangler)
packages/CormorantKit/   Swift package: CormorantCore, CormorantBlocking, CormorantAI, CormorantSync
assets/brand/        source artwork + make-icons.swift (regenerates app icons and favicons)
scripts/             repo scripts (default-browser plist checklist)
docs/                gitignored, local-only: research, scope decisions, docs/product/todo.md (plan of record)
Cormorant.xcworkspace   opens apps/ios and the package together
```

## Commands

```
mise install                         # pins node, pnpm, vite-plus (vp)
pnpm install --frozen-lockfile
vp run build | vp run test           # site + package
vp run site:dev                      # Astro dev server
vp run kit:test                      # swift test --package-path packages/CormorantKit
CORMORANT_LIVE_TESTS=1 vp run kit:test   # also downloads + compiles the real filter lists (~15s)
vp run ios:build                     # simulator build, signing off
vp run ios:test                      # UI tests on a simulator (IOS_TEST_DESTINATION overrides the device)
scripts/check-default-browser-plist.sh [path/to/Cormorant.app]
```

Simulator builds need an iOS 26+ runtime. Device builds and TestFlight need Xcode signed into Austin's Apple ID and a registered device; the TestFlight recipe is `xcodebuild archive ... -allowProvisioningUpdates` then `-exportArchive` with an ExportOptions.plist (method `app-store-connect`, destination `upload`, `manageAppVersionAndBuildNumber` true). `xcrun simctl openurl` with an http(s) URL goes to the system default browser, not Cormorant; use `cormorant://open?url=...` to drive the app.

## Conventions

- Swift 6.4, strict concurrency. The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency; the package does not.
- iOS 26 / macOS 26 deployment targets. No third-party dependencies anywhere in Swift.
- Tests use Swift Testing (`import Testing`). Package tests run on macOS; WebKit APIs (`WKContentRuleListStore`, `WKWebView`) work there under `swift test`.
- UI tests (`apps/ios/CormorantUITests`) use XCTest's `XCUIApplication`. They launch with `-uiTesting` (debug builds: no saved tabs, state in a temp file, share inbox untouched, no filter lists fetched or installed) and load pages from `FixtureServer` on 127.0.0.1, so they need no network. Wait with `appears(within:)`, `disappears(within:)` and `waitUntil` (`Waiting.swift`), not `waitForExistence` or predicate expectations: those first check about a second in. Don't make them poll faster than they do: each check is an accessibility snapshot, and a steady 0.1 s slowed CI's 3-core runners. Since a wait now returns the moment something appears, tap things that animate in with `tapWhenSettled()` (menus, switcher) or `tapInPresentedSheet()` (sheets); a tap mid-animation is dropped. CI builds once, then runs the suite in shards dealt out by `scripts/ui-test-shard.py`. On the iOS 27.1 simulator a synthesized tap didn't activate SwiftUI menu items; pressing the menu's button and dragging onto the item does.
- Public package API is the contract between the package and the app. Add API freely; change existing signatures only with the app updated in the same change.
- The Xcode project is `objectVersion = 90` with synchronized folder groups: new Swift files under `apps/ios/Cormorant/`, `apps/ios/CormorantShare/` and `apps/ios/CormorantUITests/` need no pbxproj edits. Build settings like `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` live in the pbxproj, not Info.plist, so Xcode edits don't drop them.
- Content blocking is on by default (EasyList, EasyPrivacy, EasyList Cookie). `ContentBlockingEngine.ruleLists(for:)` never blocks a navigation on network or compile; lists arrive via `listsVersion` / `onListsChanged`.
- Persistence: `BrowserState` is versioned JSON in the app group. An unreadable file is quarantined and the app must never auto-save over it (the "Start Fresh" flow).

## Default-browser entitlement checklist (hard constraints)

Apple's requirements (developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser), enforced by `scripts/check-default-browser-plist.sh` in CI:

- `http` and `https` declared in `CFBundleURLTypes` (keep the existing `dev.baldyeagle.cormorant.web` entry exactly as is; the `cormorant` scheme is a separate entry).
- WKWebView only; never UIWebView.
- On launch, a URL/search text field is shown (the keyboard-up address field).
- Navigate straight to the requested URL; no interstitials or redirects. Safe-browsing warnings and native sign-in UI are allowed.
- Never add these Info.plist keys to any target: `NSPhotoLibraryUsageDescription` (use `NSPhotoLibraryAddUsageDescription` / `PHPickerViewController`), `NSLocationAlwaysUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription` (when-in-use is fine), `NSHomeKitUsageDescription`, `NSBluetoothAlwaysUsageDescription` (while-in-use is fine), `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`.
- Don't claim Universal Links for specific domains; the system ignores them for browsers.
- The `com.apple.developer.web-browser` entitlement is requested from Apple and added to the entitlements file only once granted.

## Process

- Do not commit, push, or deploy unless Austin asks. Branch work happens in T3 worktrees; `main` is fast-forwarded by merging PRs.
- Before any substantive commit, run at least one adversarial review pass with an Opus agent (give it the code and the brief, not conclusions), fix confirmed findings, then ask.
- `docs/product/todo.md` is the plan of record; keep it current when scope or status changes. It is local-only, like all of `docs/`.
- Site deploys (`vp run site:deploy`) and TestFlight uploads are outward-facing: Austin runs them or explicitly asks for them.
