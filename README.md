# ShelfHead

A native iPhone and Apple Watch player for [Audiobookshelf](https://github.com/advplyr/audiobookshelf),
the self-hosted audiobook and podcast server.

[Download on the App Store](https://apps.apple.com/app/id6780096463)

ShelfHead is a client only. It plays what is on an Audiobookshelf server that you, or someone you
know, runs. It is an independent project and is not affiliated with Audiobookshelf.

## You need a server

Everything on the server side belongs to the Audiobookshelf project: installing it, adding
libraries, managing users, reverse proxies and single sign-on.

- Server source and issues: <https://github.com/advplyr/audiobookshelf>
- Server documentation: <https://www.audiobookshelf.org/docs>

If something is wrong with the server itself, raise it there. If something is wrong with this app,
[open an issue here](https://github.com/Juzzycooks/ShelfHead/issues).

## What the app does

- **Accounts:** several saved servers, password or OpenID Connect sign-in, and custom HTTP headers
  for servers behind a reverse proxy such as Cloudflare Access or Authelia.
- **Browsing:** Home shelves you can reorder and hide, and a Library you can browse by book,
  series, author, narrator, collection or playlist, with sorting, filters and smart filters.
- **Playback:** chapters, bookmarks, a waveform scrubber, speed remembered per book, an Up Next
  queue, sleep timers, smart rewind, chapter intro and outro skipping, and volume and tone controls.
- **Offline:** background downloads with Wi-Fi and charging rules. Downloaded books play with no
  connection, and progress syncs when the server is reachable again.
- **Listening data:** daily goal, streaks, history and a year in review.
- **Across the system:** Home Screen and Lock Screen widgets, Live Activities, Siri and Shortcuts,
  Spotlight, Handoff, CarPlay, and an Apple Watch app that works with the phone or on its own.
- **Languages:** English and Simplified Chinese.

## Requirements

- iOS 17.6 or later; watchOS 10 or later for the Watch app.
- An Audiobookshelf server you can reach from your device.
- To build: Xcode 26 or later. Some of the interface uses iOS 26 SDK symbols, so older Xcode
  versions won't compile it.

## Building

There are no package dependencies. Open `ShelfHead.xcodeproj` and build the `ShelfHead` scheme.

To run on your own device, change these under Signing & Capabilities for each target:

- the development team and the bundle identifiers (they start with `com.justin.ShelfHead`)
- the App Group, `group.com.shelfhead.app`
- the iCloud container, `iCloud.com.justin.ShelfHead`

Tests are XCTest:

```sh
xcodebuild test -project ShelfHead.xcodeproj -scheme ShelfHead \
  -destination 'platform=iOS Simulator,name=<iPhone>' -parallel-testing-enabled NO

xcodebuild test -project ShelfHead.xcodeproj -scheme "ShelfHead Watch" \
  -destination 'platform=watchOS Simulator,name=<Apple Watch>' \
  -only-testing:"ShelfHead Watch Tests" -parallel-testing-enabled NO
```

## Project layout

| Folder | What it is |
|---|---|
| `ShelfHead/` | The iOS app: `Models`, `Services`, `ViewModels`, `Views`, `Shared`, `Extensions` |
| `ShelfHeadWidgets/` | Home Screen and Lock Screen widgets, Live Activities and Control Center controls |
| `ShelfHeadIntents/` | Intents extension for Siri in CarPlay |
| `ShelfHead Watch App Watch App/` | The watchOS app |
| `ShelfHeadWatchWidgets/` | The Watch complication |
| `ShelfHeadTests/`, `ShelfHead Watch App Watch AppTests/` | Unit tests |

## Privacy

ShelfHead has no analytics, advertising or tracking. See the
[privacy policy](ShelfHead/AppStore/PRIVACY.md) for what the app stores and where data goes.

## Licence

[MIT](LICENSE).
