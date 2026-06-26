import Foundation

/// A saved server account for multi-server switching. The password is stored
/// separately in the Keychain (keyed by `passwordKey`), never in this struct.
struct ServerAccount: Codable, Identifiable, Equatable {
    let id: String
    let serverURL: String
    let username: String

    init(id: String = UUID().uuidString, serverURL: String, username: String) {
        self.id = id
        self.serverURL = serverURL
        self.username = username
    }

    var passwordKey: String { "account_pwd_\(id)" }

    var displayHost: String {
        URL(string: serverURL)?.host ?? serverURL
    }
}

/// Persists the list of saved accounts (in the Keychain) and their passwords.
enum AccountStore {
    private static let currentAccountKey = "shelfhead_currentAccountId"

    static func accounts() async -> [ServerAccount] {
        guard let json = try? await KeychainService.shared.get(.accounts),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([ServerAccount].self, from: data) else {
            return []
        }
        return list
    }

    /// Adds or updates an account (matched by serverURL + username) and stores its password.
    @discardableResult
    static func upsert(serverURL: String, username: String, password: String) async -> ServerAccount {
        var list = await accounts()
        let existing = list.first { $0.serverURL == serverURL && $0.username == username }
        let account = existing ?? ServerAccount(serverURL: serverURL, username: username)
        if existing == nil { list.append(account) }

        try? await KeychainService.shared.save(password, account: account.passwordKey)
        await save(list)
        setCurrent(account.id)
        return account
    }

    static func remove(_ account: ServerAccount) async {
        var list = await accounts()
        list.removeAll { $0.id == account.id }
        try? await KeychainService.shared.delete(account: account.passwordKey)
        await save(list)
    }

    static func password(for account: ServerAccount) async -> String? {
        (try? await KeychainService.shared.get(account: account.passwordKey)) ?? nil
    }

    static var currentAccountId: String? {
        UserDefaults.standard.string(forKey: currentAccountKey)
    }

    static func setCurrent(_ id: String) {
        UserDefaults.standard.set(id, forKey: currentAccountKey)
    }

    private static func save(_ list: [ServerAccount]) async {
        if let data = try? JSONEncoder().encode(list), let json = String(data: data, encoding: .utf8) {
            try? await KeychainService.shared.save(json, for: .accounts)
        }
    }
}
