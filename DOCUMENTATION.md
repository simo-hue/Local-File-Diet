- [2026-05-25 16:49 CEST]: Local File Diet iOS MVP Implementation
  - *Details*: Built a complete iPhone-only SwiftUI project from the local specification, including app scaffold, logo/app icons, privacy manifest, local-only file import, compression review flow, progress/cancellation UI, result sharing/export, settings, local history, and Share Extension handoff.
  - *Tech Notes*: Added native Apple-framework services using UniformTypeIdentifiers, ImageIO, PDFKit, AVFoundation, PhotosUI, Photos, OSLog, and Swift concurrency. Implemented modular compression engines for images, PDFs, videos, ZIP packaging, and unsupported passthrough. Added an Xcode project generator script using the local `xcodeproj` Ruby gem, no runtime third-party app dependencies. Bundle ID: `com.simohue.localfilediet`; Share Extension bundle ID: `com.simohue.localfilediet.shareextension`; App Group placeholder: `group.com.simohue.localfilediet`.

- [2026-05-25 16:49 CEST]: Verification
  - *Details*: Built and tested the app on iOS Simulator using XcodeBuildMCP.
  - *Tech Notes*: `build_sim` succeeded with zero warnings/errors. `test_sim` succeeded with 11 passing tests covering target parsing, byte formatting, output filename generation, file type detection, temporary-file copy safety, cancellation behavior, image compression output, PDF vector/scanned heuristic, and video bitrate estimation.

- [2026-05-25 17:15 CEST]: Simulator Launch
  - *Details*: Restored the missing shared `LocalFileDiet` Xcode scheme and launched the app on the iPhone 17 simulator for manual testing.
  - *Tech Notes*: `build_run_sim` succeeded for bundle ID `com.simohue.localfilediet`.

- [2026-05-25 17:21 CEST]: Minimal Home Redesign
  - *Details*: Updated the home screen so the transparent logo is the primary visual element instead of the app name, with concise product copy and only the essential import actions visible.
  - *Tech Notes*: Removed the white background from `Logo.imageset/logo.png`, simplified `HomeView`, hid the navigation title, preserved the settings shortcut, and added Italian localizations for the new visible strings. Verified with `build_run_sim`, simulator screenshot, and `build_sim`.

- [2026-05-25 17:25 CEST]: English-Only App Text
  - *Details*: Converted the app back to English-only text by removing Italian translations from the string catalog.
  - *Tech Notes*: `Localizable.xcstrings` now keeps English source keys without `it` localizations, so SwiftUI text resolves to English even on an Italian simulator. Verified with `rg` for Italian strings and `build_run_sim` plus simulator screenshot.

- [2026-05-26 09:22 CEST]: Premium Compression Progress UI
  - *Details*: Replaced the simple linear compression loader with a richer attention-grabbing progress panel: animated circular progress, shimmering progress bar, phase timeline, privacy note, and stronger phase-specific iconography.
  - *Tech Notes*: Added `ProgressPresentation` smoothing so progress never visually moves backward when compression engines retry different strategies. Updated `FileReviewView` to apply monotonic progress updates. Added a unit test for non-regressing progress. Verified with `build_sim`, `test_sim -only-testing:LocalFileDietTests` (12 passed), and `build_run_sim`.

- [2026-05-26 09:24 CEST]: Result Home Return Action
  - *Details*: Added a result-screen action that returns the user to the Home screen after a completed compression so they can start a new import immediately.
  - *Tech Notes*: Added `onStartNewImport` to `ResultView` and wired `AppRootView` to clear the `NavigationStack` path. Verified with `build_sim`.

- [2026-05-26 09:28 CEST]: Paid Upfront Unlimited Access
  - *Details*: Converted monetization to a paid-upfront app model. After purchase/download, users have unlimited local compressions with no runtime trial, paywall, subscriptions, or in-app purchases.
  - *Tech Notes*: Removed runtime purchase gating, compression counters, paywall UI, StoreKit product loading, and restore-purchase actions. Settings now shows unlimited access included. App price must be configured in App Store Connect at EUR 2.99. Verified with `build_sim` and `test_sim -only-testing:LocalFileDietTests` (12 passed).

- [2026-05-26 09:49 CEST]: GitHub Pages Website and App Store Legal Links
  - *Details*: Added a modern static website for Local File Diet under `docs/`, including a product home page, Privacy Policy, Support page, Terms of Use, 404 page, sitemap, robots file, and optimized logo asset. The site is designed for deployment from the public GitHub repository via GitHub Pages and includes the Privacy Policy URL and Support URL needed for App Store Connect.
  - *Tech Notes*: Added dependency-free HTML/CSS/JS assets in `docs/` with canonical GitHub Pages URLs for `https://simo-hue.github.io/Local-File-Diet/`. Updated `SettingsView` with in-app links to the Privacy Policy, Support, and Terms pages so legal/support information is accessible from the app. No new runtime dependencies were added.

- [2026-05-26 09:50 CEST]: Review Advanced Toggle Layout Fix
  - *Details*: Fixed the Advanced disclosure section on the review screen so long toggle labels no longer push switches beyond the right edge after selecting an image.
  - *Tech Notes*: Constrained the review scroll content to the available width and replaced the Advanced toggles with a reusable responsive row that allows label wrapping while keeping switches inside the viewport. Updated the existing home UI test to match the current logo-first home screen and marked it `@MainActor` to remove Swift Concurrency warnings. Verified with `build_sim` and the focused `LocalFileDietUITests/LocalFileDietUITests/testHomeScreenLoads` UI test.
