# Manual actions for Simo

Version is now **2.0 (build 2)**. Everything below needs you, because none of it can be done on the machine these changes were written on (Command Line Tools only, no Xcode).

## 1. Build and test on the Mac mini — required

```bash
xcodebuild -project LocalFileDiet.xcodeproj -scheme LocalFileDiet -destination 'platform=iOS Simulator,name=iPhone 17' build test
```

All 38 app source files type-check against the real UIKit/SwiftUI/PDFKit via Mac Catalyst with 0 errors and 0 warnings under Swift 6 strict concurrency, so the app target should build. **The test target has never been compiled** — XCTest is not available here — so that is where a build failure is most likely.

## 2. Check the build number before you upload

`CURRENT_PROJECT_VERSION` is set to **2**. Because 2.0 is a new version train, App Store Connect would also accept build 1 — 2 was kept simply because it is monotonic against everything you have uploaded before, which can never collide. Raise it if you need to; it is one `sed` over `project.pbxproj` plus the same line in `Scripts/generate_project.rb`.

## 3. Smoke-test these by hand — they could not be verified here

- **Share extension with multiple files.** The activation rule capped every attachment type at 1, which hid the extension from the share sheet entirely for multi-select. It is now 25. Select 3 photos, then 3 PDFs, and confirm "Local File Diet" appears both times. This is inferred from Apple's documented conjunctive predicate, never observed.
- **Cancel a video compression**, including by swiping back mid-encode, and on an audio-only `.m4a` (which always takes the preset-fallback path). This crashed the app before; the fix is proven across 1400 trials on macOS, but AVFoundation timing differs on device.
- **Recent history surviving a relaunch.** It never worked before — the decoder never matched the encoder. Compress something, force-quit, reopen, and confirm the entry is still listed.
- **Batch flow**: import 3+ files, compress, then "Save all as ZIP".
- **A rotated scanned PDF with highlights on it.** Annotation geometry on `/Rotate` pages is the least-settled part of the PDF work.

## 4. Known limitations that are now stated honestly in the app, not fixed

- **PDF form fields.** PDFKit will not write a document-level `/AcroForm` into a document it creates, so a form widget survives the rebuild as an annotation but stops being a fillable field. The warning says so.
- **OCRed scans.** Every page has selectable text, so no page is classified as image-dominant and the file comes back unchanged rather than having its text layer destroyed. Still worth making an explicit user choice on the review screen — tell me if you want that.
- **Finder-made archives.** `ditto`, and therefore the Finder's Compress, writes entries with a data descriptor, which the reader refuses. Those archives get wrapped as-is rather than re-packed; the warning now names the real reason instead of blaming encryption. Supporting them is a contained change if you want the feature.
- **Mixed share selections.** `MaxCount` is per type (25 each) while `maximumAttachments` is a total of 25, so a selection of 15 photos plus 15 files is accepted by the share sheet and then silently truncated to 25. Low impact, but it is silent.

## 5. App Store metadata is out of date

The listing predates all of this. The app can now honestly claim precise video size targeting (a target lands within about 4% in a single pass), PDF compression that keeps text selectable, and batch compression. Worth rewriting before submission.

## Tooling

Use `Scripts/add_file_to_project.rb`, not `generate_project.rb` — the latter rebuilds from scratch and drops three build settings Xcode has added.

```bash
GEM_HOME=$(ls -d ~/.gem/ruby/*/ | head -1) ruby Scripts/add_file_to_project.rb LocalFileDiet/Path/To/New.swift
```
