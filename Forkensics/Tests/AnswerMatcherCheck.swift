import Foundation

@main
struct AnswerMatcherCheck {
    static func main() {
        let acceptedDishGuesses = [
            "Chicken Parmigiana",
            "chicken parm",
            "Chicken Parmesan",
            "Chicken Parmagiana"
        ]

        for guess in acceptedDishGuesses {
            require(
                AnswerMatcher.matchesDish(
                    guess: guess,
                    canonical: "Chicken Parmigiana",
                    aliases: []
                ),
                "Expected dish guess to match: \(guess)"
            )
        }

        for guess in ["Fish & Chips", "fish and chips", "Fish n Chips"] {
            require(
                AnswerMatcher.matchesDish(
                    guess: guess,
                    canonical: "Fish and Chips",
                    aliases: []
                ),
                "Expected dish guess to match: \(guess)"
            )
        }

        let rejectedDishGuesses = [
            "Chicken Pasta",
            "Eggplant Parmigiana",
            "Fried Fish",
            "Fish and Fries"
        ]

        for guess in rejectedDishGuesses {
            require(
                !AnswerMatcher.matchesDish(
                    guess: guess,
                    canonical: "Chicken Parmigiana",
                    aliases: []
                ),
                "Expected dish guess to be rejected: \(guess)"
            )
        }

        require(
            AnswerMatcher.matchesRestaurant(
                guess: "Rauls",
                canonical: "Raul’s"
            ),
            "Expected apostrophe variation to match"
        )
        require(
            AnswerMatcher.matchesRestaurant(
                guess: "Smokehouse 27",
                canonical: "Smokehouse 27"
            ),
            "Expected exact restaurant to match"
        )
        require(
            !AnswerMatcher.matchesRestaurant(
                guess: "Smokehouse 72",
                canonical: "Smokehouse 27"
            ),
            "Expected materially different restaurant to be rejected"
        )

        require(ScoringRules.points(forRank: 1) == 100, "First place should score 100")
        require(ScoringRules.points(forRank: 2) == 80, "Second place should score 80")
        require(ScoringRules.points(forRank: 3) == 60, "Third place should score 60")
        require(ScoringRules.points(forRank: 4) == 0, "Fourth place should score zero")

        print("Answer matcher and scoring checks passed.")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
