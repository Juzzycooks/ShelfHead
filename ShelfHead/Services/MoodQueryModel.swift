import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
/// Batch 445: what the on-device model writes for a mood search sentence. Mapped to `MoodQuery` straight after.
@available(iOS 26.0, *)
@Generable
nonisolated struct GeneratedMoodQuery {
    @Guide(description: "Genres the listener asked for, copied exactly from the list of library genres. Empty if none was asked for.",
           .maximumCount(4))
    var genres: [String]

    @Guide(description: "Single lowercase words for the mood or flavour asked for, such as cosy, dark, funny, gripping. Not genres, not lengths. Empty if none.",
           .maximumCount(5))
    var toneWords: [String]

    @Guide(description: "Minimum length in hours, only if the listener asked for a minimum or a long book. Otherwise 0.")
    var minHours: Double

    @Guide(description: "Maximum length in hours, only if the listener asked for a limit or a short book. Otherwise 0.")
    var maxHours: Double

    @Guide(description: "True only if the listener asked for a narrator they have starred or marked as a favourite.")
    var starredNarrator: Bool

    @Guide(description: "True only if the listener asked for an author they have starred or marked as a favourite.")
    var starredAuthor: Bool

    @Guide(description: "True only if the listener asked for books they have not started or played yet.")
    var unplayedOnly: Bool

    @Guide(description: "A language name such as English, only if the listener asked for one. Otherwise empty.")
    var language: String
}
#endif

/// Batch 445: reads a mood search sentence. Uses Apple's on-device model (FoundationModels, iOS 26+) when
/// Apple Intelligence is available, merged with `MoodRuleParser`; on unavailability, error or timeout it
/// answers with the rule parser alone. Nothing leaves the device.
///
/// Apple docs checked: `Generable` and `LanguageModelSession.respond(to:generating:includeSchemaInPrompt:options:)`,
/// both iOS 26.0+. The availability gate and error handling copy `BookIntelligence`.
nonisolated enum MoodQueryModel {
    /// How long the model gets before the rules answer instead.
    static let timeoutSeconds = 8.0

    /// The query for `text`. The rule parser's reading is always the base; the model adds to it.
    static func interpret(_ text: String, knownGenres: [String]) async -> MoodQuery {
        let rules = MoodRuleParser.parse(text, knownGenres: knownGenres)
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), BookIntelligence.currentAvailability() == nil else { return rules }
        do {
            let generated = try await generate(text: text, knownGenres: knownGenres)
            return rules.merged(withModel: generated, knownGenres: knownGenres)
        } catch {
            return rules
        }
        #else
        return rules
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @concurrent
    private static func generate(text: String, knownGenres: [String]) async throws -> MoodQuery {
        let instructions = """
        You turn a listener's request for an audiobook into search settings. Fill in only what the request \
        actually says; leave everything else empty, false or 0. Never invent genres. Library genres: \
        \(knownGenres.prefix(60).joined(separator: ", ")).
        """
        let generated: GeneratedMoodQuery = try await withThrowingTaskGroup(of: GeneratedMoodQuery.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: text, generating: GeneratedMoodQuery.self)
                return response.content
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw BookIntelligenceError(reason: .timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw BookIntelligenceError(reason: .failed) }
            return first
        }
        return MoodQuery(
            genres: generated.genres,
            toneWords: generated.toneWords.map { $0.lowercased() },
            minHours: generated.minHours > 0 ? generated.minHours : nil,
            maxHours: generated.maxHours > 0 ? generated.maxHours : nil,
            starredNarrator: generated.starredNarrator,
            starredAuthor: generated.starredAuthor,
            unplayedOnly: generated.unplayedOnly,
            language: generated.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : generated.language)
    }
    #endif
}
