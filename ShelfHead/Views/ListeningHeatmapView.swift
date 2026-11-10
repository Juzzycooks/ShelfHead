import SwiftUI

/// GitHub-style listening heatmap for the Listening tab (`StatsView`'s `heatmapCard`).
/// Pure, `nonisolated` statics below are unit-tested in `ListeningHeatmapTests`; the
/// view itself computes cells once (`.onAppear`/`.onChange(of: days)`) into `@State`
/// rather than in `body`, matching this file's `cached*` precedent in StatsView.swift.
/// The one "yyyy-MM-dd" day-key formatter for everything that talks to the server's
/// `days` map (Stats, Year in Review, heatmap, `ListeningStats`). POSIX locale and a
/// Gregorian calendar, so the key never depends on the device's calendar or locale.
/// Critique 2026-10-06 (harden): four unconfigured copies of this lived in separate files.
enum DayKey {
    static func makeFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Shared instance, time zone pinned at first use (matches the old `dayKeyPOSIX`).
    /// Never mutate it.
    static let shared: DateFormatter = makeFormatter(timeZone: Calendar.current.timeZone)
}

enum ListeningHeatmap {
    struct Cell: Identifiable, Equatable {
        let id: String // "yyyy-MM-dd" day key
        let date: Date
        let minutes: Double
        let level: Int // 0...4
    }

    /// The minute boundaries between levels 1|2, 2|3 and 3|4. The legend is written from
    /// these, so what it states and what `level(minutes:)` does can't drift apart.
    static let thresholds: [Double] = [15, 30, 60]

    /// 0 for no listening, then 3 buckets up to a top "4" band for an hour or more.
    static func level(minutes: Double) -> Int {
        if minutes <= 0 { return 0 }
        if minutes < thresholds[0] { return 1 }
        if minutes < thresholds[1] { return 2 }
        if minutes < thresholds[2] { return 3 }
        return 4
    }

    // MARK: Legend (Critique 2026-10-06 (layout))

    /// Critique 2026-10-06 (layout): the legend said only "Less … More", so a sighted reader
    /// couldn't tell what a shade meant; VoiceOver users already got minutes. One label per
    /// level, 0...4, written from `thresholds`.
    static var legendLabels: [String] {
        let t = thresholds.map { Int($0) }
        return [String(localized: "None", comment: "Heatmap legend: no listening that day"),
                String(localized: "Under \(t[0])", comment: "Heatmap legend: fewer than %lld minutes"),
                String(localized: "\(t[0])\u{2013}\(t[1])", comment: "Heatmap legend: a range of minutes, %1$lld to %2$lld"),
                String(localized: "\(t[1])\u{2013}\(t[2])", comment: "Heatmap legend: a range of minutes, %1$lld to %2$lld"),
                String(localized: "\(t[2])+", comment: "Heatmap legend: %lld minutes or more")]
    }

    /// What VoiceOver reads for the legend.
    static var legendSpoken: String {
        let t = thresholds.map { Int($0) }
        return String(localized: "Shading, minutes listened per day: none, under \(t[0]), \(t[0]) to \(t[1]), \(t[1]) to \(t[2]), \(t[2]) or more", comment: "VoiceOver legend for the heatmap; each %lld is a minutes threshold")
    }

    // MARK: Level fills (Critique 2026-10-06 (layout))

    /// Grounds the heatmap sits on and its empty-cell tint, per appearance. These mirror
    /// `shelfBackground` and `shelfMuted` (Extensions.swift); the fills are computed as
    /// opaque hexes so their contrast can be measured, which a SwiftUI opacity can't.
    static let lightGroundHex = "F7F2E9"
    static let darkGroundHex = "16110C"
    static let darkMutedHex = "A89177"
    /// The empty cell is the muted ink at this strength over the ground.
    static let emptyStrength: Double = 0.15
    /// Level 1 must stand apart from an empty day by at least this much (WCAG 1.4.11
    /// non-text contrast).
    static let minimumLevelOneContrast: Double = 3.0

    /// Opaque fills for levels 0...4 (0 = empty) for an accent in one appearance.
    ///
    /// Critique 2026-10-06 (layout): level 1 was the accent at 30% opacity. Measured against
    /// the empty cell it came out about 1.0:1 in Light and 1.5:1 in Dark, so a short
    /// listening day looked like no listening at all. Now the darkest/brightest stop is
    /// the accent pushed (only if it needs to be) to ≥6:1 against the empty cell by the
    /// app's own `AppTheme.adjustedHexForContrast`, level 1 is the first blend between the
    /// empty cell and that stop that clears 3:1, and levels 2–4 step evenly up to it. In
    /// Dark the stop is the raw accent; in Light it's a deeper shade of it, the same
    /// reason `shelfAmberText` exists (the raw accent is about 1.9:1 on paper).
    static func levelFillHexes(accentHex: String, dark: Bool) -> [String] {
        let ground = dark ? darkGroundHex : lightGroundHex
        let muted = dark ? darkMutedHex : Color.shelfMutedLightHex
        let empty = HeatmapColor.mix(ground, muted, emptyStrength)
        let stop = AppTheme.adjustedHexForContrast(accentHex, backgroundHex: empty, targetRatio: dark ? 7 : 6)
        var t1 = 1.0
        for step in 1...100 {
            let t = Double(step) / 100
            if HeatmapColor.contrast(HeatmapColor.mix(empty, stop, t), empty) >= minimumLevelOneContrast {
                t1 = t
                break
            }
        }
        let levels = (0..<4).map { k in HeatmapColor.mix(empty, stop, t1 + (1 - t1) * Double(k) / 3) }
        return [empty] + levels
    }
}

/// Small sRGB helpers for `ListeningHeatmap.levelFillHexes`. `AppTheme`'s own hex parsing
/// is private to Extensions.swift, so these are local; the luminance itself is
/// `ContrastInk.relativeLuminance`, the app's one WCAG implementation.
enum HeatmapColor {
    static func components(_ hex: String) -> (r: Double, g: Double, b: Double) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        return (Double((int >> 16) & 0xFF) / 255, Double((int >> 8) & 0xFF) / 255, Double(int & 0xFF) / 255)
    }

    static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func channel(_ v: Double) -> UInt64 { UInt64((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", channel(r), channel(g), channel(b))
    }

    /// `a` blended toward `b` by `t` (0 = a, 1 = b), quantised to 8-bit like what's drawn.
    static func mix(_ a: String, _ b: String, _ t: Double) -> String {
        let x = components(a), y = components(b)
        return hex(x.r + (y.r - x.r) * t, x.g + (y.g - x.g) * t, x.b + (y.b - x.b) * t)
    }

    /// WCAG contrast ratio between two opaque colours.
    static func contrast(_ a: String, _ b: String) -> Double {
        let x = components(a), y = components(b)
        let la = ContrastInk.relativeLuminance(r: x.r, g: x.g, b: x.b)
        let lb = ContrastInk.relativeLuminance(r: y.r, g: y.g, b: y.b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

extension ListeningHeatmap {
    /// `weekCount` columns oldest -> newest, each a Sun/Mon-first (per `calendar`) week
    /// of 7 cells, ending with the week containing `today`. Days after `today` are
    /// omitted from the last column so it may be short.
    static func weeks(days: [String: Double], weekCount: Int, today: Date, calendar: Calendar) -> [[Cell]] {
        // Critique 2026-10-06 (harden): POSIX + Gregorian keys, like the server's. The old
        // formatter adopted `calendar`, so a Buddhist/Japanese-calendar device wrote
        // "2569-10-06" and the whole heatmap came up empty.
        let keyF = DayKey.makeFormatter(timeZone: calendar.timeZone)

        let startOfToday = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: startOfToday)
        // Days since this column's first weekday (calendar.firstWeekday), 0...6.
        let offsetFromWeekStart = (weekday - calendar.firstWeekday + 7) % 7
        guard let currentWeekStart = calendar.date(byAdding: .day, value: -offsetFromWeekStart, to: startOfToday)
        else { return [] }

        var result: [[Cell]] = []
        for weekOffset in stride(from: -(weekCount - 1), through: 0, by: 1) {
            guard let weekStart = calendar.date(byAdding: .day, value: weekOffset * 7, to: currentWeekStart)
            else { continue }
            var column: [Cell] = []
            for dayOffset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { continue }
                if date > startOfToday { break } // omit future days from the trailing column
                let key = keyF.string(from: date)
                let seconds = days[key] ?? 0
                let minutes = seconds / 60
                column.append(Cell(id: key, date: date, minutes: minutes, level: level(minutes: minutes)))
            }
            result.append(column)
        }
        return result
    }

    /// Labels a column ("MMM") whenever its first cell's month differs from the
    /// previous column's, including the very first column.
    static func monthLabels(for weeks: [[Cell]], calendar: Calendar) -> [(column: Int, label: String)] {
        let monthF = DateFormatter()
        monthF.calendar = calendar
        monthF.timeZone = calendar.timeZone
        monthF.setLocalizedDateFormatFromTemplate("MMM")

        var labels: [(column: Int, label: String)] = []
        var lastMonth: Int?
        for (index, column) in weeks.enumerated() {
            guard let first = column.first else { continue }
            let month = calendar.component(.month, from: first.date)
            if month != lastMonth {
                labels.append((column: index, label: monthF.string(from: first.date)))
                lastMonth = month
            }
        }
        return labels
    }
}

struct ListeningHeatmapView: View {
    let days: [String: Double]?
    var weekCount: Int = 20

    @State private var weeks: [[ListeningHeatmap.Cell]] = []
    @State private var monthLabels: [(column: Int, label: String)] = []
    @State private var weekdayLabels: [String] = Array(repeating: "", count: 7)

    @Environment(\.colorScheme) private var colorScheme

    private static let cellSpacing: CGFloat = 3
    private static let weekdayColumnWidth: CGFloat = 26
    /// Critique 2026-10-06 (layout): the axis labels were `.font(.system(size:))` at a
    /// 9pt base (under the 11pt floor), scaled by a hand-rolled capped `@ScaledMetric`.
    /// They're now the `Typo.fine` token (Caption 2, 11pt at the default size), limited to
    /// this Dynamic Type size so they keep fitting the grid's measured cells. The grid's
    /// content is read by VoiceOver as a summary plus one element per week, and the legend
    /// below it isn't capped.
    private static let axisLabelSizeCap: DynamicTypeSize = .large
    private static let monthRowHeight: CGFloat = 14
    private static let legendSwatch: CGFloat = 10

    /// Opaque level fills for the current accent and appearance. Computed once per body
    /// pass and handed to every cell (not per cell). `ThemeStore.accentHex` is observed,
    /// so an accent change redraws them.
    private var levelFills: [Color] {
        ListeningHeatmap.levelFillHexes(accentHex: ThemeStore.shared.accentHex, dark: colorScheme == .dark)
            .map { Color(hex: $0) }
    }
    // `StatsDateFormatters` in StatsView.swift is file-private, so this view (and its
    // accessibility labels) needs its own formatter rather than reaching across files.
    private static let accessibilityDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()
    // AX-1 (docs/design-review.md, Round 4): full weekday name for the per-week
    // accessibility summary ("Busiest: Wednesday, 88 minutes"). A fixed "EEEE" pattern
    // still renders a localised weekday name, matching this file's existing convention
    // of fixed `dateFormat` strings (see `keyF`/`monthF` in `ListeningHeatmap`) rather
    // than a template API.
    private static let accessibilityWeekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    /// Width the card actually gives us, measured once per layout pass. Every cell is
    /// sized from it explicitly — see the device-pass note on `body`.
    @State private var availableWidth: CGFloat = 0

    private var cellSize: CGFloat {
        let columns = CGFloat(max(weeks.count, 1))
        let usable = availableWidth - Self.weekdayColumnWidth - Self.cellSpacing * columns
        return max(4, floor(usable / columns))
    }

    // Device pass (16 Sep 2026), two rounds. Round 1: a fixed-12pt grid in a trailing-
    // anchored ScrollView sat right-aligned with dead space on the left, and month labels
    // wrapped mid-word in their 12pt columns. Round 2: a `Grid` of flexible
    // `maxWidth: .infinity` squares reported an unbounded ideal width, and the Listening
    // tab's VStack adopted it — every card on the screen grew past the right edge. Now
    // the width is measured with `onGeometryChange`, every cell gets an explicit size
    // derived from it, and month labels sit in overlays so their text can't widen the
    // layout. The grid can therefore never be wider than the card that holds it.
    var body: some View {
        let fills = levelFills
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }

            if availableWidth > 0 {
                Grid(alignment: .leading, horizontalSpacing: Self.cellSpacing, verticalSpacing: Self.cellSpacing) {
                    GridRow {
                        Color.clear.frame(width: Self.weekdayColumnWidth, height: Self.monthRowHeight)
                        ForEach(Array(weeks.indices), id: \.self) { column in
                            Color.clear
                                .frame(width: cellSize, height: Self.monthRowHeight)
                                .overlay(alignment: .leading) {
                                    if let label = monthLabels.first(where: { $0.column == column })?.label {
                                        Typo.fine(Text(label))
                                            .foregroundStyle(Color.shelfMuted)
                                            .fixedSize()
                                    }
                                }
                        }
                    }
                    ForEach(0..<7, id: \.self) { row in
                        GridRow {
                            Typo.fine(Text(weekdayLabels[row]))
                                .foregroundStyle(Color.shelfMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(width: Self.weekdayColumnWidth, alignment: .leading)
                            ForEach(Array(weeks.indices), id: \.self) { column in
                                if row < weeks[column].count {
                                    cellView(weeks[column][row], fills: fills)
                                } else {
                                    Color.clear.frame(width: cellSize, height: cellSize)
                                }
                            }
                        }
                    }
                }
                .frame(width: availableWidth, alignment: .leading)
                .clipped()
                .dynamicTypeSize(...Self.axisLabelSizeCap)
                // AX-1 (docs/design-review.md, Round 4): this grid was ~140 individual
                // VoiceOver stops (one per day cell, up to 20 weeks x 7 days) with no
                // summary — technically labelled but practically unusable for a blind
                // user. `.ignore` collapses the day cells (and the month/weekday axis
                // labels) out of the accessibility tree in favour of one summary
                // element; `.accessibilityChildren` below re-adds one stop per week
                // (~20, not ~140) so daily detail is still reachable without a full
                // sweep. An `AXChartDescriptor` audio graph was also considered per the
                // finding, but was skipped: per
                // developer.apple.com/documentation/accessibility/axnumericdataaxisdescriptor
                // and .../axcategoricaldataaxisdescriptor (checked via
                // scripts/appledoc.sh), there's no ready-made date axis descriptor —
                // ~140 sparse daily points would need a categorical x-axis keyed by
                // day-string, a separate `AXChartDescriptorRepresentable` type, and a
                // real VoiceOver/Audio Graph session to verify, none of which is
                // available in this pass. The summary + per-week children below cover
                // the finding's core ask (140 stops -> ~1 + ~20) without that risk.
                //
                // The summary is the *first synthetic child*, not the container's own
                // label/value: per developer.apple.com/documentation/swiftui/view/
                // accessibilitychildren(children:), an existing element that gets
                // `accessibilityChildren` is converted into a container, and VoiceOver on
                // iOS focuses a container's children rather than the container itself —
                // so a value set on the container would never be read.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(heatmapSummaryLabel)
                .accessibilityChildren {
                    Text(heatmapSummaryLabel)
                        .accessibilityValue(heatmapSummaryValue)
                    ForEach(Array(weeks.indices), id: \.self) { column in
                        weekAccessibilityElement(weeks[column])
                    }
                }
            }

            legendRow(fills: fills)
        }
        .onAppear { recompute() }
        .onChange(of: days) { _, _ in recompute() }
    }

    private func cellView(_ cell: ListeningHeatmap.Cell, fills: [Color]) -> some View {
        // Critique 2026-10-06 (layout): opaque, contrast-measured fills
        // (`ListeningHeatmap.levelFillHexes`). The HIG audit L12 accent stroke, a patch over
        // the old 30%-opacity first step, is gone: level 1 now clears 3:1 against empty.
        RoundedRectangle(cornerRadius: 3)
            .fill(fills[cell.level])
            .frame(width: cellSize, height: cellSize)
        // AX-1 (docs/design-review.md, Round 4): the per-cell `.accessibilityLabel` that
        // used to live here is redundant now — the enclosing grid is
        // `.accessibilityElement(children: .ignore)`, so individual cells are never
        // visited by VoiceOver. Day-level detail is exposed instead through the
        // per-week `.accessibilityChildren` built by `weekAccessibilityElement(_:)`.
    }

    /// Critique 2026-10-06 (layout): states each shade's minutes (from
    /// `ListeningHeatmap.thresholds`) instead of "Less … More". One row when it fits, two
    /// rows next, then a vertical list at large text sizes; nothing truncates.
    private func legendRow(fills: [Color]) -> some View {
        let labels = ListeningHeatmap.legendLabels
        func item(_ level: Int) -> some View {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(fills[level])
                    .frame(width: Self.legendSwatch, height: Self.legendSwatch)
                Typo.fine(Text(labels[level]))
                    .foregroundStyle(Color.shelfMuted)
                    .fixedSize()
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Typo.fine(Text("Minutes listened per day"))
                .foregroundStyle(Color.shelfMuted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.m) { ForEach(0..<labels.count, id: \.self) { item($0) } }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Space.m) { ForEach(0..<3, id: \.self) { item($0) } }
                    HStack(spacing: Space.m) { ForEach(3..<labels.count, id: \.self) { item($0) } }
                }
                VStack(alignment: .leading, spacing: 4) { ForEach(0..<labels.count, id: \.self) { item($0) } }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ListeningHeatmap.legendSpoken)
    }

    // MARK: - AX-1 accessibility summary (docs/design-review.md, Round 4)

    /// Total distinct days with any listening, across every week shown.
    private var totalActiveDays: Int {
        weeks.reduce(0) { $0 + $1.filter { $0.minutes > 0 }.count }
    }

    /// The single busiest day across every week shown, if any minutes were logged.
    private var busiestCell: ListeningHeatmap.Cell? {
        weeks.flatMap { $0 }.max(by: { $0.minutes < $1.minutes })
    }

    /// Label for the container and its summary child. Matches the actual number of weeks
    /// rendered (`weeks.count`) rather than the `weekCount` requested, in case a
    /// calendar edge case ever produces fewer columns.
    private var heatmapSummaryLabel: String {
        weeks.count == 1 ? String(localized: "Listening heatmap, last week") : String(localized: "Listening heatmap, last \(weeks.count) weeks", comment: "%lld is a number of weeks")
    }

    /// Value of the summary child (the first of `.accessibilityChildren`), e.g. "46 active days. Busiest day:
    /// 3 September, 142 minutes." Handles the no-listening-yet case explicitly.
    private var heatmapSummaryValue: String {
        let activeDays = totalActiveDays
        guard activeDays > 0, let busiest = busiestCell, busiest.minutes > 0 else {
            return String(localized: "No listening yet")
        }
        let dayText = activeDays == 1 ? String(localized: "1 active day") : String(localized: "\(activeDays) active days")
        let busiestDate = Self.accessibilityDateFormatter.string(from: busiest.date)
        return String(localized: "\(dayText). Busiest day: \(busiestDate), \(Int(busiest.minutes)) minutes.", comment: "VoiceOver heatmap summary: %1$@ is a count of active days, %2$@ is a date, %3$lld is minutes")
    }

    /// One synthetic, hidden-but-accessible element per week, supplied to
    /// `.accessibilityChildren`. `week.first` is the earliest day in the column (see
    /// `ListeningHeatmap.weeks`'s "Sun/Mon-first ... ending with the week containing
    /// today" doc comment), so it doubles as the week's start date.
    private func weekAccessibilityElement(_ week: [ListeningHeatmap.Cell]) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(weekAccessibilityLabel(week))
            .accessibilityValue(weekAccessibilityValue(week))
    }

    private func weekAccessibilityLabel(_ week: [ListeningHeatmap.Cell]) -> String {
        guard let start = week.first?.date else { return String(localized: "Week", comment: "VoiceOver: a week column of the heatmap") }
        return String(localized: "Week of \(Self.accessibilityDateFormatter.string(from: start))", comment: "VoiceOver: %@ is the week's start date")
    }

    /// e.g. "4 active days, 212 minutes. Busiest: Wednesday, 88 minutes."
    private func weekAccessibilityValue(_ week: [ListeningHeatmap.Cell]) -> String {
        let activeDays = week.filter { $0.minutes > 0 }.count
        guard activeDays > 0, let busiest = week.max(by: { $0.minutes < $1.minutes }), busiest.minutes > 0 else {
            return String(localized: "No listening this week")
        }
        let totalMinutes = Int(week.reduce(0) { $0 + $1.minutes })
        let dayText = activeDays == 1 ? String(localized: "1 active day") : String(localized: "\(activeDays) active days")
        let weekdayName = Self.accessibilityWeekdayFormatter.string(from: busiest.date)
        return String(localized: "\(dayText), \(totalMinutes) minutes. Busiest: \(weekdayName), \(Int(busiest.minutes)) minutes.", comment: "VoiceOver week summary: %1$@ is a count of active days, %2$lld total minutes, %3$@ a weekday name, %4$lld minutes on that day")
    }

    private func recompute() {
        let calendar = Calendar.current
        let computed = ListeningHeatmap.weeks(days: days ?? [:], weekCount: weekCount, today: Date(), calendar: calendar)
        weeks = computed
        monthLabels = ListeningHeatmap.monthLabels(for: computed, calendar: calendar)
        // Rows follow the calendar's first weekday (same order `weeks` uses); label every
        // other row so the column reads Mon / Wed / Fri style without crowding.
        let symbols = calendar.shortWeekdaySymbols
        weekdayLabels = (0..<7).map { row in
            row % 2 == 1 ? symbols[(calendar.firstWeekday - 1 + row) % 7] : ""
        }
    }
}
