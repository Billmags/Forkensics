import Foundation

/// Canonical answers for a challenge.
/// In production: stored server-side, never returned to non-poster clients before reveal.
/// In this prototype: held in MockDataService behind an authorization check method.
struct ChallengeSecret {
    let challengeId: UUID
    var canonicalDish: String
    /// Poster-approved alternate names (e.g. "chicken parm", "chicken parmigiana").
    var dishAliases: [String]
    var canonicalRestaurant: String
    var canonicalCity: String
    /// True once any eligible player has submitted a guess. Locks poster editing.
    var hasFirstGuess: Bool
}
