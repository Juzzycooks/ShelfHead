import SwiftUI

struct StatsView: View {
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var stats: ListeningStats?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if isLoading {
                LoadingView("Loading stats…")
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack(spacing: 12) {
                            statCard(title: "Total Listened", value: formatHours(stats?.totalTime ?? 0), icon: "headphones")
                            statCard(title: "Today", value: formatHours(stats?.today ?? 0), icon: "clock")
                        }
                        HStack(spacing: 12) {
                            statCard(title: "Day Streak", value: "\(currentStreak)", icon: "flame.fill")
                            statCard(title: "Books Finished", value: "\(libraryViewModel.finishedBooksCount)", icon: "checkmark.seal.fill")
                        }

                        if !last7Days.isEmpty {
                            weeklyChart
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Listening Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            stats = try? await AudiobookshelfAPI.shared.getListeningStats()
            if libraryViewModel.finishedBooksCount == 0 {
                await libraryViewModel.loadUserProgress()
            }
            isLoading = false
        }
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(Color.shelfAmber)
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundColor(.white)
            Text(title)
                .font(.caption)
                .foregroundColor(Color.shelfMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.shelfCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Weekly chart

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LAST 7 DAYS")
                .font(.caption.weight(.bold))
                .foregroundColor(Color.shelfMuted)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(last7Days, id: \.label) { day in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.shelfAmber)
                            .frame(height: max(4, CGFloat(day.seconds / maxDaySeconds) * 120))
                        Text(day.label)
                            .font(.system(size: 9))
                            .foregroundColor(Color.shelfMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 150, alignment: .bottom)
        }
        .padding(16)
        .background(Color.shelfCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Derived data

    private struct DayValue { let label: String; let seconds: Double }

    private var last7Days: [DayValue] {
        guard let days = stats?.days else { return [] }
        let keyFormatter = DateFormatter()
        keyFormatter.dateFormat = "yyyy-MM-dd"
        let labelFormatter = DateFormatter()
        labelFormatter.dateFormat = "EEE"

        return (0..<7).reversed().map { offset in
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let seconds = days[keyFormatter.string(from: date)] ?? 0
            return DayValue(label: labelFormatter.string(from: date), seconds: seconds)
        }
    }

    private var maxDaySeconds: Double {
        max(1, last7Days.map(\.seconds).max() ?? 1)
    }

    private var currentStreak: Int {
        guard let days = stats?.days else { return 0 }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var streak = 0
        var date = Date()
        // Grace: if nothing logged today yet, start counting from yesterday.
        if (days[formatter.string(from: date)] ?? 0) <= 0 {
            date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
        }
        while (days[formatter.string(from: date)] ?? 0) > 0 {
            streak += 1
            date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
        }
        return streak
    }

    private func formatHours(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
