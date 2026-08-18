import SwiftUI

struct LeaderboardView: View {
    @EnvironmentObject var dataService: MockDataService
    @State private var selectedTab = 0

    private var entries: [LeaderboardEntry] { dataService.leaderboard() }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $selectedTab) {
                    Text("All-Time").tag(0)
                    Text("What?").tag(1)
                    Text("Where?").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                if entries.isEmpty {
                    ContentUnavailableView("No scores yet",
                        systemImage: "trophy",
                        description: Text("Complete a round to see standings."))
                } else {
                    List {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                            LeaderboardRowView(entry: entry, rank: idx + 1,
                                              score: score(for: entry),
                                              isCurrentPlayer: entry.player.id == dataService.currentPlayer.id)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Standings")
        }
    }

    private func score(for entry: LeaderboardEntry) -> Int {
        switch selectedTab {
        case 1: return entry.whatPoints
        case 2: return entry.wherePoints
        default: return entry.totalPoints
        }
    }
}

struct LeaderboardRowView: View {
    let entry: LeaderboardEntry
    let rank: Int
    let score: Int
    let isCurrentPlayer: Bool

    var body: some View {
        HStack(spacing: 14) {
            rankView
            AvatarView(player: entry.player, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.player.displayName + (isCurrentPlayer ? " (you)" : ""))
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 12) {
                    Label("\(entry.whatPoints)", systemImage: "fork.knife")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label("\(entry.wherePoints)", systemImage: "mappin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if entry.challengesWon > 0 {
                        Label("\(entry.challengesWon)", systemImage: "trophy.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
            }
            Spacer()
            Text("\(score)")
                .font(.title3.bold())
                .foregroundStyle(rank == 1 ? .yellow : .primary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .listRowBackground(isCurrentPlayer ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    private var rankView: some View {
        Group {
            switch rank {
            case 1: Text("🥇")
            case 2: Text("🥈")
            case 3: Text("🥉")
            default:
                Text("\(rank)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
            }
        }
        .font(.title3)
        .frame(width: 32)
    }
}

struct LeaderboardView_Previews: PreviewProvider {
    static var previews: some View {
        LeaderboardView()
            .environmentObject(MockDataService())
    }
}
