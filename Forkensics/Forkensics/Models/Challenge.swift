import Foundation

// MARK: - Challenge State

enum ChallengeState: String, Equatable {
    case draft
    case active
    case locked   // server scoring window; between close and reveal
    case revealed
    case cancelled

    var displayName: String {
        switch self {
        case .draft:     return "Draft"
        case .active:    return "Active"
        case .locked:    return "Scoring…"
        case .revealed:  return "Revealed"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Challenge

/// Visible game information. Canonical answers live in ChallengeSecret (server-side).
struct Challenge: Identifiable {
    let id: UUID
    let posterId: UUID
    let groupId: UUID
    /// Placeholder color for prototype (replaces real photo).
    let imageColor: String
    let postedAt: Date
    let deadlineAt: Date
    var state: ChallengeState
    /// Optional story shown only after reveal.
    var story: String?
    /// Set when poster withdraws after first guess was received.
    var cancellationReason: String?

    var isExpired: Bool {
        state == .active && Date() > deadlineAt
    }

    var timeRemainingDescription: String {
        guard state == .active else { return "" }
        let remaining = deadlineAt.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m left" }
        return "\(minutes)m left"
    }
}

// MARK: - Eligible Participant

/// Immutable posting-time snapshot of who may play this challenge.
/// The poster is excluded. Members who join after posting are excluded.
struct EligibleParticipant: Identifiable {
    let id: UUID
    let challengeId: UUID
    let playerId: UUID
    let addedAt: Date
    /// Non-nil when this participant was removed or withdrew mid-round.
    var excludedAt: Date?

    var isActive: Bool { excludedAt == nil }
}
