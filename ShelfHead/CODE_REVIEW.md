# ShelfHead — Code Review & Feature Suggestions

_Review date: 14 June 2026. Scope: full `ShelfHead/` SwiftUI source tree (models, services, view models, views, app config)._

## Overall assessment

This is a clean, well-structured SwiftUI app. Architecture is sensible: an `actor`-isolated API client, a singleton `@Observable` audio service, thin view models proxying playback state, and a tasteful dark UI with a mini-player + full-screen player. Multi-track stitching, chapter handling, sleep timers, lock-screen/Now-Playing integration, search debouncing, and pagination are all implemented thoughtfully. The bones are good.

The issues below fall into three buckets: a few things that will actually break or silently do nothing, some unfinished wiring, and polish. The single most urgent item is authentication compatibility with current Audiobookshelf servers.

---

## Critical (will break or already non-functional)

**1. Auth uses the deprecated persistent token — likely broken on current servers.**
The app authenticates by reading `loginResponse.user.token` and using it forever as a static `Bearer` token (`AudiobookshelfAPI.login`, `AuthViewModel`). Audiobookshelf v2.26 (mid-2025) replaced this with JWT **access + refresh tokens** (access tokens expire after ~1 hour; a 30-day refresh token mints new ones). The old persistent token was kept only for a migration window and was slated for removal from the server "no earlier than 30 September 2025." As of today that window has passed, so against an up-to-date server logins may fail outright, or sessions will silently die after about an hour. This needs the new flow: capture the refresh token, call the refresh endpoint on 401, and store/rotate accordingly.

**2. Downloads never play offline.** `DownloadManager` downloads files to disk and tracks `downloadedItems`, and `localFileURL(itemId:trackIndex:)` exists — but it is never called anywhere. `AudioPlayerService.loadAndPlayTrack` always builds a streaming URL from the server's `contentUrl`. So the entire Downloads feature provides no offline playback; a downloaded book still fails without network. Wire `loadAndPlayTrack` to prefer `DownloadManager.shared.localFileURL(...)` when present.

**3. HTTP (LAN) servers will fail to connect.** `Info.plist` contains only `UIBackgroundModes`. There is no App Transport Security exception. Many self-hosted Audiobookshelf servers run plain `http://` on a local IP, which iOS blocks by default. Without an `NSAppTransportSecurity` allowance (e.g. `NSAllowsLocalNetworking`, or a documented arbitrary-loads exception), those users can't log in at all. Also consider adding `NSLocalNetworkUsageDescription`.

---

## Major (incomplete wiring / silent failures)

**4. Playback and library errors are invisible.** `PlayerViewModel.errorMessage` and `LibraryViewModel.errorMessage` are set on failure but never displayed in any view (only `AuthViewModel.errorMessage` is shown, in `LoginView`). A failed play tap or failed library load just does nothing from the user's perspective. Surface these as an alert/toast.

**5. Settings are cosmetic.** `defaultPlaybackSpeed` is local `@State`, never persisted and never applied to the player. "Skip Back 15s / Skip Forward 30s" are hardcoded labels, not editable, and the skip amounts in `AudioPlayerService` are fixed constants. Either make these real (persist to `UserDefaults`/`AppStorage`, feed into the player and remote-command intervals) or mark them clearly as fixed.

**6. Downloads list shows placeholder titles.** Only a `Set<String>` of item IDs is persisted, so `DownloadedItemRow` literally renders "Downloaded Book" for every entry. Persist minimal metadata (title, author, track filenames, chapters, duration) alongside the files so the Downloads tab and offline playback have something to show.

**7. Progress bars missing in the Library grid.** `LibraryGridItem` reads `item.progressPercent`, which comes from `userMediaProgress` on the list payload — not reliably populated by `/api/libraries/:id/items`. HomeView works around this by separately fetching a progress map (`loadUserProgress`), but the Library grid doesn't use it, so most grid items won't show progress. Reuse the same progress map (or request progress inclusion on the items call).

---

## Minor / polish

- **Token stored in plaintext `UserDefaults`.** It's saved securely in Keychain, then *also* copied to `UserDefaults` (`serverURL`/`authToken`) so `AVPlayer` and cover views can read it synchronously. UserDefaults isn't protected storage. Consider a cached in-memory accessor fed from Keychain at launch instead.
- **AirPlay button does nothing** — the toolbar item in `PlayerView` has an empty action. Use an `AVRoutePickerView` (wrapped in `UIViewRepresentable`) for real route picking.
- **Auto-advance forces playback.** `moveToNextTrack` → `loadAndPlayTrack` always calls `play()`, so a track boundary reached while paused will resume playback unexpectedly.
- **`AVAudioSession` activated at launch.** `setActive(true)` runs in `init` before anything plays. Activate on first playback and deactivate on stop to play nicer with other audio apps.
- **Dead code:** `AudiobookshelfAPI.getCoverURL(...)` and `updateProgress(...)` are never called (cover URLs are rebuilt inline in views; progress goes through session sync). Remove or adopt.
- **`startPlayback` redundancy:** `PlayerViewModel.startPlayback` sets `isLoadingSession = false` then immediately `= true`.
- **`AudioFile.id` uses `UUID()` fallback,** which produces a new identity each access for files missing `ino` — fine today since it's unused in lists, but a latent `ForEach` hazard.
- **Concurrency:** `AudioPlayerService` is `@Observable` but not `@MainActor`; it mutates observable state from `Timer` callbacks, the periodic time observer, remote-command handlers, and detached `Task`s. It mostly lands on the main thread today, but annotating it `@MainActor` (with sync work hopped appropriately) would make this provably safe under Swift concurrency checking.
- **`.preferredColorScheme(.dark)`** is hardcoded; the palette is dark-only. Fine as a choice, just noting there's no light mode.

---

## Project hygiene

- **Duplicate `ShelfHead 2/` folder** sits alongside `ShelfHead/` in the repo. This is almost certainly a Finder/iCloud duplicate. If it ever gets added to the build target it'll cause duplicate-symbol errors and confusion. Delete it (after confirming `ShelfHead/` is the live copy).
- **`.DS_Store` files are committed.** Add a `.gitignore` (Swift/Xcode template) covering `.DS_Store`, `xcuserdata/`, build artifacts.
- I could not inspect `ShelfHead.xcodeproj/project.pbxproj` (it sits outside the shared folder), so I couldn't verify target membership, deployment target, or that `Info.plist` is correctly referenced. Worth a manual check.

---

## Feature suggestions

Roughly ordered by impact-to-effort.

**Quick wins**
- Real offline playback (finishing item #2 above) — the headline feature the UI already promises.
- Per-book and global playback-speed memory; apply the Settings default.
- Mark-as-finished / mark-as-unfinished and a manual "reset progress" action on the detail screen.
- "Jump to position / chapter" from the lock screen and a chapter-skip remote command (next/previous chapter).
- Show real titles + covers in Downloads; show total storage used and a "remove all" action.
- Surface errors (retry button on failed loads, a toast when a play fails).

**Medium**
- Bookmarks with optional notes, synced via the ABS bookmarks API.
- Sleep-timer extras: "shake to reset," fade-out volume in the last 30s, and an "end of current + N chapters" option.
- CarPlay support — a natural fit for an audiobook app and a big quality-of-life win in the car.
- Background/auto-download of "Continue Listening" titles, and Wi-Fi-only download toggle.
- Series view (group by series, sort by sequence) and an Authors browse screen.
- Sort/filter controls in the Library (by title, author, added date, progress, finished/unfinished).
- Genre/tag browsing and a proper "recently added" shelf.

**Larger / platform**
- Widgets (Home/Lock Screen) and a Live Activity for the current book with progress.
- Siri Shortcuts / App Intents ("Resume my audiobook").
- Apple Watch companion for transport controls.
- Multi-server support (switch between servers/accounts).
- Statistics: listening time, streaks, books finished — ABS exposes listening-session data you can build on.
- Podcast support (ABS handles podcasts too; the models are already partly book-shaped — would need episode handling).
- Cast/Sonos or broader AirPlay 2 multi-room polish.

**Robustness worth prioritizing regardless**
- Migrate to the JWT access/refresh auth flow (item #1) and add automatic token refresh on 401.
- Add ATS handling and an in-app way to trust/allow a local HTTP server (item #3).
- Reconcile local progress with the server on launch and on conflict (last-write-wins by `lastUpdate`), so progress made offline syncs when back online.

---

## Suggested order of attack

1. JWT auth migration + token refresh (or you can't log into a current server).
2. ATS / HTTP-server support.
3. Wire downloads into playback + persist download metadata.
4. Surface errors and make Settings functional.
5. Delete `ShelfHead 2/`, add `.gitignore`.
6. Then pick from features above.

## Sources
- [Audiobookshelf API Reference](https://api.audiobookshelf.org/)
- [New JWT authentication · Discussion #4460](https://github.com/advplyr/audiobookshelf/discussions/4460)
- [Bug: Can not log in after upgrading to 2.26.0 · Issue #4477](https://github.com/advplyr/audiobookshelf/issues/4477)
- [Playback & Progress Tracking — Audiobookshelf API docs](https://deepwiki.com/audiobookshelf/audiobookshelf-api-docs/3.6-playback-and-progress-tracking)
- [Authentication & Authorization — Audiobookshelf API docs](https://deepwiki.com/audiobookshelf/audiobookshelf-api-docs/3.2-authentication-and-authorization)
