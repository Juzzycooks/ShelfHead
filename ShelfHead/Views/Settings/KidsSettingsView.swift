import SwiftUI
import UIKit

/// Batch 457: Settings > Kids & Profiles (Batch 492: its own page; it was the bottom half of Household). An administrator makes a child's Audiobookshelf account (explicit content
/// off, only chosen libraries, an optional tag allowlist) and it is saved on this device without switching to it.
/// Like `TranscriptsSettingsView`, the body is a group of sections for the settings page to host.
struct KidsSettingsView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @AppStorage(SettingsKeys.showProfilePickerAtLaunch) private var showPickerAtLaunch = false

    @State private var showAddChild = false
    @State private var kidToRemove: ServerAccount?
    @State private var removalMessage: String?
    @State private var refreshToken = 0

    private var store: KidProfileStore { .standard }
    private var isAdmin: Bool { authViewModel.currentUser?.isAdmin == true }
    private var kidAccounts: [ServerAccount] { authViewModel.accounts.filter { store.isKid($0.id) } }

    var body: some View {
        Group {
            Section {
                if isAdmin {
                    Button { showAddChild = true } label: {
                        settingRow("person.crop.circle.badge.plus", "Add a Child")
                    }
                    SettingsCaption(text: "Makes a limited account on your Audiobookshelf server and saves it on this iPhone. Explicit content is off, and the child only sees the libraries you pick.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        settingRow("lock.fill", "Add a Child")
                        SettingsCaption(text: "Only a server administrator can create a child’s account.")
                    }
                }
            } header: {
                RetroSectionHeader(title: "Kids")
            }
            .listRowBackground(Color.shelfCard)

            if !kidAccounts.isEmpty {
                Section {
                    ForEach(kidAccounts) { account in
                        kidRow(account)
                    }
                } header: {
                    RetroSectionHeader(title: "Children on this iPhone")
                }
                .listRowBackground(Color.shelfCard)
                .id(refreshToken)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $showPickerAtLaunch) {
                        settingRow("person.2.crop.square.stack.fill", "Show profile picker at launch")
                    }
                    SettingsCaption(text: "Opens on big picture tiles, one for each saved account. Going from a child’s account to a grown-up’s asks for Face ID or your passcode.")
                }
            } header: {
                // Batch 490 (REVIEW 2026-11-11 V4): was the page's one header-less section.
                RetroSectionHeader(title: "Profile Picker")
            }
            .listRowBackground(Color.shelfCard)
        }
        .sheet(isPresented: $showAddChild) {
            AddChildSheet { refreshToken += 1 }
                .environment(authViewModel)
        }
        .confirmationDialog(
            Text("Remove this child?"),
            isPresented: Binding(get: { kidToRemove != nil }, set: { if !$0 { kidToRemove = nil } }),
            titleVisibility: .visible,
            presenting: kidToRemove
        ) { account in
            Button("Remove from this iPhone", role: .destructive) { remove(account, alsoOnServer: false) }
            if canDeleteOnServer(account) {
                Button("Remove and delete the server account", role: .destructive) { remove(account, alsoOnServer: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Their listening history stays on the server unless you delete the account there too.")
        }
        // Batch 490 (REVIEW 2026-11-11 V3): label-coloured dialog buttons, as everywhere else.
        .systemChromeTint()
        .alert(Text("Couldn’t delete"), isPresented: Binding(get: { removalMessage != nil }, set: { if !$0 { removalMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: removalMessage ?? "")
        }
        .systemChromeTint()
    }

    private func kidRow(_ account: ServerAccount) -> some View {
        let profile = store.profile(for: account.id) ?? KidProfile(accountId: account.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                KidAvatarView(symbol: profile.symbol, colorIndex: profile.colorIndex, size: 44)
                // Batch 490 (REVIEW 2026-11-11 V4): type roles and tokens, not system styles.
                VStack(alignment: .leading, spacing: 2) {
                    Typo.rowTitle(Text(verbatim: account.username))
                        .foregroundStyle(Color.shelfCream)
                    Typo.rowSubtitle(Text(verbatim: account.displayHost))
                        .foregroundStyle(Color.shelfMuted)
                }
                Spacer()
                Button(role: .destructive) { kidToRemove = account } label: {
                    Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Remove \(account.username)"))
            }
            Toggle(isOn: Binding(
                get: { profile.usesBedtimeStory },
                set: { value in
                    var updated = profile
                    updated.usesBedtimeStory = value
                    store.set(updated)
                    refreshToken += 1
                }
            )) {
                Text("Use Bedtime Story for this child")
                    .foregroundStyle(Color.shelfCream)
            }
        }
        .padding(.vertical, 4)
    }

    private func canDeleteOnServer(_ account: ServerAccount) -> Bool {
        isAdmin && account.serverURL == authViewModel.serverURL
    }

    private func remove(_ account: ServerAccount, alsoOnServer: Bool) {
        Task {
            if alsoOnServer {
                do {
                    let users = try await AudiobookshelfAPI.shared.listUsers()
                    if let match = users.first(where: { $0.username == account.username }) {
                        try await AudiobookshelfAPI.shared.deleteUser(id: match.id)
                    }
                } catch {
                    // Polish pass (ST-5): friendly sentence; the raw error goes to the log.
                    ShelfLog.error(.network, "Couldn't delete the child account on the server: \(error.localizedDescription)")
                    removalMessage = String(localized: "The account couldn\u{2019}t be deleted from your server. Check your connection and try again.")
                    return
                }
            }
            await authViewModel.removeAccount(account)
            store.remove(accountId: account.id)
            refreshToken += 1
        }
    }
}

/// Batch 457: a round picture tile for a child (or a grown-up, with the person glyph).
struct KidAvatarView: View {
    let symbol: String
    let colorIndex: Int
    var size: CGFloat = 56

    var body: some View {
        let fill = Color(hex: KidAvatar.colorHexes[KidAvatar.clampedColorIndex(colorIndex)])
        ZStack {
            Circle().fill(fill)
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                // Batch 490 (REVIEW 2026-11-11 A2): white measured under 3:1 on the yellow,
                // orange and green fills; the shared contrast helper picks the ink that wins.
                .foregroundStyle(CoverPalette.ink(on: fill))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Batch 457: the Add a Child form. The password is generated and shown once (copyable); the account is created on
/// the server first, then saved here as a `ServerAccount` without switching to it.
private struct AddChildSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel
    var onCreated: () -> Void

    @State private var name = ""
    @State private var password = KidPasswordGenerator.make()
    @State private var libraries: [Library] = []
    @State private var selectedLibraryIds: Set<String> = []
    @State private var availableTags: [String] = []
    @State private var selectedTags: Set<String> = []
    @State private var allowDownloads = true
    @State private var useBedtimeStory = true
    @State private var symbol = KidAvatar.symbols[0]
    @State private var colorIndex = 0
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var createdPassword: String?
    @State private var copied = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !trimmedName.isEmpty && !selectedLibraryIds.isEmpty && !isWorking }

    var body: some View {
        NavigationStack {
            Form {
                if let createdPassword {
                    doneSection(createdPassword)
                } else {
                    formSections
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground)
            .navigationTitle(Text("Add a Child"))
            .navigationBarTitleDisplayMode(.inline)
            // Batch 490 (REVIEW 2026-11-11 V1): the shared sheet buttons. After creation, swipe
            // to dismiss is off, so the close button is its own always-placed item rather than
            // conditional content inside one.
            .toolbar {
                if createdPassword == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetCancelButton { dismiss() }
                            .monochromeToolbarItem()
                    }
                    .shelfVisibilityPriority(.high)
                    ToolbarItem(placement: .confirmationAction) {
                        SheetConfirmButton(title: "Create") { Task { await create() } }
                            .disabled(!canCreate)
                    }
                    .shelfVisibilityPriority(.high)
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        SheetCloseButton { dismiss() }
                            .monochromeToolbarItem()
                    }
                    .shelfVisibilityPriority(.high)
                }
            }
            .task { await loadLibraries() }
            .onChange(of: selectedLibraryIds) { _, _ in Task { await loadTags() } }
            .interactiveDismissDisabled(createdPassword != nil)
        }
    }

    @ViewBuilder private var formSections: some View {
        Section {
            TextField("Name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Text("Password")
                Spacer()
                Text(verbatim: password).font(.body.monospaced()).textSelection(.enabled)
                Button { password = KidPasswordGenerator.make() } label: {
                    Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("New password"))
            }
        } footer: {
            formFooter("The name is the child’s sign-in name on the server. The password is shown once more when you finish.")
        }
        // Batch 490 (REVIEW 2026-11-11 V4): card rows, retro headers and token footers,
        // like the Settings pages behind this sheet.
        .listRowBackground(Color.shelfCard)

        Section {
            avatarPicker
        } header: {
            RetroSectionHeader(title: "Picture")
        }
        .listRowBackground(Color.shelfCard)

        Section {
            ForEach(libraries) { library in
                Toggle(isOn: binding(for: library.id, in: $selectedLibraryIds)) {
                    Text(verbatim: library.name)
                }
            }
            if libraries.isEmpty { ProgressView().frame(maxWidth: .infinity) }
        } header: {
            RetroSectionHeader(title: "Libraries")
        } footer: {
            formFooter("The child can only see the libraries you tick. Explicit content is always off.")
        }
        .listRowBackground(Color.shelfCard)

        if !availableTags.isEmpty {
            Section {
                ForEach(availableTags, id: \.self) { tag in
                    Toggle(isOn: binding(for: tag, in: $selectedTags)) { Text(verbatim: tag) }
                }
            } header: {
                RetroSectionHeader(title: "Only show these tags")
            } footer: {
                formFooter("Leave all off to allow every tag. Ticking some limits the child to books carrying one of them.")
            }
            .listRowBackground(Color.shelfCard)
        }

        Section {
            Toggle("Allow downloads", isOn: $allowDownloads)
            Toggle("Use Bedtime Story for this child", isOn: $useBedtimeStory)
        } footer: {
            formFooter("Bedtime Story stops at the end of the chapter and doesn’t play on to the next book.")
        }
        .listRowBackground(Color.shelfCard)

        if let errorText {
            // Batch 490 (REVIEW 2026-11-11 V4): DESIGN.md orange rule, orange glyph beside a
            // cream sentence (was red text).
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.shelfOrange)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Typo.supporting(Text(verbatim: errorText))
                        .foregroundStyle(Color.shelfCream)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.shelfCard)
        }
    }

    private func formFooter(_ text: LocalizedStringResource) -> some View {
        Typo.supporting(Text(text))
            .foregroundStyle(Color.shelfMuted)
    }

    private var avatarPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 10)], spacing: 10) {
                ForEach(KidAvatar.symbols, id: \.self) { candidate in
                    Button { symbol = candidate } label: {
                        KidAvatarView(symbol: candidate, colorIndex: colorIndex, size: 48)
                            // Batch 490 (REVIEW 2026-11-11 V4): the label-colour token, not `.primary`.
                            .overlay(Circle().stroke(Color.shelfCream, lineWidth: symbol == candidate ? 3 : 0))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    // Batch 490 (REVIEW 2026-11-11 A2): a name, not "teddybear.fill".
                    .accessibilityLabel(Text(verbatim: KidAvatar.name(forSymbol: candidate)))
                    .accessibilityAddTraits(symbol == candidate ? .isSelected : [])
                }
            }
            // Batch 490 (REVIEW 2026-11-11 A2): 44 pt wide targets (were 36). Eight of them
            // don't fit one row on a small phone, so they wrap in a grid like the pictures.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                ForEach(Array(KidAvatar.colorHexes.enumerated()), id: \.offset) { index, hex in
                    Button { colorIndex = index } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.shelfCream, lineWidth: colorIndex == index ? 3 : 0).padding(-4))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(verbatim: KidAvatar.name(forColorIndex: index)))
                    .accessibilityAddTraits(colorIndex == index ? .isSelected : [])
                }
            }
        }
    }

    private func doneSection(_ password: String) -> some View {
        Section {
            HStack(spacing: 12) {
                KidAvatarView(symbol: symbol, colorIndex: colorIndex, size: 56)
                Typo.rowTitle(Text(verbatim: trimmedName))
                    .foregroundStyle(Color.shelfCream)
            }
            HStack {
                Text(verbatim: password).font(.title3.monospaced()).textSelection(.enabled)
                Spacer()
                Button {
                    UIPasteboard.general.string = password
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        } header: {
            RetroSectionHeader(title: "Account created")
        } footer: {
            formFooter("This password is shown only now. The child’s account is already saved on this iPhone; switch to it with the profile button at the top of Home.")
        }
        .listRowBackground(Color.shelfCard)
    }

    private func binding(for value: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) },
                set: { on in if on { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } })
    }

    private func loadLibraries() async {
        guard libraries.isEmpty else { return }
        do { libraries = try await AudiobookshelfAPI.shared.getLibraries() }
        catch {
            // Polish pass (ST-5)
            ShelfLog.error(.network, "Couldn't load libraries for the child account form: \(error.localizedDescription)")
            errorText = String(localized: "Couldn\u{2019}t load your libraries. Check your connection and try again.")
        }
    }

    /// Tags found in the selected libraries (`/api/libraries/:id?include=filterdata`).
    private func loadTags() async {
        var tags = Set<String>()
        for id in selectedLibraryIds {
            if let data = try? await AudiobookshelfAPI.shared.getFilterData(libraryId: id) {
                tags.formUnion(data.tags ?? [])
            }
        }
        availableTags = tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        selectedTags.formIntersection(tags)
    }

    private func create() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        let body = ABSUserBody.child(username: trimmedName, password: password,
                                     libraryIds: libraries.map(\.id).filter(selectedLibraryIds.contains),
                                     tags: selectedTags.sorted(), allowDownloads: allowDownloads)
        do {
            _ = try await AudiobookshelfAPI.shared.createUser(body)
        } catch {
            // Polish pass (ST-5)
            ShelfLog.error(.network, "Couldn't create the child account: \(error.localizedDescription)")
            errorText = String(localized: "Couldn\u{2019}t create the account. Check your connection and that the username isn\u{2019}t already taken, then try again.")
            return
        }
        // Save it on this device without making it the signed-in account: upsert marks the new account
        // current, so put the parent's back.
        let previous = AccountStore.currentAccountId
        let current = authViewModel.accounts.first { $0.id == previous }
        let outcome = await AccountStore.upsert(serverURL: authViewModel.serverURL, username: trimmedName,
                                                password: password, customHeaders: current?.customHeaders,
                                                acknowledgedInsecureConnection: current?.insecureConnectionAcknowledged)
        if let previous { AccountStore.setCurrent(previous) }
        KidProfileStore.standard.set(KidProfile(accountId: outcome.account.id, symbol: symbol,
                                                colorIndex: colorIndex, usesBedtimeStory: useBedtimeStory))
        await authViewModel.loadAccounts()
        onCreated()
        createdPassword = password
    }
}
