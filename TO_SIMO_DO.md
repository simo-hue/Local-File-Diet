# Manual actions for Simo

## 5. Website — capture the four real screenshots (BLOCKING for launch)

The redesigned site is built and working, but `docs/assets/shots/` currently holds
**placeholders**, not real screens. The layout is final, so you only need to drop the
real PNGs in with the same filenames — no code changes.

**Capture on the iPhone 16 Pro simulator, iOS appearance set to Dark, at 1206 × 2622:**

| File | Screen | What it must show |
|---|---|---|
| `docs/assets/shots/result.png` | Result | A real video compression with a dramatic delta. The hero overlays a `112.4 MB → 9.6 MB` tag, so capture something close to that or tell me and I'll change the tag. |
| `docs/assets/shots/review.png` | Review | A target selected **and** the Plan estimate block visible. |
| `docs/assets/shots/batch.png` | Batch result | Several files listed, with "Save all as ZIP" visible. |
| `docs/assets/shots/progress.png` | Compressing | The percentage ring partway through, not at 0% or 100%. |

Notes:
- Dark mode matters — the site is dark-only and light screenshots will look like pasted rectangles.
- Only the **top ~40%** of `batch.png` and `review.png` is visible on the page (they sit in cropped device frames), so put the interesting content near the top of those screens.
- `progress.png` is not yet placed on any page; it is captured for future use and for the App Store.

## 6. Website — optional follow-ups

- **Custom domain.** The site is on `simo-hue.github.io/Local-File-Diet/`, which reads as a
  hobby project at the moment you are asking someone to pay. If you buy a domain, add a
  `CNAME` file in `docs/`, change `SITE` at the top of `Scripts/build_site.py`, re-run it,
  and update the three URLs in App Store Connect.
- **App Store Connect.** Marketing/Support/Privacy URLs are unchanged, so nothing is required
  there right now.

## 4. Known limitations that are now stated honestly in the app, not fixed

- **PDF form fields.** PDFKit will not write a document-level `/AcroForm` into a document it creates, so a form widget survives the rebuild as an annotation but stops being a fillable field. The warning says so.
- **OCRed scans.** Every page has selectable text, so no page is classified as image-dominant and the file comes back unchanged rather than having its text layer destroyed. Still worth making an explicit user choice on the review screen — tell me if you want that.
- **Finder-made archives.** `ditto`, and therefore the Finder's Compress, writes entries with a data descriptor, which the reader refuses. Those archives get wrapped as-is rather than re-packed; the warning now names the real reason instead of blaming encryption. Supporting them is a contained change if you want the feature.
- **Mixed share selections.** `MaxCount` is per type (25 each) while `maximumAttachments` is a total of 25, so a selection of 15 photos plus 15 files is accepted by the share sheet and then silently truncated to 25. Low impact, but it is silent.