- [2026-05-25 16:49 CEST]: GitHub publication
  - Run a single push when ready: `git push -u origin main`.

- [2026-05-25 16:49 CEST]: Apple signing and capabilities
  - In Xcode, set the Apple Developer Team for the app and Share Extension targets.
  - Create/enable the App Group `group.com.simohue.localfilediet` in the Apple Developer portal, then attach it to both targets.
  - Confirm the bundle identifiers are available: `com.simohue.localfilediet` and `com.simohue.localfilediet.shareextension`.

- [2026-05-25 16:49 CEST]: StoreKit product setup
  - Create the lifetime non-consumable product in App Store Connect with product ID `localfilediet.lifetime`, or update `PurchaseService` if you choose a different product ID.
