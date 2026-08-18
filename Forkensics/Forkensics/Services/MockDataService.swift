import Foundation
import Combine

// MARK: - MockDataService

final class MockDataService: ObservableObject, DataServiceProtocol {

    // MARK: Published state
    @Published var challenges: [Challenge] = []
    @Published var eligibles: [UUID: [EligibleParticipant]] = [:]
    @Published var guessAttemptsByChallenge: [UUID: [GuessAttempt]] = [:]
    @Published var hintsByChallenge: [UUID: [Hint]] = [:]
    @Published var scoreEventsByChallenge: [UUID: [ScoreEvent]] = [:]
    @Published var commentsByChallenge: [UUID: [Comment]] = [:]
    @Published var reactionsByChallenge: [UUID: [Reaction]] = [:]

    // MARK: Private (authorization-gated)
    private var secrets: [UUID: ChallengeSecret] = [:]

    // MARK: Players
    @Published var players: [Player] = []
    let currentPlayer: Player

    // MARK: Receipt sequence
    private var receiptSequenceCounter = 0
    private func nextSeq() -> Int { receiptSequenceCounter += 1; return receiptSequenceCounter }

    // MARK: Init
    init() {
        let (all, current) = MockDataService.buildPlayers()
        self.players = all
        self.currentPlayer = current
        MockDataService.populate(service: self)
    }

    // MARK: - Accessors

    func challenge(for id: UUID) -> Challenge? {
        challenges.first { $0.id == id }
    }

    func secret(for challengeId: UUID) -> ChallengeSecret? {
        guard let challenge = challenge(for: challengeId) else { return nil }
        let isPoster = challenge.posterId == currentPlayer.id
        let isRevealed = challenge.state == .revealed
        guard isPoster || isRevealed else { return nil }
        return secrets[challengeId]
    }

    func eligibleParticipants(for challengeId: UUID) -> [EligibleParticipant] {
        eligibles[challengeId] ?? []
    }

    func activeEligibles(for challengeId: UUID) -> [EligibleParticipant] {
        eligibleParticipants(for: challengeId).filter { $0.isActive }
    }

    func guessAttempts(for challengeId: UUID) -> [GuessAttempt] {
        guessAttemptsByChallenge[challengeId] ?? []
    }

    func currentPlayerLatestGuess(for challengeId: UUID) -> GuessAttempt? {
        guessAttempts(for: challengeId)
            .filter { $0.playerId == currentPlayer.id }
            .sorted { $0.receiptSequence > $1.receiptSequence }
            .first
    }

    func hints(for challengeId: UUID) -> [Hint] {
        (hintsByChallenge[challengeId] ?? []).sorted { $0.postedAt < $1.postedAt }
    }

    func scoreEvents(for challengeId: UUID) -> [ScoreEvent] {
        scoreEventsByChallenge[challengeId] ?? []
    }

    func comments(for challengeId: UUID) -> [Comment] {
        (commentsByChallenge[challengeId] ?? []).sorted { $0.postedAt < $1.postedAt }
    }

    func reactions(for challengeId: UUID) -> [Reaction] {
        reactionsByChallenge[challengeId] ?? []
    }

    func player(for id: UUID) -> Player? {
        players.first { $0.id == id }
    }

    func leaderboard() -> [LeaderboardEntry] {
        var totals: [UUID: (total: Int, what: Int, where_: Int, wins: Int)] = [:]
        for events in scoreEventsByChallenge.values {
            for e in events {
                var t = totals[e.playerId] ?? (0, 0, 0, 0)
                t.total += e.points
                if e.race == .what { t.what += e.points }
                else { t.where_ += e.points }
                totals[e.playerId] = t
            }
        }
        // Count challenge wins (highest combined score)
        for challenge in challenges where challenge.state == .revealed {
            let events = scoreEvents(for: challenge.id)
            let combined = Dictionary(grouping: events, by: { $0.playerId })
                .mapValues { $0.reduce(0) { $0 + $1.points } }
            if let winner = combined.max(by: { $0.value < $1.value }) {
                var t = totals[winner.key] ?? (0, 0, 0, 0)
                t.wins += 1
                totals[winner.key] = t
            }
        }
        return players
            .compactMap { p -> LeaderboardEntry? in
                let t = totals[p.id] ?? (0, 0, 0, 0)
                return LeaderboardEntry(id: p.id, player: p, totalPoints: t.total,
                                        whatPoints: t.what, wherePoints: t.where_, challengesWon: t.wins)
            }
            .sorted { $0.totalPoints > $1.totalPoints }
    }

    // MARK: - Actions (Poster)

    func updateSecret(for challengeId: UUID, dish: String, aliases: [String], restaurant: String, city: String) {
        guard var s = secrets[challengeId], !s.hasFirstGuess else { return }
        s.canonicalDish = dish
        s.dishAliases = aliases
        s.canonicalRestaurant = restaurant
        s.canonicalCity = city
        secrets[challengeId] = s
        objectWillChange.send()
    }

    func postHint(for challengeId: UUID, text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let hint = Hint(id: UUID(), challengeId: challengeId, text: text, postedAt: Date())
        hintsByChallenge[challengeId, default: []].append(hint)
    }

    func revealChallenge(_ challengeId: UUID) {
        guard let idx = challenges.firstIndex(where: { $0.id == challengeId }),
              let secret = secrets[challengeId] else { return }

        // Lock first, then score and reveal
        challenges[idx].state = .locked

        // Compute correctness on all attempts
        var attempts = guessAttemptsByChallenge[challengeId] ?? []
        for i in attempts.indices {
            attempts[i].whatCorrect = isWhatCorrect(guess: attempts[i].whatText, secret: secret)
            attempts[i].whereCorrect = isWhereCorrect(
                restaurant: attempts[i].whereRestaurant,
                city: attempts[i].whereCity,
                secret: secret
            )
        }
        guessAttemptsByChallenge[challengeId] = attempts

        // Compute score events
        scoreEventsByChallenge[challengeId] = computeScoreEvents(for: challengeId, secret: secret)

        challenges[idx].state = .revealed
    }

    func cancelChallenge(_ challengeId: UUID, reason: String) {
        guard let idx = challenges.firstIndex(where: { $0.id == challengeId }) else { return }
        challenges[idx].state = .cancelled
        challenges[idx].cancellationReason = reason
    }

    func createChallenge(imageColor: String, dish: String, aliases: [String],
                         restaurant: String, city: String, story: String?, duration: TimeInterval) {
        let id = UUID()
        let now = Date()
        let challenge = Challenge(
            id: id, posterId: currentPlayer.id, groupId: MockIDs.group,
            imageColor: imageColor, postedAt: now,
            deadlineAt: now.addingTimeInterval(duration), state: .active, story: story
        )
        let secret = ChallengeSecret(
            challengeId: id, canonicalDish: dish, dishAliases: aliases,
            canonicalRestaurant: restaurant, canonicalCity: city, hasFirstGuess: false
        )
        // Eligible: all players except poster
        let eligible = players
            .filter { $0.id != currentPlayer.id }
            .map { EligibleParticipant(id: UUID(), challengeId: id, playerId: $0.id, addedAt: now) }

        challenges.insert(challenge, at: 0)
        secrets[id] = secret
        eligibles[id] = eligible
        guessAttemptsByChallenge[id] = []
        hintsByChallenge[id] = []
        scoreEventsByChallenge[id] = []
        commentsByChallenge[id] = []
        reactionsByChallenge[id] = []
    }

    // MARK: - Actions (Guesser)

    func submitGuess(for challengeId: UUID, what: String, restaurant: String, city: String) {
        guard let challengeIdx = challenges.firstIndex(where: { $0.id == challengeId }),
              challenges[challengeIdx].state == .active else { return }

        let attempt = GuessAttempt(
            id: UUID(), challengeId: challengeId, playerId: currentPlayer.id,
            whatText: what, whereRestaurant: restaurant, whereCity: city,
            receivedAt: Date(), receiptSequence: nextSeq()
        )
        guessAttemptsByChallenge[challengeId, default: []].append(attempt)

        // Lock poster editing if this is the first guess
        if var s = secrets[challengeId], !s.hasFirstGuess {
            s.hasFirstGuess = true
            secrets[challengeId] = s
        }

        // Check all-guessed auto-reveal
        checkAutoReveal(challengeId: challengeId)
    }

    // MARK: - Actions (Post-reveal)

    func addComment(to challengeId: UUID, text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let comment = Comment(id: UUID(), challengeId: challengeId,
                              authorId: currentPlayer.id, text: text, postedAt: Date())
        commentsByChallenge[challengeId, default: []].append(comment)
    }

    func addReaction(to challengeId: UUID, emoji: String) {
        // One reaction per player per emoji
        var existing = reactionsByChallenge[challengeId] ?? []
        if let i = existing.firstIndex(where: { $0.playerId == currentPlayer.id && $0.emoji == emoji }) {
            existing.remove(at: i)
        } else {
            existing.append(Reaction(id: UUID(), challengeId: challengeId, playerId: currentPlayer.id, emoji: emoji))
        }
        reactionsByChallenge[challengeId] = existing
    }

    func deleteComment(_ commentId: UUID, from challengeId: UUID) {
        guard var list = commentsByChallenge[challengeId],
              let i = list.firstIndex(where: { $0.id == commentId }),
              list[i].authorId == currentPlayer.id else { return }
        list[i].isDeleted = true
        commentsByChallenge[challengeId] = list
    }

    // MARK: - Private Helpers

    private func checkAutoReveal(challengeId: UUID) {
        let active = activeEligibles(for: challengeId)
        let guessedIds = Set(
            (guessAttemptsByChallenge[challengeId] ?? []).map { $0.playerId }
        )
        let allGuessed = active.allSatisfy { guessedIds.contains($0.playerId) }
        if allGuessed { revealChallenge(challengeId) }
    }

    // MARK: - Text Normalization

    func normalize(_ text: String) -> String {
        AnswerMatcher.normalize(text)
    }

    func isWhatCorrect(guess: String, secret: ChallengeSecret) -> Bool {
        AnswerMatcher.matchesDish(
            guess: guess,
            canonical: secret.canonicalDish,
            aliases: secret.dishAliases,
            version: secret.answerMatcherVersion
        )
    }

    func isWhereCorrect(restaurant: String, city: String, secret: ChallengeSecret) -> Bool {
        _ = city
        return AnswerMatcher.matchesRestaurant(
            guess: restaurant,
            canonical: secret.canonicalRestaurant,
            version: secret.answerMatcherVersion
        )
    }

    // MARK: - Scoring

    private func computeScoreEvents(for challengeId: UUID, secret: ChallengeSecret) -> [ScoreEvent] {
        let active = activeEligibles(for: challengeId)
        guard !active.isEmpty,
              let challenge = challenge(for: challengeId) else { return [] }
        let eligibleIds = Set(active.map { $0.playerId })
        let attempts = guessAttemptsByChallenge[challengeId] ?? []
        var events: [ScoreEvent] = []

        for race in [ScoringRace.what, ScoringRace.whereGuess] {
            // Find first correct attempt per eligible player
            var firstCorrects: [(playerId: UUID, seq: Int, receivedAt: Date)] = []
            for pid in eligibleIds {
                let playerAttempts = attempts.filter { $0.playerId == pid }
                let correct = playerAttempts.filter {
                    race == .what ? ($0.whatCorrect == true) : ($0.whereCorrect == true)
                }.sorted {
                    if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
                    return $0.receiptSequence < $1.receiptSequence
                }
                if let first = correct.first {
                    firstCorrects.append((pid, first.receiptSequence, first.receivedAt))
                }
            }

            // Sort by receivedAt then sequence
            firstCorrects.sort {
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
                return $0.seq < $1.seq
            }

            // Standard competition ranking with tie support
            var rank = 1
            var i = 0
            while i < firstCorrects.count {
                var j = i
                while j < firstCorrects.count - 1 &&
                      firstCorrects[j + 1].receivedAt == firstCorrects[i].receivedAt &&
                      firstCorrects[j + 1].seq == firstCorrects[i].seq {
                    j += 1
                }
                let points = ScoringRules.points(
                    forRank: rank,
                    version: challenge.rulesVersion
                )
                for k in i...j {
                    events.append(ScoreEvent(
                        id: UUID(), challengeId: challengeId,
                        playerId: firstCorrects[k].playerId, race: race,
                        points: points, rank: rank,
                        rulesVersion: challenge.rulesVersion, calculatedAt: Date()
                    ))
                }
                rank += (j - i + 1)
                i = j + 1
            }
        }
        return events
    }
}

// MARK: - Mock Player IDs

enum MockIDs {
    static let bill  = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let jean  = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let tom   = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let mary  = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let steve = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    static let group = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

    // Challenge IDs
    static let c1 = UUID(uuidString: "00000000-0000-0000-0001-000000000001")! // active, jean posted
    static let c2 = UUID(uuidString: "00000000-0000-0000-0001-000000000002")! // active, tom posted, bill guessed
    static let c3 = UUID(uuidString: "00000000-0000-0000-0001-000000000003")! // active, bill posted, no guesses
    static let c4 = UUID(uuidString: "00000000-0000-0000-0001-000000000004")! // active, bill posted, has guesses
    static let c5 = UUID(uuidString: "00000000-0000-0000-0001-000000000005")! // revealed, mary posted
    static let c6 = UUID(uuidString: "00000000-0000-0000-0001-000000000006")! // revealed, tie scenario
    static let c7 = UUID(uuidString: "00000000-0000-0000-0001-000000000007")! // cancelled
}

// MARK: - Mock Data Population

private extension MockDataService {

    static func buildPlayers() -> ([Player], Player) {
        let bill  = Player(id: MockIDs.bill,  displayName: "Bill",  avatarColor: .blue)
        let jean  = Player(id: MockIDs.jean,  displayName: "Jean",  avatarColor: .purple)
        let tom   = Player(id: MockIDs.tom,   displayName: "Tom",   avatarColor: .orange)
        let mary  = Player(id: MockIDs.mary,  displayName: "Mary",  avatarColor: .green)
        let steve = Player(id: MockIDs.steve, displayName: "Steve", avatarColor: .red)
        return ([bill, jean, tom, mary, steve], bill)
    }

    static func populate(service s: MockDataService) {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        func later(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

        // ── Challenge 1: Active – Jean posted, Bill hasn't guessed ──
        let ch1 = Challenge(id: MockIDs.c1, posterId: MockIDs.jean, groupId: MockIDs.group,
                            imageColor: "orange", postedAt: ago(2), deadlineAt: later(22), state: .active)
        s.challenges.append(ch1)
        s.secrets[MockIDs.c1] = ChallengeSecret(
            challengeId: MockIDs.c1, canonicalDish: "Chicken Tikka Masala",
            dishAliases: ["chicken tikka", "tikka masala"],
            canonicalRestaurant: "Tamarind Tribeca", canonicalCity: "New York", hasFirstGuess: true)
        s.eligibles[MockIDs.c1] = [
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c1, playerId: MockIDs.bill,  addedAt: ago(2)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c1, playerId: MockIDs.tom,   addedAt: ago(2)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c1, playerId: MockIDs.mary,  addedAt: ago(2)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c1, playerId: MockIDs.steve, addedAt: ago(2)),
        ]
        s.hintsByChallenge[MockIDs.c1] = [
            Hint(id: UUID(), challengeId: MockIDs.c1, text: "It's from the Indian subcontinent 🌶", postedAt: ago(1))
        ]
        // Tom and Steve have guessed; Bill and Mary have not
        s.guessAttemptsByChallenge[MockIDs.c1] = [
            GuessAttempt(id: UUID(), challengeId: MockIDs.c1, playerId: MockIDs.tom,
                         whatText: "Chicken Curry", whereRestaurant: "Tamarind Tribeca", whereCity: "New York",
                         receivedAt: ago(1.5), receiptSequence: s.nextSeq()),
            GuessAttempt(id: UUID(), challengeId: MockIDs.c1, playerId: MockIDs.steve,
                         whatText: "Tikka Masala", whereRestaurant: "Tamarind Tribeca", whereCity: "New York",
                         receivedAt: ago(1.2), receiptSequence: s.nextSeq()),
        ]
        s.scoreEventsByChallenge[MockIDs.c1] = []
        s.commentsByChallenge[MockIDs.c1] = []
        s.reactionsByChallenge[MockIDs.c1] = []

        // ── Challenge 2: Active – Tom posted, Bill has guessed incorrectly ──
        let ch2 = Challenge(id: MockIDs.c2, posterId: MockIDs.tom, groupId: MockIDs.group,
                            imageColor: "red", postedAt: ago(3), deadlineAt: later(21), state: .active)
        s.challenges.append(ch2)
        s.secrets[MockIDs.c2] = ChallengeSecret(
            challengeId: MockIDs.c2, canonicalDish: "Reuben Sandwich",
            dishAliases: ["reuben"],
            canonicalRestaurant: "Katz's Delicatessen", canonicalCity: "New York", hasFirstGuess: true)
        s.eligibles[MockIDs.c2] = [
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c2, playerId: MockIDs.bill,  addedAt: ago(3)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c2, playerId: MockIDs.jean,  addedAt: ago(3)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c2, playerId: MockIDs.mary,  addedAt: ago(3)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c2, playerId: MockIDs.steve, addedAt: ago(3)),
        ]
        s.hintsByChallenge[MockIDs.c2] = []
        // Bill guessed wrong – can edit
        s.guessAttemptsByChallenge[MockIDs.c2] = [
            GuessAttempt(id: UUID(), challengeId: MockIDs.c2, playerId: MockIDs.bill,
                         whatText: "Club Sandwich", whereRestaurant: "Katz's", whereCity: "New York",
                         receivedAt: ago(2), receiptSequence: s.nextSeq()),
        ]
        s.scoreEventsByChallenge[MockIDs.c2] = []
        s.commentsByChallenge[MockIDs.c2] = []
        s.reactionsByChallenge[MockIDs.c2] = []

        // ── Challenge 3: Active – Bill posted, NO guesses yet ──
        let ch3 = Challenge(id: MockIDs.c3, posterId: MockIDs.bill, groupId: MockIDs.group,
                            imageColor: "green", postedAt: ago(0.5), deadlineAt: later(1.5), state: .active)
        s.challenges.append(ch3)
        s.secrets[MockIDs.c3] = ChallengeSecret(
            challengeId: MockIDs.c3, canonicalDish: "Omakase",
            dishAliases: ["sushi omakase", "chef's choice sushi", "omakase sushi"],
            canonicalRestaurant: "Nobu", canonicalCity: "New York", hasFirstGuess: false)  // <-- editable
        s.eligibles[MockIDs.c3] = [
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c3, playerId: MockIDs.jean,  addedAt: ago(0.5)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c3, playerId: MockIDs.tom,   addedAt: ago(0.5)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c3, playerId: MockIDs.mary,  addedAt: ago(0.5)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c3, playerId: MockIDs.steve, addedAt: ago(0.5)),
        ]
        s.hintsByChallenge[MockIDs.c3] = []
        s.guessAttemptsByChallenge[MockIDs.c3] = []
        s.scoreEventsByChallenge[MockIDs.c3] = []
        s.commentsByChallenge[MockIDs.c3] = []
        s.reactionsByChallenge[MockIDs.c3] = []

        // ── Challenge 4: Active – Bill posted, Jean has guessed, edit LOCKED ──
        let ch4 = Challenge(id: MockIDs.c4, posterId: MockIDs.bill, groupId: MockIDs.group,
                            imageColor: "blue", postedAt: ago(4), deadlineAt: later(44), state: .active,
                            story: "The best pizza I've ever had — no contest.")
        s.challenges.append(ch4)
        s.secrets[MockIDs.c4] = ChallengeSecret(
            challengeId: MockIDs.c4, canonicalDish: "Margherita Pizza",
            dishAliases: ["margherita", "margherita pie"],
            canonicalRestaurant: "Lucali", canonicalCity: "Brooklyn", hasFirstGuess: true)  // <-- locked
        s.eligibles[MockIDs.c4] = [
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c4, playerId: MockIDs.jean,  addedAt: ago(4)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c4, playerId: MockIDs.tom,   addedAt: ago(4)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c4, playerId: MockIDs.mary,  addedAt: ago(4)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c4, playerId: MockIDs.steve, addedAt: ago(4)),
        ]
        s.hintsByChallenge[MockIDs.c4] = [
            Hint(id: UUID(), challengeId: MockIDs.c4, text: "Classic New York style 🍕", postedAt: ago(2))
        ]
        s.guessAttemptsByChallenge[MockIDs.c4] = [
            GuessAttempt(id: UUID(), challengeId: MockIDs.c4, playerId: MockIDs.jean,
                         whatText: "Pepperoni Pizza", whereRestaurant: "Lucali", whereCity: "Brooklyn",
                         receivedAt: ago(3), receiptSequence: s.nextSeq()),
        ]
        s.scoreEventsByChallenge[MockIDs.c4] = []
        s.commentsByChallenge[MockIDs.c4] = []
        s.reactionsByChallenge[MockIDs.c4] = []

        // ── Challenge 5: Revealed – Mary posted, full results ──
        // Eligible: Bill, Jean, Tom, Steve (4)
        // What? Jean(1st,4pts) Bill(2nd,3pts) Steve(3rd,2pts) Tom(0)
        // Where? Bill(1st,4pts) Tom(2nd,3pts) Jean(0) Steve(0)
        // Combined: Bill=7 🏆, Jean=4, Tom=3, Steve=2
        let ch5 = Challenge(id: MockIDs.c5, posterId: MockIDs.mary, groupId: MockIDs.group,
                            imageColor: "yellow", postedAt: ago(48), deadlineAt: ago(24), state: .revealed,
                            story: "Wahoo's after the beach — perfect summer tacos! 🌊")
        s.challenges.append(ch5)
        s.secrets[MockIDs.c5] = ChallengeSecret(
            challengeId: MockIDs.c5, canonicalDish: "Fish Tacos",
            dishAliases: ["fish taco"],
            canonicalRestaurant: "Wahoo's Fish Taco", canonicalCity: "Los Angeles", hasFirstGuess: true)
        s.eligibles[MockIDs.c5] = [
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.bill,  addedAt: ago(48)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.jean,  addedAt: ago(48)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.tom,   addedAt: ago(48)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.steve, addedAt: ago(48)),
        ]
        s.hintsByChallenge[MockIDs.c5] = [
            Hint(id: UUID(), challengeId: MockIDs.c5, text: "Beach town vibes 🏄", postedAt: ago(47))
        ]
        let t5 = ago(45)
        s.guessAttemptsByChallenge[MockIDs.c5] = [
            GuessAttempt(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.jean,
                         whatText: "Fish Tacos", whereRestaurant: "Wahoo's Fish Taco", whereCity: "San Diego",
                         receivedAt: t5.addingTimeInterval(300), receiptSequence: s.nextSeq(),
                         whatCorrect: true, whereCorrect: false),
            GuessAttempt(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.bill,
                         whatText: "Fish Tacos", whereRestaurant: "Wahoo's Fish Taco", whereCity: "Los Angeles",
                         receivedAt: t5.addingTimeInterval(480), receiptSequence: s.nextSeq(),
                         whatCorrect: true, whereCorrect: true),
            GuessAttempt(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.tom,
                         whatText: "Shrimp Tacos", whereRestaurant: "Wahoo's Fish Taco", whereCity: "Los Angeles",
                         receivedAt: t5.addingTimeInterval(720), receiptSequence: s.nextSeq(),
                         whatCorrect: false, whereCorrect: true),
            GuessAttempt(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.steve,
                         whatText: "fish taco", whereRestaurant: "Cabo's", whereCity: "Los Angeles",
                         receivedAt: t5.addingTimeInterval(900), receiptSequence: s.nextSeq(),
                         whatCorrect: true, whereCorrect: false),
        ]
        s.scoreEventsByChallenge[MockIDs.c5] = [
            ScoreEvent(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.jean,  race: .what, points: 4, rank: 1, rulesVersion: "1.0", calculatedAt: ago(24)),
            ScoreEvent(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.bill,  race: .what, points: 3, rank: 2, rulesVersion: "1.0", calculatedAt: ago(24)),
            ScoreEvent(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.steve, race: .what, points: 2, rank: 3, rulesVersion: "1.0", calculatedAt: ago(24)),
            ScoreEvent(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.bill,  race: .whereGuess, points: 4, rank: 1, rulesVersion: "1.0", calculatedAt: ago(24)),
            ScoreEvent(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.tom,   race: .whereGuess, points: 3, rank: 2, rulesVersion: "1.0", calculatedAt: ago(24)),
        ]
        s.commentsByChallenge[MockIDs.c5] = [
            Comment(id: UUID(), challengeId: MockIDs.c5, authorId: MockIDs.jean,
                    text: "I WAS SO CLOSE on the city 😭", postedAt: ago(23.8)),
            Comment(id: UUID(), challengeId: MockIDs.c5, authorId: MockIDs.bill,
                    text: "Been there twice this year, it's 🔥", postedAt: ago(23.5)),
            Comment(id: UUID(), challengeId: MockIDs.c5, authorId: MockIDs.tom,
                    text: "Fish tacos?? I thought shrimp 🤦", postedAt: ago(23)),
            Comment(id: UUID(), challengeId: MockIDs.c5, authorId: MockIDs.mary,
                    text: "You all need to visit LA more often!! 🌴", postedAt: ago(22)),
        ]
        s.reactionsByChallenge[MockIDs.c5] = [
            Reaction(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.jean,  emoji: "😭"),
            Reaction(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.tom,   emoji: "😭"),
            Reaction(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.bill,  emoji: "🔥"),
            Reaction(id: UUID(), challengeId: MockIDs.c5, playerId: MockIDs.steve, emoji: "👏"),
        ]

        // ── Challenge 6: Revealed – Steve posted, TIE on What? ──
        // Eligible: Bill, Jean, Tom, Mary (4)
        // Bill and Jean tied on What? (same receivedAt, Bill lower seq) → Bill rank 1 (4pts), Jean rank 1 (4pts)
        //   → tie! Both get rank 1 pts = 4. Tom rank 3 (skip 2) = 2 pts. Mary = 0
        // Where? Mary(1st,4pts) Tom(2nd,3pts) Bill+Jean=0
        let ch6 = Challenge(id: MockIDs.c6, posterId: MockIDs.steve, groupId: MockIDs.group,
                            imageColor: "pink", postedAt: ago(72), deadlineAt: ago(48), state: .revealed)
        s.challenges.append(ch6)
        s.secrets[MockIDs.c6] = ChallengeSecret(
            challengeId: MockIDs.c6, canonicalDish: "Tonkotsu Ramen",
            dishAliases: ["ramen", "tonkotsu"],
            canonicalRestaurant: "Ippudo", canonicalCity: "New York", hasFirstGuess: true)
        s.eligibles[MockIDs.c6] = [
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.bill, addedAt: ago(72)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.jean, addedAt: ago(72)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.tom,  addedAt: ago(72)),
            EligibleParticipant(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.mary, addedAt: ago(72)),
        ]
        s.hintsByChallenge[MockIDs.c6] = []
        let tiedTime = ago(70)  // Bill and Jean submitted at the exact same server timestamp
        let tiedSeqBill = s.nextSeq()
        let tiedSeqJean = s.nextSeq()   // Jean seq is higher → tiebreak goes to Bill, BUT
                                         // same receivedAt → both rank 1 (rank tie demo)
        // For true tie demo: set both seqs artificially equal isn't realistic.
        // Instead, same receivedAt but different seq → Bill wins tiebreak.
        // Showing this as "Bill rank 1, Jean rank 2" demonstrates the tiebreak rule.
        s.guessAttemptsByChallenge[MockIDs.c6] = [
            GuessAttempt(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.bill,
                         whatText: "Tonkotsu Ramen", whereRestaurant: "Nobu", whereCity: "New York",
                         receivedAt: tiedTime, receiptSequence: tiedSeqBill,
                         whatCorrect: true, whereCorrect: false),
            GuessAttempt(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.jean,
                         whatText: "Ramen", whereRestaurant: "Joe's Shanghai", whereCity: "New York",
                         receivedAt: tiedTime, receiptSequence: tiedSeqJean,
                         whatCorrect: true, whereCorrect: false),
            GuessAttempt(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.tom,
                         whatText: "Tonkotsu Ramen", whereRestaurant: "Ippudo", whereCity: "New York",
                         receivedAt: ago(69), receiptSequence: s.nextSeq(),
                         whatCorrect: true, whereCorrect: true),
            GuessAttempt(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.mary,
                         whatText: "Noodle Soup", whereRestaurant: "Ippudo", whereCity: "New York",
                         receivedAt: ago(68), receiptSequence: s.nextSeq(),
                         whatCorrect: false, whereCorrect: true),
        ]
        // What? tie: Bill seq < Jean seq at same timestamp → Bill rank 1 (4 pts), Jean rank 2 (3 pts)
        // Tom rank 3 (2 pts), Mary 0
        // Where? Tom(1st,4pts) Mary(2nd,3pts)
        s.scoreEventsByChallenge[MockIDs.c6] = [
            ScoreEvent(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.bill, race: .what, points: 4, rank: 1, rulesVersion: "1.0", calculatedAt: ago(48)),
            ScoreEvent(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.jean, race: .what, points: 3, rank: 2, rulesVersion: "1.0", calculatedAt: ago(48)),
            ScoreEvent(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.tom,  race: .what, points: 2, rank: 3, rulesVersion: "1.0", calculatedAt: ago(48)),
            ScoreEvent(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.tom,  race: .whereGuess, points: 4, rank: 1, rulesVersion: "1.0", calculatedAt: ago(48)),
            ScoreEvent(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.mary, race: .whereGuess, points: 3, rank: 2, rulesVersion: "1.0", calculatedAt: ago(48)),
        ]
        s.commentsByChallenge[MockIDs.c6] = [
            Comment(id: UUID(), challengeId: MockIDs.c6, authorId: MockIDs.jean,
                    text: "MILLISECONDS apart, Bill! 😤", postedAt: ago(47.9)),
            Comment(id: UUID(), challengeId: MockIDs.c6, authorId: MockIDs.bill,
                    text: "Server timestamps don't lie 😇", postedAt: ago(47.5)),
            Comment(id: UUID(), challengeId: MockIDs.c6, authorId: MockIDs.tom,
                    text: "I got both right and nobody cares 😂", postedAt: ago(47)),
        ]
        s.reactionsByChallenge[MockIDs.c6] = [
            Reaction(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.jean, emoji: "😤"),
            Reaction(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.bill, emoji: "😇"),
            Reaction(id: UUID(), challengeId: MockIDs.c6, playerId: MockIDs.tom,  emoji: "🍜"),
        ]

        // ── Challenge 7: Cancelled ──
        var ch7 = Challenge(id: MockIDs.c7, posterId: MockIDs.tom, groupId: MockIDs.group,
                            imageColor: "teal", postedAt: ago(10), deadlineAt: ago(8), state: .cancelled)
        ch7.cancellationReason = "Wrong photo — that was actually my lunch from Monday 😂"
        s.challenges.append(ch7)
        s.secrets[MockIDs.c7] = ChallengeSecret(
            challengeId: MockIDs.c7, canonicalDish: "?", dishAliases: [],
            canonicalRestaurant: "?", canonicalCity: "?", hasFirstGuess: false)
        s.eligibles[MockIDs.c7] = []
        s.hintsByChallenge[MockIDs.c7] = []
        s.guessAttemptsByChallenge[MockIDs.c7] = []
        s.scoreEventsByChallenge[MockIDs.c7] = []
        s.commentsByChallenge[MockIDs.c7] = []
        s.reactionsByChallenge[MockIDs.c7] = []
    }
}
