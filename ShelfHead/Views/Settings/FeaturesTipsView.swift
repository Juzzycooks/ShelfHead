import SwiftUI
import TipKit

/// Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §10, §7c): the cheap, no-flow-to-maintain
/// half of this app's discoverability answer — a short static list of things the app
/// does that you'd otherwise have to stumble into, plus a way to see the three TipKit
/// tips (`AppTips.swift`) again. Deliberately not a tour or a carousel: just a list,
/// reached from Settings > About, for the person who wants to go looking rather than
/// wait to be told.
struct FeaturesTipsView: View {
    var bottomInset: CGFloat = 0
    /// Critique 2026-10-06 (clarify): the `SettingsRow` a search result opened, if any.
    var focusRow: String? = nil
    @State private var didResetTips = false

    private struct Feature: Identifiable {
        /// A `SettingsRow` id: stable, so search can scroll to it (was a fresh `UUID()`).
        let id: String
        let icon: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        /// Critique 2026-10-06 (clarify): the Settings page that configures this feature,
        /// when there is one, so the row opens it instead of only describing it.
        var settingsPage: SettingsPage? = nil
        var settingsRow: String? = nil
        /// Batch 490 (REVIEW 2026-11-11 N3): the OS the feature needs, when this device is
        /// below it. Shown as a short note instead of hiding the row (HIG: explain, don't hide).
        var requirement: Requirement = .none
    }

    /// Batch 490 (REVIEW 2026-11-11 N3): OS floors some features have.
    private enum Requirement {
        case none, iOS18, iOS26

        /// The note to show, or nil when this device already meets it.
        var unmetNote: LocalizedStringResource? {
            switch self {
            case .none:
                return nil
            case .iOS18:
                if #available(iOS 18.0, *) { return nil }
                return "Needs iOS 18 or later."
            case .iOS26:
                if #available(iOS 26.0, *) { return nil }
                return "Needs iOS 26 or later."
            }
        }
    }

    private struct FeatureGroup: Identifiable {
        let id: String
        let title: LocalizedStringResource
        let features: [Feature]
    }

    // Batch 490 (REVIEW 2026-11-11 N3): four groups instead of one flat list, and the
    // features added since Stage 6 (transcripts, Apple Intelligence, Stats extras, system
    // surfaces). Each title matches its `SettingsSearchIndex` entry so a search result
    // names the row it lands on. Keep this list and the index in step.
    private let groups: [FeatureGroup] = [
        FeatureGroup(id: "player", title: "In the Player", features: [
            Feature(id: SettingsRow.featureDrivingMode, icon: "car.fill", title: "Driving Mode",
                    detail: "Big buttons, one glance — in the full player’s ⋯ menu."),
            Feature(id: SettingsRow.featureCassette, icon: "arrow.2.squarepath", title: "Cassette view",
                    detail: "Tap the cover in the full player to flip to a tape-deck view of what’s playing."),
            Feature(id: SettingsRow.featureFineScrub, icon: "hand.draw", title: "Fine scrubbing",
                    detail: "While dragging the scrubber, drag down for slower, more precise seeking."),
            Feature(id: SettingsRow.featureSleepShake, icon: "moon.zzz.fill", title: "Sleep timer, shake to extend",
                    detail: "With a sleep timer running, shake your phone to extend it.",
                    settingsPage: .sleepTimer, settingsRow: SettingsRow.shakeGesture),
            Feature(id: SettingsRow.featureClips, icon: "scissors", title: "Quote clips and Mixtapes",
                    detail: "Save a favourite moment with Clip… in the player’s ⋯ menu. Mixtapes collect them, under Stats › More."),
            Feature(id: SettingsRow.featureTranscriptSearch, icon: "text.magnifyingglass", title: "Search inside a book",
                    detail: "Find a line you heard and jump to it, with Search in Book… in the player’s ⋯ menu. Needs a transcript.",
                    settingsPage: .transcripts, settingsRow: SettingsRow.transcriptsEnabled, requirement: .iOS26),
            Feature(id: SettingsRow.featureCaptions, icon: "captions.bubble", title: "Live captions",
                    detail: "Read along with the narrator in place of the cover, with Show Captions in the player’s ⋯ menu. Needs a transcript.",
                    settingsPage: .transcripts, settingsRow: SettingsRow.transcriptsEnabled, requirement: .iOS26),
        ]),
        FeatureGroup(id: "book", title: "About the Book", features: [
            Feature(id: SettingsRow.featureRecaps, icon: "sparkles", title: "Previously On and I Zoned Out",
                    detail: "A short catch-up on what you’ve heard so far, or on the last few minutes. In the player’s ⋯ menu; needs a transcript and Apple Intelligence.",
                    requirement: .iOS26),
            Feature(id: SettingsRow.featureXRay, icon: "person.2", title: "X-Ray",
                    detail: "The people, places and terms you’ve met so far, each with a jump back to where they came up. Only uses what you’ve already heard.",
                    requirement: .iOS26),
            Feature(id: SettingsRow.featureAskTheBook, icon: "questionmark.circle", title: "Ask the Book",
                    detail: "Ask a question about the story so far and jump to the passage the answer came from. No spoilers: it only uses what you’ve heard.",
                    requirement: .iOS26),
            Feature(id: SettingsRow.featureReadAlong, icon: "book", title: "Read Along",
                    detail: "Follow the book’s EPUB as it plays, with the sentence being read highlighted. For books with an EPUB and a transcript.",
                    requirement: .iOS26),
        ]),
        FeatureGroup(id: "system", title: "Around iOS", features: [
            Feature(id: SettingsRow.featureWidget, icon: "apps.iphone.badge.plus", title: "Home Screen widgets",
                    detail: "Add the ShelfHead widget for at-a-glance progress and quick controls."),
            Feature(id: SettingsRow.featureLiveActivities, icon: "platter.filled.bottom.iphone", title: "Live Activities",
                    detail: "Sleep timer and downloads on the Lock Screen.",
                    settingsPage: .systemPrivacy, settingsRow: SettingsRow.liveActivities),
            Feature(id: SettingsRow.featureControls, icon: "switch.2", title: "Control Centre controls",
                    detail: "Add Playback, Resume Last Book, Sleep Timer or Open Now Playing to Control Centre, the Lock Screen or the Action button.",
                    requirement: .iOS18),
            Feature(id: SettingsRow.featureSiri, icon: "waveform", title: "Siri and Shortcuts",
                    detail: "Resume, play a book by name, find a line, skip, or set a sleep timer by voice or in a shortcut.",
                    settingsPage: .systemPrivacy, settingsRow: SettingsRow.siri),
            // Batch 490 (REVIEW 2026-11-11 N3): the Watch plays on its own now, not only as a remote.
            Feature(id: SettingsRow.featureWatch, icon: "applewatch", title: "Apple Watch app",
                    detail: "Play downloaded books from your Watch, with or without your iPhone."),
        ]),
        FeatureGroup(id: "fun", title: "Just for Fun", features: [
            Feature(id: SettingsRow.featureBSide, icon: "shuffle", title: "B-Side",
                    detail: "Play a random book you haven’t started — from Home, or the shuffle row in Library."),
            Feature(id: SettingsRow.featureDailyGoal, icon: "target", title: "Daily listening goal",
                    detail: "Set a goal from the ⋯ button on the Stats tab’s top card, and keep your streak going."),
            Feature(id: SettingsRow.featureCassetteWall, icon: "books.vertical", title: "Cassette Wall",
                    detail: "Every book you’ve finished, as a wall of tapes. Under Stats › More."),
            Feature(id: SettingsRow.featurePassport, icon: "airplane.departure", title: "Listening Passport",
                    detail: "Stamps for the genres, narrators and decades you’ve finished. Under Stats › More."),
            Feature(id: SettingsRow.featureDeckSkins, icon: "paintpalette", title: "Deck skins",
                    detail: "Restyle the player’s tape deck.",
                    settingsPage: .appearance, settingsRow: SettingsRow.deckSkin),
            Feature(id: SettingsRow.featureHousehold, icon: "person.2.fill", title: "Household",
                    detail: "Share recommendations and run book clubs with family and friends over iCloud.",
                    settingsPage: .household, settingsRow: SettingsRow.household),
        ]),
    ]

    @ViewBuilder
    private func featureLabel(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.icon)
                // VD-7 (docs/design-review.md, Round 4): leads the row's title
                // text (default `.body` styling), so scale with it — `minWidth`
                // below (was a fixed `width`) lets the leading column grow with
                // it instead of clipping the glyph at AX sizes.
                .scaledFont(16, relativeTo: .body)
                // Critique 2026-10-06 (distill): muted, like every other Settings row
                // glyph; the accent is for action or live state (One Light Rule).
                .foregroundStyle(Color.shelfMuted)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .foregroundStyle(Color.shelfCream)
                Typo.supporting(Text(feature.detail))
                    .foregroundStyle(Color.shelfMuted)
                if let note = feature.requirement.unmetNote {
                    Typo.supporting(Text(note))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        SettingsAnchoredList(focusRow: focusRow) {
            ForEach(groups) { group in
            Section {
                ForEach(group.features) { feature in
                    Group {
                        if let page = feature.settingsPage {
                            NavigationLink {
                                SettingsDestinationView(page: page, bottomInset: bottomInset,
                                                        focusRow: feature.settingsRow)
                            } label: {
                                featureLabel(feature)
                            }
                            .accessibilityHint("Opens \(page.title) settings")
                        } else {
                            featureLabel(feature)
                        }
                    }
                    .settingsRowAnchor(feature.id)
                }
            } header: {
                RetroSectionHeader(title: group.title)
            }
            .listRowBackground(Color.shelfCard)
            }

            Section {
                Button {
                    // Stage 6: honest about what this actually does — TipKit's own
                    // `resetDatastore()` is documented to run *before* `Tips.configure()`
                    // (called once at launch, in `ShelfHeadApp.init()`), so calling it
                    // mid-session doesn't retroactively un-dismiss a tip already shown
                    // this launch. What this button can do right now: zero each tip's
                    // own trigger counter, so the *next* time its trigger condition is
                    // met from scratch, it's eligible again; `resetDatastore()` is also
                    // called so a fresh launch starts clean. **[device check]** — the
                    // exact boundary of what "reappears immediately" vs. "reappears next
                    // launch" looks like in practice needs an on-device TipKit session
                    // to confirm; the subtitle below is written to not overpromise.
                    FineScrubTip.scrubCount = 0
                    CassetteFlipTip.playerOpenCount = 0
                    DrivingModeTip.minutesPlayedLifetime = 0
                    // Code review fix (26 August 2026): added alongside `drivingModeOpened`
                    // itself — resetting the counter but leaving this `true` would leave
                    // `DrivingModeTip`'s own rule permanently unsatisfiable after "Show
                    // tips again."
                    DrivingModeTip.drivingModeOpened = false
                    try? Tips.resetDatastore()
                    didResetTips = true
                    Haptics.success()
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                            .frame(width: 24)
                        Text(didResetTips ? "Tips reset" : "Show tips again")
                    }
                }
                .disabled(didResetTips)
            } header: {
                RetroSectionHeader(title: "Tips")
            } footer: {
                // Critique 2026-10-06 (distill): Typo.supporting, like every other
                // Settings footer, and shorter.
                Typo.supporting(Text("Each tip can appear again when its moment comes around. One already shown this launch may need a relaunch."))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)
        }
        .background(Color.shelfBackground.ignoresSafeArea())
        .navigationTitle("Features & Tips")
        .navigationBarTitleDisplayMode(.inline)
        .reexpandsTabBarOnAppear()
    }
}

// MARK: - What’s New

/// Batch 490 (REVIEW 2026-11-11 N3): decides when the What’s New sheet appears — once per
/// marketing version (`CFBundleShortVersionString`), never on a fresh install. The caller
/// (the app root) reads `shouldPresentAfterUpdate`, presents `WhatsNewSheet`, then calls
/// `markPresented()`. Settings › About also opens the sheet on demand.
enum WhatsNew {
    /// Device-local; on `SettingsExport.excludedKeys` (an import must not replay or hide it).
    static let lastSeenVersionKey = "settings_whatsNewLastSeenVersion"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// True once after an update to a newer marketing version. On a fresh install (nothing
    /// stored yet) it stores the current version silently and returns false, so a new user
    /// isn't told what changed in an app they've never used. An existing user updating to
    /// the first build that has this key also counts as a fresh install, so their first
    /// sheet is at the release after it.
    static var shouldPresentAfterUpdate: Bool {
        let defaults = UserDefaults.standard
        let lastSeen = defaults.string(forKey: lastSeenVersionKey)
        if lastSeen == nil, !currentVersion.isEmpty {
            defaults.set(currentVersion, forKey: lastSeenVersionKey)
            return false
        }
        return shouldPresent(current: currentVersion, lastSeen: lastSeen)
    }

    /// Records the running version as seen, so the sheet doesn't come back until the next one.
    static func markPresented() {
        guard !currentVersion.isEmpty else { return }
        UserDefaults.standard.set(currentVersion, forKey: lastSeenVersionKey)
    }

    /// Pure rule: present only when a version was seen before and the running one is newer
    /// (numeric compare, so "7.10" > "7.9", and a downgrade or reinstall of an older build
    /// doesn't show it).
    static func shouldPresent(current: String, lastSeen: String?) -> Bool {
        guard let lastSeen, !lastSeen.isEmpty, !current.isEmpty else { return false }
        return current.compare(lastSeen, options: .numeric) == .orderedDescending
    }
}

/// Batch 490 (REVIEW 2026-11-11 N3): the release notes for the running version, in the app
/// skin. Presented after an update (see `WhatsNew`) and from Settings › About.
struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    init() {}

    private struct Item: Identifiable {
        let id: Int
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
    }

    /// The version these notes describe. Update at each release cut, with `items`.
    private let version = "7.6"

    // Update this list at each release cut, from that release's `WhatsNew-<version>.txt`
    // (plain user-facing language; no file names). Currently WhatsNew-7.6.txt.
    private let items: [Item] = [
        Item(id: 1, title: "Search finds more",
             detail: "Library search now matches authors and narrators, shows up to 50 books instead of 12, and remembers your recent searches."),
        Item(id: 2, title: "Tidy Continue Listening",
             detail: "Touch and hold a book you’ve stopped listening to and remove it from Continue Listening. You can do the same for a series, and undo either."),
        Item(id: 3, title: "Sleep timer",
             detail: "Set any length up to three hours, add one more chapter to an end-of-chapter timer, and jump back to where you were when you set it."),
        Item(id: 4, title: "Player",
             detail: "Driving Mode keeps the screen on, the player works in landscape, Up Next is in the player’s menu, and the chapter list shows what you’ve played."),
        Item(id: 5, title: "Signing in",
             detail: "A reminder stays on screen when your session ends, single sign-on errors name the server setting to change, and the sign-in page shows your server’s version."),
        Item(id: 6, title: "Shortcuts and links",
             detail: "Touch and hold the app icon for Resume, Downloads and Search. New Control Centre controls skip back, skip forward and add a bookmark."),
        Item(id: 7, title: "CarPlay",
             detail: "Lists page both ways, Home follows the shelves you chose on iPhone, and keyboard search appears where the system supports it."),
        Item(id: 8, title: "Apple Watch",
             detail: "Double Tap plays and pauses. Choose a storage limit, download on Wi-Fi only, add 15 minutes to a sleep timer, and skip chapters from your headphones."),
        Item(id: 9, title: "Listening",
             detail: "See your most listened books and your library’s totals, set a books-this-year goal, and export your listening history."),
        Item(id: 10, title: "Reading",
             detail: "PDFs gain Contents and Go to Page. EPUBs gain Sepia and Black pages and relaxed line spacing.")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Typo.rowTitle(Text(item.title))
                                .foregroundStyle(Color.shelfCream)
                            Typo.supporting(Text(item.detail))
                                .foregroundStyle(Color.shelfMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    RetroSectionHeader(title: "Version \(version)")
                }
                .listRowBackground(Color.shelfCard)
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground.ignoresSafeArea())
            .navigationTitle("What’s New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetCloseButton { dismiss() }.monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)
            }
        }
    }
}

#Preview {
    NavigationStack {
        FeaturesTipsView()
    }
}
