# Manual actions for Simo

## 1. Build and run the tests on the Mac mini (required)

No Xcode is installed on the machine these changes were written on — Command Line Tools only. Nothing has been compiled for iOS or run in a simulator. Every file was parse-checked, and the whole non-SwiftUI layer (22 files: all four engines, all models, file import, persistence, the batch runner) type-checks together under Swift 6 with complete strict concurrency at the iOS 17 deployment target with **0 errors and 0 warnings**. The iOS build itself, and all SwiftUI rendering, are unverified.

```bash
xcodebuild -project LocalFileDiet.xcodeproj -scheme LocalFileDiet -destination 'platform=iOS Simulator,name=iPhone 17' build test
```

Test files added across the five loops:

| File | Cases | Verified off-device? |
|---|---|---|
| `ArchiveCompressionEngineTests.swift` | 12 | Yes — ZIP proven against system `unzip`/`zipinfo` |
| `ImageCompressionEngineTests.swift` | 7 new | Mostly — HEIC-alpha and image-to-PDF could not run |
| `PDFCompressionEngineTests.swift` | 8 | Yes — engine runs unmodified on macOS |
| `PDFAnalyzerTests.swift` | 5 (rewritten) | Yes |
| `VideoEncodingPlanTests.swift` | 13 | Yes — plus real encodes against fixtures |
| `BatchRunnerTests.swift`, `TargetSelectionTests.swift` | — | Logic yes, via harness; XCTest plumbing no |
| `CoreUtilityTests.swift` | +10 | Yes |

Watch these two in particular, since no macOS harness could execute them:
- the HEIC-with-alpha image case (HEIC encoding availability differs on device),
- anything touching `UIGraphicsPDFRenderer` — though loop 3 moved PDF writing to Core Graphics, so this should now be moot.

## 2. Smoke-test these by hand on a device

These are the paths that only exist in SwiftUI or in the extension, so nothing here could be executed:
- **Batch flow** — pick 3+ files in the Files picker, confirm the batch review screen lists them all, compress, then try "Save all as ZIP".
- **Share extension** — share a PDF into Local File Diet from Files. It should open the app on the review screen. This is the fix I am least able to verify: `extensionContext.open` is not dependable from a share extension, so it now falls back to walking the responder chain to `UIApplication.open`.
- **Recent files** — swipe/context-menu delete, and tapping a row to re-share. Rows whose output has been pruned by the 24-hour cache cleanup should appear dimmed and unavailable rather than failing on tap.

## 3. One product decision I need from you

**How should OCRed scans behave?** A scanned PDF that has been through OCR has selectable text on every page, so the hybrid engine classifies no page as image-dominant and returns the file unchanged rather than destroying the text layer. The warning says so plainly. If you want those files to shrink, it has to become an explicit choice on the review screen — something like "these pages are photos with recognised text — shrink them and lose the text layer?". Tell me which you want and I will build it.

## 4. Tooling notes

- **Use `Scripts/add_file_to_project.rb`, not `Scripts/generate_project.rb`.** The generator rebuilds the project from nothing and had drifted from the committed one: it wiped `DEVELOPMENT_TEAM`, downgraded `objectVersion` from 54 to 46, and dropped three build settings Xcode had added (`DEAD_CODE_STRIPPING`, `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`, `STRING_CATALOG_GENERATE_SYMBOLS`). I pinned the team ID and object version in it, but it still loses those three settings, so it is only good for scaffolding from scratch.

  ```bash
  GEM_HOME=$(ls -d ~/.gem/ruby/*/ | head -1) ruby Scripts/add_file_to_project.rb LocalFileDiet/Path/To/NewFile.swift
  ```

- The `xcodeproj` Ruby gem was installed with `gem install xcodeproj --user-install`, which is why the `GEM_HOME` prefix is needed.

## 5. App Store copy is now understated

`APP_STORE_CONNECT_COPY.md` predates these changes. The app can now genuinely claim precise video size targeting ("compress a video to under 10 MB" lands within about 4% in a single pass), PDF compression that keeps text selectable, and batch compression. Worth a rewrite before the next submission.
