import Foundation

enum LibraryGenreSupport {
    static func loadGenreOptions(
        sectionId: String,
        plexService: PlexService
    ) async throws -> [LibraryGenreOption] {
        let filters = try await plexService.getLibraryFilters(sectionId: sectionId)

        guard let genreFilter = filters.first(where: {
            $0.filter.localizedCaseInsensitiveCompare("genre") == .orderedSame
        }) else {
            return [.all]
        }

        let values = try await plexService.getLibraryFilterValues(path: genreFilter.key)
        let genres = values
            .compactMap { genreOption(from: $0, parameterName: genreFilter.filter) }
            .sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }

        guard !genres.isEmpty else {
            return [.all]
        }

        return [.all] + genres
    }

    static func matchedGenres(
        for tags: [PlexTag],
        availableGenres: [LibraryGenreOption],
        limit: Int = 3
    ) -> [LibraryGenreOption] {
        let validGenres = availableGenres.filter { $0.value != nil }
        guard !validGenres.isEmpty else { return [] }

        let genreByNormalizedTitle = Dictionary(
            validGenres.map { (normalizeGenreTitle($0.title), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var matches: [LibraryGenreOption] = []
        var seenValues = Set<String>()

        for tag in tags {
            let normalizedTitle = normalizeGenreTitle(tag.tag)
            guard let genre = genreByNormalizedTitle[normalizedTitle],
                  let value = genre.value,
                  seenValues.insert(value).inserted else {
                continue
            }

            matches.append(genre)

            if matches.count >= limit {
                break
            }
        }

        return matches
    }

    static func inferredGenres(
        from tags: [PlexTag],
        limit: Int = 3
    ) -> [LibraryGenreOption] {
        var matches: [LibraryGenreOption] = []
        var seenTitles = Set<String>()

        for tag in tags {
            let normalizedTitle = normalizeGenreTitle(tag.tag)
            guard !normalizedTitle.isEmpty,
                  seenTitles.insert(normalizedTitle).inserted else {
                continue
            }

            matches.append(
                LibraryGenreOption(
                    title: tag.tag,
                    value: tag.tag
                )
            )

            if matches.count >= limit {
                break
            }
        }

        return matches
    }

    static func genreOption(
        from filterValue: PlexLibraryFilterValue,
        parameterName: String
    ) -> LibraryGenreOption? {
        guard let value = extractFilterValue(from: filterValue.key, parameterName: parameterName),
              !value.isEmpty else {
            return nil
        }

        return LibraryGenreOption(title: filterValue.title, value: value)
    }

    static func extractFilterValue(from key: String, parameterName: String) -> String? {
        if let components = URLComponents(string: key),
           let queryItems = components.queryItems,
           let value = queryItems.first(where: { $0.name == parameterName })?.value {
            return value
        }

        if key.hasPrefix("/") {
            return key.split(separator: "/").last.map(String.init)
        }

        return key.isEmpty ? nil : key
    }

    static func containsGenre(
        _ tags: [PlexTag],
        matching genre: LibraryGenreOption
    ) -> Bool {
        let normalizedTarget = normalizeGenreTitle(genre.title)
        let normalizedValue = genre.value.map(normalizeGenreTitle)

        return tags.contains { tag in
            let normalizedTag = normalizeGenreTitle(tag.tag)
            guard !normalizedTag.isEmpty else { return false }

            return normalizedTag == normalizedTarget ||
                (normalizedValue.map { normalizedTag == $0 } ?? false)
        }
    }

    static func normalizeGenreTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
