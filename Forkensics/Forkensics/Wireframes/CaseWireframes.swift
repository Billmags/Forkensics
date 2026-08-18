import SwiftUI
import UIKit

struct ActiveCaseWireframe: View {
    let makeGuess: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(showsBackButton: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("ACTIVE CASE")
                        .font(.system(size: 23, weight: .black))
                        .tracking(0.4)
                    Text("You’ve received a new case. Can you crack it?")
                        .font(.footnote)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    DetectiveAvatar(detective: WireframeDetective("Maggie", initials: "MS"), size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Posted by Maggie Schroeder").font(.subheadline.weight(.semibold))
                        Text("to Schroeder Table").font(.caption).foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer()
                }
                .forkensicsCard()

                FoodPhotoPlaceholder(
                    height: 270,
                    label: "Case food photo",
                    imageName: "ChickenParmigiana"
                )

                HStack(spacing: 14) {
                    Image(systemName: "clock")
                        .font(.title2)
                        .foregroundStyle(ForkensicsColor.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("REVEALS IN").font(.caption2.weight(.bold)).foregroundStyle(ForkensicsColor.secondaryText)
                        Text("03:47:12")
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

                HStack(spacing: 14) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(ForkensicsColor.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("1 CLUE AVAILABLE").font(.caption.weight(.bold))
                        Text("Tap to view privately. Costs 40 points.")
                            .font(.caption).foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(ForkensicsColor.mutedText)
                }
                .forkensicsCard()

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

struct MakeGuessWireframe: View {
    enum ClueState { case unavailable, available, revealed }

    let clueState: ClueState
    let openClue: () -> Void
    let lockIn: () -> Void

    @State private var dish = ""
    @State private var restaurant = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForkensicsHeader(showsBackButton: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MAKE YOUR GUESS")
                        .font(.system(size: 28, weight: .black))
                    Text("Lock in your suspects before time runs out.")
                        .font(.subheadline)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    DetectiveAvatar(detective: WireframeDetective("Maggie", initials: "MS"), size: 40)
                    Text("Case from Maggie Schroeder\nto Schroeder Table")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                    Spacer()
                }
                .forkensicsCard()

                FoodPhotoPlaceholder(
                    height: 220,
                    label: "Case food photo",
                    imageName: "ChickenParmigiana"
                )

                clueModule

                ForkensicsTextField(label: "Dish suspect", prompt: "Enter dish name", text: $dish)
                ForkensicsTextField(label: "Restaurant suspect", prompt: "Enter restaurant or place", text: $restaurant)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(ForkensicsColor.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LOCK IT IN").font(.caption.weight(.bold))
                        Text("Once you lock in, you cannot change your guess. Guesses remain private until reveal.")
                            .font(.caption).foregroundStyle(ForkensicsColor.secondaryText)
                    }
                }
                .forkensicsCard()

                ForkensicsPrimaryButton(
                    title: "Lock In My Guesses",
                    systemImage: "lock",
                    enabled: !dish.isEmpty && !restaurant.isEmpty,
                    action: lockIn
                )
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }

    @ViewBuilder private var clueModule: some View {
        switch clueState {
        case .unavailable:
            EmptyView()
        case .available:
            Button(action: openClue) {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(ForkensicsColor.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("1 CLUE AVAILABLE").font(.caption.weight(.bold)).foregroundStyle(.white)
                        Text("View the clue privately. Costs 40 points.")
                            .font(.caption).foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(ForkensicsColor.mutedText)
                }
                .forkensicsCard()
            }
            .buttonStyle(ForkensicsPressButtonStyle())
        case .revealed:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.open")
                    .foregroundStyle(ForkensicsColor.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("CLUE REVEALED").font(.caption.weight(.bold)).foregroundStyle(ForkensicsColor.orange)
                    Text("A family recipe that’s been passed down for generations.")
                        .font(.subheadline)
                    Text("Unlocked • 40 points deducted")
                        .font(.caption).foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
            }
            .forkensicsCard()
            .overlay {
                RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius)
                    .stroke(ForkensicsColor.orange.opacity(0.55), lineWidth: 1)
            }
        }
    }
}

struct ClueConfirmationWireframe: View {
    let reveal: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ForkensicsHeader(showsBackButton: true)
            Spacer()
            Image(systemName: "lightbulb")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(ForkensicsColor.orange)
            Text("NEED A CLUE?")
                .font(.system(size: 32, weight: .black))
            Text("Using this clue deducts 40 points from your case score.")
                .foregroundStyle(ForkensicsColor.secondaryText)
                .multilineTextAlignment(.center)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THE CLUE").font(.caption2.weight(.bold)).foregroundStyle(ForkensicsColor.orange)
                    Text("Hidden until you accept the 40-point deduction.").font(.caption).foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
                Text("−40\nPTS")
                    .font(.headline.weight(.black))
                    .foregroundStyle(ForkensicsColor.orange)
                    .multilineTextAlignment(.center)
            }
            .forkensicsCard()
            ForkensicsPrimaryButton(title: "Reveal Clue — −40 Pts", systemImage: "lightbulb", action: reveal)
            ForkensicsSecondaryButton(title: "Never Mind", action: cancel)
            Spacer()
        }
        .padding(ForkensicsSpacing.screen)
        .forkensicsScreen()
    }
}

struct LockedInWireframe: View {
    let openTableTalk: () -> Void
    let viewCases: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ForkensicsHeader(showsBackButton: true, backAction: viewCases)

                VStack(alignment: .leading, spacing: 14) {
                    ForkensicsSectionLabel(text: "Detectives on this case")
                    DetectiveTableSeating(
                        tableName: "Schroeder Table",
                        detectives: WireframeSamples.detectives
                    )
                }
                .forkensicsCard()

                HStack(spacing: 14) {
                    FoodPhotoPlaceholder(
                        height: 82,
                        label: "Case food photo",
                        imageName: "ChickenParmigiana"
                    )
                    .frame(width: 98)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Schroeder Table").font(.headline)
                        Text("From Liam").font(.caption).foregroundStyle(ForkensicsColor.secondaryText)
                        Text("Posted today • Fort Myers, FL").font(.caption2).foregroundStyle(ForkensicsColor.mutedText)
                    }
                    Spacer()
                }
                .forkensicsCard()

                ForkensicsPrimaryButton(title: "Open Table Talk", systemImage: "bubble.left.and.bubble.right", action: openTableTalk)
                ForkensicsSecondaryButton(title: "View My Cases", action: viewCases)
            }
            .padding(.horizontal, ForkensicsSpacing.screen)
            .padding(.bottom, ForkensicsSpacing.screen)
            .padding(.top, 10)
        }
        .forkensicsScreen()
    }
}

struct CaseTableTalkWireframe: View {
    private struct TableTalkMessage: Identifiable {
        let id = UUID()
        let sender: String
        let text: String
        let fromYou: Bool
    }

    private static let openingMessages = [
        TableTalkMessage(sender: "Olivia", text: "I’m feeling Italian for sure. That sauce looks 🔥", fromYou: false),
        TableTalkMessage(sender: "You", text: "Agreed. Those noodles look handmade.", fromYou: true),
        TableTalkMessage(sender: "Olivia", text: "I’m going classic… thinking red sauce and parm.", fromYou: false)
    ]

    let revealed: Bool
    @State private var message = ""
    @State private var sentMessages: [TableTalkMessage] = []

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ForkensicsHeader(showsBackButton: true)
                Text("SCHROEDER TABLE").font(.title2.weight(.black))
                Text(revealed ? "CASE REVEALED" : "CASE ACTIVE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForkensicsColor.orange)
                HStack {
                    ForEach(WireframeSamples.detectives) { detective in
                        DetectiveAvatar(detective: detective, size: 38)
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
                        ForEach(Self.openingMessages) { item in
                            messageBubble(item)
                        }
                        if revealed {
                            messageBubble(TableTalkMessage(sender: "Olivia", text: "All right—we were so confident!", fromYou: false))
                        }
                        ForEach(sentMessages) { item in
                            messageBubble(item)
                                .id(item.id)
                        }
                    }
                    .padding(ForkensicsSpacing.screen)
                }
                .onChange(of: sentMessages.count) {
                    guard let latestMessageID = sentMessages.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.24)) {
                        proxy.scrollTo(latestMessageID, anchor: .bottom)
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
                        .contentShape(Circle())
                }
                .buttonStyle(ForkensicsPressButtonStyle())
                .disabled(trimmedMessage.isEmpty)
                .accessibilityLabel("Send message")
            }
            .padding(ForkensicsSpacing.screen)
            .background(ForkensicsColor.background)
        }
        .forkensicsScreen()
    }

    private func sendMessage() {
        let text = trimmedMessage
        guard !text.isEmpty else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sentMessages.append(TableTalkMessage(sender: "You", text: text, fromYou: true))
        message = ""
    }

    private func messageBubble(_ message: TableTalkMessage) -> some View {
        HStack {
            if message.fromYou { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.sender.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.7)
                    .foregroundStyle(message.fromYou ? Color.black.opacity(0.62) : ForkensicsColor.orange)
                Text(message.text)
                    .font(.subheadline)
            }
                .padding(12)
                .background(message.fromYou ? ForkensicsColor.orange : ForkensicsColor.surface)
                .foregroundStyle(message.fromYou ? Color.black : ForkensicsColor.primaryText)
                .clipShape(RoundedRectangle(cornerRadius: 15))
            if !message.fromYou { Spacer(minLength: 70) }
        }
    }
}

struct CaseRevealedWireframe: View {
    let scoreBreakdown: () -> Void
    let nextCase: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForkensicsHeader(showsBackButton: true)
                ForkensicsRevealCelebration(
                    eyebrow: "Mystery solved",
                    title: "CASE CRACKED!",
                    subtitle: "Perfect dish and place match. That’s detective work.",
                    points: 140
                )
                FoodPhotoPlaceholder(
                    height: 260,
                    label: "Sliced barbecue brisket",
                    imageName: "BBQBrisket"
                )

                VStack(spacing: 0) {
                    revealRow(icon: "fork.knife", label: "Dish", value: "BBQ Brisket")
                    Divider().overlay(ForkensicsColor.line)
                    revealRow(icon: "storefront", label: "Restaurant", value: "Smokehouse 27")
                    Divider().overlay(ForkensicsColor.line)
                    revealRow(icon: "mappin", label: "Location", value: "Austin, TX")
                }
                .forkensicsCard()

                Button(action: scoreBreakdown) {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.bar.fill")
                            .foregroundStyle(ForkensicsColor.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("SEE HOW YOU SCORED").font(.caption.weight(.bold))
                            Text("Review your 140-point breakdown")
                                .font(.caption)
                                .foregroundStyle(ForkensicsColor.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ForkensicsColor.orange)
                    }
                    .forkensicsCard()
                }
                .buttonStyle(ForkensicsPressButtonStyle())

                ForkensicsPrimaryButton(title: "Next Case", providesLightHaptic: true, action: nextCase)
                ForkensicsSecondaryButton(title: "View Score Breakdown", action: scoreBreakdown)
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }

    private func revealRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(ForkensicsColor.orange).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(ForkensicsColor.secondaryText)
                Text(value).font(.body.weight(.semibold))
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

struct ScoreBreakdownWireframe: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(title: "Your Case Results", showsAlert: false, showsBackButton: true)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Great job!").font(.system(size: 31, weight: .black))
                        Text("You cracked the case.").foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer()
                    Text("140\nPOINTS")
                        .font(.title3.weight(.black))
                        .foregroundStyle(ForkensicsColor.orange)
                        .multilineTextAlignment(.center)
                        .frame(width: 90, height: 90)
                        .overlay { Circle().stroke(ForkensicsColor.orange, lineWidth: 2) }
                }

                FoodPhotoPlaceholder(
                    height: 180,
                    label: "Sliced barbecue brisket",
                    imageName: "BBQBrisket"
                )

                VStack(spacing: 0) {
                    scoreRow(icon: "fork.knife", label: "Dish · 1st correct", value: "BBQ Brisket", points: "+100")
                    Divider().overlay(ForkensicsColor.line)
                    scoreRow(icon: "storefront", label: "Place · 2nd correct", value: "Smokehouse 27", points: "+80")
                    Divider().overlay(ForkensicsColor.line)
                    scoreRow(icon: "lightbulb", label: "Clue Used", value: "1 clue", points: "−40")
                }
                .forkensicsCard()

                HStack {
                    Text("TOTAL POINTS").font(.caption.weight(.bold)).foregroundStyle(ForkensicsColor.secondaryText)
                    Spacer()
                    Text("140").font(.title2.weight(.black)).foregroundStyle(ForkensicsColor.orange)
                }
                .forkensicsCard()
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }

    private func scoreRow(icon: String, label: String, value: String, points: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).foregroundStyle(ForkensicsColor.orange).frame(width: 25)
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(ForkensicsColor.secondaryText)
                Text(value).font(.subheadline.weight(.semibold))
            }
            Spacer()
            Text(points).font(.headline.weight(.black)).foregroundStyle(ForkensicsColor.orange)
        }
        .padding(.vertical, 12)
    }
}
