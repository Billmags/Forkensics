import SwiftUI

struct RevealView: View {
    @EnvironmentObject var dataService: MockDataService
    let challenge: Challenge

    private var secret: ChallengeSecret? { dataService.secret(for: challenge.id) }
    private var poster: Player? { dataService.player(for: challenge.posterId) }
    private var scoreEvents: [ScoreEvent] { dataService.scoreEvents(for: challenge.id) }
    private var eligibles: [EligibleParticipant] { dataService.activeEligibles(for: challenge.id) }
    private var attempts: [GuessAttempt] { dataService.guessAttempts(for: challenge.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Photo
                ChallengeImageView(colorName: challenge.imageColor, size: 200)
                    .padding(.top, 16)

                // Answer reveal
                if let secret {
                    answerCard(secret: secret)
                }

                // Story
                if let story = challenge.story {
                    storyCard(story: story)
                }

                Divider()

                // What? Race
                raceSection(race: .what)

                Divider()

                // Where? Race
                raceSection(race: .whereGuess)

                Divider()

                // Challenge winner
                challengeWinnerSection

                Divider()

                // Conversation
                ConversationView(challenge: challenge)

                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationTitle("Reveal")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Answer Card

    private func answerCard(secret: ChallengeSecret) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(secret.canonicalDish)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if !secret.dishAliases.isEmpty {
                    Text("Also: " + secret.dishAliases.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.orange)
                Text("\(secret.canonicalRestaurant) · \(secret.canonicalCity)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let url = mapsURL(restaurant: secret.canonicalRestaurant, city: secret.canonicalCity) {
                    Link(destination: url) {
                        Image(systemName: "map.fill")
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .padding()
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func mapsURL(restaurant: String, city: String) -> URL? {
        let q = "\(restaurant) \(city)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "http://maps.apple.com/?q=\(q)")
    }

    // MARK: - Story Card

    private func storyCard(story: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Story from \(poster?.displayName ?? "poster")", systemImage: "quote.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(story)
                .font(.subheadline)
                .italic()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Race Section

    private func raceSection(race: ScoringRace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(race.displayName + " Results")
                .font(.headline)

            let raceEvents = scoreEvents.filter { $0.race == race }.sorted { $0.rank < $1.rank }
            let rankedIds = Set(raceEvents.map(\.playerId))

            // Ranked players
            ForEach(raceEvents) { event in
                if let player = dataService.player(for: event.playerId),
                   let attempt = latestAttempt(for: event.playerId) {
                    raceRow(player: player, event: event, attempt: attempt, race: race)
                }
            }

            // Players with no correct answer
            let noScore = eligibles.filter { !rankedIds.contains($0.playerId) }
            ForEach(noScore) { ep in
                if let player = dataService.player(for: ep.playerId) {
                    let attempt = latestAttempt(for: ep.playerId)
                    noScoreRow(player: player, attempt: attempt, race: race)
                }
            }
        }
    }

    private func raceRow(player: Player, event: ScoreEvent, attempt: GuessAttempt, race: ScoringRace) -> some View {
        let isMe = player.id == dataService.currentPlayer.id
        let guessText = race == .what ? attempt.whatText :
            "\(attempt.whereRestaurant) · \(attempt.whereCity)"
        return HStack(spacing: 12) {
            rankBadge(rank: event.rank)
            AvatarView(player: player, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(player.displayName + (isMe ? " (you)" : ""))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("+\(event.points) pts")
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                }
                Text(guessText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(isMe ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private func noScoreRow(player: Player, attempt: GuessAttempt?, race: ScoringRace) -> some View {
        let isMe = player.id == dataService.currentPlayer.id
        let guessText: String
        if let attempt {
            guessText = race == .what ? attempt.whatText : "\(attempt.whereRestaurant) · \(attempt.whereCity)"
        } else {
            guessText = "No answer submitted"
        }
        return HStack(spacing: 12) {
            Text("—")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
                .frame(width: 28)
            AvatarView(player: player, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(player.displayName + (isMe ? " (you)" : ""))
                        .font(.subheadline)
                        .foregroundStyle(attempt != nil ? .primary : .secondary)
                    Spacer()
                    Text("0 pts")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(guessText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: attempt != nil ? "xmark.circle.fill" : "minus.circle")
                .foregroundStyle(attempt != nil ? .red : .secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(isMe ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private func rankBadge(rank: Int) -> some View {
        Text("#\(rank)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(rank == 1 ? .yellow : .secondary)
            .frame(width: 28)
    }

    // MARK: - Challenge Winner

    private var challengeWinnerSection: some View {
        let combined = combinedScores()
        let winner = combined.max(by: { $0.value < $1.value })

        return VStack(spacing: 12) {
            Text("🏆 Challenge Winner")
                .font(.headline)

            if let winner, let player = dataService.player(for: winner.key) {
                HStack(spacing: 12) {
                    AvatarView(player: player, size: 48)
                    VStack(alignment: .leading) {
                        Text(player.displayName)
                            .font(.title3.bold())
                        Text("\(winner.value) combined points")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "trophy.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                }
                .padding()
                .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                // Full combined standings
                VStack(spacing: 8) {
                    ForEach(combined.sorted(by: { $0.value > $1.value }), id: \.key) { pid, pts in
                        if let p = dataService.player(for: pid), pid != winner.key {
                            HStack {
                                AvatarView(player: p, size: 28)
                                Text(p.displayName)
                                    .font(.subheadline)
                                Spacer()
                                Text("\(pts) pts")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("No correct answers — no winner this round.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func combinedScores() -> [UUID: Int] {
        var totals: [UUID: Int] = [:]
        for event in scoreEvents {
            totals[event.playerId, default: 0] += event.points
        }
        return totals
    }

    private func latestAttempt(for playerId: UUID) -> GuessAttempt? {
        attempts.filter { $0.playerId == playerId }
            .sorted { $0.receiptSequence > $1.receiptSequence }
            .first
    }
}
