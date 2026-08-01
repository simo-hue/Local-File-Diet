# Manual actions for Simo

## 4. Known limitations that are now stated honestly in the app, not fixed

- **PDF form fields.** PDFKit will not write a document-level `/AcroForm` into a document it creates, so a form widget survives the rebuild as an annotation but stops being a fillable field. The warning says so.
- **OCRed scans.** Every page has selectable text, so no page is classified as image-dominant and the file comes back unchanged rather than having its text layer destroyed. Still worth making an explicit user choice on the review screen — tell me if you want that.
- **Finder-made archives.** `ditto`, and therefore the Finder's Compress, writes entries with a data descriptor, which the reader refuses. Those archives get wrapped as-is rather than re-packed; the warning now names the real reason instead of blaming encryption. Supporting them is a contained change if you want the feature.
- **Mixed share selections.** `MaxCount` is per type (25 each) while `maximumAttachments` is a total of 25, so a selection of 15 photos plus 15 files is accepted by the share sheet and then silently truncated to 25. Low impact, but it is silent.