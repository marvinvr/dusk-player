import Foundation

/// The browse value lists the Filters sheet reads (02 §3): studios and people
/// that appear in one library.
extension JellyfinAPI {
    /// The studios (networks too, for shows) of `parentID`'s titles.
    static func studios(parentID: String) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("parentId", parentID)
        return .json(.get, "/Studios", query: query.items, isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, includeItemTypes: [.studio], expectsUserData: false)
        }
    }

    /// The people of `parentID`'s titles credited as one of `personTypes`.
    static func persons(parentID: String, personTypes: [JellyfinPersonKind]) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("parentId", parentID)
        query.add("personTypes", list: personTypes)
        return .json(.get, "/Persons", query: query.items, isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, includeItemTypes: [.person], expectsUserData: false)
        }
    }
}
