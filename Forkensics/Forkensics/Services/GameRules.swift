import Foundation

enum ScoringRules {
    static let currentVersion = "2.0"

    static func points(forRank rank: Int, version: String = currentVersion) -> Int {
        guard version == currentVersion else { return 0 }

        switch rank {
        case 1: return 100
        case 2: return 80
        case 3: return 60
        default: return 0
        }
    }
}

enum AnswerMatcher {
    static let currentVersion = "1.0"

    private static let dishEquivalenceGroups: [Set<String>] = [
        ["chicken parmigiana", "chicken parmesan", "chicken parm"],
        ["fish and chips", "fish chips"],
        ["street tacos", "street taco"],
        ["fish tacos", "fish taco"],
        ["barbecue brisket", "bbq brisket"],
        ["cheeseburger and fries", "burger and fries", "burger fries"]
    ]

    static func normalize(_ text: String) -> String {
        var normalized = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )

        normalized = normalized
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "-", with: " ")

        normalized = normalized
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined(separator: " ")

        let tokens = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in token == "n" ? "and" : String(token) }

        return tokens.joined(separator: " ")
    }

    static func matchesDish(
        guess: String,
        canonical: String,
        aliases: [String],
        version: String = currentVersion
    ) -> Bool {
        let normalizedGuess = normalize(guess)
        guard !normalizedGuess.isEmpty else { return false }

        var candidates = Set(([canonical] + aliases).map(normalize).filter { !$0.isEmpty })
        guard !candidates.isEmpty else { return false }

        if version == currentVersion {
            for group in normalizedDishEquivalenceGroups where !group.isDisjoint(with: candidates) {
                candidates.formUnion(group)
            }
        }

        if candidates.contains(normalizedGuess) { return true }
        guard version == currentVersion else { return false }

        return candidates.contains { isConservativeTypoMatch(normalizedGuess, $0) }
    }

    static func matchesRestaurant(
        guess: String,
        canonical: String,
        aliases: [String] = [],
        version: String = currentVersion
    ) -> Bool {
        let normalizedGuess = normalize(guess)
        let candidates = Set(([canonical] + aliases).map(normalize).filter { !$0.isEmpty })

        guard !normalizedGuess.isEmpty, !candidates.isEmpty else { return false }
        if candidates.contains(normalizedGuess) { return true }
        guard version == currentVersion else { return false }

        return candidates.contains { isConservativeTypoMatch(normalizedGuess, $0) }
    }

    private static var normalizedDishEquivalenceGroups: [Set<String>] {
        dishEquivalenceGroups.map { Set($0.map(normalize)) }
    }

    private static func isConservativeTypoMatch(_ lhs: String, _ rhs: String) -> Bool {
        let leftTokens = lhs.split(separator: " ").map(String.init)
        let rightTokens = rhs.split(separator: " ").map(String.init)
        guard leftTokens.count == rightTokens.count else { return false }

        var totalDistance = 0
        var changedTokenCount = 0

        for (left, right) in zip(leftTokens, rightTokens) {
            if left == right { continue }

            let shorterLength = min(left.count, right.count)
            let longerLength = max(left.count, right.count)
            guard shorterLength >= 4 else { return false }

            let allowedDistance = longerLength >= 9 ? 2 : 1
            let distance = levenshteinDistance(left, right)
            guard distance <= allowedDistance else { return false }

            totalDistance += distance
            changedTokenCount += 1
        }

        return changedTokenCount > 0 && changedTokenCount <= 2 && totalDistance <= 2
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)

        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)

        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)

            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current[rightIndex + 1] = min(insertion, deletion, substitution)
            }

            previous = current
        }

        return previous[right.count]
    }
}
