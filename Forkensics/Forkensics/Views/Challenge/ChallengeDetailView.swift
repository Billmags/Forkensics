import SwiftUI

/// Routes to the correct sub-view based on challenge state and current player's role.
struct ChallengeDetailView: View {
    @EnvironmentObject var dataService: MockDataService
    let challenge: Challenge

    private var iAmPoster: Bool { challenge.posterId == dataService.currentPlayer.id }

    private var amIEligible: Bool {
        dataService.activeEligibles(for: challenge.id)
            .contains { $0.playerId == dataService.currentPlayer.id }
    }

    private var iHaveGuessed: Bool {
        dataService.currentPlayerLatestGuess(for: challenge.id) != nil
    }

    var body: some View {
        Group {
            switch challenge.state {
            case .revealed:
                RevealView(challenge: challenge)

            case .cancelled:
                cancelledView

            case .active, .locked:
                if iAmPoster {
                    PosterControlsView(challenge: challenge)
                } else if amIEligible && !iHaveGuessed {
                    GuessEntryView(challenge: challenge)
                } else if amIEligible && iHaveGuessed {
                    waitingView
                } else {
                    notEligibleView
                }

            case .draft:
                Text("Draft — not yet posted.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Waiting view (eligible, already guessed)
    private var waitingView: some View {
        ScrollView {
            VStack(spacing: 24) {
                ChallengeImageView(colorName: challenge.imageColor, size: 160)
                    .padding(.top, 20)

                VStack(spacing: 6) {
                    Text("Guess received!")
                        .font(.title3.bold())
                    Text("Waiting for \(remainingCount) more player\(remainingCount == 1 ? "" : "s") to guess, or for \(posterName) to reveal.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if let guess = dataService.currentPlayerLatestGuess(for: challenge.id) {
                    yourGuessCard(guess: guess)
                }

                hintSection

                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationTitle("Challenge")
    }

    private var remainingCount: Int {
        let eligibles = dataService.activeEligibles(for: challenge.id)
        let guessedIds = Set(dataService.guessAttempts(for: challenge.id).map(\.playerId))
        return eligibles.filter { !guessedIds.contains($0.playerId) }.count
    }

    private var posterName: String {
        dataService.player(for: challenge.posterId)?.displayName ?? "the poster"
    }

    private func yourGuessCard(guess: GuessAttempt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your guess")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 8) {
                Label(guess.whatText.isEmpty ? "—" : guess.whatText, systemImage: "fork.knife")
                    .font(.subheadline)
                Label("\(guess.whereRestaurant.isEmpty ? "—" : guess.whereRestaurant) · \(guess.whereCity.isEmpty ? "—" : guess.whereCity)",
                      systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var hintSection: some View {
        let hints = dataService.hints(for: challenge.id)
        return Group {
            if !hints.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hints")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(hints) { hint in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(.yellow)
                            Text(hint.text)
                                .font(.subheadline)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    // MARK: Not eligible
    private var notEligibleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("You're not in this round.")
                .font(.headline)
            Text("You joined the group after this challenge was posted.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .navigationTitle("Challenge")
    }

    // MARK: Cancelled
    private var cancelledView: some View {
        VStack(spacing: 16) {
            ChallengeImageView(colorName: challenge.imageColor, size: 120)
                .padding(.top, 20)
                .opacity(0.4)
            Text("Challenge Cancelled")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
            if let reason = challenge.cancellationReason {
                Text("\"\(reason)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Text("No points awarded.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .navigationTitle("Cancelled")
    }
}
