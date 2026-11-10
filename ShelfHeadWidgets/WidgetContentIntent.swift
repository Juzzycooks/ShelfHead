import AppIntents
import WidgetKit

/// What a placed widget should show. Previously the widget was a `StaticConfiguration`
/// hardwired to the current session, so a paused library — or no session at all — left it
/// showing an empty tape deck with nothing to act on.
///
/// The choices are bounded by what actually crosses the App Group boundary (see
/// `SharedLibrary`): the live session, the head of the Up Next queue, or one of the books
/// the app has published. There is deliberately no "any book in my library" option — the
/// widget has no credentials and no network, so offering the catalogue would mean
/// mirroring it into the shared container.
struct SelectWidgetContentIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Book"
    static var description = IntentDescription("Pick what this widget shows — whatever you're playing now, what's next, or a specific book.")

    @Parameter(title: "Show", default: .nowPlaying)
    var mode: WidgetContentMode

    /// Only meaningful when `mode` is `.specificBook`. Optional because the system does
    /// not automatically request optional parameters — the provider falls back to the live
    /// session when it's `nil`, which is the sensible reading of "book mode, no book".
    ///
    /// W9 (REVIEW_2026-09-04_UI.md Pass 4): kept as a fallback description for contexts
    /// that render the parameter's own info (e.g. VoiceOver reading the Shortcuts app
    /// editor) rather than the conditional summary below. HIG audit 2026-09-17 M13 made
    /// that summary conditional, so in the normal configuration sheet this row is now
    /// hidden outside book mode and the caveat mostly stops applying.
    @Parameter(title: "Book", description: "Only takes effect when Show is set to \"A Specific Book.\"")
    var book: PinnedBookEntity?

    /// HIG audit 2026-09-17 M13: the Book row used to be unconditional because
    /// `When(\.$mode, .equalTo, .specificBook)` failed to compile here — Swift couldn't
    /// infer the key path's root (`Intent` in `KeyPath<Intent, Parameter>`; see
    /// `ParameterSummaryWhenCondition.init(_:_:_:_:otherwise:)` at
    /// https://developer.apple.com/documentation/appintents/parametersummarywhencondition)
    /// from a bare `\.$mode` in this builder context. Spelling the root explicitly as
    /// `\SelectWidgetContentIntent.$mode`, as the old comment suspected, is what the
    /// signature actually needs — the initializer takes `KeyPath<Intent, Parameter>`,
    /// not something inferable from context alone. `.equalTo` is
    /// `EquatableComparisonOperator`, which `WidgetContentMode` (an `AppEnum`) supports.
    /// See also https://developer.apple.com/documentation/appintents/parametersummary
    /// for the overall `Summary`/`When`/key-path substitution model. If this still fails
    /// to compile, the next thing to try is `Switch(\SelectWidgetContentIntent.$mode) {
    /// Case(.specificBook) { Summary(...) { \.$book } } } default: { Summary(...) }`
    /// (`ParameterSummarySwitchCondition`/`ParameterSummaryCaseCondition`), which takes
    /// the same explicit-root key path but dispatches on all three cases instead of one
    /// boolean comparison.
    static var parameterSummary: some ParameterSummary {
        When(\SelectWidgetContentIntent.$mode, .equalTo, .specificBook) {
            Summary("Show \(\.$mode)") {
                \.$book
            }
        } otherwise: {
            Summary("Show \(\.$mode)")
        }
    }

    init() {}
}

/// String raw values rather than `Int`: these persist inside saved widget configurations,
/// so a readable, stable identifier is worth more than compactness.
enum WidgetContentMode: String, AppEnum {
    case nowPlaying
    case upNext
    case specificBook

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Content"

    static var caseDisplayRepresentations: [WidgetContentMode: DisplayRepresentation] = [
        .nowPlaying: DisplayRepresentation(title: "Now Playing",
                                           subtitle: "Whatever you're listening to"),
        .upNext: DisplayRepresentation(title: "Up Next",
                                       subtitle: "The next book in your queue"),
        .specificBook: DisplayRepresentation(title: "A Specific Book",
                                             subtitle: "Pick one you're part-way through")
    ]
}

/// A book the widget can be pinned to, drawn from `SharedLibrary`'s published set.
///
/// A shadow model, not `LibraryItem`: that type carries the whole media/chapters/audioFiles
/// graph and isn't in this target at all. Only what the picker and the widget actually
/// render is exposed.
struct PinnedBookEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Book"
    static let defaultQuery = PinnedBookQuery()

    let id: String

    @Property(title: "Title") var title: String
    @Property(title: "Author") var author: String

    init(from book: SharedLibrary.PinnableBook) {
        self.id = book.id
        self.title = book.title
        self.author = book.author
    }

    /// W9 (REVIEW_2026-09-04_UI.md Pass 4): only used to build `placeholderNoBooks`
    /// below — a synthetic row for when `SharedLibrary`'s published set is empty (a
    /// fresh install, or before Home has loaded once). Its id can never match a real
    /// published book, so picking it behaves exactly like picking nothing:
    /// `PlaybackProvider.resolved(for:at:)`'s `payload.books.first { $0.id == entity.id }`
    /// lookup misses and the widget falls back to the live session — the same outcome
    /// as today's "no book selected" case. This only replaces a silently-empty picker
    /// with one row that explains why it's empty.
    private init(placeholderId: String, title: String, author: String) {
        self.id = placeholderId
        self.title = title
        self.author = author
    }

    fileprivate static let placeholderNoBooks = PinnedBookEntity(
        placeholderId: "shelfhead.no-books-yet",
        title: String(localized: "Open ShelfHead to see books here"),
        author: "")

    /// PL-17 (docs/design-review.md, follow-up): a stand-in for one specific SAVED
    /// pin's id that can't currently be resolved because the user is signed out
    /// (`SharedLibrary`'s published set is empty while signed out — see
    /// `PinnedBookQuery.entities(for:)`). Keeps the same `id` as the saved
    /// configuration — unlike `placeholderNoBooks` above, which stands for "nothing
    /// saved at all" — so the saved selection isn't at risk of being cleared or shown
    /// blank purely because it's momentarily unresolvable. Apple's documentation for
    /// `entities(for:)` (developer.apple.com/documentation/appintents/entityquery/
    /// entities(for:), iOS 16.0+) says only that "the system skips identifiers that
    /// have no matching entity" for a given call's *return value* — it doesn't say
    /// whether that also clears or blanks the widget's persisted configuration, and no
    /// AppIntentConfiguration/WidgetConfigurationIntent page found a clearer answer
    /// either, so this takes the safe reading rather than assuming either way.
    /// `ShelfHeadWidgets.PlaybackProvider.resolved(for:at:)` checks
    /// `SharedPlayback.isSignedIn` before it ever reaches `SharedLibrary`, so this
    /// placeholder is never drawn as a live pinned book — it only keeps the
    /// configuration intact until the real book resolves again after sign-in.
    fileprivate static func signedOutPlaceholder(id: String) -> PinnedBookEntity {
        PinnedBookEntity(placeholderId: id, title: String(localized: "Sign in to ShelfHead to see this book"), author: "")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: author.isEmpty ? nil : "\(author)")
    }
}

/// `EnumerableEntityQuery` rather than a searchable one: the published set is capped at
/// `SharedLibrary.maxBooks`, so the picker can simply show all of it and free-text search
/// would have nothing extra to find.
struct PinnedBookQuery: EnumerableEntityQuery {
    /// W9 (REVIEW_2026-09-04_UI.md Pass 4): on a fresh install, or before Home has
    /// loaded once, `SharedLibrary.read().books` is empty and this used to return an
    /// empty array — the picker opened blank with nothing explaining why. One
    /// placeholder row beats a silent blank list.
    func allEntities() async throws -> [PinnedBookEntity] {
        let books = SharedLibrary.read().books.map(PinnedBookEntity.init(from:))
        return books.isEmpty ? [.placeholderNoBooks] : books
    }

    /// Missing ids are omitted, not thrown on: a book that has dropped out of the
    /// published set (finished, or pushed past the cap) must leave the widget falling back
    /// to the live session rather than putting the whole configuration into an error state.
    /// The placeholder id is handled the same way — it never matches a real published
    /// book, so it's simply echoed back if asked for (e.g. re-displaying an already-made
    /// selection) rather than silently dropped.
    func entities(for identifiers: [String]) async throws -> [PinnedBookEntity] {
        var matches = SharedLibrary.read().books
            .filter { identifiers.contains($0.id) }
            .map(PinnedBookEntity.init(from:))
        if identifiers.contains(PinnedBookEntity.placeholderNoBooks.id) {
            matches.append(.placeholderNoBooks)
        }

        // PL-17 (docs/design-review.md, follow-up): while signed out, `SharedLibrary
        // .read().books` is empty, so a saved "specific book" pin's id would otherwise
        // silently go unmatched above for as long as the user stays signed out — see
        // `PinnedBookEntity.signedOutPlaceholder(id:)` for why that's treated as a risk
        // worth guarding against rather than confirmed safe. Echo back a same-id
        // placeholder for every requested id this call couldn't otherwise match, so the
        // saved selection survives; skipped for `placeholderNoBooks`'s own id, which is
        // already handled above.
        if SharedPlayback.isSignedIn == false {
            let matchedIds = Set(matches.map(\.id))
            let unresolved = identifiers.filter { !matchedIds.contains($0) }
            matches.append(contentsOf: unresolved.map(PinnedBookEntity.signedOutPlaceholder(id:)))
        }
        return matches
    }

    /// Without this the picker opens empty until the user searches.
    func suggestedEntities() async throws -> [PinnedBookEntity] {
        try await allEntities()
    }
}
