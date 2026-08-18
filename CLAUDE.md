# yomy — Project Rules for Claude Code

This document tells Claude Code how to work inside this repo. Read it before making changes.

---

## 1. Overview

**yomy** 📰 is an iOS RSS reader inspired by Apple News.

The name comes from 読み (*yomi*), Japanese for "reading".

This project follows the naming convention of Shakshi3104's other apps: a short, mood-based name that evokes the core action of the app.

---

## 2. Tech Stack

| Item | Choice |
|---|---|
| UI | SwiftUI with Liquid Glass |
| State | `@State` / `@Environment` / SwiftUI native bindings |
| Persistence | SwiftData (`@Model`: `Feed`, `Article`, `Category`) |
| RSS / Atom parsing | [FeedKit](https://github.com/nmdias/FeedKit) (Swift Package Manager) |
| Widget | WidgetKit, data shared via App Group + JSON file |
| Minimum iOS | **17.0** (some features gated by `#available(iOS 26.0, *)`) |
| Bundle ID | `com.shakshi.yomy` (fork-specific) |
| App Group | `group.com.shakshi.yomy` |
| Xcode | 16.0+ |
| Swift | 5.9+ |

---

## 3. Data Strategy

- **Source RSS feeds** are fetched from the network and parsed with FeedKit.
- **SwiftData** stores `Feed`, `Article`, and `Category` records locally on device.
- **Widget** reads from the App Group's container via `Shared/WidgetDataStore.swift`. The main app writes a JSON snapshot of the latest articles and image cache; the widget reads it. No SwiftData access from the widget process.
- **OG images** are fetched lazily by `OGImageFetcher` when a feed entry has no `imageURL`. Result is written back to the `Article` so it persists.

### App Group container

The app and widget share data through `group.com.shakshi.yomy`. Both targets must list this entitlement and Xcode's signing must use the same Apple Developer team.

---

## 4. Build & Test Commands

Prefer these over opening Xcode. Use them to verify your changes compile.

### Build for device / simulator

```bash
xcodebuild -project Yomi.xcodeproj -scheme Yomi \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO
```

### Clean build

```bash
xcodebuild -project Yomi.xcodeproj -scheme Yomi clean
```

If a build fails, read the output carefully and fix the errors before reporting back. Do not stop at the first error — fix as many as you can in one pass.

### TestFlight (external)

```bash
asc workflow run testflight_external VERSION:1.0 GROUP:"yomy Tester"
```

**Never pass `SUBMIT_BETA:false` for an external release.** The env default in `.asc/workflow.json` is already `true`; leave it alone. Even when the marketing version is already approved, *every* build must be submitted for Beta App Review individually or it stalls at "Ready to Submit" and never reaches testers. `betaReviewState: APPROVED` in `asc status` is a per-version historical result, not a signal that the new build is exempt.

Do not copy parameters from previous runs in `.asc/runs/*.json` — earlier runs contain `SUBMIT_BETA:false` and reusing them reintroduces the bug.

If a build was uploaded without submission, submit it without re-archiving:

```bash
asc publish testflight --app 6770222036 --build-number <N> --group "yomy Tester" --submit --confirm --wait
```

Build numbers are auto-assigned from the git commit count by a Run Script phase, so re-running with nothing committed collides with the existing build.

---

## 5. Code Style

- **SwiftUI**. Use SwiftUI native state APIs (`@State`, `@Binding`, `@Query`, `@Environment`). Don't reach for `ObservableObject`.
- **iOS 17+ baseline.** iOS 26 features must be gated with `#available(iOS 26.0, *)` and provide a 17–25 fallback.
- **async/await everywhere** for networking and SwiftData writes that follow.
- **`throws` for errors**, not `Result`.
- **One screen per file.** ViewModels, when they exist, live next to the View.
- **No force-unwrap** in production code paths. Especially URLs from user-typed strings — guard them.

### Naming

- Views end with `View` (e.g. `LatestView`, `SettingsView`)
- Reusable parts in `Views/Components/` (e.g. `CategoryPickerSection`, `CachedAsyncImage`)
- Services are nouns (`FeedService`, `RSSFetcher`, `OGImageFetcher`, `OPMLManager`)

---

## 6. UI Guidelines

### Article cards

- **Featured (top of Latest)**: image at top, full-bleed, 240pt tall; title and metadata below
- **Regular**: text on left, 80×80pt thumbnail on right; same metadata layout
- All cards have a `⋯` menu in the bottom-right that opens Save / Mark as Read / Share. Long-press also opens the same actions via `contextMenu`.

### Saved indicator

A `bookmark.fill` (accent color) appears next to the `⋯` menu when `article.isSaved == true`. Visible across Latest / FeedDetail / Saved / Search.

### Article display

Tapping a card opens `ArticleWebView` as a **sheet** (not push). Sheet has Close on top-leading and Save / Share on top-trailing. Widget URLs resolve to the same sheet via SwiftData lookup.

### Settings

A gear icon on the Latest tab's NavBar opens `SettingsView` as a sheet (Madeleine-style). Settings does not occupy a tab. Within Settings, `Categories` and `About` are pushed via `NavigationLink`.

---

## 7. SwiftData Rules

- `Feed`, `Article`, `Category` are `@Model` types in `Yomi/Models/`.
- `Feed.articles` uses `@Relationship(deleteRule: .cascade, inverse: \Article.feed)`.
- `feed.category` is a plain `String` (not a relationship to `Category`). The `Category` model exists only so users can manage the list of categories. Renaming a `Category` does not retroactively update existing feeds.
- The "General" category is seeded once on first launch via a UserDefaults flag in `YomiApp.swift`. It can then be deleted by the user like any other category.

---

## 8. File Creation Rules (IMPORTANT)

The Xcode project (`Yomi.xcodeproj/project.pbxproj`) is **edited by hand**, not generated by XcodeGen. Adding a new `.swift` file requires updating the pbxproj in **four** places:

1. `PBXBuildFile` section
2. `PBXFileReference` section
3. The owning `PBXGroup`'s `children` array
4. The target's `PBXSourcesBuildPhase` (or `PBXResourcesBuildPhase` for assets)

When you add a new Swift file:

1. Create the file with `Write`.
2. Edit `Yomi.xcodeproj/project.pbxproj` to register it in the four locations.
3. Use 24-character hex IDs for new entries (`PBXBuildFile` and `PBXFileReference` get distinct IDs).
4. Build with `xcodebuild` to verify the file is picked up.

You may freely edit, rename, or delete content *within* existing files.

---

## 9. Project Structure

```
yomy/
├── Yomi/                         main app target
│   ├── YomiApp.swift             entry point, ModelContainer setup, default category seed
│   ├── ContentView.swift         TabView + iOS 26 search-tab branching, widget URL sheet
│   ├── Info.plist
│   ├── Yomi.entitlements         App Group
│   ├── AppIcon.icon              Icon Composer bundle
│   ├── BackgroundRefresh/
│   │   └── BackgroundRefreshService.swift   BGTaskScheduler registration
│   ├── Models/
│   │   ├── Feed.swift            @Model
│   │   ├── Article.swift         @Model
│   │   └── Category.swift        @Model
│   ├── Services/
│   │   ├── FeedService.swift     add / refresh / delete + widget data sync
│   │   ├── RSSFetcher.swift      FeedKit wrapper
│   │   ├── OGImageFetcher.swift  fetch og:image / twitter:image lazily
│   │   └── OPMLManager.swift     OPML import / export
│   └── Views/
│       ├── Articles/             tab views + article components
│       │   ├── LatestView.swift
│       │   ├── SavedView.swift
│       │   ├── SearchView.swift
│       │   ├── ArticleWebView.swift
│       │   ├── ArticleRowView.swift     featured / regular variants
│       │   └── ArticleContextMenu.swift Save / Read / Share buttons
│       ├── Feeds/                feed management views
│       │   ├── FeedsView.swift
│       │   ├── FeedDetailView.swift
│       │   ├── FeedManageView.swift
│       │   ├── AddFeedView.swift
│       │   └── FeedRowView.swift
│       ├── Settings/             settings views
│       │   ├── SettingsView.swift
│       │   ├── CategoriesView.swift
│       │   └── AboutView.swift
│       └── Components/           generic shared UI
│           ├── CachedAsyncImage.swift
│           └── CategoryPickerSection.swift
├── YomiWidget/                   widget extension target
│   ├── YomiWidget.swift          Provider, three sizes
│   └── YomiWidgetBundle.swift
├── Shared/                       used by both targets
│   └── WidgetDataStore.swift     App Group JSON store + image cache
└── Yomi.xcodeproj
```

---

## 10. Common Pitfalls

### Layout

1. `aspectRatio(contentMode: .fill)` on an image with `.clipped()` does **not** always constrain the parent's layout bounds to the frame size. Wrap with `Color.clear` + `.background { image }` + `.clipped()`, or use a `GeometryReader { proxy in image.frame(width: proxy.size.width, height: imageHeight) }`. Otherwise text in adjacent VStacks can overflow horizontally.
2. `.padding()` *after* `.frame(maxWidth: .infinity)` extends the view 32pt wider than its parent. Put `.padding()` *before* the frame, or use `HStack { content; Spacer(minLength: 0) }.padding()`.
3. `Menu` inside a Form Section renders as a button and inherits the accent (blue) tint. Add `.tint(.primary)` to the Menu to keep the row label looking like normal Form text.

### TextField

4. `TextField`'s placeholder colorization via `prompt: Text(...).foregroundStyle(...)` is unreliable on iOS 26, especially with `.keyboardType(.URL)`. Use `ZStack(alignment: .leading) { Text("...").foregroundStyle(.secondary).allowsHitTesting(false); TextField("", text: $...) }` for a guaranteed gray placeholder.
5. `Menu { Picker(...); Button(...) }` (mixing Picker and Button inside a Menu) can trigger `_UIReparentingView` warnings on iOS 26. Use individual `Button`s with manual `Label(name, systemImage: "checkmark")` for the selected item instead.

### Date grouping

6. When grouping articles by date string (e.g. `MM/dd` for current year, `yyyy/MM/dd` for older), do **not** sort the resulting groups by string. `"2024/12/04"` < `"12/24"` lexicographically. Sort groups by the actual `publishedAt` of each group's first article.

### Widget

7. The widget reads from the App Group's JSON file — no direct SwiftData access. After mutating articles in the main app, call the widget update path in `FeedService` so the JSON snapshot and image cache stay in sync.
8. Widget URL deep links use scheme `yomi://` (not `yomy`). The `CFBundleURLName` is set in Info.plist; the scheme matches what was originally registered upstream.

### iOS 26 / Liquid Glass

9. `Tab(role: .search)` is iOS 26+. Always wrap in `if #available(iOS 26.0, *)` and provide a 17–25 fallback.
10. Do not nest `.glassEffect()`. Do not apply glass to content itself (photos, long text). Do not override sheet backgrounds.

### SwiftData

11. The app group container is the primary source of truth. CoreData warnings about `Application Support` not existing on first launch are noisy but harmless — `Recovery attempt ... was successful!` follows.

---

## 11. How to Work With the User

- After each file change, run the build command (§4) before declaring success.
- If a build fails, fix errors yourself — do not ask the user to fix Swift compile errors unless you genuinely cannot.
- When adding a new file, remember to update `Yomi.xcodeproj/project.pbxproj` in four places (§8).
- Keep PRs focused. The user prefers squash-merging one logical change at a time.
- The user sometimes asks for an "Apple News–like" / "Madeleine-like" pattern. Compare the existing app's screens for inspiration when in doubt; both are the user's own apps.
