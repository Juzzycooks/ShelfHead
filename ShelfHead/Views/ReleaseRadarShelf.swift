import SwiftUI

/// Batch 442: Home shelf of later books in the user's series, upcoming or out but not in the
/// library. Standalone: pass the library snapshot; it hides itself when the radar is off or empty.
/// Covers come from Audible's CDN via `AsyncImage` (no ABS credentials involved).
struct ReleaseRadarShelf: View {
    let libraryItems: [LibraryItem]

    @State private var radar = ReleaseRadarViewModel.shared
    @State private var selected: ReleaseRadarPlanner.RadarEntry?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Batch 490 (REVIEW 2026-11-11 E4): observed, so turning the radar off in Settings hides the shelf
    /// without a relaunch (`SettingsStore.releaseRadarEnabled` is a static read SwiftUI can't track).
    @AppStorage(SettingsKeys.releaseRadarEnabled) private var enabled = false

    private var cardWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 200 : 130 }

    var body: some View {
        Group {
            if enabled, !radar.entries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    RetroSectionHeader(title: LocalizedStringResource("Release Radar", comment: "Home shelf title"))
                        .padding(.horizontal, Space.pageH)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(radar.entries.prefix(20)) { entry in
                                Button { selected = entry } label: {
                                    ReleaseRadarCard(entry: entry, width: cardWidth)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        markNotInterested(entry)
                                    } label: {
                                        Label("Not Interested", systemImage: "hand.thumbsdown")
                                    }
                                }
                                .accessibilityAction(named: Text("Not Interested")) { markNotInterested(entry) }
                            }
                        }
                        .padding(.horizontal, Space.pageH)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Release Radar")
                }
            }
        }
        .task(id: libraryItems.count) {
            await radar.refreshIfNeeded(items: libraryItems)
        }
        .sheet(item: $selected) { entry in
            ReleaseRadarDetailSheet(entry: entry) { markNotInterested(entry) }
        }
    }

    /// Batch 490 (REVIEW 2026-11-11 F27): hides the book now and from later checks; `HomeView`
    /// shows the Undo toast.
    private func markNotInterested(_ entry: ReleaseRadarPlanner.RadarEntry) {
        Haptics.selection()
        radar.markNotInterested(entry)
    }
}

private struct ReleaseRadarCard: View {
    let entry: ReleaseRadarPlanner.RadarEntry
    let width: CGFloat

    private var status: ReleaseRadarPlanner.Status { entry.status(today: Date(), calendar: .current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReleaseRadarCover(url: entry.coverURL, size: width)
            // Batch 490 (REVIEW 2026-11-11 V6): a label, not an action or live state, so taupe (One Light Rule).
            Typo.fine(Text(verbatim: "\(entry.seriesName) · \(ReleaseRadarViewModel.sequenceLabel(entry.sequence))"), weight: .semibold)
                .foregroundStyle(Color.shelfMuted)
                .lineLimit(1)
            Typo.rowTitle(Text(verbatim: entry.title))
                .foregroundStyle(Color.shelfCream)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Typo.rowSubtitle(Text(verbatim: ReleaseRadarViewModel.releaseLabel(status)))
                .foregroundStyle(Color.shelfMuted)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ReleaseRadarCover: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default:
                ZStack {
                    Color.shelfCard
                    Image(systemName: "book.closed").foregroundStyle(Color.shelfMuted)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityHidden(true)
    }
}

/// Small detail sheet: Open in Audible, plus a release-day reminder for upcoming books.
/// Batch 490 (REVIEW 2026-11-11 V1/V2/V4): the shelf background, Typo roles and cream/taupe ink,
/// one primary (Open in Audible), the reminder as a text button, a scrolling body with a `.large`
/// detent for big text sizes, and the standard close button. F27: a quiet Not Interested.
struct ReleaseRadarDetailSheet: View {
    let entry: ReleaseRadarPlanner.RadarEntry
    /// Batch 490 (REVIEW 2026-11-11 F27): hides this book (the presenter shows the Undo toast).
    var onNotInterested: (() -> Void)? = nil

    @State private var radar = ReleaseRadarViewModel.shared
    @State private var showNotificationsDeniedAlert = false
    @State private var reminderError: String?
    @Environment(\.dismiss) private var dismiss

    private var status: ReleaseRadarPlanner.Status { entry.status(today: Date(), calendar: .current) }
    private var isUpcoming: Bool { if case .upcoming = status { return true } else { return false } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        ReleaseRadarCover(url: entry.coverURL, size: 110)
                        VStack(alignment: .leading, spacing: 4) {
                            Typo.cardTitle(Text(verbatim: entry.title))
                                .foregroundStyle(Color.shelfCream)
                            Typo.rowSubtitle(Text(verbatim: entry.author))
                                .foregroundStyle(Color.shelfMuted)
                            Typo.metadata(Text(verbatim: "\(entry.seriesName) · \(ReleaseRadarViewModel.sequenceLabel(entry.sequence))"))
                                .foregroundStyle(Color.shelfCream)
                            Typo.metadata(Text(verbatim: "\(ReleaseRadarViewModel.releaseLabel(status)) · \(entry.releaseDate.formatted(date: .long, time: .omitted))"))
                                .foregroundStyle(Color.shelfMuted)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let url = SettingsStore.releaseRadarRegion.productURL(asin: entry.asin) {
                        Link(destination: url) {
                            Label("Open in Audible", systemImage: "arrow.up.right.square")
                                .shelfButtonStyle()
                        }
                        .buttonStyle(.plain)
                    }
                    if isUpcoming {
                        Button {
                            Task {
                                reminderError = nil
                                switch await radar.toggleReminder(entry) {
                                case .notificationsOff?: showNotificationsDeniedAlert = true
                                case .releaseDayPassed?:
                                    reminderError = String(localized: "It's already release day, so there's nothing to remind you about.",
                                                           comment: "Release radar: reminder not set because the release is today or past")
                                case .failed?:
                                    reminderError = String(localized: "Couldn't set the reminder. Try again.",
                                                           comment: "Release radar: scheduling the local notification failed")
                                case .scheduled?, nil: break
                                }
                            }
                        } label: {
                            Label(radar.reminders.contains(entry.asin) ? "Reminder set" : "Remind me",
                                  systemImage: radar.reminders.contains(entry.asin) ? "bell.fill" : "bell")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.shelfAmberText)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if let reminderError {
                            Typo.supporting(Text(verbatim: reminderError))
                                .foregroundStyle(Color.shelfMuted)
                        } else {
                            Typo.supporting(Text("You'll get a notification on release day."))
                                .foregroundStyle(Color.shelfMuted)
                        }
                    }
                    if let onNotInterested {
                        Button {
                            dismiss()
                            onNotInterested()
                        } label: {
                            Typo.secondaryAction(Text("Not Interested"))
                                .foregroundStyle(Color.shelfMuted)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Hides this book from Release Radar"))
                    }
                }
                .padding(Space.pageH)
            }
            .background(Color.shelfBackground.ignoresSafeArea())
            .navigationTitle("Release Radar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .monochromeToolbarItem()
                }
            }
            .task { await radar.loadReminders() }
            .alert("Notifications Are Off", isPresented: $showNotificationsDeniedAlert) {
                Button("Open Settings") {
                    // Same alert as Settings › Notifications: land on the app's own Notifications page.
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Notifications are off for ShelfHead. Turn them on in Settings to use this.")
            }
            .systemChromeTint()
        }
        .presentationDetents([.medium, .large])
    }
}
