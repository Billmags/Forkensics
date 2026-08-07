import Foundation

/// Immutable record of one submission or edit event.
/// Every time a player submits or edits their guess, a new GuessAttempt is appended.
/// The server receipt timestamp and monotonic sequence determine rank.
struct GuessAttempt: Identifiable {
    let id: UUID
    let challengeId: UUID
    let playerId: UUID

    // Guess content
    let whatText: String
    let whereRestaurant: String
    let whereCity: String

    // Server-authoritative ordering
    let receivedAt: Date
    let receiptSequence: Int   // monotonically increasing across all challenges

    // Set at reveal time by server; nil until revealed
    var whatCorrect: Bool?
    var whereCorrect: Bool?
}

// MARK: - Scoring Race

enum ScoringRace: String {
    case what
    case whereGuess = "where"

    var displayName: String {
        switch self {
        case .what:       return "What?"
        case .whereGuess: return "Where?"
        }
    }
}
