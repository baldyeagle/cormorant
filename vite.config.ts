import { defineConfig } from 'vite-plus';

// Task graph for `vp run`. Leaf tasks live here; the `build` / `test`
// aggregates live in the root package.json as nested `vp run` calls, because
// Vite+ forbids a task and a package.json script sharing a name, and we want
// `pnpm build` and `vp run build` to behave identically.
//
// Swift and Xcode tasks set `cache: false`: SwiftPM and xcodebuild keep their
// own incremental state in .build/ and DerivedData/.

const KIT = 'packages/CormorantKit';
const WORKSPACE = 'Cormorant.xcworkspace';
const SCHEME = 'Cormorant';
// iOS deployment target is 26.0, so the simulator must run iOS 26+.
// Override with IOS_TEST_DESTINATION='platform=iOS Simulator,name=...'.
const IOS_TEST_DESTINATION = 'platform=iOS Simulator,name=iPhone Duo,OS=27.1';

const xcodebuild = (action: 'build' | 'test', destination: string) =>
  [
    'xcodebuild',
    `-workspace ${WORKSPACE}`,
    `-scheme ${SCHEME}`,
    `-destination "${destination}"`,
    '-configuration Debug',
    'CODE_SIGNING_ALLOWED=NO',
    action,
  ].join(' ');

// Native code (Swift, Xcode-managed JSON) is out of scope for oxlint/oxfmt.
const NATIVE = ['apps/ios/**', 'apps/macos/**', 'packages/**', '*.xcworkspace/**'];

export default defineConfig({
  fmt: {
    singleQuote: true,
    printWidth: 100,
    ignorePatterns: [...NATIVE, '**/dist/**', '**/.astro/**'],
  },
  lint: {
    ignorePatterns: [...NATIVE, '**/dist/**', '**/.astro/**'],
  },
  run: {
    tasks: {
      // Site: delegate to apps/site/package.json scripts (inlined by Vite+).
      'site:build': { command: 'vp run site#build' },
      'site:test': { command: 'vp run site#test' },
      'site:dev': { command: 'vp run site#dev', cache: false },
      // Deploy is never part of `build`; run it explicitly.
      'site:deploy': { command: 'vp run site#deploy', cache: false },

      // CormorantKit (SwiftPM), run from the repo root.
      'kit:build': { command: `swift build --package-path ${KIT}`, cache: false },
      'kit:test': { command: `swift test --package-path ${KIT}`, cache: false },

      // iOS app via the shared workspace.
      'ios:build': {
        command: xcodebuild('build', 'generic/platform=iOS Simulator'),
        cache: false,
      },
      'ios:test': {
        command: xcodebuild('test', `\${IOS_TEST_DESTINATION:-${IOS_TEST_DESTINATION}}`),
        cache: false,
      },
    },
  },
});
