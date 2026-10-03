# yomy 📰

![yomy screenshots](materials/yomy.png)

yomy is a simple RSS reader for iOS, inspired by Apple News.

The name comes from 読み (*yomi*), Japanese for "reading".

## Features

- Apple News–style article cards with full-bleed images and metadata
- Subscribe to RSS / Atom feeds, organize them by category
- Save articles for later, mark as read, share via the system share sheet
- Home Screen widget showing the latest articles in three sizes
- OPML import / export
- iOS 26 search experience with `Tab(role: .search)`

## Requirements

- Xcode 16.0+
- iOS 17.0+ (some features require iOS 26)

## Links

- [Website](https://shakshi3104.github.io/apps/yomy/)
- [Privacy Policy](https://shakshi3104.github.io/apps/yomy/privacy/)

## Acknowledgements

Originally forked from [minsc-of-secrets/yomy](https://github.com/minsc-of-secrets/yomy).

## Parser regression tests

On macOS 14+ with Xcode's Swift 5.9+ toolchain:

```bash
swift test
```

The Swift package compiles the same RSS/Atom/JSON parser, OPML parser, and
SwiftData models used by the app. Tests use local XML fixtures; no live feed
requests are required. GitHub Actions runs them on pull requests.
This is a parser check, not an iOS app build or UI test. Build the app separately:

```bash
xcodebuild -project Yomi.xcodeproj -scheme Yomi \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Use an Xcode version with the iOS 26 SDK for the current UI APIs and Icon Composer assets.
