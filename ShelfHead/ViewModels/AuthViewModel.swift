import Foundation
import SwiftUI

@Observable
final class AuthViewModel {
    var isAuthenticated = false
    var isLoading = false
    var errorMessage: String?
    var currentUser: User?
    var serverURL: String = ""
    var username: String = ""

    // Multi-server
    var accounts: [ServerAccount] = []
    var currentAccountId: String? { AccountStore.currentAccountId }

    func loadAccounts() async {
        accounts = await AccountStore.accounts()
    }

    /// Switches to a saved account by re-authenticating with its stored password.
    func switchAccount(_ account: ServerAccount) async {
        guard let password = await AccountStore.password(for: account) else {
            errorMessage = "No saved password for this server. Please add it again."
            return
        }
        AudioPlayerService.shared.stop()
        await login(serverURL: account.serverURL, username: account.username, password: password)
    }

    func removeAccount(_ account: ServerAccount) async {
        await AccountStore.remove(account)
        await loadAccounts()
    }

    func checkExistingSession() async {
        // No stored credentials → require login.
        guard let savedURL = try? await KeychainService.shared.get(.serverURL),
              let savedToken = try? await KeychainService.shared.get(.authToken) else {
            return
        }
        let savedRefresh: String? = try? await KeychainService.shared.get(.refreshToken)
        let savedUsername: String? = try? await KeychainService.shared.get(.username)

        // Seed the in-memory store; the API layer will auto-refresh on 401.
        await AudiobookshelfAPI.shared.configure(
            serverURL: savedURL,
            accessToken: savedToken,
            refreshToken: savedRefresh
        )
        serverURL = savedURL
        username = savedUsername ?? ""
        // Restore the session immediately from stored credentials so the app works
        // offline; only sign out if the server *actively rejects* us below.
        isAuthenticated = true

        do {
            let user = try await AudiobookshelfAPI.shared.getCurrentUser()
            currentUser = user
            username = user.username
        } catch APIError.unauthorized {
            // Token genuinely rejected (and refresh/re-auth failed) — require login.
            try? await KeychainService.shared.deleteAll()
            AuthStore.shared.clear()
            currentUser = nil
            isAuthenticated = false
        } catch {
            // Offline or a transient/server error — keep the restored session.
        }
    }

    func login(serverURL: String, username: String, password: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let cleanURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try await AudiobookshelfAPI.shared.login(
                serverURL: cleanURL,
                username: username,
                password: password
            )

            // The API layer already stored the server URL + tokens (AuthStore + Keychain).
            // Persist the remaining values, including the password for silent re-auth.
            try await KeychainService.shared.save(cleanURL, for: .serverURL)
            try await KeychainService.shared.save(username, for: .username)
            try await KeychainService.shared.save(password, for: .password)
            try await KeychainService.shared.save(response.user.id, for: .userId)

            // Remember this account for multi-server switching.
            await AccountStore.upsert(serverURL: cleanURL, username: username, password: password)
            await loadAccounts()

            currentUser = response.user
            self.serverURL = cleanURL
            self.username = username
            isAuthenticated = true
        } catch let error as APIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Connection failed. Please check the server URL and try again."
        }

        isLoading = false
    }

    func logout() async {
        AudioPlayerService.shared.stop()
        await AudiobookshelfAPI.shared.logout()
        try? await KeychainService.shared.deleteAll()
        AuthStore.shared.clear()
        currentUser = nil
        isAuthenticated = false
    }
}
