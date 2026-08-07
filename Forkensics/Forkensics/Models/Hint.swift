import Foundation

/// A poster-written hint broadcast equally to all eligible players.
/// No point penalty. Visible with timestamp throughout the round.
struct Hint: Identifiable {
    let id: UUID
    let challengeId: UUID
    let text: String
    let postedAt: Date
}
