import Foundation

/// Jellyfin names languages by ISO 639-2, mostly in the bibliographic form
/// (`ger`, `fre`, `chi`: its culture list and its subtitle search); Dusk's
/// settings use ISO 639-1 (`de`, `fr`, `zh`).
enum JellyfinLanguageCodes {
    /// ISO 639-1 for a Jellyfin language (`ger` and `deu` → `de`, `nor` →
    /// `no`). A two-letter code passes through; nil for an empty value.
    /// Unknown codes come back lowercased, as given.
    static func twoLetter(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !code.isEmpty else { return nil }
        if let alpha2 = Locale.LanguageCode(code).identifier(.alpha2) { return alpha2 }
        if let terminology = bibliographicToTerminology[code],
           let alpha2 = Locale.LanguageCode(terminology).identifier(.alpha2) {
            return alpha2
        }
        return code
    }

    /// ISO 639-2/B for a Dusk language (`de` → `ger`, `en` → `eng`). A
    /// three-letter code is brought to the bibliographic form; unknown codes
    /// come back lowercased, as given.
    static func threeLetter(_ code: String) -> String {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terminology = Locale.LanguageCode(code).identifier(.alpha3) ?? code
        return terminologyToBibliographic[terminology] ?? terminology
    }

    /// The ISO 639-2 languages whose bibliographic and terminology codes differ.
    private static let terminologyToBibliographic: [String: String] = [
        "sqi": "alb", "hye": "arm", "eus": "baq", "mya": "bur", "zho": "chi",
        "ces": "cze", "nld": "dut", "fra": "fre", "kat": "geo", "deu": "ger",
        "ell": "gre", "isl": "ice", "mkd": "mac", "mri": "mao", "msa": "may",
        "fas": "per", "ron": "rum", "slk": "slo", "bod": "tib", "cym": "wel",
    ]

    private static let bibliographicToTerminology: [String: String] = Dictionary(
        uniqueKeysWithValues: terminologyToBibliographic.map { ($1, $0) }
    )
}
