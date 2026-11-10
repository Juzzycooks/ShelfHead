import Foundation

enum PlaybackSpeed: Double, CaseIterable {
    case x0_5 = 0.5
    case x0_75 = 0.75
    case x1_0 = 1.0
    case x1_25 = 1.25
    case x1_5 = 1.5
    case x1_75 = 1.75
    case x2_0 = 2.0
    case x2_5 = 2.5
    case x3_0 = 3.0

    var label: String {
        if self == .x1_0 {
            return "1×"
        }
        let value = rawValue
        if value == value.rounded() {
            return "\(Int(value))×"
        }
        return "\(value)×"
    }
}

enum SleepTimerOption: Equatable {
    case off
    case minutes(Int)
    case endOfChapter
    /// End of the current chapter plus `n` additional chapters.
    case chapters(Int)
    /// Stop when the current book finishes (does not auto-advance the queue).
    case endOfBook

    var label: String {
        switch self {
        case .off:
            return String(localized: "Off", comment: "Sleep timer option: no timer")
        case .minutes(let mins):
            return String(localized: "\(mins) min", comment: "Sleep timer option. %lld is minutes")
        case .endOfChapter:
            return String(localized: "End of chapter", comment: "Sleep timer option: stop at the end of the current chapter")
        case .chapters(let n):
            return String(localized: "End of chapter +\(n)", comment: "Sleep timer option: stop after the current chapter plus %lld more chapters")
        case .endOfBook:
            return String(localized: "End of book", comment: "Sleep timer option: stop when the book finishes")
        }
    }

    static var presets: [SleepTimerOption] {
        [.off, .minutes(5), .minutes(10), .minutes(15), .minutes(30), .minutes(45), .minutes(60),
         .endOfChapter, .chapters(1), .chapters(2), .endOfBook]
    }

    /// The player's sleep menu, top level (critique 2026-10-05, distill): the four picks
    /// people actually reach for at bedtime. The chapter option is dropped for a book with
    /// no chapters, where it would be a silent no-op. Together with `menuMorePicks` this is
    /// every preset except `.off`, which the menu offers as "Turn Off" only while a timer
    /// runs. Pinned by `SleepTimerMenuTests`.
    static func menuQuickPicks(hasChapters: Bool) -> [SleepTimerOption] {
        [.minutes(15), .minutes(30), .minutes(60)] + (hasChapters ? [.endOfChapter] : [])
    }

    /// The rest of the presets, behind the menu's "More" submenu.
    static func menuMorePicks(hasChapters: Bool) -> [SleepTimerOption] {
        [.minutes(5), .minutes(10), .minutes(45)]
            + (hasChapters ? [.chapters(1), .chapters(2)] : [])
            + [.endOfBook]
    }
}
