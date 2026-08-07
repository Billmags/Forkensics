import Foundation

struct Player: Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var avatarColor: AvatarColor

    enum AvatarColor: String, CaseIterable {
        case orange, blue, green, purple, red, yellow, pink, teal

        var hex: String {
            switch self {
            case .orange: return "F97316"
            case .blue:   return "3B82F6"
            case .green:  return "22C55E"
            case .purple: return "A855F7"
            case .red:    return "EF4444"
            case .yellow: return "EAB308"
            case .pink:   return "EC4899"
            case .teal:   return "14B8A6"
            }
        }
    }

    var initials: String {
        displayName
            .components(separatedBy: .whitespaces)
            .compactMap { $0.first.map { String($0) } }
            .prefix(2)
            .joined()
            .uppercased()
    }
}
