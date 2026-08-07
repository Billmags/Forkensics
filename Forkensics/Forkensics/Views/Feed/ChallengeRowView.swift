import SwiftUI

struct ChallengeRowView: View {
    let challenge: Challenge
    @EnvironmentObject var dataService: MockDataService

    private var poster: Player? { dataService.player(for: challenge.posterId) }
    private var guessCount: Int { dataService.guessAttempts(for: challenge.id).map(\.playerId).unique.count }
    private var eligibleCount: Int { dataService.activeEligibles(for: challenge.id).count }
    private var iAmPoster: Bool { challenge.posterId == dataService.currentPlayer.id }
    private var iHaveGuessed: Bool {
        dataService.currentPlayerLatestGuess(for: challenge.id) != nil
    }

    var body: some View {
        HStack(spacing: 14) {
            ChallengeImageView(colorName: challenge.imageColor, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let poster {
                        AvatarView(player: poster, size: 22)
                        Text(iAmPoster ? "Your challenge" : poster.displayName)
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    StateBadge(state: challenge.state)
                }

                subtitleText
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if challenge.state == .active {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(challenge.timeRemainingDescription)
                            .font(.caption2)
                    }
                    .foregroundStyle(challenge.deadlineAt.timeIntervalSinceNow < 3600 ? .orange : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitleText: Text {
        switch challenge.state {
        case .active:
            if iAmPoster {
                return Text("\(guessCount) of \(eligibleCount) guessed")
            } else if iHaveGuessed {
                return Text("Your guess is in • waiting for reveal")
            } else {
                return Text("Tap to guess!")
            }
        case .locked:
            return Text("Scoring in progress…")
        case .revealed:
            let events = dataService.scoreEvents(for: challenge.id)
            let myPoints = events.filter { $0.playerId == dataService.currentPlayer.id }.reduce(0) { $0 + $1.points }
            return Text("Revealed • You scored \(myPoints) pts")
        case .cancelled:
            return Text("Cancelled")
        case .draft:
            return Text("Draft")
        }
    }
}

// MARK: - Array unique helper
private extension Array where Element: Hashable {
    var unique: [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
