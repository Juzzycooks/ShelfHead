import Foundation

/// Batch 457: what this device knows about a child's saved account. Audiobookshelf has no avatars, time limits or
/// parent links, so the picture, colour and the "use Bedtime Story" choice live only here, in UserDefaults, keyed by
/// the saved account's id. Restrictions themselves (libraries, tags, explicit content) are enforced by the server.
nonisolated struct KidProfile: Codable, Equatable {
    var accountId: String
    var symbol: String
    var colorIndex: Int
    /// A parent's choice, on by default for a new child. Applies the Bedtime Story listening profile when the
    /// account is switched to.
    var usesBedtimeStory: Bool

    init(accountId: String, symbol: String = KidAvatar.symbols[0], colorIndex: Int = 0, usesBedtimeStory: Bool = true) {
        self.accountId = accountId
        self.symbol = symbol
        self.colorIndex = colorIndex
        self.usesBedtimeStory = usesBedtimeStory
    }
}

/// Batch 457: avatar choices for the profile picker. Colours are hex strings (identity colours a child picks, not
/// interface accents), resolved with `Color(hex:)` by the views.
nonisolated enum KidAvatar {
    static let symbols = ["teddybear.fill", "star.fill", "moon.stars.fill", "pawprint.fill", "rocket.fill",
                          "fish.fill", "tortoise.fill", "bird.fill", "leaf.fill", "sparkles",
                          "crown.fill", "balloon.fill"]
    static let colorHexes = ["E5604D", "F2A23C", "E8C547", "5DAE6B", "3FA7A0", "4C8DDB", "8A6FD1", "D96FA8"]
    static let adultSymbol = "person.crop.circle.fill"

    /// A stable colour for an account that has no stored choice (an adult), from its id.
    static func defaultColorIndex(for accountId: String) -> Int {
        accountId.utf8.reduce(0) { ($0 &+ Int($1)) % colorHexes.count } % colorHexes.count
    }

    static func clampedColorIndex(_ index: Int) -> Int {
        guard !colorHexes.isEmpty else { return 0 }
        return min(max(index, 0), colorHexes.count - 1)
    }
}

/// Batch 457: the per-account kid flag store. A value type over an injectable `UserDefaults` so tests use a
/// throwaway suite; `.standard` is what the app uses. One JSON dictionary, accountId to profile.
nonisolated struct KidProfileStore {
    static let storageKey = "settings_kidProfiles"
    static let standard = KidProfileStore(defaults: .standard)

    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func all() -> [String: KidProfile] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let map = try? JSONDecoder().decode([String: KidProfile].self, from: data) else { return [:] }
        return map
    }

    func profile(for accountId: String?) -> KidProfile? {
        guard let accountId else { return nil }
        return all()[accountId]
    }

    func isKid(_ accountId: String?) -> Bool { profile(for: accountId) != nil }

    var hasAnyKid: Bool { !all().isEmpty }

    func set(_ profile: KidProfile) {
        var map = all()
        map[profile.accountId] = profile
        write(map)
    }

    func remove(accountId: String) {
        var map = all()
        map[accountId] = nil
        write(map)
    }

    private func write(_ map: [String: KidProfile]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

extension SettingsKeys {
    /// Batch 457: show the picture picker at launch. Off by default.
    static let showProfilePickerAtLaunch = "settings_showProfilePickerAtLaunch"
}

extension SettingsStore {
    static var showProfilePickerAtLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.showProfilePickerAtLaunch) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.showProfilePickerAtLaunch) }
    }
}
