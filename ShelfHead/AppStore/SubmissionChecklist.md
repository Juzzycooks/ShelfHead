# ShelfHead — App Store Submission: Reviewer Notes & Checklist

This is the full path from "code complete" to "live on the App Store," plus the notes to
give App Review so the app isn't rejected for being un-testable.

---

## 1. The single biggest risk: App Review can't test it

ShelfHead needs a working Audiobookshelf server to do anything. If a reviewer installs it
and sees only a login screen they can't get past, **the app is rejected** (Guideline 2.1 —
App Completeness). You must give the reviewer a way in.

**Recommended:** stand up a small public demo Audiobookshelf server with a few public-domain
titles (e.g. from LibriVox, which are free to distribute), and a reviewer account.

In **App Store Connect → your app → App Review Information**:

- Tick **"Sign-in required."**
- **Demo server URL:** put it in the **Notes** field (the username/password fields are for
  credentials; the server address goes in Notes since ShelfHead asks for a URL).
- **User name / Password:** the reviewer account.
- **Notes:** paste the block below.

### Paste-ready App Review notes

```
ShelfHead is a client for Audiobookshelf (audiobookshelf.org), a self-hosted audiobook
server. It plays the user's own server library; it contains no content of its own.

To test, open the app and enter:
  Server URL: https://DEMO-SERVER-URL-HERE
  Username:   <reviewer-username>
  Password:   <reviewer-password>

The demo server hosts public-domain audiobooks (LibriVox) for review purposes.

Notes on app behavior:
- The app connects only to the server URL the user enters. It uses standard iOS HTTPS
  (URLSession / AVFoundation). It may also connect over HTTP because many users self-host
  on local networks without TLS; this is why App Transport Security exceptions are present.
- All credentials are stored in the iOS Keychain. The app has no analytics, tracking, ads,
  or developer-side data collection.
- Background audio, lock-screen controls, and CarPlay are used for audiobook playback.
```

If you'd rather not run a public server, attach a **screen-recording** of full app usage in
App Review Notes — but a live demo account is strongly preferred and less likely to be
bounced.

---

## 2. Export compliance (encryption)

ShelfHead only uses encryption built into iOS (HTTPS via URLSession/AVFoundation). That is
**exempt** from export documentation. To skip the per-build prompt in App Store Connect,
add this to the app target's **Info.plist**:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

You will then not be asked about encryption on each upload. (This is a real regulatory
declaration, not just a UI shortcut — it's accurate here because the app adds no custom
cryptography.)

---

## 3. App Transport Security (ATS) justification

If `Info.plist` contains an ATS exception (e.g. `NSAllowsArbitraryLoads` or
`NSAllowsLocalNetworking`) so users can reach self-hosted/HTTP servers, App Review may ask
why. Keep the exception as narrow as the app allows, and use this justification (already
included in the review notes above):

> "ShelfHead connects to user-configured, self-hosted Audiobookshelf servers. Users
> commonly run these on local networks or without TLS, so the app must be able to reach
> user-controlled HTTP endpoints. The app does not load arbitrary third-party web content."

If you can require HTTPS, prefer `NSAllowsLocalNetworking` (for LAN) over a blanket
`NSAllowsArbitraryLoads`, as the narrower exception is reviewed more favorably.

---

## 4. Privacy manifest & App Privacy

- Add the included **`PrivacyInfo.xcprivacy`** to the **app target** (Target → Build Phases
  → it should appear; ensure "Target Membership" is checked). It declares no tracking, no
  collected data, and the required-reason `UserDefaults` API (CA92.1).
- In App Store Connect → **App Privacy**, select **"Data Not Collected."**
- If you ever add a crash/analytics SDK, you must update both the manifest and the App
  Privacy answers.

---

## 5. CarPlay entitlement (may gate your timeline)

CarPlay **audio** apps require the `com.apple.developer.carplay-audio` entitlement, which
**Apple grants by request** (developer.apple.com → Contact Us → CarPlay). This can take time
and is not auto-approved.

- If you want to ship sooner, **disable CarPlay for the first release** and add it once the
  entitlement is granted, or
- Request the entitlement now and wait before submitting the CarPlay-enabled build.

Also confirm the **Background Modes → Audio** capability is enabled (required for background
playback) and that the **App Group** used by the widget is configured on the App ID.

---

## 6. Screenshots (required)

App Store Connect requires at least one screenshot for the largest supported size of each
device family you ship. As of now:

- **iPhone 6.9" (e.g. iPhone 16 Pro Max):** required. 1320 × 2868 (portrait).
- **iPhone 6.5"/6.7":** often still accepted/needed for older tooling — provide if prompted.
- **iPad 13" (if the app ships for iPad):** 2064 × 2752 (portrait) or matching landscape.
- **Apple Watch (if the watch app ships as part of this app):** provide watch screenshots.

Capture from the Simulator (Device → screenshot) or a real device. Show: library grid,
a book detail, the now-playing player, and downloads.

---

## 7. End-to-end submission checklist

### A. Apple Developer Program
- [ ] Enroll in the Apple Developer Program ($99 USD/year). Individual or Organization.

### B. Identifiers & capabilities (developer.apple.com → Certificates, IDs & Profiles)
- [ ] Create/confirm the **App ID / bundle identifier** (must match the Xcode project).
- [ ] Enable capabilities used by the app: **App Groups** (for the widget), and
      **CarPlay** only if/when its entitlement is granted.
- [ ] Confirm **Background Modes → Audio** is on in the Xcode target.

### C. Xcode project hygiene
- [ ] Set a unique **bundle identifier**, **version** (e.g. 1.0.0), and **build** number.
- [ ] Ensure the **widget** and **watch** targets share the matching `CURRENT_PROJECT_VERSION`
      / `CFBundleVersion` as the app (a recurring gotcha in this project).
- [ ] Add `PrivacyInfo.xcprivacy` to the app target.
- [ ] Add `ITSAppUsesNonExemptEncryption = false` to Info.plist.
- [ ] Provide an **app icon** for all required sizes (1024×1024 marketing icon included).
- [ ] Archive with a **Release** configuration and **Any iOS Device (arm64)**.

### D. App Store Connect record
- [ ] Create the app (App Store Connect → Apps → +). Pick the bundle ID.
- [ ] Fill **listing copy** from `AppStoreListing.md` (name, subtitle, description, keywords,
      promotional text, categories).
- [ ] Set **Privacy Policy URL** (host `PRIVACY.md`) and **Support URL**.
- [ ] Complete **App Privacy** → "Data Not Collected."
- [ ] Complete the **Age Rating** questionnaire (media player → typically 4+).
- [ ] Upload **screenshots** for each required device size.
- [ ] Set **pricing** (Free) and **availability**.

### E. Build upload
- [ ] In Xcode: **Product → Archive**, then **Distribute App → App Store Connect → Upload**
      (or use Transporter). Wait for processing.
- [ ] Attach the processed build to the app version.
- [ ] (Optional but recommended) Run a **TestFlight** internal test first to verify the
      uploaded build works against a real server.

### F. App Review information
- [ ] Tick **Sign-in required** and provide the **demo server URL + reviewer account**
      (Section 1) in the Notes/credentials fields.
- [ ] Add the **ATS justification** (Section 3) to the notes.

### G. Submit
- [ ] Click **Add for Review → Submit**. Choose manual or automatic release.
- [ ] Watch for messaging from App Review; respond quickly to any questions (the demo
      account + notes head off the most common rejection).

---

## 8. Common rejection reasons to pre-empt

- **2.1 App Completeness** — reviewer couldn't log in. → Demo server + account (Section 1).
- **5.1.1 Privacy** — missing/incorrect privacy manifest or App Privacy answers. → Section 4.
- **2.5.x** — undeclared/over-broad ATS or background modes. → Sections 3 and 5.
- **Metadata** — missing Support URL or Privacy Policy URL. → Section 6/7D.
- **CarPlay** — shipping CarPlay code without the granted entitlement. → Section 5.
