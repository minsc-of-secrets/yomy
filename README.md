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
The CI also verifies that the Mark All Read regression fails against the original
implementation before building the app and widget without signing.
These state tests do not measure or reproduce the UI freeze reported in issue #6.
