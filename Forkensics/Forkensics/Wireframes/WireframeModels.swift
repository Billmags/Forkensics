import Foundation
import Combine

enum ForkensicsTab: String, CaseIterable, Identifiable {
    case cases = "Cases"
    case tableTalk = "Table Talk"
    case post = "Post"
    case leaderboard = "Leaderboard"
    case profile = "Profile"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .cases: return "magnifyingglass"
        case .tableTalk: return "bubble.left.and.bubble.right"
        case .post: return "plus.circle.fill"
        case .leaderboard: return "trophy"
        case .profile: return "person"
        }
    }
}

enum WireframeRoute: Hashable {
    case activeCase
    case postedCase(UUID)
    case postedCaseTable(UUID, String)
    case investigatePostedCase(UUID)
    case makePostedGuess(UUID)
    case postedClueConfirmation(UUID)
    case postedCaseLockedIn(UUID)
    case postedCaseTableTalk(UUID, String)
    case postedCaseRevealed(UUID)
    case makeGuessNoClue
    case makeGuessWithClue
    case clueConfirmation
    case makeGuessClueRevealed
    case lockedIn
    case activeTableTalk
    case revealedTableTalk
    case caseRevealed
    case scoreBreakdown
    case alerts
    case myTables
    case tableDetail(UUID)
}

enum LaunchPhase {
    case splash
    case welcome
    case sampleGuess
    case sampleReveal
    case accountChoice
    case signIn
    case createAccount
    case forgotPassword
    case checkEmail
    case chooseAlias
    case signedIn
}

struct WireframeDetective: Identifiable, Hashable {
    let id: UUID
    let name: String
    let initials: String
    let isLocked: Bool

    init(_ name: String, initials: String, isLocked: Bool = false) {
        self.id = UUID()
        self.name = name
        self.initials = initials
        self.isLocked = isLocked
    }
}

struct WireframeCase: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let dish: String
    let restaurant: String
    let table: String
    let poster: String
    let countdown: String
    let status: String
    let hasClue: Bool

    var imageName: String {
        switch dish {
        case "Chicken Parmigiana": return "ChickenParmigiana"
        case "Burger and Fries": return "BurgerAndFries"
        case "Street Tacos": return "StreetTacos"
        case "Fish and Chips": return "FishAndChips"
        case "BBQ Brisket": return "BBQBrisket"
        default: return "BurgerAndFries"
        }
    }
}

struct WireframePostedCase: Identifiable, Codable {
    let id: UUID
    let postedAt: Date
    let photoData: Data
    let title: String
    let dish: String
    let restaurant: String
    let location: String
    let clue: String
    let tableNames: [String]
    let durationHours: Int
    let posterPlayerID: String

    init(
        id: UUID = UUID(),
        postedAt: Date = Date(),
        photoData: Data,
        title: String = "Untitled Case",
        dish: String,
        restaurant: String,
        location: String,
        clue: String,
        tableNames: [String],
        durationHours: Int,
        posterPlayerID: String = WireframePlayerDirectory.maggie.id
    ) {
        self.id = id
        self.postedAt = postedAt
        self.photoData = photoData
        self.title = title
        self.dish = dish
        self.restaurant = restaurant
        self.location = location
        self.clue = clue
        self.tableNames = tableNames
        self.durationHours = durationHours
        self.posterPlayerID = posterPlayerID
    }

    var deadlineAt: Date {
        postedAt.addingTimeInterval(TimeInterval(durationHours * 60 * 60))
    }

    private enum CodingKeys: String, CodingKey {
        case id, postedAt, photoData, title, dish, restaurant, location, clue, tableNames, durationHours, posterPlayerID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        postedAt = try container.decode(Date.self, forKey: .postedAt)
        photoData = try container.decode(Data.self, forKey: .photoData)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Case"
        dish = try container.decode(String.self, forKey: .dish)
        restaurant = try container.decode(String.self, forKey: .restaurant)
        location = try container.decode(String.self, forKey: .location)
        clue = try container.decode(String.self, forKey: .clue)
        tableNames = try container.decode([String].self, forKey: .tableNames)
        durationHours = try container.decode(Int.self, forKey: .durationHours)
        posterPlayerID = try container.decodeIfPresent(String.self, forKey: .posterPlayerID)
            ?? WireframePlayerDirectory.maggie.id
    }
}

struct WireframePlayer: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let handle: String

    var initials: String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

struct WireframeTableRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var detail: String
    var avatarStyle: String
    let ownerPlayerID: String
    var memberPlayerIDs: [String]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        detail: String,
        avatarStyle: String,
        ownerPlayerID: String,
        memberPlayerIDs: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.avatarStyle = avatarStyle
        self.ownerPlayerID = ownerPlayerID
        var seen: Set<String> = []
        self.memberPlayerIDs = ([ownerPlayerID] + memberPlayerIDs).filter { seen.insert($0).inserted }
        self.createdAt = createdAt
    }

    func role(for playerID: String) -> String {
        ownerPlayerID == playerID ? "Owner" : "Detective"
    }
}

@MainActor
final class WireframeTableStore: ObservableObject {
    @Published private(set) var tables: [WireframeTableRecord]

    nonisolated static let storageKey = "forkensics.wireframe.tables.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let storedTables = try? JSONDecoder().decode([WireframeTableRecord].self, from: data) {
            tables = storedTables
        } else {
            tables = Self.sampleTables
        }
    }

    func tables(for playerID: String) -> [WireframeTableRecord] {
        tables
            .filter { $0.memberPlayerIDs.contains(playerID) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func table(id: UUID) -> WireframeTableRecord? {
        tables.first(where: { $0.id == id })
    }

    @discardableResult
    func create(
        name: String,
        avatarStyle: String,
        ownerPlayerID: String,
        detectivePlayerIDs: [String]
    ) -> WireframeTableRecord {
        let table = WireframeTableRecord(
            name: name,
            detail: "A private table for your favorite detectives.",
            avatarStyle: avatarStyle,
            ownerPlayerID: ownerPlayerID,
            memberPlayerIDs: detectivePlayerIDs
        )
        tables.insert(table, at: 0)
        save()
        return table
    }

    func update(id: UUID, name: String, detail: String, avatarStyle: String) {
        guard let index = tables.firstIndex(where: { $0.id == id }) else { return }
        tables[index].name = name
        tables[index].detail = detail
        tables[index].avatarStyle = avatarStyle
        save()
    }

    func removeDetective(_ playerID: String, from tableID: UUID) {
        guard let index = tables.firstIndex(where: { $0.id == tableID }),
              tables[index].ownerPlayerID != playerID else { return }
        tables[index].memberPlayerIDs.removeAll(where: { $0 == playerID })
        save()
    }

    func delete(_ tableID: UUID) {
        tables.removeAll(where: { $0.id == tableID })
        save()
    }

    func leave(_ tableID: UUID, playerID: String) {
        guard let index = tables.firstIndex(where: { $0.id == tableID }),
              tables[index].ownerPlayerID != playerID else { return }
        tables[index].memberPlayerIDs.removeAll(where: { $0 == playerID })
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tables) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static var sampleTables: [WireframeTableRecord] {
        let calendar = Calendar(identifier: .gregorian)
        let createdAt = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)) ?? Date()
        return [
            WireframeTableRecord(
                id: UUID(uuidString: "B4DE0801-CAFE-4C01-9000-000000000001")!,
                name: "Schroeder Table",
                detail: "Family, food, and fiercely competitive guesses.",
                avatarStyle: "walnut",
                ownerPlayerID: "maggie",
                memberPlayerIDs: ["maggie", "olivia", "noah", "sophia", "mason"],
                createdAt: createdAt
            ),
            WireframeTableRecord(
                id: UUID(uuidString: "B4DE0801-CAFE-4C01-9000-000000000002")!,
                name: "Dinner Friends",
                detail: "Our regular crew for restaurant reconnaissance.",
                avatarStyle: "navy",
                ownerPlayerID: "liam",
                memberPlayerIDs: ["maggie", "liam", "ava", "ethan", "mia", "lucas", "emma", "ben"],
                createdAt: createdAt.addingTimeInterval(-21 * 24 * 60 * 60)
            ),
            WireframeTableRecord(
                id: UUID(uuidString: "B4DE0801-CAFE-4C01-9000-000000000003")!,
                name: "Food Detectives",
                detail: "Serious sleuths with very strong appetites.",
                avatarStyle: "charcoal",
                ownerPlayerID: "priya",
                memberPlayerIDs: ["maggie", "priya", "daniel", "grace", "marcus", "nina", "theo", "zoe", "andre", "julia", "sam", "chloe"],
                createdAt: createdAt.addingTimeInterval(-55 * 24 * 60 * 60)
            )
        ]
    }
}

enum WireframePlayerDirectory {
    static let maggie = WireframePlayer(id: "maggie", name: "Maggie Schroeder", handle: "@maggie.s")

    static let tableNames = ["Schroeder Table", "Dinner Friends", "Food Detectives"]

    static let players: [WireframePlayer] = [
        maggie,
        WireframePlayer(id: "olivia", name: "Olivia Schroeder", handle: "@olivia.s"),
        WireframePlayer(id: "noah", name: "Noah Schroeder", handle: "@noah.s"),
        WireframePlayer(id: "sophia", name: "Sophia Lane", handle: "@sophia.l"),
        WireframePlayer(id: "mason", name: "Mason Jacobs", handle: "@mason.j"),
        WireframePlayer(id: "liam", name: "Liam Carter", handle: "@liam.c"),
        WireframePlayer(id: "ava", name: "Ava Brooks", handle: "@ava.b"),
        WireframePlayer(id: "ethan", name: "Ethan Cole", handle: "@ethan.c"),
        WireframePlayer(id: "mia", name: "Mia Torres", handle: "@mia.t"),
        WireframePlayer(id: "lucas", name: "Lucas Reed", handle: "@lucas.r"),
        WireframePlayer(id: "emma", name: "Emma Price", handle: "@emma.p"),
        WireframePlayer(id: "ben", name: "Ben Walker", handle: "@ben.w"),
        WireframePlayer(id: "priya", name: "Priya Shah", handle: "@priya.s"),
        WireframePlayer(id: "daniel", name: "Daniel Kim", handle: "@daniel.k"),
        WireframePlayer(id: "grace", name: "Grace Chen", handle: "@grace.c"),
        WireframePlayer(id: "marcus", name: "Marcus Lee", handle: "@marcus.l"),
        WireframePlayer(id: "nina", name: "Nina Patel", handle: "@nina.p"),
        WireframePlayer(id: "theo", name: "Theo Grant", handle: "@theo.g"),
        WireframePlayer(id: "zoe", name: "Zoe Martin", handle: "@zoe.m"),
        WireframePlayer(id: "andre", name: "Andre Lewis", handle: "@andre.l"),
        WireframePlayer(id: "julia", name: "Julia Ross", handle: "@julia.r"),
        WireframePlayer(id: "sam", name: "Sam Rivera", handle: "@sam.r"),
        WireframePlayer(id: "chloe", name: "Chloe Baker", handle: "@chloe.b")
    ]

    private static let tablePlayerIDs: [String: [String]] = [
        "Schroeder Table": ["maggie", "olivia", "noah", "sophia", "mason"],
        "Dinner Friends": ["maggie", "liam", "ava", "ethan", "mia", "lucas", "emma", "ben"],
        "Dinner Friends Table": ["maggie", "liam", "ava", "ethan", "mia", "lucas", "emma", "ben"],
        "Food Detectives": ["maggie", "priya", "daniel", "grace", "marcus", "nina", "theo", "zoe", "andre", "julia", "sam", "chloe"]
    ]

    static func player(id: String) -> WireframePlayer {
        players.first(where: { $0.id == id }) ?? maggie
    }

    static func players(in tableName: String) -> [WireframePlayer] {
        if let data = UserDefaults.standard.data(forKey: WireframeTableStore.storageKey),
           let tables = try? JSONDecoder().decode([WireframeTableRecord].self, from: data),
           let table = tables.first(where: { $0.name == tableName }) {
            return table.memberPlayerIDs.map(player(id:))
        }
        return (tablePlayerIDs[tableName] ?? tablePlayerIDs["Schroeder Table"] ?? [])
            .map(player(id:))
    }

    static func tables(for playerID: String) -> [String] {
        tableNames.filter { tableName in
            players(in: tableName).contains(where: { $0.id == playerID })
        }
    }
}

struct WireframeGuessRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let playerID: String
    let dish: String
    let restaurant: String
    let lockedAt: Date

    init(
        id: UUID = UUID(),
        playerID: String,
        dish: String,
        restaurant: String,
        lockedAt: Date = Date()
    ) {
        self.id = id
        self.playerID = playerID
        self.dish = dish
        self.restaurant = restaurant
        self.lockedAt = lockedAt
    }
}

struct WireframeTableTalkRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let playerID: String
    let tableName: String
    let text: String
    let sentAt: Date

    init(
        id: UUID = UUID(),
        playerID: String,
        tableName: String,
        text: String,
        sentAt: Date = Date()
    ) {
        self.id = id
        self.playerID = playerID
        self.tableName = tableName
        self.text = text
        self.sentAt = sentAt
    }
}

struct WireframeCaseActivity: Identifiable, Codable {
    var id: UUID { caseID }
    let caseID: UUID
    var guesses: [WireframeGuessRecord]
    var cluePlayerIDs: Set<String>
    var messages: [WireframeTableTalkRecord]
    var forcedRevealAt: Date?

    init(caseID: UUID) {
        self.caseID = caseID
        guesses = []
        cluePlayerIDs = []
        messages = []
        forcedRevealAt = nil
    }
}

struct WireframeScoreResult {
    let dishRank: Int?
    let placeRank: Int?
    let dishPoints: Int
    let placePoints: Int
    let cluePenalty: Int

    var totalPoints: Int {
        max(0, dishPoints + placePoints - cluePenalty)
    }
}

enum WireframeLeaderboardPeriod: Hashable {
    case thisMonth
    case allTime
}

struct WireframeLeaderboardEntry: Identifiable {
    var id: String { player.id }
    let player: WireframePlayer
    let rank: Int
    let points: Int
    let caseCount: Int
    let latestCasePoints: Int
    let movement: Int?
}

struct WireframeLeaderboardCaseResult: Identifiable {
    let id: UUID
    let caseTitle: String
    let postedAt: Date
    let dishPoints: Int
    let placePoints: Int
    let cluePenalty: Int
    let totalPoints: Int
}

struct WireframeConversationSummary: Identifiable {
    var id: String { "\(item.id.uuidString)-\(tableName)" }
    let item: WireframePostedCase
    let tableName: String
    let revealed: Bool
    let lockedCount: Int
    let messagePreview: String
}

@MainActor
final class WireframeChallengeStore: ObservableObject {
    @Published private(set) var postedCases: [WireframePostedCase] = []
    @Published private(set) var activities: [WireframeCaseActivity] = []
    @Published private(set) var currentPlayerID: String
    @Published private(set) var persistenceError: String?

    /// The authenticated user's real Supabase UUID (set after sign-in).
    /// Used alongside currentPlayerID to correctly identify the poster
    /// when cases come from the Supabase backend.
    private var supabaseUserID: String?

    private let storeURL: URL?
    private let activityURL: URL?
    private let defaults: UserDefaults

    private static let currentPlayerKey = "ForkensicsWireframe.currentPlayerID"

    init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        currentPlayerID = defaults.string(forKey: Self.currentPlayerKey)
            ?? WireframePlayerDirectory.maggie.id

        do {
            let supportDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let forkensicsDirectory = supportDirectory.appendingPathComponent(
                "ForkensicsWireframe",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: forkensicsDirectory,
                withIntermediateDirectories: true
            )
            storeURL = forkensicsDirectory.appendingPathComponent("posted-cases.json")
            activityURL = forkensicsDirectory.appendingPathComponent("case-activity.json")
        } catch {
            storeURL = nil
            activityURL = nil
            persistenceError = "Forkensics could not prepare local case storage."
        }

        load()
    }

    var currentPlayer: WireframePlayer {
        WireframePlayerDirectory.player(id: currentPlayerID)
    }

    func switchPlayer(to playerID: String) {
        guard WireframePlayerDirectory.players.contains(where: { $0.id == playerID }) else { return }
        currentPlayerID = playerID
        defaults.set(playerID, forKey: Self.currentPlayerKey)
    }

    // MARK: - Supabase integration

    /// Stores the authenticated user's real Supabase UUID.
    /// Call this once after sign-in so poster comparisons work for server-fetched cases.
    func setSupabaseUserID(_ id: String) {
        supabaseUserID = id
    }

    /// Replaces the in-memory case list with server-fetched cases from Supabase.
    /// The local disk store is NOT rewritten — on next cold launch this will be
    /// called again from the Supabase fetch, so disk persistence is a warm cache only.
    /// Activities (guesses, messages, clue usage) are preserved across loads.
    func loadFromSupabase(_ serverCases: [WireframePostedCase]) {
        postedCases = serverCases
    }

    func add(_ postedCase: WireframePostedCase) {
        postedCases.insert(postedCase, at: 0)
        save()
    }

    func postedByCurrentPlayer(_ item: WireframePostedCase) -> Bool {
        item.posterPlayerID == currentPlayerID
            || (supabaseUserID.map { item.posterPlayerID == $0 } ?? false)
    }

    func isAvailableToCurrentPlayer(_ item: WireframePostedCase) -> Bool {
        guard item.posterPlayerID != currentPlayerID else { return false }
        return item.tableNames.contains { tableName in
            WireframePlayerDirectory.players(in: tableName).contains(where: { $0.id == currentPlayerID })
        }
    }

    func commonTableName(for item: WireframePostedCase, playerID: String? = nil) -> String {
        let targetPlayerID = playerID ?? currentPlayerID
        return item.tableNames.first { tableName in
            WireframePlayerDirectory.players(in: tableName).contains(where: { $0.id == targetPlayerID })
        } ?? item.tableNames.first ?? "Table"
    }

    func guess(for caseID: UUID, playerID: String? = nil) -> WireframeGuessRecord? {
        let targetPlayerID = playerID ?? currentPlayerID
        return activity(for: caseID).guesses.first(where: { $0.playerID == targetPlayerID })
    }

    func hasUsedClue(for caseID: UUID, playerID: String? = nil) -> Bool {
        let targetPlayerID = playerID ?? currentPlayerID
        return activity(for: caseID).cluePlayerIDs.contains(targetPlayerID)
    }

    func useClue(for caseID: UUID) {
        updateActivity(caseID: caseID) { activity in
            activity.cluePlayerIDs.insert(currentPlayerID)
        }
    }

    func lockGuess(for caseID: UUID, dish: String, restaurant: String) {
        updateActivity(caseID: caseID) { activity in
            guard !activity.guesses.contains(where: { $0.playerID == currentPlayerID }) else { return }
            activity.guesses.append(
                WireframeGuessRecord(
                    playerID: currentPlayerID,
                    dish: dish,
                    restaurant: restaurant
                )
            )
        }
    }

    func guesses(for caseID: UUID, tableName: String? = nil) -> [WireframeGuessRecord] {
        let guesses = activity(for: caseID).guesses
        guard let tableName else { return guesses }
        let memberIDs = Set(WireframePlayerDirectory.players(in: tableName).map(\.id))
        return guesses.filter { memberIDs.contains($0.playerID) }
    }

    func eligiblePlayers(for item: WireframePostedCase, tableName: String? = nil) -> [WireframePlayer] {
        let tableNames = tableName.map { [$0] } ?? item.tableNames
        var seen: Set<String> = []
        return tableNames
            .flatMap(WireframePlayerDirectory.players(in:))
            .filter { player in
                player.id != item.posterPlayerID && seen.insert(player.id).inserted
            }
    }

    func isRevealed(_ item: WireframePostedCase, now: Date = Date()) -> Bool {
        let activity = activity(for: item.id)
        if activity.forcedRevealAt != nil || item.deadlineAt <= now { return true }
        let eligibleIDs = Set(eligiblePlayers(for: item).map(\.id))
        let guessedIDs = Set(activity.guesses.map(\.playerID))
        return !eligibleIDs.isEmpty && eligibleIDs.isSubset(of: guessedIDs)
    }

    func forceReveal(_ item: WireframePostedCase) {
        updateActivity(caseID: item.id) { activity in
            activity.forcedRevealAt = Date()
        }
    }

    func messages(for caseID: UUID, tableName: String) -> [WireframeTableTalkRecord] {
        activity(for: caseID).messages
            .filter { $0.tableName == tableName }
            .sorted { $0.sentAt < $1.sentAt }
    }

    func sendMessage(for caseID: UUID, tableName: String, text: String) {
        updateActivity(caseID: caseID) { activity in
            activity.messages.append(
                WireframeTableTalkRecord(
                    playerID: currentPlayerID,
                    tableName: tableName,
                    text: text
                )
            )
        }
    }

    func score(for item: WireframePostedCase, playerID: String? = nil) -> WireframeScoreResult {
        let targetPlayerID = playerID ?? currentPlayerID
        let guesses = activity(for: item.id).guesses.sorted { $0.lockedAt < $1.lockedAt }
        let correctDish = guesses.filter {
            AnswerMatcher.matchesDish(guess: $0.dish, canonical: item.dish, aliases: [])
        }
        let correctPlace = guesses.filter {
            AnswerMatcher.matchesRestaurant(guess: $0.restaurant, canonical: item.restaurant)
        }
        let dishRank = correctDish.firstIndex(where: { $0.playerID == targetPlayerID }).map { $0 + 1 }
        let placeRank = correctPlace.firstIndex(where: { $0.playerID == targetPlayerID }).map { $0 + 1 }
        let cluePenalty = hasUsedClue(for: item.id, playerID: targetPlayerID) ? 40 : 0

        return WireframeScoreResult(
            dishRank: dishRank,
            placeRank: placeRank,
            dishPoints: dishRank.map { ScoringRules.points(forRank: $0) } ?? 0,
            placePoints: placeRank.map { ScoringRules.points(forRank: $0) } ?? 0,
            cluePenalty: cluePenalty
        )
    }

    func leaderboard(
        for tableName: String,
        period: WireframeLeaderboardPeriod,
        now: Date = Date()
    ) -> [WireframeLeaderboardEntry] {
        let players = WireframePlayerDirectory.players(in: tableName)
        let revealedCases = leaderboardCases(for: tableName, period: period, now: now)
        let latestCaseID = revealedCases.first?.id

        struct PlayerSummary {
            let player: WireframePlayer
            let points: Int
            let caseCount: Int
            let latestCasePoints: Int
            let previousPoints: Int
            let previousCaseCount: Int
        }

        let summaries: [PlayerSummary] = players.compactMap { player in
            let history = leaderboardHistory(
                for: player.id,
                tableName: tableName,
                period: period,
                now: now
            )
            guard !history.isEmpty else { return nil }

            let latestCasePoints = history.first(where: { $0.id == latestCaseID })?.totalPoints ?? 0
            let previousHistory = history.filter { $0.id != latestCaseID }
            return PlayerSummary(
                player: player,
                points: history.reduce(0) { $0 + $1.totalPoints },
                caseCount: history.count,
                latestCasePoints: latestCasePoints,
                previousPoints: previousHistory.reduce(0) { $0 + $1.totalPoints },
                previousCaseCount: previousHistory.count
            )
        }

        let ordered = summaries.sorted {
            if $0.points != $1.points { return $0.points > $1.points }
            return $0.player.name.localizedCaseInsensitiveCompare($1.player.name) == .orderedAscending
        }
        let previousParticipants = summaries.filter { $0.previousCaseCount > 0 }

        return ordered.map { summary in
            let rank = 1 + summaries.filter { $0.points > summary.points }.count
            let previousRank: Int? = summary.previousCaseCount > 0
                ? 1 + previousParticipants.filter { $0.previousPoints > summary.previousPoints }.count
                : nil

            return WireframeLeaderboardEntry(
                player: summary.player,
                rank: rank,
                points: summary.points,
                caseCount: summary.caseCount,
                latestCasePoints: summary.latestCasePoints,
                movement: previousRank.map { $0 - rank }
            )
        }
    }

    func leaderboardHistory(
        for playerID: String,
        tableName: String,
        period: WireframeLeaderboardPeriod,
        now: Date = Date()
    ) -> [WireframeLeaderboardCaseResult] {
        leaderboardCases(for: tableName, period: period, now: now).compactMap { item in
            guard item.posterPlayerID != playerID,
                  guess(for: item.id, playerID: playerID) != nil else { return nil }

            let result = score(for: item, playerID: playerID)
            return WireframeLeaderboardCaseResult(
                id: item.id,
                caseTitle: item.title,
                postedAt: item.postedAt,
                dishPoints: result.dishPoints,
                placePoints: result.placePoints,
                cluePenalty: result.cluePenalty,
                totalPoints: result.totalPoints
            )
        }
    }

    private func leaderboardCases(
        for tableName: String,
        period: WireframeLeaderboardPeriod,
        now: Date
    ) -> [WireframePostedCase] {
        postedCases
            .filter { item in
                guard item.tableNames.contains(tableName), isRevealed(item, now: now) else {
                    return false
                }
                switch period {
                case .thisMonth:
                    return Calendar.current.isDate(item.postedAt, equalTo: now, toGranularity: .month)
                case .allTime:
                    return true
                }
            }
            .sorted { $0.postedAt > $1.postedAt }
    }

    private func activity(for caseID: UUID) -> WireframeCaseActivity {
        activities.first(where: { $0.caseID == caseID }) ?? WireframeCaseActivity(caseID: caseID)
    }

    private func updateActivity(
        caseID: UUID,
        update: (inout WireframeCaseActivity) -> Void
    ) {
        if let index = activities.firstIndex(where: { $0.caseID == caseID }) {
            update(&activities[index])
        } else {
            var activity = WireframeCaseActivity(caseID: caseID)
            update(&activity)
            activities.append(activity)
        }
        saveActivities()
    }

    private func load() {
        if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let data = try Data(contentsOf: storeURL)
                postedCases = try JSONDecoder().decode([WireframePostedCase].self, from: data)
                persistenceError = nil
            } catch {
                persistenceError = "Saved cases could not be loaded. New cases will still work in this session."
            }
        }

        if let activityURL, FileManager.default.fileExists(atPath: activityURL.path) {
            do {
                let data = try Data(contentsOf: activityURL)
                activities = try JSONDecoder().decode([WireframeCaseActivity].self, from: data)
            } catch {
                persistenceError = "Saved case activity could not be loaded. New guesses will still work."
            }
        }
    }

    private func save() {
        guard let storeURL else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(postedCases)
            try data.write(to: storeURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "This case is visible now, but could not be saved for the next launch."
        }
    }

    private func saveActivities() {
        guard let activityURL else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(activities)
            try data.write(to: activityURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "This activity is visible now, but could not be saved for the next launch."
        }
    }
}

enum WireframeSamples {
    static let detectives = [
        WireframeDetective("You", initials: "MS", isLocked: true),
        WireframeDetective("Olivia", initials: "OS", isLocked: true),
        WireframeDetective("Noah", initials: "NS"),
        WireframeDetective("Sophia", initials: "SL"),
        WireframeDetective("Mason", initials: "MJ")
    ]

    static let activeCase = WireframeCase(
        title: "Sunday Supper Mystery",
        dish: "Chicken Parmigiana",
        restaurant: "Trattoria Roma",
        table: "Schroeder Table",
        poster: "Maggie Schroeder",
        countdown: "03:47:12",
        status: "YOUR TURN",
        hasClue: true
    )

    static let cases = [
        activeCase,
        WireframeCase(
            title: "Late-Night Bite",
            dish: "Burger and Fries",
            restaurant: "The Corner Grill",
            table: "Dinner Friends Table",
            poster: "Mason Jacobs",
            countdown: "14h 06m",
            status: "YOUR TURN",
            hasClue: false
        ),
        WireframeCase(
            title: "Patio Plate",
            dish: "Street Tacos",
            restaurant: "El Camino",
            table: "Schroeder Table",
            poster: "Olivia Schroeder",
            countdown: "5h 22m",
            status: "YOUR TURN",
            hasClue: true
        ),
        WireframeCase(
            title: "Pub Grub Puzzle",
            dish: "Fish and Chips",
            restaurant: "Hidden until reveal",
            table: "Schroeder Table",
            poster: "Noah Schroeder",
            countdown: "47m",
            status: "LOCKED IN",
            hasClue: false
        )
    ]
}
