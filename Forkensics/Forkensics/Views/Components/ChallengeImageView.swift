import SwiftUI

/// Placeholder image for the prototype. Replaced by real photo in a future step.
struct ChallengeImageView: View {
    let colorName: String
    var size: CGFloat = 80
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(color.opacity(0.2))
                .frame(width: size, height: size)
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(color.opacity(0.4), lineWidth: 1.5)
                .frame(width: size, height: size)
            Image(systemName: "fork.knife")
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch colorName {
        case "orange": return .orange
        case "red":    return .red
        case "green":  return .green
        case "blue":   return .blue
        case "purple": return .purple
        case "yellow": return .yellow
        case "pink":   return .pink
        case "teal":   return .teal
        default:       return .gray
        }
    }
}

/// Circular avatar showing player initials.
struct AvatarView: View {
    let player: Player
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarColor.opacity(0.2))
                .frame(width: size, height: size)
            Circle()
                .strokeBorder(avatarColor.opacity(0.5), lineWidth: 1.5)
                .frame(width: size, height: size)
            Text(player.initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(avatarColor)
        }
    }

    private var avatarColor: Color {
        switch player.avatarColor {
        case .orange: return .orange
        case .blue:   return .blue
        case .green:  return .green
        case .purple: return .purple
        case .red:    return .red
        case .yellow: return .yellow
        case .pink:   return .pink
        case .teal:   return .teal
        }
    }
}

/// Badge showing challenge state.
struct StateBadge: View {
    let state: ChallengeState

    var body: some View {
        Text(state.displayName.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 1))
    }

    private var color: Color {
        switch state {
        case .draft:     return .gray
        case .active:    return .blue
        case .locked:    return .orange
        case .revealed:  return .green
        case .cancelled: return .gray
        }
    }
}

struct ChallengeImageView_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 20) {
            ChallengeImageView(colorName: "orange", size: 80)
            ChallengeImageView(colorName: "blue", size: 80)
            ChallengeImageView(colorName: "pink", size: 80)
        }
        .padding()
    }
}
