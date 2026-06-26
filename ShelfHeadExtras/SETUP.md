# ShelfHead — Platform Extensions Setup

These features need new Xcode targets / entitlements that can't be created safely outside Xcode. The source is ready in `ShelfHeadExtras/`; follow the steps to wire each up. None of this affects your current build until you add the targets.

## 0. App Group (shared by widget + app)
1. Select the **ShelfHead** target → Signing & Capabilities → **+ Capability → App Groups**.
2. Add a group, e.g. `group.com.shelfhead.app`. Add the same group to the widget and watch targets.
3. If you choose a different id, update `appGroup` in `Shared/SharedPlayback.swift`.
4. In the main app, write the snapshot whenever playback changes (in `AudioPlayerService.updateNowPlaying()` is a good spot):
   ```swift
   SharedPlayback.write(.init(itemId: currentItemId ?? "", title: currentSession?.libraryItem?.title ?? "",
       author: currentSession?.libraryItem?.authorName ?? "", currentTime: currentTime,
       duration: duration, isPlaying: isPlaying, updatedAt: Date()))
   WidgetCenter.shared.reloadAllTimelines()   // import WidgetKit
   ```
   Add `Shared/SharedPlayback.swift` to the **main app target** as well.

## 1. Widgets (Home / Lock Screen)
1. File → New → Target → **Widget Extension** (uncheck "Include Live Activity"). Name it `ShelfHeadWidgets`.
2. Keep `ShelfHeadWidgets.swift` (the widget bundle) and `SharedPlayback.swift` in the target; the App Group bridges data from the app.
3. Add the App Group capability to the widget target.
4. Build & run the widget scheme.

> Note: Live Activities (Dynamic Island) were intentionally removed from ShelfHead and are no longer part of this setup.

## 3. Apple Watch companion
1. File → New → Target → **watchOS → App** named `ShelfHead Watch`.
2. Add `Watch/ShelfHeadWatchApp.swift` to the watch target.
3. On the **phone** side, add a `WCSessionDelegate` that activates `WCSession`, maps incoming `command` messages onto `AudioPlayerService.shared` (`play`/`pause`/`skipForward`/`skipBackward`), and pushes state via `updateApplicationContext(["title":…,"isPlaying":…,"progress":…])` whenever playback changes.
4. Add the App Group to the watch target if you want it to read the shared snapshot directly.

## 4. CarPlay
`Services/CarPlaySceneDelegate.swift` is already in the main target and compiles. To activate:
1. **Entitlement:** request `com.apple.developer.carplay-audio` from Apple (https://developer.apple.com/contact/carplay/). Once granted and in your provisioning profile, add it to `ShelfHead.entitlements`:
   ```xml
   <key>com.apple.developer.carplay-audio</key><true/>
   ```
   ⚠️ Do not add this before Apple grants it, or device code-signing will fail.
2. **Scene manifest:** add to Info.plist:
   ```xml
   <key>UIApplicationSceneManifest</key>
   <dict>
     <key>UIApplicationSupportsMultipleScenes</key><true/>
     <key>UISceneConfigurations</key>
     <dict>
       <key>CPTemplateApplicationSceneSessionRoleApplication</key>
       <array>
         <dict>
           <key>UISceneConfigurationName</key><string>CarPlay</string>
           <key>UISceneDelegateClassName</key>
           <string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
         </dict>
       </array>
     </dict>
   </dict>
   ```
   (SwiftUI provides the phone window scene automatically; do not add a `UIWindowSceneSessionRoleApplication` entry or you'll have to manage the phone scene manually.)
3. Test in the **CarPlay Simulator** (Xcode → Simulator → I/O → External Displays → CarPlay).
