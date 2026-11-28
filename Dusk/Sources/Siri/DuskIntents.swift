import AppIntents
import Foundation

// Siri playback: "Play Brooklyn Nine-Nine in Dusk".
//
// Two routes reach `SiriPlaybackService`:
// - `PlayTitleIntent`, an App Shortcut whose phrases carry the title. Siri only
//   matches titles registered beforehand (`SiriTitleCatalog`, recently watched
//   and recently added), so those resolve instantly and offline.
// - `PlayInDuskIntent`, the system's free-form video intent (`PlayVideoIntent`):
//   Siri hands over the spoken text, which is searched on Plex. It also backs
//   the "Play something in Dusk" shortcut, where Siri asks for the title.
// Both open Dusk first: only the foreground app connects its servers.
// See docs/siri.md.

/// A movie or show in the user's Plex libraries.
struct PlexTitleEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Movie or Show")
    static let defaultQuery = PlexTitleEntityQuery()

    /// `MediaItemID.storageKey`: server and rating key.
    let id: String
    let kind: SiriTitleKind
    let title: String
    let year: Int?

    var displayRepresentation: DisplayRepresentation {
        let kindLabel = kind == .movie ? "Movie" : "TV Show"
        let subtitle = year.map { "\(kindLabel) · \($0)" } ?? kindLabel
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            synonyms: synonyms
        )
    }

    /// Spoken forms Siri should also accept: "Brooklyn 99" for "Brooklyn
    /// Nine-Nine", "The Office" for "The Office (US)".
    private var synonyms: [LocalizedStringResource] {
        var forms: [String] = []
        let compact = SiriTitleNormalizer.tokens(title).joined(separator: " ")
        if compact.caseInsensitiveCompare(title) != .orderedSame,
           compact.contains(where: \.isNumber) {
            forms.append(compact)
        }
        if let parenthesis = title.firstIndex(of: "("), parenthesis > title.startIndex {
            let bare = title[..<parenthesis].trimmingCharacters(in: .whitespaces)
            if !bare.isEmpty {
                forms.append(bare)
            }
        }
        return forms.map { LocalizedStringResource(stringLiteral: $0) }
    }

    init(id: String, kind: SiriTitleKind, title: String, year: Int?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.year = year
    }

    init(_ candidate: SiriTitleCandidate) {
        self.init(id: candidate.id.storageKey, kind: candidate.kind, title: candidate.title, year: candidate.year)
    }

    init(_ entry: SiriCatalogEntry) {
        self.init(id: entry.id.storageKey, kind: entry.kind, title: entry.title, year: entry.year)
    }

    var candidate: SiriTitleCandidate? {
        guard let itemID = MediaItemID(storageKey: id) else { return nil }
        return SiriTitleCandidate(id: itemID, kind: kind, title: title, year: year)
    }
}

struct PlexTitleEntityQuery: EntityStringQuery {
    @Dependency private var siri: SiriPlaybackService

    @MainActor
    func entities(for identifiers: [PlexTitleEntity.ID]) async throws -> [PlexTitleEntity] {
        let catalog = SiriTitleCatalog.shared
        return identifiers.compactMap { identifier in
            if let entry = MediaItemID(storageKey: identifier).flatMap(catalog.entry(for:)) {
                return PlexTitleEntity(entry)
            }
            return siri.recentlyMatched[identifier]
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlexTitleEntity] {
        let entities = await siri.entities(matching: string).map(PlexTitleEntity.init)
        siri.remember(entities)
        return entities
    }

    /// What Siri learns for the App Shortcut phrases, and what the Shortcuts
    /// app offers first.
    @MainActor
    func suggestedEntities() async throws -> [PlexTitleEntity] {
        SiriTitleCatalog.shared.entries.map(PlexTitleEntity.init)
    }
}

/// "Play <title> in Dusk" for titles Siri already knows.
struct PlayTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Movie or Show"
    static let description = IntentDescription(
        "Plays a movie, or the next episode of a show, from your Plex libraries."
    )
    #if os(tvOS)
    static let supportedModes: IntentModes = .foreground(.immediate)
    #else
    static let openAppWhenRun = true
    #endif

    @Parameter(title: "Title", requestValueDialog: "What would you like to watch?")
    var title: PlexTitleEntity

    @Dependency private var siri: SiriPlaybackService

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$title)")
    }

    init() {}

    init(title: PlexTitleEntity) {
        self.title = title
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let candidate = title.candidate else {
            return .result(dialog: "I couldn’t find \(title.title) in your Plex libraries.")
        }
        let reply = await siri.play(candidate)
        return .result(dialog: "\(reply)")
    }
}

/// "Play <anything> in Dusk": Siri's own video intent with the spoken text.
struct PlayInDuskIntent: PlayVideoIntent {
    static let title: LocalizedStringResource = "Play in Dusk"
    static let description = IntentDescription(
        "Finds a movie or show in your Plex libraries by name and plays it."
    )
    static let supportedCategories: [VideoCategory] = [.movies, .tv]

    @Parameter(title: "Title", requestValueDialog: "What would you like to watch?")
    var term: String

    @Dependency private var siri: SiriPlaybackService

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await siri.lookUp(term) {
        case .unavailable(let message):
            return .result(dialog: "\(message)")
        case .resolved(.notFound):
            return .result(dialog: "I couldn’t find \(term) in your Plex libraries.")
        case .resolved(.match(let candidate)):
            let reply = await siri.play(candidate)
            return .result(dialog: "\(reply)")
        case .resolved(.ambiguous(let candidates)):
            let chosen = try await choose(among: candidates)
            let reply = await siri.play(chosen)
            return .result(dialog: "\(reply)")
        }
    }

    /// Siri reads the matches out and plays the one picked. Before iOS 26
    /// there is no choice prompt, so the best-ranked match plays. Not on the
    /// main actor: the choice options are not Sendable.
    private func choose(among candidates: [SiriTitleCandidate]) async throws -> SiriTitleCandidate {
        guard let first = candidates.first else { throw $term.needsValueError() }
        guard #available(iOS 26.0, tvOS 26.0, *) else { return first }

        let options = candidates.map { IntentChoiceOption(title: "\($0.choiceLabel)") }
        let choice = try await requestChoice(
            between: options + [.cancel],
            dialog: "Which one did you mean?"
        )
        guard let index = options.firstIndex(of: choice) else {
            throw $term.needsValueError("What would you like to watch?")
        }
        return candidates[index]
    }
}

struct DuskAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayTitleIntent(),
            phrases: [
                "Play \(\.$title) in \(.applicationName)",
                "Play \(\.$title) on \(.applicationName)",
                "Watch \(\.$title) in \(.applicationName)",
                "Watch \(\.$title) on \(.applicationName)",
                "Resume \(\.$title) in \(.applicationName)",
                "Resume \(\.$title) on \(.applicationName)",
                "Continue \(\.$title) in \(.applicationName)",
                "Continue \(\.$title) on \(.applicationName)",
            ],
            shortTitle: "Play",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayInDuskIntent(),
            phrases: [
                "Play something in \(.applicationName)",
                "Play something on \(.applicationName)",
                "Watch something in \(.applicationName)",
                "Watch something on \(.applicationName)",
                "Find something to watch in \(.applicationName)",
            ],
            shortTitle: "Play by Name",
            systemImageName: "magnifyingglass"
        )
    }
}
