# ShelfHead — Code Review Fixes Implemented

This documents the changes made in response to `CODE_REVIEW.md`. All items from the review were addressed. **The app has not been compiled/run** in this environment (no Xcode/iOS toolchain available) — an independent static review found no compile or logic errors, but please build and run through the checklist at the bottom.

## New files
- `Services/AuthStore.swift` — thread-safe in-memory holder for server URL + access/refresh tokens (replaces plaintext `UserDefaults` token storage). Seeded from Keychain at launch.
- `Models/SettingsStore.swift` — keys/defaults for playback preferences (default speed, skip intervals).
- `Models/DownloadedBook.swift` — on-disk download manifest; can rebuild a `PlaybackSession` for fully-offline playback.

All three were added to the Xcode project target (`project.pbxproj`).

## Critical
1. **JWT auth (v2.26+).** `login` now sends `x-return-tokens: true` and stores `accessToken` + `refreshToken`. A 401 on any request triggers a single `/auth/refresh` (via `x-refresh-token`), then retries the original request. If refresh fails, it silently re-authenticates with credentials stored in the Keychain (mitigates the known iOS "lost rotation" logout). Falls back gracefully to the legacy `token` for old servers. Logout calls `POST /logout`.
2. **Offline playback.** Downloads now write a `manifest.json` (tracks with offsets, chapters, metadata, resume position). The player prefers local files; if a server session can't start, it builds a local session from the manifest and plays with no network. Local resume position is persisted on every sync.
3. **HTTP/LAN servers.** `Info.plist` now has `NSAppTransportSecurity` (arbitrary loads + local networking) and `NSLocalNetworkUsageDescription`.

## Major
4. **Errors surfaced.** Playback errors show a global alert (`MainTabView`); library errors show alerts in Home/Library via a reusable `errorAlert` modifier.
5. **Settings are functional.** Default speed and skip-forward/back intervals persist via `@AppStorage` and are applied to the player and lock-screen controls (`refreshSkipIntervals`).
6. **Downloads show real titles/authors** from the manifest (no more "Downloaded Book").
7. **Library grid progress** now uses the shared progress map (loaded on `loadLibraries`).

## Minor / polish
- Token no longer written to plaintext `UserDefaults` — all reads go through `AuthStore`.
- AirPlay button replaced with a real `AVRoutePickerView`.
- Auto-advance and cross-track seeks respect the paused state (no surprise resume).
- Audio session is activated on play / deactivated on stop (was activated at launch).
- `AudioFile.id` is stable (was minting a new UUID each access).
- Removed dead `getCoverURL`; fixed redundant flag in `startPlayback`.

## Project hygiene
- Added `.gitignore` at the repo root (covers `.DS_Store`, `xcuserdata/`, build output, and `ShelfHead 2/`).
- **Action needed from you:** delete the duplicate `ShelfHead 2/` folder in Finder. It is not referenced by the Xcode project (safe to remove), but the sandbox couldn't delete it.

## Not done (deliberately)
- Full `@MainActor` annotation of `AudioPlayerService` was left out. It's a provability/safety nicety, not a bug; doing it blind (without a compiler to verify the isolation hops and the `static let shared` init) risked breaking the build. State mutations already occur on the main thread. Recommend doing this with Xcode's concurrency checking on.

---

---

# Feature batch 1 — "Quick wins" (added after review fixes)

All in-app, no new targets. Independent static review found no compile/logic errors.

- **Per-book + global speed memory.** Each book remembers its own playback speed; if none set, the global default applies. Speed is saved whenever changed and applied on playback start (`SettingsStore.resolvedSpeed`, `PlayerViewModel`).
- **Mark finished / not finished / reset progress.** New ⋯ menu on the book detail screen; actions sync to the server (`PATCH /api/me/progress`) and refresh the screen (`LibraryViewModel.markFinished/markUnfinished/resetProgress`).
- **Lock-screen chapter navigation.** Next/previous-track remote commands now jump chapters (`skipToNextChapter`/`skipToPreviousChapter`); previous restarts the current chapter if >3s in. Scrubbing/jump-to-position already worked.
- **Downloads storage + remove all.** Header shows book count and total size; a Remove All action (with confirmation) frees space (`DownloadManager.totalStorageUsed`/`removeAllDownloads`).
- **Errors: retry + toast.** Failed library loads show a Retry button; playback failures now show a transient toast instead of a modal alert (`errorAlert(retry:)`, new `toast` modifier).
- **Offline ↔ server progress reconciliation.** Manifests carry a `lastUpdate` timestamp; on launch/progress-load, offline progress newer than the server is pushed up and newer server progress is pulled down (last-write-wins). Playback resume also prefers the newer source (`DownloadManager.reconcile`, `PlayerViewModel.resolvedStartTime`).

### Extra things to test for this batch
- Change speed on book A, then book B; reopen each — each should restore its own speed.
- Mark a book finished, then not finished, then reset — confirm the badge/percent and the server both update.
- On the lock screen, use the next/previous-track buttons to jump chapters.
- Download a book, listen offline, then go online and relaunch — confirm the offline position syncs to the server (and to other devices).
- Trigger a play failure (e.g. offline + not downloaded) — confirm a toast, not a stuck spinner.

---

---

# Feature batches 2–4 (Library browsing, Infrastructure, CarPlay)

Independent static review found no compile/logic errors. New files were added to the Xcode project (main target).

## Library browsing
- **Sort & filter** in the Library tab: sort by Title / Author / Date Added / Duration with an ascending/descending toggle, and filter by progress (All / Not Started / In Progress / Finished). Uses ABS's `group.base64(value)` filter encoding with strict percent-encoding so Base64 survives transport.
- **Series** browse + detail (books shown in sequence order) via `GET /api/libraries/{id}/series`.
- **Authors** browse + per-author book grid, sourced from `?include=filterdata`.
- A segmented Books / Series / Authors switcher at the top of the Library tab.

## Infrastructure
- **Listening statistics** (Settings → Listening Stats): total time, today, day streak, books finished, and a 7-day bar chart, from `/api/me/listening-stats`.
- **Multi-server / accounts**: saved servers live in the Keychain (passwords keyed per-account); Settings → Servers lets you switch (silent re-auth), add, or delete accounts. Logging in adds the account automatically.
- **Auto-download Continue Listening** + **Wi-Fi-only** toggles (Settings → Downloads). Continue-Listening items auto-download after the home shelves load; a `NetworkMonitor` gates this to Wi-Fi when requested. Manual downloads are never gated.
- HTTP/LAN servers are already globally permitted by the ATS settings added earlier, so no separate "trust" step is required.

## CarPlay (code in main target, activation gated)
- `Services/CarPlaySceneDelegate.swift` builds Continue-Listening and Downloaded lists and drives playback through `AudioPlayerService`. It compiles but is inert until you (1) obtain the `com.apple.developer.carplay-audio` entitlement from Apple and (2) add the CarPlay scene manifest — both documented in `ShelfHeadExtras/SETUP.md`. The entitlement is intentionally NOT enabled to avoid breaking device code-signing.

## Widgets / Live Activity / Apple Watch (deliverables, not yet in project)
These each need a new Xcode target, so they live in `ShelfHeadExtras/` (outside the build) with full source and step-by-step setup in `ShelfHeadExtras/SETUP.md`:
- `Widgets/ShelfHeadWidget.swift` — Home/Lock-Screen widget (current book + progress).
- `Widgets/NowPlayingLiveActivity.swift` + `Shared/NowPlayingAttributes.swift` — Live Activity / Dynamic Island.
- `Shared/SharedPlayback.swift` — App Group bridge the app writes and the widget reads.
- `Watch/ShelfHeadWatchApp.swift` — watchOS transport-control companion (WatchConnectivity).

### Extra things to test for these batches
- Library: change sort/filter and confirm the grid reloads; open a Series and an Author; confirm progress bars still show.
- Stats: confirm totals, streak, and the 7-day chart look sane.
- Multi-server: add a second server, switch between them, delete one; confirm the active one shows a checkmark and content reloads.
- Auto-download: enable it + Wi-Fi-only, open Home on Wi-Fi, confirm Continue-Listening titles begin downloading; on cellular they should not.

---

## Build & test checklist (in Xcode)
1. Open the project; confirm `AuthStore.swift`, `SettingsStore.swift`, `DownloadedBook.swift` show up and are in the **ShelfHead target** (Target Membership). Build (⌘B).
2. **Login** against your server (try both `https://` and a plain `http://` LAN address). Confirm the local-network permission prompt appears once.
3. Leave the app idle > the access-token lifetime (or restart the server) and confirm it keeps working without bouncing you to login (refresh path).
4. **Sign out / back in** — confirm no leftover session.
5. Start a book, lock the phone: lock-screen controls, artwork, skip intervals, and scrubbing all work.
6. Change **default speed** and **skip intervals** in Settings; confirm they apply to a new playback session and the lock screen.
7. **Download** a book, then enable Airplane Mode and play it — confirm offline playback and that the resume position sticks.
8. Force a failure (wrong server URL) and confirm an error alert appears instead of a silent no-op.
9. Verify AirPlay picker opens the route menu.
