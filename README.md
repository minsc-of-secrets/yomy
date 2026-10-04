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

## Article-state regression tests

With an Xcode iOS 26 SDK and an available iPhone simulator:

```bash
bash scripts/test-article-state.sh
```

The harness stages the app's actual services, models, and widget store in a
throwaway Swift package, then runs XCTest against an in-memory SwiftData store
on the simulator. No duplicate service implementation is maintained in tests.
It covers delayed read actions versus Mark All Read, repeated actions across
same-URL articles, independent empty URLs, and deletion before deferred writes.
CI runs the current state tests and builds the app and widget without signing.
The initial validation also confirmed the Mark All Read test fails against the
original implementation: [red/green evidence](https://github.com/minsc-of-secrets/yomy/actions/runs/37129326056).
That historical check is no longer run on every push. For an explicit one-off
comparison, set `YOMY_BASELINE_REF` to a compatible earlier commit when invoking
the harness (the historical regression is expected to return a failing test).
These state tests do not measure or reproduce the UI freeze reported in issue #6.

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
