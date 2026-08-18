import SwiftUI
import UIKit

struct LocalTableTalkHomeWireframe: View {
    let currentPlayer: WireframePlayer
    let conversations: [WireframeConversationSummary]
    let openConversation: (WireframeConversationSummary) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(title: "Table Talk")
                Text("Private conversations unlock after you lock in. Posters can join after reveal.")
                    .font(.subheadline)
                    .foregroundStyle(ForkensicsColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if conversations.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 34))
                            .foregroundStyle(ForkensicsColor.orange)
                        Text("No Table Talk yet")
                            .font(.headline)
                        Text("Lock in a guess to join—or, if you posted the case, wait until it reveals.")
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 42)
                    .forkensicsCard()
                } else {
                    ForEach(conversations) { conversation in
                        Button {
                            openConversation(conversation)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .foregroundStyle(ForkensicsColor.orange)
                                    .frame(width: 44, height: 44)
                                    .background(ForkensicsColor.orange.opacity(0.12))
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.item.title)
                                        .font(.headline)
                                        .foregroundStyle(ForkensicsColor.primaryText)
                                    Text(conversation.revealed ? "\(conversation.tableName) • Revealed" : "\(conversation.tableName) • \(conversation.lockedCount) locked in")
                                        .font(.caption)
                                        .foregroundStyle(ForkensicsColor.orange)
                                    Text(conversation.messagePreview)
                                        .font(.subheadline)
                                        .foregroundStyle(ForkensicsColor.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(ForkensicsColor.mutedText)
                            }
                            .forkensicsCard()
                        }
                        .buttonStyle(ForkensicsPressButtonStyle())
                    }
                }

#if DEBUG
                Text("Testing as \(currentPlayer.name)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ForkensicsColor.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
#endif
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }
}

struct ActivePostedCaseWireframe: View {
    let item: WireframePostedCase
    let poster: WireframePlayer
    let tableName: String
    let makeGuess: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(showsBackButton: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("ACTIVE CASE")
                        .font(.caption2.weight(.black))
                        .tracking(1.2)
                        .foregroundStyle(ForkensicsColor.orange)
                    Text(item.title)
                        .font(.system(size: 27, weight: .black))
                    Text("You’ve received a new case. Can you crack it?")
                        .font(.footnote)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    DetectiveAvatar(
                        detective: WireframeDetective(poster.name, initials: poster.initials),
                        size: 42
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Posted by \(poster.name)")
                            .font(.subheadline.weight(.semibold))
                        Text("to \(tableName)")
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer()
                }
                .forkensicsCard()

                postedPhoto(item, height: 270)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 14) {
                        Image(systemName: "clock")
                            .font(.title2)
                            .foregroundStyle(ForkensicsColor.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("REVEALS IN")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(ForkensicsColor.secondaryText)
                            Text(remainingTime(until: item.deadlineAt, now: context.date))
                                .font(.system(size: 27, weight: .black, design: .rounded))
                                .foregroundStyle(ForkensicsColor.orange)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .allowsTightening(true)
                        }
                        .layoutPriority(1)
                        Spacer()
                        Text("Reveals when time expires\nor all detectives lock in.")
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 132, alignment: .trailing)
                    }
                    .forkensicsCard()
                }

                if !item.clue.isEmpty {
                    HStack(spacing: 14) {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(ForkensicsColor.orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("1 CLUE AVAILABLE").font(.caption.weight(.bold))
                            Text("View it privately while making your guess. Costs 40 points.")
                                .font(.caption)
                                .foregroundStyle(ForkensicsColor.secondaryText)
                        }
                        Spacer()
                    }
                    .forkensicsCard()
                }

                VStack(alignment: .leading, spacing: 5) {
                    ForkensicsSectionLabel(text: "Your mission")
                    Text("Name the dish and the restaurant or place you think it’s from.")
                        .font(.subheadline)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ForkensicsPrimaryButton(title: "Make Your Guess", systemImage: "pencil", action: makeGuess)
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }
}

struct PostedCaseGuessWireframe: View {
    let item: WireframePostedCase
    let poster: WireframePlayer
    let tableName: String
    let clueRevealed: Bool
    let openClue: () -> Void
    let lockIn: (String, String) -> Void

    @State private var dish = ""
    @State private var restaurant = ""

    private var canLock: Bool {
        !dish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !restaurant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForkensicsHeader(showsBackButton: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("MAKE YOUR GUESS")
                        .font(.system(size: 28, weight: .black))
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(ForkensicsColor.orange)
                    Text("Lock in your suspects before time runs out.")
                        .font(.subheadline)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    DetectiveAvatar(
                        detective: WireframeDetective(poster.name, initials: poster.initials),
                        size: 40
                    )
                    Text("Case from \(poster.name)\nto \(tableName)")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                    Spacer()
                }
                .forkensicsCard()

                postedPhoto(item, height: 220)
                clueModule

                ForkensicsTextField(label: "Dish suspect", prompt: "Enter dish name", text: $dish)
                ForkensicsTextField(label: "Restaurant suspect", prompt: "Enter restaurant or place", text: $restaurant)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(ForkensicsColor.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LOCK IT IN").font(.caption.weight(.bold))
                        Text("Once you lock in, you cannot change your guess. Guesses remain private until reveal.")
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                }
                .forkensicsCard()

                ForkensicsPrimaryButton(
                    title: "Lock In My Guesses",
                    systemImage: "lock",
                    enabled: canLock
                ) {
                    lockIn(
                        dish.trimmingCharacters(in: .whitespacesAndNewlines),
                        restaurant.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }

    @ViewBuilder private var clueModule: some View {
        if item.clue.isEmpty {
            EmptyView()
        } else if clueRevealed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.open")
                    .foregroundStyle(ForkensicsColor.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR PRIVATE CLUE")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ForkensicsColor.orange)
                    Text(item.clue)
                        .font(.subheadline)
                    Text("Only you can see this • 40 points deducted")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
            }
            .forkensicsCard()
            .overlay {
                RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius)
                    .stroke(ForkensicsColor.orange.opacity(0.55), lineWidth: 1)
            }
        } else {
            Button(action: openClue) {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(ForkensicsColor.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("1 CLUE AVAILABLE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ForkensicsColor.primaryText)
                        Text("View the clue privately. Costs 40 points.")
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(ForkensicsColor.mutedText)
                }
                .forkensicsCard()
            }
            .buttonStyle(ForkensicsPressButtonStyle())
        }
    }
}

struct PostedCaseLockedInWireframe: View {
    let item: WireframePostedCase
    let tableName: String
    let detectives: [WireframeDetective]
    let isRevealed: Bool
    let openTableTalk: () -> Void
    let viewResults: () -> Void
    let viewCases: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ForkensicsHeader(showsBackButton: true, backAction: viewCases)

                VStack(alignment: .leading, spacing: 14) {
                    ForkensicsSectionLabel(text: "Detectives on this case")
                    DetectiveTableSeating(tableName: tableName, detectives: detectives)
                }
                .forkensicsCard()

                HStack(spacing: 14) {
                    postedPhoto(item, height: 82)
                        .frame(width: 98)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(tableName)
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.orange)
                        Text("From \(WireframePlayerDirectory.player(id: item.posterPlayerID).name)")
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                        Text(isRevealed ? "Case revealed" : "Your guesses are safely locked")
                            .font(.caption2)
                            .foregroundStyle(ForkensicsColor.mutedText)
                    }
                    Spacer()
                }
                .forkensicsCard()

                if isRevealed {
                    ForkensicsPrimaryButton(title: "View Results", systemImage: "sparkles", action: viewResults)
                }
                ForkensicsPrimaryButton(title: "Open Table Talk", systemImage: "bubble.left.and.bubble.right", action: openTableTalk)
                ForkensicsSecondaryButton(title: "View My Cases", action: viewCases)
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }
}

struct PostedCaseTableTalkWireframe: View {
    let item: WireframePostedCase
    let tableName: String
    let currentPlayer: WireframePlayer
    let detectives: [WireframeDetective]
    let messages: [WireframeTableTalkRecord]
    let revealed: Bool
    let send: (String) -> Void

    @State private var message = ""

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ForkensicsHeader(showsBackButton: true)
                Text(item.title.uppercased()).font(.title2.weight(.black))
                Text(tableName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ForkensicsColor.secondaryText)
                Text(revealed ? "CASE REVEALED" : "CASE ACTIVE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForkensicsColor.orange)
                HStack {
                    ForEach(detectives) { detective in
                        DetectiveAvatar(detective: detective, size: 34)
                            .frame(maxWidth: .infinity)
                    }
                }
                .forkensicsCard()
            }
            .padding(.horizontal, ForkensicsSpacing.screen)
            .padding(.top, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        if messages.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.title)
                                    .foregroundStyle(ForkensicsColor.orange)
                                Text("Start the investigation")
                                    .font(.headline)
                                Text("Only detectives who locked in can join this Table Talk.")
                                    .font(.caption)
                                    .foregroundStyle(ForkensicsColor.secondaryText)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 70)
                        }

                        ForEach(messages) { record in
                            messageBubble(record)
                                .id(record.id)
                        }
                    }
                    .padding(ForkensicsSpacing.screen)
                }
                .onChange(of: messages.count) {
                    guard let latestID = messages.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.24)) {
                        proxy.scrollTo(latestID, anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Make your case…", text: $message)
                    .submitLabel(.send)
                    .onSubmit(sendMessage)
                    .textInputAutocapitalization(.sentences)
                    .padding(12)
                    .background(ForkensicsColor.surface)
                    .clipShape(Capsule())
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(trimmedMessage.isEmpty ? ForkensicsColor.mutedText : ForkensicsColor.orange)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(ForkensicsPressButtonStyle())
                .disabled(trimmedMessage.isEmpty)
            }
            .padding(ForkensicsSpacing.screen)
            .background(ForkensicsColor.background)
        }
        .forkensicsScreen()
    }

    private func sendMessage() {
        guard !trimmedMessage.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        send(trimmedMessage)
        message = ""
    }

    private func messageBubble(_ record: WireframeTableTalkRecord) -> some View {
        let fromYou = record.playerID == currentPlayer.id
        let sender = WireframePlayerDirectory.player(id: record.playerID)

        return HStack {
            if fromYou { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 4) {
                Text((fromYou ? "You" : sender.name).uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.7)
                    .foregroundStyle(fromYou ? Color.black.opacity(0.62) : ForkensicsColor.orange)
                Text(record.text).font(.subheadline)
            }
            .padding(12)
            .background(fromYou ? ForkensicsColor.orange : ForkensicsColor.surface)
            .foregroundStyle(fromYou ? Color.black : ForkensicsColor.primaryText)
            .clipShape(RoundedRectangle(cornerRadius: 15))
            if !fromYou { Spacer(minLength: 70) }
        }
    }
}

struct PostedCaseRevealWireframe: View {
    let item: WireframePostedCase
    let guess: WireframeGuessRecord?
    let score: WireframeScoreResult
    let viewCases: () -> Void

    private var solvedSomething: Bool {
        score.dishPoints > 0 || score.placePoints > 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForkensicsHeader(showsBackButton: true, backAction: viewCases)

                ForkensicsRevealCelebration(
                    eyebrow: item.title,
                    title: solvedSomething ? "CASE CRACKED!" : "CASE REVEALED",
                    subtitle: solvedSomething ? "Your detective work paid off." : "The answer is in. Better luck on the next case!",
                    points: score.totalPoints
                )

                postedPhoto(item, height: 250)

                if let guess {
                    VStack(alignment: .leading, spacing: 0) {
                        ForkensicsSectionLabel(text: "Your results")
                            .padding(.bottom, 8)
                        comparisonRow(
                            icon: "fork.knife",
                            label: "Dish",
                            yourGuess: guess.dish,
                            correctAnswer: item.dish,
                            isCorrect: score.dishRank != nil
                        )
                        Divider().overlay(ForkensicsColor.line)
                        comparisonRow(
                            icon: "storefront",
                            label: "Restaurant",
                            yourGuess: guess.restaurant,
                            correctAnswer: item.restaurant,
                            answerDetail: item.location.isEmpty ? nil : item.location,
                            isCorrect: score.placeRank != nil
                        )
                    }
                    .forkensicsCard()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForkensicsSectionLabel(text: "Case answer")
                            .padding(.bottom, 8)
                        answerOnlyRow(icon: "fork.knife", label: "Dish", answer: item.dish)
                        Divider().overlay(ForkensicsColor.line)
                        answerOnlyRow(
                            icon: "storefront",
                            label: "Restaurant",
                            answer: item.restaurant,
                            detail: item.location.isEmpty ? nil : item.location
                        )
                    }
                    .forkensicsCard()
                }

                VStack(spacing: 0) {
                    scoreRow(
                        label: rankLabel(prefix: "Dish", rank: score.dishRank),
                        points: score.dishPoints
                    )
                    Divider().overlay(ForkensicsColor.line)
                    scoreRow(
                        label: rankLabel(prefix: "Place", rank: score.placeRank),
                        points: score.placePoints
                    )
                    if score.cluePenalty > 0 {
                        Divider().overlay(ForkensicsColor.line)
                        scoreRow(label: "Private clue used", points: -score.cluePenalty)
                    }
                }
                .forkensicsCard()

                HStack {
                    Text("TOTAL POINTS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ForkensicsColor.secondaryText)
                    Spacer()
                    Text("\(score.totalPoints)")
                        .font(.title2.weight(.black))
                        .foregroundStyle(ForkensicsColor.orange)
                }
                .forkensicsCard()

                ForkensicsPrimaryButton(title: "View My Cases", systemImage: "folder", action: viewCases)
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }

    private func rankLabel(prefix: String, rank: Int?) -> String {
        guard let rank else { return "\(prefix) · Not correct" }
        let suffix: String
        switch rank {
        case 1: suffix = "1st"
        case 2: suffix = "2nd"
        case 3: suffix = "3rd"
        default: suffix = "\(rank)th"
        }
        return "\(prefix) · \(suffix) correct"
    }

    private func scoreRow(label: String, points: Int) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(ForkensicsColor.secondaryText)
            Spacer()
            Text(points > 0 ? "+\(points)" : "\(points)")
                .font(.headline.weight(.black))
                .foregroundStyle(ForkensicsColor.orange)
        }
        .padding(.vertical, 12)
    }

    private func comparisonRow(
        icon: String,
        label: String,
        yourGuess: String,
        correctAnswer: String,
        answerDetail: String? = nil,
        isCorrect: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(ForkensicsColor.orange)
                    .frame(width: 24)
                Text(label.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForkensicsColor.secondaryText)
                Spacer()
                Label(
                    isCorrect ? "CORRECT" : "INCORRECT",
                    systemImage: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(isCorrect ? Color.green : Color.red)
            }

            resultValue(label: "YOUR GUESS", value: yourGuess, color: isCorrect ? .green : .red)
            resultValue(label: "CORRECT ANSWER", value: correctAnswer, color: ForkensicsColor.primaryText)

            if let answerDetail {
                Label(answerDetail, systemImage: "mappin")
                    .font(.caption)
                    .foregroundStyle(ForkensicsColor.secondaryText)
            }
        }
        .padding(.vertical, 13)
    }

    private func resultValue(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ForkensicsColor.secondaryText)
            Text(value)
                .font(.body.weight(.bold))
                .foregroundStyle(color)
        }
        .padding(.leading, 34)
    }

    private func answerOnlyRow(
        icon: String,
        label: String,
        answer: String,
        detail: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(ForkensicsColor.orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ForkensicsColor.secondaryText)
                Text(answer).font(.body.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

@ViewBuilder
private func postedPhoto(_ item: WireframePostedCase, height: CGFloat) -> some View {
    if let image = UIImage(data: item.photoData) {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius, style: .continuous)
                    .stroke(ForkensicsColor.line, lineWidth: 1)
            }
            .accessibilityLabel("Mystery food photo")
    } else {
        FoodPhotoPlaceholder(height: height, label: "Mystery food photo")
    }
}

private func remainingTime(until deadline: Date, now: Date) -> String {
    let seconds = max(0, Int(deadline.timeIntervalSince(now)))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainingSeconds = seconds % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
}
