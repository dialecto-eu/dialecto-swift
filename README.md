# DialectoLive

Show the translations you merged in GitHub in a shipped Mac or iOS app, without a rebuild or a store review.
Swift 6, macOS 14 and iOS 17, no dependencies. MIT.

Dialecto builds a signed release from each commit on the branch you follow, one JSON file per language from
your String Catalog (`.xcstrings`). This package fetches it, checks it and answers string lookups from it. If
anything is wrong, the app keeps the text it has: it never throws into your app and never shows a blank.

## Install

In Xcode: File → Add Package Dependencies, paste

```
https://github.com/dialecto-eu/dialecto-swift
```

choose "Up to Next Major Version" from `0.1.0`, and add `DialectoLive` to your app target. Add
`DialectoLiveEditing` too if you want live editing in debug builds (see below).

Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/dialecto-eu/dialecto-swift", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "DialectoLive", package: "dialecto-swift"),
        .product(name: "DialectoLiveEditing", package: "dialecto-swift"),
    ]),
]
```

Only those two libraries are built into your app. A release build of your app carries none of the editing code.

## Server

The package talks to Dialecto at app.dialecto.eu: releases come from the channel of a project that follows a
branch of your repository. Live editing needs the server release that adds native live editing (after v1.13.0).

## Use

```swift
import DialectoLive

// Once, at launch.
DialectoLive.start(
    channel: "<public id>",
    publicKeys: ["ed25519:…"],            // from the channel's settings card
    builtAt: "2026-11-15T12:00:00Z")      // committer time of the commit this build came from

DialectoLive.string("export.button", default: "Export")   // the live text, or the default
Text(live: "export.button")                                // SwiftUI; redraws when a release lands
NSLocalizedString("export.button", comment: "")            // answered from the release first
```

`start` applies the release it cached last time before it returns, so the first screen already shows live
text, then checks in the background. It checks at start, when the app returns to the foreground, when the
system language changes, and every 15 minutes. `await DialectoLive.refresh()` checks now.

## Which lookups see a release

| Lookup | Live text |
|---|---|
| `DialectoLive.string(_:default:)` | yes |
| `Text(live:)` | yes, and it redraws |
| `NSLocalizedString`, `Bundle.main.localizedString(forKey:value:table:)`, AppKit and UIKit lookups on the main bundle | yes |
| `String(localized:)`, `Text("key")` (a `LocalizedStringKey`), `LocalizedStringResource` | no |

The last row does not go through `Bundle.localizedString`; it keeps the text bundled with the app. Use
`Text(live:)` or `DialectoLive.string` for the strings you want to fix live. This was checked by running
each path against a release in the demo (see Develop).

The `Bundle.main` hook is installed once by `start` (a second `start` leaves it alone) and answers only the
main bundle and only the tables the release carries. A table `T` reads the catalog named `T`, or a catalog in
a folder whose path ends in `T` (`App/Localizable.xcstrings` is `Localizable`). `nil` is `Localizable`.

## What a release carries

- One text per key and language: the `stringUnit` value. A key that is stale in Xcode is kept.
- Not carried, so the bundled text stays: plural variations, device variations, substitutions, keys marked
  not to translate, and any language value that is empty. (Every vendor stops at plurals.)
- The language is the one the app shows (`Bundle.main.preferredLocalizations`), matched to the catalog's
  names (`zh-Hans-DE` finds `zh-Hans`, then `zh`). Only that language is downloaded, and only when its file
  changed.

## What it refuses

A release changes nothing when:

- no signature on its manifest verifies against one of your `publicKeys` (Ed25519, over the payload bytes as
  given);
- a payload does not match the manifest's sha256;
- its `sequence` is not above the one held (the same sequence under another release id is refused too);
- its commit time is before `builtAt`;
- the manifest is malformed, too large, or lists a file URL that could leave the channel.

A single value whose printf tokens (`%@`, `%lld`, `%1$@`; `%%` takes none) differ from the app's own text for
that key is dropped, and the rest of the release applies. Any error goes to the optional `onError` and the
current strings stay.

## Cache

The last verified release is kept in the app's Application Support folder,
`Dialecto/Live/<channel>/`: the manifest bytes as served and the payloads. The cache is verified again on
every launch; one the keys no longer trust, or one older than the build, is ignored.

## Live editing in debug builds

`DialectoLiveEditing` is a second product for debug builds only. Sign in to Dialecto from the app, and the text
you type in Dialecto's editor shows in the running app within a couple of seconds; click text in "Edit text"
mode and Dialecto's editor opens on its key. Every source of the target is inside `#if DEBUG`; wrap the call too:

```swift
import DialectoLiveEditing   // also inside #if DEBUG, or the import fails in a release build

#if DEBUG
    DialectoLiveEditing.start(project: "owner/name")     // server: app.dialecto.eu
#endif
```

Nothing runs before `start`. On a Mac it adds a **Dialecto** menu (Sign in, Edit text, Keys) and the keys
window. On iOS it adds a small Dialecto button over the app that opens the keys sheet. Sign-in shows a large
code with Copy and Open browser; type the code on Dialecto's page and approve. A code that expires or is
denied says so, with Sign in again. The token (8 hours) is kept in the Keychain; if the Keychain
refuses it (an unsigned build, a sandbox without the entitlement) it is held in memory for the run. In a signed
app that is the default; for an unsigned build or a headless run pass `tokenStorage: .memory` or `.file(url)` so
no Keychain prompt appears. Xcode previews never sign in; they use a token already held, or show bundled text.

- **Drafts** (your unmerged edits, in locales you may edit) take precedence over the live release, which
  takes precedence over the bundle. A draft whose placeholders differ from the app's text is not shown.
- **Keys panel**: one row per key the app looked up since launch, newest first: the key, the text shown now,
  and a Draft tag or "Not shown" with the reason (plural, device variation, not translatable, empty,
  placeholders differ, check failed). It has a filter, and shows the sign-in state at the top. Picking a row
  opens the editor on that key. A bundle lookup knows only its table (`localizable`) while the release names
  a catalog in a folder by its path (`app-localizable`); the panel counts both as one catalog.
- **Edit text** (⌃⌥⌘E on a Mac, or the panel's Edit text button): on a Mac a sea frame goes round the app's
  windows with an "Editing text · esc" badge, the pointer turns to a hand, and the text under it gets an
  outline with its key. On iOS the floating button turns sea and reads Editing text, and a frame goes round
  the screen.
  A click on Dialecto's text opens its key; a click on other text adds a short note to the panel and keeps
  the mode on. Esc, or the same control, turns it off.

  A Mac app, sandboxed or not, needs no permission. iOS reads the app's accessibility tree, which iOS builds
  only when accessibility is on. In the simulator:

  ```
  xcrun simctl spawn booted defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true
  xcrun simctl spawn booted defaults write com.apple.Accessibility AccessibilityEnabled -bool true
  ```

  then reboot the simulator. An app cannot turn this on for itself, and a device cannot do it for you; use the
  keys panel there. A click on text finds the key by matching the text against what the app looked up: exact,
  then interpolated (`Hello, %@!`), then a label that merges several strings.

### What text is reached

Text shown through `Text(live:)`, `DialectoLive.string` and `NSLocalizedString` / `Bundle.localizedString` on
the main bundle. SwiftUI literals (`Text("…")`, `Button("…")`, `TextField("…")`, `Menu("…")`, `.help("…")`,
`String(localized:)`) never pass through the bundle: convert them to `Text(live:)` to edit them live. AppKit
text read once through `NSLocalizedString` updates on its next read, not on a draft.

### Release builds

A test builds the demo (`Demo/`) with `-c release` and fails if the binary holds the server path, the Keychain service
name or the panel's words, after checking that the debug build has all of them.

## Contract

`Tests/Fixtures/contract/` holds a String Catalog, the signed manifest and the payloads the Dialecto server
builds from it, and a **test-only** key. The server's tests rebuild the release from the input and fail on any
byte of difference, so the server and this client cannot drift. The key is never trusted by default: the app
passes the keys it trusts.

## Develop

```
swift build
swift test
cd Demo
swift run dialecto-live-demo        # before, after one release, after a second one swapped in
swift run dialecto-live-demo editing owner/name --server http://localhost:4500   # the live editing demo
```

The demos are their own package in `Demo/`, so a package that depends on DialectoLive never builds them. The
editing demo's commands (a file a headless run writes to) are listed at the top of
`Demo/Sources/dialecto-live-demo/EditingDemo.swift`. Screenshots of the panel, Edit text and the consent page are
in `docs/`.

### iOS host

`dialecto-live-ios-demo` is the same demo as an iOS app, for the simulator. SwiftPM builds the binary; an app
bundle is the binary plus `Demo/IOSHost/Info.plist`. From `Demo/`:

```
swift build --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --product dialecto-live-ios-demo
mkdir -p .build/ios-host/LiveDemo.app
cp IOSHost/Info.plist .build/out/Products/Debug-iphonesimulator/dialecto-live-ios-demo .build/ios-host/LiveDemo.app/
codesign --force --sign - .build/ios-host/LiveDemo.app
xcrun simctl install booted .build/ios-host/LiveDemo.app
xcrun simctl launch booted eu.dialecto.live-demo editing owner/name --server http://localhost:4500
```

It keeps its token in a file in its own container, never the Keychain. Its commands are listed at the top of
`Demo/Sources/dialecto-live-ios-demo/main.swift`; write them to `Documents/cmd` in the app's data container
(`xcrun simctl get_app_container booted eu.dialecto.live-demo data`).
