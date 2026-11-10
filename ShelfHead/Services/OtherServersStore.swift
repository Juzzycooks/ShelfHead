import Foundation

/// Backs the Home "On Other Servers" shelf and its See-all screen: for every saved
/// account other than the one currently signed in, tries to fetch that server's
/// in-progress books through a private, non-persisting `AudiobookshelfAPI` client so
/// browsing another server never disturbs the primary account's session, Keychain
/// entries, or `AuthStore.shared`. Playback, downloads and the Library tab stay
/// single-account by design — this store only ever reads a lightweight in-progress
/// list to surface elsewhere, and switching servers goes through the existing
/// `AuthViewModel.switchAccount`.
@MainActor
@Observable
final class OtherServersStore {
    static let shared = OtherServersStore()

    enum State: Equatable {
        case loading
        case ready
        case needsSignIn
        case failed(String)
    }

    struct ServerShelf: Identifiable {
        let account: ServerAccount
        var id: String { account.id }
        var items: [LibraryItem] = []
        /// Nil for a `.needsSignIn` shelf — there's no session to fetch a cover with.
        var client: AudiobookshelfAPI?
        var state: State = .loading
    }

    var shelves: [ServerShelf] = []
    var isLoading = false
    var lastRefresh: Date?

    /// `.ready` shelves' items only, interleaved round-robin across servers so one
    /// prolific server doesn't crowd the other(s) out of the shelf's visible head.
    var mergedItems: [(account: ServerAccount, item: LibraryItem)] {
        let lists = shelves
            .filter { $0.state == .ready }
            .map { shelf in shelf.items.map { (account: shelf.account, item: $0) } }
        return Self.interleave(lists)
    }

    /// Cover bytes, memoised per `"<shelfId>/<itemId>"`. Capped at a small size — this
    /// is a "few servers, a dozen items each" cache, not a general-purpose one — and
    /// simply dropped in full when the cap is hit rather than evicting individually.
    private var coverCache: [String: Data] = [:]
    private let coverCacheLimit = 60
    /// Review 3 Medium 9: bumped by every refresh start and every reset, so an older pass can tell it was superseded.
    private var generation = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: .shelfheadAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reset()
                await self?.refresh(currentAccountId: AccountStore.currentAccountId, force: true)
            }
        }
    }

    /// Also ends the private clients' server sessions — each `login()` creates an auth
    /// session on that server (visible in its Active Sessions list), so dropping a client
    /// without `logout()` would leave one behind per refresh.
    func reset() {
        generation += 1
        let clients = shelves.compactMap(\.client)
        shelves = []
        lastRefresh = nil
        for client in clients {
            Task { await client.logout() }
        }
    }

    /// Refreshes every other saved account's in-progress shelf. Skips the whole pass if
    /// it last ran under 5 minutes ago, unless `force`. A plain serial loop rather than
    /// a `withTaskGroup` — accounts are few, and it keeps `LibraryItem`/`AudiobookshelfAPI`
    /// from having to cross a task-group boundary under `targeted` concurrency checking,
    /// the same reasoning `AudiobookQuery.entities(matching:)` uses in `PlaybackIntents.swift`.
    func refresh(currentAccountId: String?, force: Bool = false) async {
        // Review 2 Medium 11 (30 October 2026): a child's session never logs in to other servers.
        if KidProfileStore.standard.isKid(AccountStore.currentAccountId) {
            let old = shelves.compactMap(\.client)   // Review 4 Low (stray sessions)
            shelves = []
            for client in old { Task { await client.logout() } }
            return
        }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 300 { return }
        // Review 3 Medium 9: remember who and which pass this is; re-check after every await.
        generation += 1
        let myGeneration = generation
        let startAccountId = AccountStore.currentAccountId
        func isStale() -> Bool {
            Self.isStaleRefresh(startAccountId: startAccountId, currentAccountId: AccountStore.currentAccountId,
                                startGeneration: myGeneration, currentGeneration: generation,
                                isKidNow: KidProfileStore.standard.isKid(AccountStore.currentAccountId))
        }
        let accounts = await AccountStore.accounts().filter { $0.id != currentAccountId }
        if isStale() { return }
        guard !accounts.isEmpty else {
            let old = shelves.compactMap(\.client)   // Review 4 Low (stray sessions)
            shelves = []
            for client in old { Task { await client.logout() } }
            lastRefresh = Date()
            return
        }

        isLoading = true
        var result: [ServerShelf] = []
        var created: [AudiobookshelfAPI] = []   // clients this pass logged in, to log out if discarded
        for account in accounts {
            if isStale() { break }
            guard let password = await AccountStore.password(for: account), !password.isEmpty else {
                result.append(ServerShelf(account: account, client: nil, state: .needsSignIn))
                continue
            }
            // Reuse the client from the previous refresh when it's still signed in, so a
            // periodic refresh doesn't open a fresh auth session on that server every time;
            // the 401 → refresh-token path inside the client covers an expired access token.
            if let existing = shelves.first(where: { $0.id == account.id })?.client, await existing.isConfigured,
               let items = try? await existing.getItemsInProgress(limit: 12) {
                result.append(ServerShelf(account: account, items: items, client: existing, state: .ready))
                continue
            }
            let client = AudiobookshelfAPI(store: AuthStore(), persistsCredentials: false)
            // Review Low (Accounts, 30 October 2026): the main app asks for a one-time
            // acknowledgement before plain HTTP to a non-local host; this background login
            // never did. Refuse unless that account was already acknowledged.
            if Self.shouldRefusePlainHTTP(serverURL: account.serverURL, acknowledged: account.hasAcknowledgedInsecureConnection) {
                result.append(ServerShelf(account: account, state: .failed(
                    String(localized: "This server uses an unencrypted connection that hasn't been approved. Switch to it once to review the warning."))))
                continue
            }
            do {
                created.append(client)
                _ = try await client.login(serverURL: account.serverURL, username: account.username,
                                            password: password, customHeaders: account.customHeaders ?? [:])
                let items = try await client.getItemsInProgress(limit: 12)
                result.append(ServerShelf(account: account, items: items, client: client, state: .ready))
            } catch {
                result.append(ServerShelf(account: account, client: client, state: .failed(error.localizedDescription)))
            }
        }
        if isStale() {
            for client in created { Task { await client.logout() } }
            // Only the newest pass owns the loading flag.
            if myGeneration == generation { isLoading = false }
            return
        }
        // Review 4 Low (stray sessions): log out old clients the new result doesn't carry
        // (a failed reuse got a fresh client; a removed account's shelf is gone).
        let kept = Set(result.compactMap { $0.client }.map { ObjectIdentifier($0) })
        let replaced = shelves.compactMap(\.client).filter { !kept.contains(ObjectIdentifier($0)) }
        shelves = result
        for client in replaced { Task { await client.logout() } }
        isLoading = false
        lastRefresh = Date()
    }

    /// Review 3 Medium 9: true when a refresh's result must be dropped (account changed, a newer
    /// refresh/reset began, or the account is now a kid's).
    nonisolated static func isStaleRefresh(startAccountId: String?, currentAccountId: String?,
                                           startGeneration: Int, currentGeneration: Int, isKidNow: Bool) -> Bool {
        startAccountId != currentAccountId || startGeneration != currentGeneration || isKidNow
    }

    func coverData(for item: LibraryItem, from shelf: ServerShelf) async -> Data? {
        let key = "\(shelf.id)/\(item.id)"
        if let cached = coverCache[key] { return cached }
        guard let client = shelf.client,
              let url = URL(string: "\(shelf.account.serverURL)/api/items/\(item.id)/cover?width=300") else { return nil }
        var fetched = try? await client.authorizedData(for: url)
        // Review 5 Low (Other Servers cover): the captured client may have been replaced meanwhile.
        if fetched == nil, let current = shelves.first(where: { $0.id == shelf.id })?.client, current !== client {
            fetched = try? await current.authorizedData(for: url)
        }
        guard let data = fetched else { return nil }
        if coverCache.count >= coverCacheLimit { coverCache.removeAll() }
        coverCache[key] = data
        return data
    }

    /// True when `serverURL` is plain HTTP to a non-local host and the user never
    /// acknowledged that for this account (the main app's `requiresInsecureConnectionConfirmation` rule).
    nonisolated static func shouldRefusePlainHTTP(serverURL: String, acknowledged: Bool) -> Bool {
        !acknowledged && ServerURLRules.requiresInsecureConnectionConfirmation(for: serverURL)
    }

    /// Round-robins `n` lists into one: index 0 of every list, then index 1, and so on,
    /// skipping any list once it runs out. Pure and `nonisolated` so it's directly
    /// testable without the actor/`@MainActor` machinery around it.
    nonisolated static func interleave<T>(_ lists: [[T]]) -> [T] {
        guard !lists.isEmpty else { return [] }
        var out: [T] = []
        let maxCount = lists.map(\.count).max() ?? 0
        for index in 0..<maxCount {
            for list in lists where index < list.count {
                out.append(list[index])
            }
        }
        return out
    }
}
