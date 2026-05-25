- [2026-05-25 16:49 CEST]: Local File Diet iOS MVP Implementation
  - *Details*: Built a complete iPhone-only SwiftUI project from the local specification, including app scaffold, logo/app icons, privacy manifest, local-only file import, compression review flow, progress/cancellation UI, result sharing/export, settings, lightweight paywall, local history, and Share Extension handoff.
  - *Tech Notes*: Added native Apple-framework services using UniformTypeIdentifiers, ImageIO, PDFKit, AVFoundation, PhotosUI, Photos, StoreKit 2, OSLog, and Swift concurrency. Implemented modular compression engines for images, PDFs, videos, ZIP packaging, and unsupported passthrough. Added an Xcode project generator script using the local `xcodeproj` Ruby gem, no runtime third-party app dependencies. Bundle ID: `com.simohue.localfilediet`; Share Extension bundle ID: `com.simohue.localfilediet.shareextension`; App Group placeholder: `group.com.simohue.localfilediet`; StoreKit product placeholder: `localfilediet.lifetime`.

- [2026-05-25 16:49 CEST]: Verification
  - *Details*: Built and tested the app on iOS Simulator using XcodeBuildMCP.
  - *Tech Notes*: `build_sim` succeeded with zero warnings/errors. `test_sim` succeeded with 11 passing tests covering target parsing, byte formatting, output filename generation, file type detection, temporary-file copy safety, cancellation behavior, image compression output, PDF vector/scanned heuristic, and video bitrate estimation.

- [2026-05-25 17:15 CEST]: Simulator Launch
  - *Details*: Restored the missing shared `LocalFileDiet` Xcode scheme and launched the app on the iPhone 17 simulator for manual testing.
  - *Tech Notes*: `build_run_sim` succeeded for bundle ID `com.simohue.localfilediet`. StoreKit product setup is not required for Debug compression testing.

- [2026-05-25 17:21 CEST]: Minimal Home Redesign
  - *Details*: Updated the home screen so the transparent logo is the primary visual element instead of the app name, with concise product copy and only the essential import actions visible.
  - *Tech Notes*: Removed the white background from `Logo.imageset/logo.png`, simplified `HomeView`, hid the navigation title, preserved the settings shortcut, and added Italian localizations for the new visible strings. Verified with `build_run_sim`, simulator screenshot, and `build_sim`.
