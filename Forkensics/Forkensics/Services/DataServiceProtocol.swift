import Foundation

/// Documents the interface contract between views and the data layer.
/// MockDataService fulfills this protocol in Step 1.
/// A future SupabaseDataService will fulfill it once the backend step is approved.
///
/// Views reference MockDataService directly via @EnvironmentObject for Step 1.
/// When the real service is introduced, injection is swapped at the app root.
protocol DataServiceProtocol {

    // MARK: Current player
    var currentPlayer: Player { get }

    // MARK: Challenges
    var challenges: [Challenge] { get }
    func challenge(for id: UUID) -> Challenge?

    // MARK: Secrets (authorized access only)
    /// Returns the secret only if currentPlayer is the poster, or challenge is revealed.
    func secret(for challengeId: UUID) -> ChallengeSecret?

    // MARK: Participants
    func eligibleParticipants(for challengeId: UUID) -> [EligibleParticipant]
    /// Active (non-excluded) eligible participants.
    func activeEligibles(for challengeId: UUID) -> [EligibleParticipant]

    // MARK: Guesses
    /// All GuessAttempts for a challenge. Before reveal, only the current player's own are surfaced by views.
    func guessAttempts(for challengeId: UUID) -> [GuessAttempt]
    /// The most recently submitted GuessAttempt for the current player on a given challenge.
    func currentPlayerLatestGuess(for challengeId: UUID) -> GuessAttempt?

    // MARK: Hints
    func hints(for challengeId: UUID) -> [Hint]

    // MARK: Scores
    func scoreEvents(for challengeId: UUID) -> [ScoreEvent]

    // MARK: Conversation
    func comments(for challengeId: UUID) -> [Comment]
    func reactions(for challengeId: UUID) -> [Reaction]

    // MARK: Players
    func player(for id: UUID) -> Player?

    // MARK: Leaderboard
    func leaderboard() -> [LeaderboardEntry]

    // MARK: Actions — poster
    func updateSecret(for challengeId: UUID, dish: String, aliases: [String], restaurant: String, city: String)
    func postHint(for challengeId: UUID, text: String)
    func revealChallenge(_ challengeId: UUID)
    func cancelChallenge(_ challengeId: UUID, reason: String)
    func createChallenge(imageColor: String, dish: String, aliases: [String], restaurant: String, city: String, story: String?, duration: TimeInterval)

    // MARK: Actions — guesser
    func submitGuess(for challengeId: UUID, what: String, restaurant: String, city: String)

    // MARK: Actions — post-reveal
    func addComment(to challengeId: UUID, text: String)
    func addReaction(to challengeId: UUID, emoji: String)
    func deleteComment(_ commentId: UUID, from challengeId: UUID)
}

struct LeaderboardEntry: Identifiable {
    let id: UUID       // player id
    let player: Player
    let totalPoints: Int
    let whatPoints: Int
    let wherePoints: Int
    let challengesWon: Int
}
