import Foundation

struct Comment: Identifiable {
    let id: UUID
    let challengeId: UUID
    let authorId: UUID
    var text: String
    let postedAt: Date
    var isDeleted: Bool = false
}

struct Reaction: Identifiable {
    let id: UUID
    let challengeId: UUID
    let playerId: UUID
    let emoji: String
}
