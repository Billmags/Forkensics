import Foundation

/// Immutable record of points awarded for one player in one race of one challenge.
/// Current ladder: first 100, second 80, third 60, fourth and later zero.
/// Scores are never silently overwritten; corrections produce a new event linked to CorrectionEvent.
struct ScoreEvent: Identifiable {
    let id: UUID
    let challengeId: UUID
    let playerId: UUID
    let race: ScoringRace
    let points: Int
    let rank: Int
    let rulesVersion: String   // e.g. "1.0"
    let calculatedAt: Date
}

/// Visible record of a score correction. Original ScoreEvents remain immutable.
struct CorrectionEvent: Identifiable {
    let id: UUID
    let challengeId: UUID
    let correctedByPlayerId: UUID
    let reason: String
    let correctedAt: Date
}
