import SwiftUI

/// Batch 422 (transcription foundation): the Transcripts page. On-device speech-to-text
/// of downloaded books (`TranscriptionCenter`, iOS 26+), kept on this iPhone. Below iOS 26
/// the page is the explanation plus the unsupported status only: no toggles that do nothing.
struct TranscriptsSettingsView: View {
    @AppStorage(SettingsKeys.transcriptsEnabled) private var transcriptsEnabled = true
    @AppStorage(SettingsKeys.transcribeWhileCharging) private var transcribeWhileCharging = true
    @AppStorage(SettingsKeys.transcriptDefaultLanguage) private var defaultLanguage = ""
    /// Batch 433: narrator "Previously On…" montage options.
    @AppStorage(SettingsKeys.recapSpokenLinks) private var recapSpokenLinks = false
    @AppStorage(SettingsKeys.recapAutoPlay) private var recapAutoPlay = false
    /// Batch 425: "" = off, else a language identifier like "zh-Hans" or "fr".
    @AppStorage(SettingsKeys.captionTranslationLanguage) private var captionTranslation = ""

    @State private var center = TranscriptionCenter.shared
    @State private var intelligence = BookIntelligence.shared
    @State private var locales: [Locale] = []
    @State private var translationTargets: [String] = []
    @State private var confirmDeleteAll = false

    private var isSupportedOS: Bool { center.isSupportedOS }

    var body: some View {
        Group {
            Section {
                if isSupportedOS {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $transcriptsEnabled) {
                            settingRow("text.quote", "Book transcripts")
                        }
                        SettingsCaption(text: "Transcripts are made on this iPhone from downloaded books and never leave the device. They power search, captions and more.")
                    }
                    .settingsRowAnchor(SettingsRow.transcriptsEnabled)
                } else {
                    // Below iOS 26 there is nothing to switch: explanation + status only.
                    VStack(alignment: .leading, spacing: 6) {
                        settingRow("text.quote", "Book transcripts")
                        SettingsCaption(text: "Transcripts are made on this iPhone from downloaded books and never leave the device. They power search, captions and more.")
                    }
                    .settingsRowAnchor(SettingsRow.transcriptsEnabled)
                }

                statusRow
            } header: {
                RetroSectionHeader(title: "Transcripts")
            }
            .listRowBackground(Color.shelfCard)

            if isSupportedOS {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $transcribeWhileCharging) {
                            settingRow("bolt.fill", "Transcribe while charging")
                        }
                        SettingsCaption(text: "Runs overnight, only on power. Skipped in Low Power Mode or when the phone is hot.")
                    }
                    .disabled(!transcriptsEnabled)
                    .settingsRowAnchor(SettingsRow.transcribeWhileCharging)

                    VStack(alignment: .leading, spacing: 6) {
                        SettingsControlRow(icon: "globe", title: "Language") {
                            Picker("Language", selection: $defaultLanguage) {
                                Text("Match the book").tag("")
                                ForEach(languageOptions, id: \.identifier) { option in
                                    Text(verbatim: option.name).tag(option.identifier)
                                }
                            }
                            .labelsHidden()
                            .tint(Color.shelfAmberText)
                        }
                        SettingsCaption(text: "Used when a book doesn’t say which language it is in. A single book can override this from its page.")
                    }
                    .disabled(!transcriptsEnabled)
                    .settingsRowAnchor(SettingsRow.transcriptLanguage)

                    // Batch 425: Translation framework is iOS 18+; hidden below that.
                    if #available(iOS 18.0, *) {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsControlRow(icon: "translate", title: "Translate captions") {
                                Picker("Translate captions", selection: $captionTranslation) {
                                    Text("Off").tag("")
                                    ForEach(translationOptions, id: \.identifier) { option in
                                        Text(verbatim: option.name).tag(option.identifier)
                                    }
                                }
                                .labelsHidden()
                                .tint(Color.shelfAmberText)
                            }
                            SettingsCaption(text: "Captions can show a translation under each line, made on this iPhone. Turn captions on from the player’s menu.")
                        }
                        .disabled(!transcriptsEnabled)
                    }
                } header: {
                    RetroSectionHeader(title: "Options")
                }
                .listRowBackground(Color.shelfCard)

                // Batch 428: recaps and "I Zoned Out" need Apple Intelligence on top of a transcript.
                Section {
                    intelligenceRow
                    SettingsCaption(text: "\"Previously On\u{2026}\" and \"I Zoned Out\" in the player’s menu use Apple Intelligence to write short recaps from the transcript. It all happens on this iPhone.")

                    // Batch 433: the narrator montage.
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $recapSpokenLinks) {
                            settingRow("text.bubble.fill", "Spoken Links in Recaps")
                        }
                        SettingsCaption(text: "Recaps play the narrator’s own voice. This adds short spoken lines between the moments.")
                    }
                    .settingsRowAnchor(SettingsRow.recapSpokenLinks)

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $recapAutoPlay) {
                            settingRow("play.circle.fill", "Play Recap When Resuming")
                        }
                        SettingsCaption(text: "After a few days away, the prepared recap plays before the book. Recaps are prepared overnight while charging.")
                    }
                    .settingsRowAnchor(SettingsRow.recapAutoPlay)
                } header: {
                    RetroSectionHeader(title: "Apple Intelligence")
                }
                .listRowBackground(Color.shelfCard)

                Section {
                    LabeledContent {
                        Typo.supporting(Text(verbatim: ByteCountFormatter.string(fromByteCount: center.storageBytes, countStyle: .file)))
                            .foregroundStyle(Color.shelfMuted)
                    } label: {
                        settingRow("internaldrive.fill", "Transcript storage")
                    }
                    .accessibilityElement(children: .combine)
                    .settingsRowAnchor(SettingsRow.transcriptStorage)

                    Button(role: .destructive) {
                        confirmDeleteAll = true
                    } label: {
                        Label("Delete All Transcripts", systemImage: "trash")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .disabled(center.storageBytes == 0)
                    .confirmationDialog("Delete all transcripts?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                        Button("Delete All Transcripts", role: .destructive) {
                            center.deleteAllTranscripts()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Transcripts can be made again from your downloaded books.")
                    }
                    .systemChromeTint()
                } header: {
                    RetroSectionHeader(title: "Storage")
                }
                .listRowBackground(Color.shelfCard)
            }
        }
        .task {
            center.refreshStorage()
            locales = await center.supportedLocales()
        }
        .task {
            if #available(iOS 18.0, *) {
                translationTargets = await CaptionTranslator.supportedTargetIdentifiers()
            }
        }
        .task { intelligence.refreshAvailability() }
        .task(id: defaultLanguage) {
            await center.refreshAvailability(localeIdentifier: defaultLanguage.isEmpty ? nil : defaultLanguage)
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        let status = Self.statusText(for: center.availability)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            if center.availability == .checking {
                ProgressView().frame(width: 20)
            } else {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.isProblem ? Color.shelfOrange : Color.shelfAmberText)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            Typo.supporting(Text(status.text))
                // DESIGN.md orange rule: orange glyph, cream sentence.
                .foregroundStyle(Color.shelfCream)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Batch 428: whether the on-device model can write recaps right now, or why not.
    private var intelligenceRow: some View {
        let problem = intelligence.availability
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(problem == nil ? Color.shelfAmberText : Color.shelfOrange)
                .frame(width: 20)
                .accessibilityHidden(true)
            Group {
                if let problem {
                    Typo.supporting(Text(verbatim: problem.message))
                } else {
                    Typo.supporting(Text("Apple Intelligence is ready"))
                }
            }
            // DESIGN.md orange rule: orange glyph, cream sentence.
            .foregroundStyle(Color.shelfCream)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    static func statusText(for availability: TranscriptionCenter.Availability)
        -> (text: LocalizedStringResource, symbol: String, isProblem: Bool) {
        switch availability {
        case .unsupportedOS:
            return ("Needs iOS 26 or later", "exclamationmark.triangle.fill", true)
        case .deviceUnsupported:
            return ("This device can’t transcribe speech on-device", "exclamationmark.triangle.fill", true)
        case .languageUnsupported:
            return ("This language isn’t supported for transcripts yet", "exclamationmark.triangle.fill", true)
        case .needsModelDownload:
            return ("The speech model downloads the first time a book is transcribed", "arrow.down.circle", false)
        case .checking:
            return ("Checking speech support\u{2026}", "ellipsis.circle", false)
        case .ready:
            return ("Ready to transcribe", "checkmark.circle.fill", false)
        }
    }

    // MARK: - Languages

    private struct LanguageOption { let identifier: String; let name: String }

    /// Supported translation targets by display name; the saved choice stays listed while the list loads.
    private var translationOptions: [LanguageOption] {
        var ids = translationTargets
        if !captionTranslation.isEmpty, !ids.contains(captionTranslation) { ids.append(captionTranslation) }
        return ids.map {
            LanguageOption(identifier: $0, name: Locale.current.localizedString(forIdentifier: $0) ?? $0)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Supported locales by display name; the saved choice is kept in the list even when
    /// the locale list hasn't loaded (or no longer contains it) so the Picker never shows blank.
    private var languageOptions: [LanguageOption] {
        var options = locales.map {
            LanguageOption(identifier: $0.identifier,
                           name: Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
        }
        if !defaultLanguage.isEmpty, !options.contains(where: { $0.identifier == defaultLanguage }) {
            options.append(LanguageOption(identifier: defaultLanguage,
                                          name: Locale.current.localizedString(forIdentifier: defaultLanguage) ?? defaultLanguage))
        }
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
