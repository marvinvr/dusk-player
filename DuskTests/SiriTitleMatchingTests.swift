import Foundation
import Testing
@testable import Dusk

/// Spoken titles → Plex titles, and which episode "play <show>" starts.
@Suite("Siri title matching")
struct SiriTitleMatchingTests {
    private func candidate(
        _ title: String,
        _ kind: SiriTitleKind = .show,
        year: Int? = nil,
        key: String? = nil,
        server: String = "server-a",
        inProgress: Bool = false,
        lastViewedAt: Int? = nil
    ) -> SiriTitleCandidate {
        SiriTitleCandidate(
            id: MediaItemID(serverID: server, ratingKey: key ?? title),
            kind: kind,
            title: title,
            year: year,
            isInProgress: inProgress,
            lastViewedAt: lastViewedAt
        )
    }

    private func resolve(_ spoken: String, _ candidates: [SiriTitleCandidate]) -> SiriTitleResolution {
        SiriTitleMatcher.resolve(SiriTitleQuery(spoken), among: candidates)
    }

    private func matchedTitle(_ resolution: SiriTitleResolution) -> String? {
        if case .match(let candidate) = resolution { return candidate.title }
        return nil
    }

    // MARK: - Query parsing

    @Test("Kind and year hints are stripped from the title")
    func queryHints() {
        let movie = SiriTitleQuery("the movie Dune 2021")
        #expect(movie.text == "Dune")
        #expect(movie.kind == .movie)
        #expect(movie.year == 2021)

        let show = SiriTitleQuery("the show Severance")
        #expect(show.text == "Severance")
        #expect(show.kind == .show)
        #expect(show.year == nil)
    }

    @Test("A title that is a year keeps it")
    func yearTitle() {
        let query = SiriTitleQuery("1917")
        #expect(query.text == "1917")
        #expect(query.year == nil)
    }

    @Test("A kind word that is the whole title is kept")
    func kindWordAsTitle() {
        #expect(SiriTitleQuery("movie").text == "movie")
    }

    @Test("Search terms add spelled-out digits and the longest word")
    func searchTerms() {
        #expect(SiriTitleQuery("Brooklyn 99").searchTerms == ["Brooklyn 99", "Brooklyn nine nine", "brooklyn"])
        #expect(SiriTitleQuery("Dune").searchTerms == ["Dune"])
    }

    // MARK: - Normalisation

    @Test("Numbers, punctuation, accents and articles fold together")
    func normalisation() {
        #expect(SiriTitleNormalizer.tokens("Brooklyn Nine-Nine").joined() == SiriTitleNormalizer.tokens("brooklyn 99").joined())
        #expect(SiriTitleNormalizer.tokens("Ocean's Eleven") == ["oceans", "11"])
        #expect(SiriTitleNormalizer.tokens("Rocky II") == ["rocky", "2"])
        #expect(SiriTitleNormalizer.tokens("Rocky two") == ["rocky", "2"])
        #expect(SiriTitleNormalizer.tokens("twenty one jump street") == ["21", "jump", "street"])
        #expect(SiriTitleNormalizer.tokens("Amélie") == ["amelie"])
        #expect(SiriTitleNormalizer.tokens("The Office") == ["office"])
        #expect(SiriTitleNormalizer.tokens("Law & Order") == ["law", "and", "order"])
        #expect(SiriTitleNormalizer.tokens("I, Robot") == ["i", "robot"])
    }

    // MARK: - Resolution

    @Test("Spoken digits match a title with number words")
    func digitsMatchWords() {
        let library = [candidate("Brooklyn Nine-Nine"), candidate("Brooklyn", .movie, year: 2015)]
        #expect(matchedTitle(resolve("brooklyn 99", library)) == "Brooklyn Nine-Nine")
        #expect(matchedTitle(resolve("Brooklyn nine nine", library)) == "Brooklyn Nine-Nine")
        #expect(matchedTitle(resolve("Brooklyn Nine-Nine", library)) == "Brooklyn Nine-Nine")
    }

    @Test("An exact title beats a longer one it starts")
    func exactBeatsPrefix() {
        let library = [
            candidate("Dune: Part Two", .movie, year: 2024),
            candidate("Dune", .movie, year: 2021),
        ]
        #expect(matchedTitle(resolve("Dune", library)) == "Dune")
    }

    @Test("A prefix finds a title with a subtitle")
    func prefixMatch() {
        let library = [candidate("Mission: Impossible - Dead Reckoning", .movie), candidate("Severance")]
        #expect(matchedTitle(resolve("mission impossible dead reckoning", library)) == "Mission: Impossible - Dead Reckoning")
    }

    @Test("A small mis-transcription still matches")
    func fuzzyMatch() {
        let library = [candidate("Severance"), candidate("Succession")]
        #expect(matchedTitle(resolve("Severence", library)) == "Severance")
    }

    @Test("Unrelated titles are not found")
    func notFound() {
        let library = [candidate("Severance"), candidate("The Bear")]
        #expect(resolve("Breaking Bad", library) == .notFound)
        #expect(resolve("", library) == .notFound)
        #expect(resolve("Severance", []) == .notFound)
    }

    @Test("Short words do not match inside longer titles")
    func noShortContainment() {
        #expect(resolve("up", [candidate("Pitch Perfect: Up Close", .movie)]) == .notFound)
    }

    @Test("Same title as a movie and a show is ambiguous without a hint")
    func movieAndShowAmbiguous() {
        let movie = candidate("Fargo", .movie, year: 1996)
        let show = candidate("Fargo", .show, year: 2014)
        #expect(resolve("Fargo", [movie, show]) == .ambiguous([movie, show]))
        #expect(resolve("the show Fargo", [movie, show]) == .match(show))
        #expect(resolve("Fargo 1996", [movie, show]) == .match(movie))
    }

    @Test("Watch history breaks a tie between versions")
    func historyBreaksTie() {
        let uk = candidate("The Office", year: 2001, key: "1")
        let us = candidate("The Office (US)", year: 2005, key: "2", lastViewedAt: 1_700_000_000)
        #expect(resolve("the office", [uk, us]) == .match(us))

        let inProgress = candidate("The Office (US)", year: 2005, key: "2", inProgress: true, lastViewedAt: 1)
        let rewatched = candidate("The Office", year: 2001, key: "1", lastViewedAt: 2)
        #expect(resolve("the office", [rewatched, inProgress]) == .match(inProgress))
    }

    @Test("Two versions without history stay ambiguous")
    func versionsWithoutHistory() {
        let uk = candidate("The Office", year: 2001, key: "1")
        let us = candidate("The Office (US)", year: 2005, key: "2")
        #expect(resolve("The Office", [uk, us]) == .ambiguous([uk, us]))
    }

    @Test("A title on two servers is one candidate, the first server's")
    func duplicatesAcrossServers() {
        let first = candidate("Severance", year: 2022, server: "server-a")
        let second = candidate("Severance", year: 2022, server: "server-b")
        #expect(resolve("severance", [first, second]) == .match(first))
    }

    @Test("Many similar titles are offered as a short list")
    func franchiseIsAmbiguous() {
        let library = [
            candidate("Star Wars: A New Hope", .movie, year: 1977),
            candidate("Star Wars: The Empire Strikes Back", .movie, year: 1980),
            candidate("Star Trek", .movie, year: 2009),
        ]
        guard case .ambiguous(let choices) = resolve("star wars", library) else {
            Issue.record("Expected a choice between the Star Wars films")
            return
        }
        #expect(choices.map(\.title) == ["Star Wars: A New Hope", "Star Wars: The Empire Strikes Back"])
    }

    // MARK: - Next episode

    private func episode(
        _ season: Int,
        _ number: Int,
        watched: Bool = false,
        inProgress: Bool = false,
        lastViewedAt: Int? = nil
    ) -> SiriNextEpisodePicker.Episode {
        SiriNextEpisodePicker.Episode(
            id: MediaItemID(serverID: "server-a", ratingKey: "\(season)x\(number)"),
            season: season,
            index: number,
            isWatched: watched,
            isInProgress: inProgress,
            lastViewedAt: lastViewedAt
        )
    }

    @Test("An episode in progress resumes")
    func resumesInProgress() {
        let episodes = [
            episode(1, 1, watched: true, lastViewedAt: 10),
            episode(1, 2, inProgress: true, lastViewedAt: 20),
            episode(1, 3),
        ]
        #expect(SiriNextEpisodePicker.pick(from: episodes) == episodes[1])
    }

    @Test("The episode after the last one watched plays next")
    func nextAfterLastWatched() {
        let episodes = [
            episode(1, 1),
            episode(1, 2, watched: true, lastViewedAt: 10),
            episode(2, 1, watched: true, lastViewedAt: 30),
            episode(2, 2),
            episode(1, 3),
        ]
        #expect(SiriNextEpisodePicker.pick(from: episodes)?.id.ratingKey == "2x2")
    }

    @Test("Specials are skipped when the show has regular episodes")
    func skipsSpecials() {
        let episodes = [episode(0, 1), episode(1, 1), episode(1, 2)]
        #expect(SiriNextEpisodePicker.pick(from: episodes)?.id.ratingKey == "1x1")
    }

    @Test("A fully watched show starts over, an empty one has nothing")
    func fullyWatchedAndEmpty() {
        let episodes = [
            episode(1, 2, watched: true, lastViewedAt: 20),
            episode(1, 1, watched: true, lastViewedAt: 10),
        ]
        #expect(SiriNextEpisodePicker.pick(from: episodes)?.id.ratingKey == "1x1")
        #expect(SiriNextEpisodePicker.pick(from: []) == nil)
    }
}
