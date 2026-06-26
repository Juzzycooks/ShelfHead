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

    var label: String {
        switch self {
        case .off:
            return "Off"
        case .minutes(let mins):
            return "\(mins) min"
        case .endOfChapter:
            return "End of chapter"
        }
    }

    static var presets: [SleepTimerOption] {
        [.off, .minutes(5), .minutes(10), .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter]
    }
}

enum PlayerDisplayMode {
    case mini
    case full
}
