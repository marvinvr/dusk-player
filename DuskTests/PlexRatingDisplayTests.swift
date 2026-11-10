import Testing
@testable import Dusk

@Suite("Detail page rating display")
struct PlexRatingDisplayTests {
    @Test("Every source with a logo maps to it; TVDB keeps its text label")
    func sourceLogos() {
        #expect(PlexRating(image: "imdb://image.rating", value: 6.4, type: "audience").display?.logo == .imdb)
        #expect(PlexRating(image: "imdb://image.rating", value: 6.4, type: "audience").display?.value == "6.4")
        #expect(PlexRating(image: "themoviedb://image.rating", value: 6.5, type: "audience").display?.logo == .tmdb)
        #expect(PlexRating(image: "themoviedb://image.rating", value: 6.5, type: "audience").display?.value == "65%")
        #expect(PlexRating(image: "thetvdb://image.rating", value: 8, type: "audience").display?.logo == nil)
        #expect(PlexRating(image: "thetvdb://image.rating", value: 8, type: "audience").display?.source == "TVDB")
        #expect(PlexRating(image: "unknown://image.rating", value: 8, type: "audience").display == nil)
    }

    @Test("Rotten Tomatoes icons follow the displayed score at the 60% line")
    func rottenTomatoesThreshold() {
        let critic = "rottentomatoes://image.rating.ripe"
        let audience = "rottentomatoes://image.rating.upright"
        #expect(PlexRating(image: critic, value: 6, type: "critic").display?.logo == .tomatometerFresh)
        #expect(PlexRating(image: critic, value: 5.9, type: "critic").display?.logo == .tomatometerRotten)
        #expect(PlexRating(image: audience, value: 6, type: "audience").display?.logo == .popcornmeterHot)
        #expect(PlexRating(image: audience, value: 5.9, type: "audience").display?.logo == .popcornmeterStale)
        // Plex's image and the score disagree: the score decides.
        #expect(PlexRating(image: "rottentomatoes://image.rating.rotten", value: 9, type: "critic").display?.logo == .tomatometerFresh)
        // Rounds up to the 60% on screen.
        #expect(PlexRating(image: critic, value: 5.96, type: "critic").display?.value == "60%")
        #expect(PlexRating(image: critic, value: 5.96, type: "critic").display?.logo == .tomatometerFresh)
    }

    @Test("Critic and audience scores of one source both survive de-duplication by name")
    func criticAndAudienceAreDistinct() {
        let critic = PlexRating(image: "rottentomatoes://image.rating.ripe", value: 9, type: "critic")
        let audience = PlexRating(image: "rottentomatoes://image.rating.spilled", value: 4, type: nil)
        #expect(critic.display?.source != audience.display?.source)
        #expect(audience.display?.logo == .popcornmeterStale)
    }

    @Test("An episode's /library/metadata payload yields its sources and the user's rating (#66)")
    func episodeDetailsRatings() throws {
        // Shape of a Plex TV agent episode: the Rating array plus the flat
        // audienceRating fields, and the signed-in user's own rating.
        let json = """
        { "ratingKey": "42", "key": "/library/metadata/42", "type": "episode",
          "title": "Ozymandias", "index": 14, "parentIndex": 5,
          "grandparentTitle": "Breaking Bad",
          "audienceRating": 9.2, "audienceRatingImage": "themoviedb://image.rating",
          "userRating": 9,
          "Rating": [
            { "image": "imdb://image.rating", "value": 10.0, "type": "audience" },
            { "image": "themoviedb://image.rating", "value": 9.2, "type": "audience" },
            { "image": "imdb://image.rating", "value": 10.0, "type": "audience" }
          ] }
        """
        let details = try JSONDecoder().decode(PlexMediaDetails.self, from: Data(json.utf8))
        #expect(details.type == .episode)
        #expect(details.userRating == 9)
        let shown = PlexRating.sources(for: details).compactMap(\.display)
        #expect(shown.map { $0.source } == ["IMDb", "TMDB"])
        #expect(shown.map { $0.value } == ["10.0", "92%"])
    }

    @Test("An episode without the Rating array falls back to its audience rating")
    func episodeDetailsFlatRatingFallback() throws {
        let json = """
        { "ratingKey": "43", "key": "/library/metadata/43", "type": "episode",
          "title": "Pilot", "audienceRating": 7.4, "audienceRatingImage": "themoviedb://image.rating" }
        """
        let details = try JSONDecoder().decode(PlexMediaDetails.self, from: Data(json.utf8))
        #expect(PlexRating.sources(for: details).compactMap(\.display?.value) == ["74%"])
    }

    @Test(
        "Content ratings drop the country prefix",
        arguments: [
            ("de/12", "12"), ("gb/15", "15"), ("ca/14A", "14A"), ("de/FSK 16", "FSK 16"),
            ("PG-13", "PG-13"), ("TV-MA", "TV-MA"), ("12", "12"),
            ("N/A", "N/A"), ("PG/13", "PG/13"), ("de/", "de/"), (" de/12 ", "12"),
        ]
    )
    func contentRating(raw: String, expected: String) {
        #expect(PlexContentRating.display(raw) == expected)
    }

    @Test("A missing or blank content rating shows nothing")
    func emptyContentRating() {
        #expect(PlexContentRating.display(nil) == nil)
        #expect(PlexContentRating.display("  ") == nil)
    }
}
