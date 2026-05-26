- [2026-05-25 16:49 CEST]: GitHub publication
  - Run a single push when ready: `git push -u origin main`.

- [2026-05-25 16:49 CEST]: Apple signing and capabilities
  - In Xcode, set the Apple Developer Team for the app and Share Extension targets.
  - Create/enable the App Group `group.com.simohue.localfilediet` in the Apple Developer portal, then attach it to both targets.
  - Confirm the bundle identifiers are available: `com.simohue.localfilediet` and `com.simohue.localfilediet.shareextension`.

- [2026-05-26 09:28 CEST]: App Store paid app pricing
  - In App Store Connect, configure Local File Diet as a paid app priced at EUR 2.99.
  - Do not create an in-app purchase product for unlimited compression; the app now grants unlimited conversions after download.
