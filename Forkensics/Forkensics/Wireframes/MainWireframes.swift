import SwiftUI
import PhotosUI
import UIKit

struct CasesHomeWireframe: View {
    let postedCases: [WireframePostedCase]
    let incomingCases: [WireframePostedCase]
    let lockedCaseIDs: Set<UUID>
    let revealedCaseIDs: Set<UUID>
    let openCase: () -> Void
    let openPostedCase: (WireframePostedCase) -> Void
    let openIncomingCase: (WireframePostedCase) -> Void
    let openAlerts: () -> Void

    init(
        postedCases: [WireframePostedCase] = [],
        incomingCases: [WireframePostedCase] = [],
        lockedCaseIDs: Set<UUID> = [],
        revealedCaseIDs: Set<UUID> = [],
        openCase: @escaping () -> Void,
        openPostedCase: @escaping (WireframePostedCase) -> Void = { _ in },
        openIncomingCase: @escaping (WireframePostedCase) -> Void = { _ in },
        openAlerts: @escaping () -> Void
    ) {
        self.postedCases = postedCases
        self.incomingCases = incomingCases
        self.lockedCaseIDs = lockedCaseIDs
        self.revealedCaseIDs = revealedCaseIDs
        self.openCase = openCase
        self.openPostedCase = openPostedCase
        self.openIncomingCase = openIncomingCase
        self.openAlerts = openAlerts
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForkensicsHeader(alertAction: openAlerts)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CASES")
                            .font(.system(size: 34, weight: .black))
                        Text("Cases waiting for your best guess.")
                            .font(.subheadline)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer()
                }

                PickerLikeTabs(labels: ["Active", "Your Cases", "Solved"], selection: 1)

                if !postedCases.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForkensicsSectionLabel(text: "Posted by you")
                        ForEach(postedCases) { postedCase in
                            PostedCaseRowWireframe(
                                item: postedCase,
                                isRevealed: revealedCaseIDs.contains(postedCase.id),
                                action: { openPostedCase(postedCase) }
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForkensicsSectionLabel(text: "Your turn")
                    ForEach(incomingCases.filter {
                        !lockedCaseIDs.contains($0.id) && !revealedCaseIDs.contains($0.id)
                    }) { item in
                        IncomingPostedCaseRowWireframe(
                            item: item,
                            isLocked: false,
                            isRevealed: false,
                            action: { openIncomingCase(item) }
                        )
                    }
                    ForEach(Array(WireframeSamples.cases.prefix(3))) { item in
                        CaseRowWireframe(item: item, action: openCase)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForkensicsSectionLabel(text: "Locked in")
                    ForEach(incomingCases.filter {
                        lockedCaseIDs.contains($0.id) && !revealedCaseIDs.contains($0.id)
                    }) { item in
                        IncomingPostedCaseRowWireframe(
                            item: item,
                            isLocked: true,
                            isRevealed: false,
                            action: { openIncomingCase(item) }
                        )
                    }
                    if let locked = WireframeSamples.cases.last {
                        CaseRowWireframe(item: locked, action: openCase)
                    }
                }

                if incomingCases.contains(where: { revealedCaseIDs.contains($0.id) }) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForkensicsSectionLabel(text: "Solved")
                        ForEach(incomingCases.filter { revealedCaseIDs.contains($0.id) }) { item in
                            IncomingPostedCaseRowWireframe(
                                item: item,
                                isLocked: lockedCaseIDs.contains(item.id),
                                isRevealed: true,
                                action: { openIncomingCase(item) }
                            )
                        }
                    }
                }

                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                        .foregroundStyle(ForkensicsColor.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("New case invites show up here.")
                            .font(.subheadline.weight(.semibold))
                        Text("Jump in, make your guess, and lock it in.")
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer()
                }
                .forkensicsCard()
            }
            .padding(.horizontal, ForkensicsSpacing.screen)
            .padding(.bottom, ForkensicsSpacing.screen)
            .padding(.top, 10)
        }
        .forkensicsScreen()
    }
}

struct PostedCaseRowWireframe: View {
    let item: WireframePostedCase
    var isRevealed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if let image = UIImage(data: item.photoData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        FoodPhotoPlaceholder(height: 76, label: "Posted case photo")
                    }
                }
                .frame(width: 88, height: 76)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Your posted case photo")

                VStack(alignment: .leading, spacing: 5) {
                    Text(isRevealed ? "CASE REVEALED" : "CASE ACTIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ForkensicsColor.orange)
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(ForkensicsColor.primaryText)
                        .lineLimit(1)
                    Text("Sent to \(item.tableNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                        .lineLimit(1)
                    Label("Reveals in \(item.durationHours)h", systemImage: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForkensicsColor.mutedText)
            }
            .forkensicsCard()
        }
        .buttonStyle(ForkensicsPressButtonStyle())
        .accessibilityLabel("Open your active case, \(item.title)")
    }
}

struct IncomingPostedCaseRowWireframe: View {
    let item: WireframePostedCase
    let isLocked: Bool
    let isRevealed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if let image = UIImage(data: item.photoData) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        FoodPhotoPlaceholder(height: 76, label: "Case food photo")
                    }
                }
                .frame(width: 88, height: 76)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 5) {
                    Text(isRevealed ? "CASE REVEALED" : (isLocked ? "LOCKED IN" : "YOUR TURN"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ForkensicsColor.orange)
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(ForkensicsColor.primaryText)
                        .lineLimit(1)
                    Text("Posted by \(WireframePlayerDirectory.player(id: item.posterPlayerID).name) • \(item.tableNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                        .lineLimit(1)
                    Label(isRevealed ? "Results ready" : "Reveals in \(item.durationHours)h", systemImage: isRevealed ? "sparkles" : "hourglass")
                        .font(.caption2)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForkensicsColor.mutedText)
            }
            .forkensicsCard()
        }
        .buttonStyle(ForkensicsPressButtonStyle())
    }
}

struct PostedCaseDetailWireframe: View {
    let item: WireframePostedCase
    let guessCount: Int
    let isRevealed: Bool
    let openTable: (String) -> Void
    let forceReveal: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForkensicsHeader(
                title: "Your Case",
                showsAlert: false,
                showsBackButton: true,
                backAction: close
            )
            .padding(.horizontal, ForkensicsSpacing.screen)
            .padding(.top, 10)
            .padding(.bottom, 18)

            ScrollView {
                VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isRevealed ? "CASE REVEALED" : "CASE ACTIVE")
                        .font(.caption2.weight(.black))
                        .tracking(1.2)
                        .foregroundStyle(ForkensicsColor.orange)
                    Text(item.title)
                        .font(.system(size: 32, weight: .black))
                    Text(isRevealed ? "The results are ready." : "Detectives are working the case.")
                        .font(.subheadline)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                postedPhoto

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    timerCard(now: context.date)
                }

                answerCard
                tablesCard
#if DEBUG
                if !isRevealed {
                    ForkensicsSecondaryButton(title: "Reveal Now (Test)", action: forceReveal)
                }
#endif
                }
                .padding(.horizontal, ForkensicsSpacing.screen)
                .padding(.bottom, ForkensicsSpacing.screen)
            }
        }
        .forkensicsScreen()
    }

    @ViewBuilder private var postedPhoto: some View {
        if let image = UIImage(data: item.photoData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 230)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius, style: .continuous)
                        .stroke(ForkensicsColor.line, lineWidth: 1)
                }
                .accessibilityLabel("Photo for your case, \(item.title)")
        } else {
            FoodPhotoPlaceholder(height: 230, label: "Your posted case photo")
        }
    }

    private func timerCard(now: Date) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "clock")
                .font(.title2)
                .foregroundStyle(ForkensicsColor.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(isRevealed ? "STATUS" : "REVEALS IN")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ForkensicsColor.secondaryText)
                Text(isRevealed ? "REVEALED" : remainingTime(from: now))
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(ForkensicsColor.orange)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
            }
            .layoutPriority(1)

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(guessCount) \(guessCount == 1 ? "GUESS" : "GUESSES")")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForkensicsColor.primaryText)
                Text("Reveals at time limit\nor when all lock in.")
                    .font(.caption2)
                    .foregroundStyle(ForkensicsColor.secondaryText)
                    .multilineTextAlignment(.trailing)
            }
            .frame(width: 132, alignment: .trailing)
        }
        .forkensicsCard()
        .accessibilityElement(children: .combine)
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForkensicsSectionLabel(text: "Case answer")
                .padding(.bottom, 8)
            detailRow(icon: "fork.knife", label: "Dish", value: item.dish)
            Divider().overlay(ForkensicsColor.line)
            detailRow(icon: "storefront", label: "Restaurant", value: item.restaurant)
            if !item.location.isEmpty {
                Divider().overlay(ForkensicsColor.line)
                detailRow(icon: "mappin", label: "Location", value: item.location)
            }
            if !item.clue.isEmpty {
                Divider().overlay(ForkensicsColor.line)
                detailRow(icon: "lightbulb", label: "Clue", value: item.clue)
            }
        }
        .forkensicsCard()
    }

    private var tablesCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForkensicsSectionLabel(text: "Sent to")
            ForEach(Array(item.tableNames.enumerated()), id: \.element) { index, tableName in
                if index > 0 {
                    Divider().overlay(ForkensicsColor.line)
                }

                Button {
                    openTable(tableName)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.3")
                            .foregroundStyle(ForkensicsColor.orange)
                            .frame(width: 24)
                        Text(tableName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ForkensicsColor.primaryText)
                        Spacer()
                        Text("VIEW STATUS")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(ForkensicsColor.secondaryText)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ForkensicsColor.orange)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                }
                .buttonStyle(ForkensicsPressButtonStyle())
                .accessibilityLabel("View members and guess status for \(tableName)")
            }
        }
        .forkensicsCard()
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .foregroundStyle(ForkensicsColor.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ForkensicsColor.secondaryText)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ForkensicsColor.primaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func remainingTime(from now: Date) -> String {
        let seconds = max(0, Int(item.deadlineAt.timeIntervalSince(now)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }
}

struct PostedCaseTableStatusWireframe: View {
    private enum MemberStatus: Equatable {
        case poster
        case guessed
        case waiting

        var label: String {
            switch self {
            case .poster: return "POSTER"
            case .guessed: return "GUESS IN"
            case .waiting: return "WAITING"
            }
        }

        var icon: String {
            switch self {
            case .poster: return "person.crop.circle.badge.checkmark"
            case .guessed: return "checkmark.circle.fill"
            case .waiting: return "clock"
            }
        }
    }

    private struct Member: Identifiable {
        let playerID: String
        let name: String
        let status: MemberStatus
        let guess: WireframeGuessRecord?

        var id: String { playerID }
        var initials: String {
            name.split(separator: " ")
                .prefix(2)
                .compactMap(\.first)
                .map(String.init)
                .joined()
                .uppercased()
        }
    }

    let item: WireframePostedCase
    let tableName: String
    let guesses: [WireframeGuessRecord]
    let isRevealed: Bool
    let scoreForPlayer: (String) -> WireframeScoreResult
    let openTableTalk: () -> Void

    private var guessesByPlayerID: [String: WireframeGuessRecord] {
        Dictionary(uniqueKeysWithValues: guesses.map { ($0.playerID, $0) })
    }

    private var members: [Member] {
        WireframePlayerDirectory.players(in: tableName).map { player in
            let guess = guessesByPlayerID[player.id]
            return Member(
                playerID: player.id,
                name: player.id == item.posterPlayerID ? "\(player.name) (You)" : player.name,
                status: player.id == item.posterPlayerID
                    ? .poster
                    : (guess == nil ? .waiting : .guessed),
                guess: guess
            )
        }
    }

    private var detectives: [WireframeDetective] {
        members.map {
            WireframeDetective(
                $0.name,
                initials: $0.initials,
                isLocked: $0.status == .guessed
            )
        }
    }

    private var eligibleCount: Int {
        members.filter { $0.status != .poster }.count
    }

    private var guessCount: Int {
        members.filter { $0.status == .guessed }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(
                    title: tableName,
                    showsAlert: false,
                    showsBackButton: true
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(isRevealed ? "TABLE RESULTS" : "CASE PARTICIPATION")
                        .font(.caption2.weight(.black))
                        .tracking(1.2)
                        .foregroundStyle(ForkensicsColor.orange)
                    Text(item.title)
                        .font(.title3.weight(.black))
                    Text(isRevealed
                         ? "See how every detective did."
                         : "\(guessCount) of \(eligibleCount) detectives have guessed.")
                        .font(.title3.weight(.bold))
                    Text(isRevealed
                         ? "Answers and Table Talk are now unlocked."
                         : "You can see participation, but answers stay private until reveal.")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DetectiveTableSeating(
                    tableName: tableName,
                    detectives: detectives,
                    statusText: isRevealed
                        ? "RESULTS READY"
                        : "\(guessCount) OF \(eligibleCount) GUESSED"
                )
                .forkensicsCard()

                if isRevealed {
                    answerCard
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForkensicsSectionLabel(text: isRevealed ? "Detective results" : "Table members")
                        .padding(.bottom, 8)

                    ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                        if index > 0 {
                            Divider().overlay(ForkensicsColor.line)
                        }
                        memberRow(member)
                    }
                }
                .forkensicsCard()

                if isRevealed {
                    ForkensicsPrimaryButton(
                        title: "Open Table Talk",
                        systemImage: "bubble.left.and.bubble.right",
                        providesLightHaptic: true,
                        action: openTableTalk
                    )
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "eye.slash.fill")
                            .foregroundStyle(ForkensicsColor.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("PARTICIPATION ONLY")
                                .font(.caption.weight(.bold))
                            Text("Their answers, clue activity, and Table Talk stay hidden from you until this case reveals.")
                                .font(.caption)
                                .foregroundStyle(ForkensicsColor.secondaryText)
                        }
                        Spacer()
                    }
                    .forkensicsCard()
                }
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
        .navigationTitle(item.title)
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForkensicsSectionLabel(text: "Correct answer")
                .padding(.bottom, 8)
            answerRow(icon: "fork.knife", label: "Dish", value: item.dish)
            Divider().overlay(ForkensicsColor.line)
            answerRow(icon: "storefront", label: "Restaurant", value: item.restaurant)
            if !item.location.isEmpty {
                Divider().overlay(ForkensicsColor.line)
                answerRow(icon: "mappin", label: "Location", value: item.location)
            }
        }
        .forkensicsCard()
    }

    private func memberRow(_ member: Member) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(member.initials)
                    .font(.caption.weight(.bold))
                    .frame(width: 42, height: 42)
                    .background(ForkensicsColor.raised)
                    .clipShape(Circle())
                    .overlay {
                        Circle().stroke(
                            member.status == .guessed ? ForkensicsColor.orange : ForkensicsColor.line,
                            lineWidth: 2
                        )
                    }

                Text(member.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()

                if isRevealed, member.status != .poster {
                    Text(member.guess == nil ? "NO GUESS" : "+\(scoreForPlayer(member.playerID).totalPoints) PTS")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(member.guess == nil ? ForkensicsColor.secondaryText : ForkensicsColor.orange)
                } else {
                    Label(member.status.label, systemImage: member.status.icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(
                            member.status == .guessed
                                ? ForkensicsColor.orange
                                : ForkensicsColor.secondaryText
                        )
                }
            }

            if isRevealed, let guess = member.guess {
                let score = scoreForPlayer(member.playerID)
                VStack(spacing: 8) {
                    guessResultRow(
                        label: "Dish",
                        guess: guess.dish,
                        correct: score.dishRank != nil,
                        points: score.dishPoints
                    )
                    guessResultRow(
                        label: "Place",
                        guess: guess.restaurant,
                        correct: score.placeRank != nil,
                        points: score.placePoints
                    )
                    if score.cluePenalty > 0 {
                        HStack {
                            Label("Private clue used", systemImage: "lightbulb.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(ForkensicsColor.secondaryText)
                            Spacer()
                            Text("−\(score.cluePenalty) PTS")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(ForkensicsColor.orange)
                        }
                    }
                }
                .padding(12)
                .background(ForkensicsColor.raised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func answerRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(ForkensicsColor.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ForkensicsColor.secondaryText)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }

    private func guessResultRow(
        label: String,
        guess: String,
        correct: Bool,
        points: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(correct ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ForkensicsColor.secondaryText)
                Text(guess)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ForkensicsColor.primaryText)
            }
            Spacer(minLength: 8)
            Text(correct ? "+\(points) PTS" : "WRONG")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(correct ? Color.green : Color.red)
        }
    }
}

struct MissingPostedCaseWireframe: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ForkensicsHeader(
                title: "Your Case",
                showsAlert: false,
                showsBackButton: true,
                backAction: close
            )
            Spacer()
            Image(systemName: "exclamationmark.magnifyingglass")
                .font(.system(size: 38))
                .foregroundStyle(ForkensicsColor.orange)
            Text("This case is no longer available.")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, ForkensicsSpacing.screen)
        .padding(.top, 10)
        .forkensicsScreen()
    }
}

struct PickerLikeTabs: View {
    let labels: [String]
    let selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { index in
                Text(labels[index].uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(index == selection ? ForkensicsColor.orange : ForkensicsColor.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                        if index == selection {
                            Rectangle().fill(ForkensicsColor.orange).frame(height: 2)
                        }
                    }
            }
        }
        .background(ForkensicsColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}

struct CaseRowWireframe: View {
    let item: WireframeCase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                FoodPhotoPlaceholder(
                    height: 76,
                    label: "Case food photo",
                    imageName: item.imageName
                )
                    .frame(width: 88)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.status)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(ForkensicsColor.orange)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ForkensicsColor.mutedText)
                    }
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(ForkensicsColor.primaryText)
                        .lineLimit(1)
                    Text("Posted by \(item.poster) • \(item.table)")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                        .lineLimit(1)
                    Label("Reveals in \(item.countdown)", systemImage: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
            }
            .padding(12)
            .background(ForkensicsColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius)
                    .stroke(ForkensicsColor.line, lineWidth: 1)
            }
        }
        .buttonStyle(ForkensicsPressButtonStyle())
    }
}

struct ProfileWireframe: View {
    let currentPlayer: WireframePlayer
    let switchPlayer: (String) -> Void
    let openTables: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ForkensicsHeader()

                VStack(spacing: 10) {
                    Text(currentPlayer.initials)
                        .font(.title2.weight(.bold))
                        .frame(width: 92, height: 92)
                        .background(ForkensicsColor.raised)
                        .clipShape(Circle())
                        .overlay { Circle().stroke(ForkensicsColor.orange, lineWidth: 3) }
                    Text(currentPlayer.name)
                        .font(.title2.weight(.bold))
                    Text(currentPlayer.handle)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                    Label("Detective since August 2026", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }

                HStack(spacing: 10) {
                    statCard(value: "620", label: "Case Points")
                    statCard(value: "47", label: "Dishes Cracked")
                    statCard(value: "39", label: "Places Nailed")
                }

#if DEBUG
                VStack(alignment: .leading, spacing: 10) {
                    ForkensicsSectionLabel(text: "Local multiplayer test")
                    Text("Switch players on this phone. Cases, private clues, guesses, and Table Talk stay separate for each detective.")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)

                    Menu {
                        ForEach(WireframePlayerDirectory.players) { player in
                            Button {
                                switchPlayer(player.id)
                            } label: {
                                if player.id == currentPlayer.id {
                                    Label(player.name, systemImage: "checkmark")
                                } else {
                                    Text(player.name)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "person.2.badge.gearshape")
                                .foregroundStyle(ForkensicsColor.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TEST AS")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(ForkensicsColor.secondaryText)
                                Text(currentPlayer.name)
                                    .font(.subheadline.weight(.bold))
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(ForkensicsColor.orange)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ForkensicsPressButtonStyle())
                }
                .forkensicsCard()
#endif

                VStack(spacing: 0) {
                    profileRow(icon: "folder", title: "Case Files", subtitle: "Your cases and solved cases")
                    Divider().overlay(ForkensicsColor.line)
                    profileRow(icon: "person.2", title: "Friends", subtitle: "Find detectives and challenge friends")
                    Divider().overlay(ForkensicsColor.line)
                    Button(action: openTables) {
                        profileRow(icon: "person.3", title: "My Tables", subtitle: "Manage your tables and invites")
                    }
                    .buttonStyle(ForkensicsPressButtonStyle())
                    Divider().overlay(ForkensicsColor.line)
                    profileRow(icon: "gearshape", title: "Settings", subtitle: "Account, privacy, notifications and more")
                }
                .forkensicsCard()
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.title3.weight(.black))
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(ForkensicsColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 76)
        .background(ForkensicsColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(ForkensicsColor.line) }
    }

    private func profileRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(ForkensicsColor.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(ForkensicsColor.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(ForkensicsColor.mutedText)
        }
        .padding(.vertical, 12)
    }
}

struct MyTablesWireframe: View {
    let currentPlayer: WireframePlayer
    let tables: [WireframeTableRecord]
    let openTable: (UUID) -> Void
    let createTable: (String, String, [String]) -> WireframeTableRecord
    let openCreatedTable: (UUID) -> Void

    @State private var showsCreateTable = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(
                    title: "My Tables",
                    showsAlert: false,
                    showsBackButton: true
                )

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("YOUR TABLES")
                            .font(.system(size: 29, weight: .black))
                        Text("Your private circles for cases, conversation, and friendly competition.")
                            .font(.subheadline)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Button {
                        showsCreateTable = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 44, height: 44)
                            .background(ForkensicsColor.orange)
                            .clipShape(Circle())
                    }
                    .buttonStyle(ForkensicsPressButtonStyle())
                    .accessibilityLabel("Create Table")
                }

                if tables.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(tables) { table in
                            tableCard(table)
                        }
                    }
                }

                Button {
                    showsCreateTable = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.3.fill")
                            .font(.title3)
                            .foregroundStyle(ForkensicsColor.orange)
                            .frame(width: 44, height: 44)
                            .background(ForkensicsColor.orange.opacity(0.12))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Create a Table")
                                .font(.headline)
                                .foregroundStyle(ForkensicsColor.primaryText)
                            Text("Bring your detectives together in a new private table.")
                                .font(.caption)
                                .foregroundStyle(ForkensicsColor.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(ForkensicsColor.orange)
                    }
                    .forkensicsCard()
                    .overlay {
                        RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius)
                            .strokeBorder(ForkensicsColor.orange.opacity(0.58), style: StrokeStyle(lineWidth: 1, dash: [5]))
                    }
                }
                .buttonStyle(ForkensicsPressButtonStyle())
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
        .fullScreenCover(isPresented: $showsCreateTable) {
            CreateTableFlowWireframe(
                currentPlayer: currentPlayer,
                cancel: { showsCreateTable = false },
                create: { name, avatarStyle, detectivePlayerIDs in
                    let table = createTable(name, avatarStyle, detectivePlayerIDs)
                    showsCreateTable = false
                    DispatchQueue.main.async {
                        openCreatedTable(table.id)
                    }
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3")
                .font(.system(size: 36))
                .foregroundStyle(ForkensicsColor.orange)
            Text("No tables yet")
                .font(.title3.weight(.bold))
            Text("Create one and invite up to 19 other detectives.")
                .font(.subheadline)
                .foregroundStyle(ForkensicsColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .forkensicsCard()
    }

    private func tableCard(_ table: WireframeTableRecord) -> some View {
        Button {
            openTable(table.id)
        } label: {
            HStack(spacing: 16) {
                CompactTableMembershipPreview(table: table)
                    .frame(width: 112, height: 112)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(table.name)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(ForkensicsColor.primaryText)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ForkensicsColor.mutedText)
                    }
                    Text("\(table.memberPlayerIDs.count) detectives")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ForkensicsColor.orange)
                    Text(table.detail)
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                        .lineLimit(2)
                    Text("\(table.role(for: currentPlayer.id))  •  \(table.ownerPlayerID == currentPlayer.id ? "Created" : "Joined") \(table.createdAt.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ForkensicsColor.mutedText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .contentShape(Rectangle())
            .forkensicsCard()
        }
        .buttonStyle(ForkensicsPressButtonStyle())
        .accessibilityLabel("\(table.name), \(table.memberPlayerIDs.count) detectives, \(table.role(for: currentPlayer.id))")
    }
}

struct TableDetailManagementWireframe: View {
    let table: WireframeTableRecord
    let currentPlayer: WireframePlayer
    let close: () -> Void
    let updateTable: (String, String, String) -> Void
    let removeDetective: (String) -> Void
    let deleteTable: () -> Void
    let leaveTable: () -> Void

    @State private var showsInviteSheet = false
    @State private var showsEditSheet = false
    @State private var showsManageSheet = false
    @State private var confirmsDelete = false
    @State private var confirmsLeave = false
    @State private var selectedMember: WireframePlayer?

    private var isOwner: Bool {
        table.ownerPlayerID == currentPlayer.id
    }

    private var members: [WireframePlayer] {
        table.memberPlayerIDs.map(WireframePlayerDirectory.player(id:))
    }

    private var seatingDetectives: [WireframeDetective] {
        members.map { player in
            WireframeDetective(
                player.id == currentPlayer.id ? "You" : player.name.components(separatedBy: " ").first ?? player.name,
                initials: player.initials
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(
                    title: "Table Details",
                    showsAlert: false,
                    showsBackButton: true,
                    backAction: close
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(table.name)
                        .font(.system(size: 31, weight: .black))
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                    Text("\(members.count) detectives  •  Created \(table.createdAt.formatted(.dateTime.month(.wide).year()))")
                        .font(.subheadline)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                    Text(table.detail)
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DetectiveTableSeating(
                    tableName: table.name,
                    detectives: seatingDetectives,
                    statusText: "\(members.count) DETECTIVES"
                )
                .forkensicsCard()

                VStack(spacing: 0) {
                    HStack {
                        ForkensicsSectionLabel(text: "Detectives")
                        Text("\(members.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    .padding(.bottom, 6)

                    ForEach(members) { player in
                        Button {
                            selectedMember = player
                        } label: {
                            HStack(spacing: 12) {
                                Text(player.initials)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(ForkensicsColor.primaryText)
                                    .frame(width: 44, height: 44)
                                    .background(ForkensicsColor.raised)
                                    .clipShape(Circle())
                                    .overlay { Circle().stroke(ForkensicsColor.line) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(player.id == currentPlayer.id ? "\(player.name) (You)" : player.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(ForkensicsColor.primaryText)
                                    Text(player.handle)
                                        .font(.caption)
                                        .foregroundStyle(ForkensicsColor.secondaryText)
                                }
                                Spacer()
                                Text(player.id == table.ownerPlayerID ? "Owner" : "Detective")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(player.id == table.ownerPlayerID ? ForkensicsColor.orange : ForkensicsColor.secondaryText)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(ForkensicsColor.mutedText)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(ForkensicsPressButtonStyle())

                        if player.id != members.last?.id {
                            Divider().overlay(ForkensicsColor.line)
                                .padding(.leading, 56)
                        }
                    }
                }
                .forkensicsCard()

                if isOwner {
                    ownerControls
                } else {
                    detectiveControls
                }
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
        .sheet(isPresented: $showsInviteSheet) {
            ForkensicsShareSheet(
                activityItems: ["Join my Forkensics table, \(table.name): https://forkensics.app/invite/\(table.id.uuidString.lowercased())"],
                completion: { _ in showsInviteSheet = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showsEditSheet) {
            EditTableSheetWireframe(table: table) { name, detail, avatarStyle in
                updateTable(name, detail, avatarStyle)
                showsEditSheet = false
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showsManageSheet) {
            ManageDetectivesSheetWireframe(
                table: table,
                removeDetective: removeDetective,
                close: { showsManageSheet = false }
            )
            .presentationDetents([.large])
        }
        .alert("Delete \(table.name)?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Table", role: .destructive, action: deleteTable)
        } message: {
            Text("This removes the table for every detective. This cannot be undone.")
        }
        .alert("Leave \(table.name)?", isPresented: $confirmsLeave) {
            Button("Cancel", role: .cancel) {}
            Button("Leave Table", role: .destructive, action: leaveTable)
        } message: {
            Text("You’ll lose access to this table and its future cases.")
        }
        .sheet(item: $selectedMember) { player in
            DetectiveSummarySheetWireframe(player: player)
                .presentationDetents([.height(310)])
        }
    }

    private var ownerControls: some View {
        VStack(spacing: 12) {
            ForkensicsPrimaryButton(
                title: "Invite Detectives",
                systemImage: "person.badge.plus",
                providesLightHaptic: true
            ) {
                showsInviteSheet = true
            }
            TableManagementActionButton(
                title: "Edit Table",
                subtitle: "Change the table name, description, or avatar.",
                systemImage: "pencil"
            ) {
                showsEditSheet = true
            }
            TableManagementActionButton(
                title: "Manage Detectives",
                subtitle: "Review or remove people from this table.",
                systemImage: "person.2.badge.gearshape"
            ) {
                showsManageSheet = true
            }
            Button {
                confirmsDelete = true
            } label: {
                Label("DELETE TABLE", systemImage: "trash")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.red.opacity(0.5))
                    }
            }
            .buttonStyle(ForkensicsPressButtonStyle())
            .padding(.top, 6)
        }
    }

    private var detectiveControls: some View {
        Button {
            confirmsLeave = true
        } label: {
            Label("LEAVE TABLE", systemImage: "rectangle.portrait.and.arrow.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red.opacity(0.5))
                }
        }
        .buttonStyle(ForkensicsPressButtonStyle())
    }
}

struct MissingTableWireframe: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 46))
                .foregroundStyle(ForkensicsColor.orange)
            Text("Table unavailable")
                .font(.title2.weight(.black))
            Text("This table may have been deleted or you may no longer be a member.")
                .font(.subheadline)
                .foregroundStyle(ForkensicsColor.secondaryText)
                .multilineTextAlignment(.center)
            ForkensicsPrimaryButton(title: "Back to My Tables", action: close)
        }
        .padding(ForkensicsSpacing.screen)
        .forkensicsScreen()
    }
}

private struct CompactTableMembershipPreview: View {
    let table: WireframeTableRecord

    private var players: [WireframePlayer] {
        Array(table.memberPlayerIDs.prefix(6)).map(WireframePlayerDirectory.player(id:))
    }

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(geometry.size.width, geometry.size.height) * 0.37

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [ForkensicsColor.raised, Color(hex: 0x090909)],
                            center: .center,
                            startRadius: 4,
                            endRadius: 54
                        )
                    )
                    .overlay { Circle().stroke(ForkensicsColor.orange.opacity(0.72), lineWidth: 2) }
                    .frame(width: 70, height: 70)
                    .position(center)

                Image(systemName: "fork.knife")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForkensicsColor.orange)
                    .position(center)

                ForEach(Array(players.enumerated()), id: \.element.id) { index, player in
                    let angle = (-Double.pi / 2) + (Double(index) * 2 * Double.pi / Double(max(players.count, 1)))
                    Text(player.initials)
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 25, height: 25)
                        .background(ForkensicsColor.raised)
                        .clipShape(Circle())
                        .overlay { Circle().stroke(ForkensicsColor.line) }
                        .position(
                            x: center.x + CGFloat(cos(angle)) * radius,
                            y: center.y + CGFloat(sin(angle)) * radius
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct TableManagementActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .foregroundStyle(ForkensicsColor.orange)
                    .frame(width: 40, height: 40)
                    .background(ForkensicsColor.orange.opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ForkensicsColor.primaryText)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForkensicsColor.mutedText)
            }
            .contentShape(Rectangle())
            .forkensicsCard()
        }
        .buttonStyle(ForkensicsPressButtonStyle())
    }
}

private struct EditTableSheetWireframe: View {
    @Environment(\.dismiss) private var dismiss
    let table: WireframeTableRecord
    let save: (String, String, String) -> Void

    @State private var name: String
    @State private var detail: String
    @State private var avatarStyle: String

    private let avatarStyles = ["charcoal", "walnut", "navy", "marble"]

    init(table: WireframeTableRecord, save: @escaping (String, String, String) -> Void) {
        self.table = table
        self.save = save
        _name = State(initialValue: table.name)
        _detail = State(initialValue: table.detail)
        _avatarStyle = State(initialValue: table.avatarStyle)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ForkensicsTextField(label: "Table Name", prompt: "Name your table", text: $name)
                    ForkensicsTextField(label: "Description", prompt: "What brings this table together?", text: $detail)
                    VStack(alignment: .leading, spacing: 12) {
                        ForkensicsSectionLabel(text: "Table Avatar")
                        HStack(spacing: 14) {
                            ForEach(avatarStyles, id: \.self) { style in
                                Button {
                                    avatarStyle = style
                                } label: {
                                    TableIdentityAvatar(style: style, selected: avatarStyle == style)
                                }
                                .buttonStyle(ForkensicsPressButtonStyle())
                            }
                        }
                    }
                    ForkensicsPrimaryButton(
                        title: "Save Changes",
                        systemImage: "checkmark",
                        enabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        save(
                            name.trimmingCharacters(in: .whitespacesAndNewlines),
                            detail.trimmingCharacters(in: .whitespacesAndNewlines),
                            avatarStyle
                        )
                    }
                }
                .padding(ForkensicsSpacing.screen)
            }
            .navigationTitle("Edit Table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .forkensicsScreen()
        }
        .preferredColorScheme(.dark)
    }
}

private struct ManageDetectivesSheetWireframe: View {
    let table: WireframeTableRecord
    let removeDetective: (String) -> Void
    let close: () -> Void

    @State private var memberIDs: [String]

    init(table: WireframeTableRecord, removeDetective: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.table = table
        self.removeDetective = removeDetective
        self.close = close
        _memberIDs = State(initialValue: table.memberPlayerIDs)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(memberIDs.map(WireframePlayerDirectory.player(id:))) { player in
                        HStack(spacing: 12) {
                            Text(player.initials)
                                .font(.caption.weight(.bold))
                                .frame(width: 44, height: 44)
                                .background(ForkensicsColor.raised)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(player.name).font(.subheadline.weight(.semibold))
                                Text(player.id == table.ownerPlayerID ? "Owner" : "Detective")
                                    .font(.caption)
                                    .foregroundStyle(player.id == table.ownerPlayerID ? ForkensicsColor.orange : ForkensicsColor.secondaryText)
                            }
                            Spacer()
                            if player.id != table.ownerPlayerID {
                                Button("Remove", role: .destructive) {
                                    memberIDs.removeAll(where: { $0 == player.id })
                                    removeDetective(player.id)
                                }
                                .font(.caption.weight(.bold))
                            }
                        }
                        .padding(.vertical, 12)
                        if player.id != memberIDs.last {
                            Divider().overlay(ForkensicsColor.line)
                        }
                    }
                }
                .forkensicsCard()
                .padding(ForkensicsSpacing.screen)
            }
            .navigationTitle("Manage Detectives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                }
            }
            .forkensicsScreen()
        }
        .preferredColorScheme(.dark)
    }
}

private struct DetectiveSummarySheetWireframe: View {
    let player: WireframePlayer

    var body: some View {
        VStack(spacing: 12) {
            Text(player.initials)
                .font(.title2.weight(.bold))
                .frame(width: 82, height: 82)
                .background(ForkensicsColor.raised)
                .clipShape(Circle())
                .overlay { Circle().stroke(ForkensicsColor.orange, lineWidth: 2) }
            Text(player.name)
                .font(.title3.weight(.black))
            Text(player.handle)
                .foregroundStyle(ForkensicsColor.secondaryText)
            Text("Detective profile details will live here.")
                .font(.caption)
                .foregroundStyle(ForkensicsColor.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ForkensicsSpacing.screen)
        .forkensicsScreen()
    }
}

private struct TableIdentityAvatar: View {
    let style: String
    let selected: Bool

    private var colors: [Color] {
        switch style {
        case "walnut": return [Color(hex: 0x9A542A), Color(hex: 0x3A1708)]
        case "navy": return [Color(hex: 0x243B5A), Color(hex: 0x07111F)]
        case "marble": return [Color(hex: 0xEFE9E2), Color(hex: 0x777777)]
        default: return [Color(hex: 0x383838), Color(hex: 0x111111)]
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "fork.knife")
                .foregroundStyle(style == "marble" ? Color.black : Color.white)
            Circle()
                .stroke(selected ? ForkensicsColor.orange : ForkensicsColor.line, lineWidth: selected ? 3 : 1)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black, ForkensicsColor.orange)
                    .offset(x: 23, y: 23)
            }
        }
        .frame(width: 62, height: 62)
    }
}

struct TableTalkHomeWireframe: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(title: "Table Talk")
                Text("Private conversations unlock after you lock in.")
                    .font(.subheadline)
                    .foregroundStyle(ForkensicsColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                conversationCard(title: "Schroeder Table", subtitle: "Case active • 4 detectives locked in", message: "I’m feeling Italian for sure.")
                conversationCard(title: "Dinner Friends Table", subtitle: "Case revealed", message: "That restaurant guess was close!")
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }

    private func conversationCard(title: String, subtitle: String, message: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(ForkensicsColor.orange)
                .frame(width: 44, height: 44)
                .background(ForkensicsColor.orange.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(ForkensicsColor.orange)
                Text(message).font(.subheadline).foregroundStyle(ForkensicsColor.secondaryText).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(ForkensicsColor.mutedText)
        }
        .forkensicsCard()
    }
}

struct PostCaseWireframe: View {
    let viewCases: () -> Void
    let sendCase: (WireframePostedCase) -> Void
    let currentPlayer: WireframePlayer
    let tables: [WireframeTableRecord]
    let createTable: (String, String, [String]) -> WireframeTableRecord
    let openCreatedTable: (UUID) -> Void

    @State private var caseTitle = ""
    @State private var dish = ""
    @State private var restaurant = ""
    @State private var location = ""
    @State private var clue = ""
    @State private var durationHours = 2
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showsCamera = false
    @State private var showsCustomDuration = false
    @State private var customDurationHours = 2
    @State private var currentStep = 1
    @State private var selectedTableIDs: Set<UUID> = []
    @State private var showsCreateTable = false

    private let presetDurations = [2, 6, 12, 24]
    private let sampleFoodPhotos = [
        (name: "BurgerAndFries", label: "Burger and fries"),
        (name: "StreetTacos", label: "Street tacos"),
        (name: "FishAndChips", label: "Fish and chips"),
        (name: "BBQBrisket", label: "BBQ brisket")
    ]

    init(
        viewCases: @escaping () -> Void = {},
        sendCase: @escaping (WireframePostedCase) -> Void = { _ in },
        currentPlayer: WireframePlayer = WireframePlayerDirectory.maggie,
        tables: [WireframeTableRecord] = [],
        createTable: @escaping (String, String, [String]) -> WireframeTableRecord = { name, avatarStyle, detectivePlayerIDs in
            WireframeTableRecord(
                name: name,
                detail: "New table",
                avatarStyle: avatarStyle,
                ownerPlayerID: WireframePlayerDirectory.maggie.id,
                memberPlayerIDs: detectivePlayerIDs
            )
        },
        openCreatedTable: @escaping (UUID) -> Void = { _ in }
    ) {
        self.viewCases = viewCases
        self.sendCase = sendCase
        self.currentPlayer = currentPlayer
        self.tables = tables
        self.createTable = createTable
        self.openCreatedTable = openCreatedTable
    }

    private var cameraIsAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    private var canContinueDetails: Bool {
        selectedImage != nil &&
        !caseTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !dish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !restaurant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    Color.clear.frame(height: 0).id("post-case-top")
                    ForkensicsHeader(title: "Case File", showsAlert: false)

                    if currentStep <= 3 {
                        StepperHeader(current: currentStep)
                    }

                    switch currentStep {
                    case 1:
                        caseDetailsStep
                    case 2:
                        chooseTablesStep
                    case 3:
                        reviewStep
                    default:
                        caseSentStep
                    }
                }
                .padding(ForkensicsSpacing.screen)
            }
            .onChange(of: currentStep) {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("post-case-top", anchor: .top)
                }
            }
        }
        .forkensicsScreen()
        .fullScreenCover(isPresented: $showsCamera) {
            ForkensicsCameraPicker(image: $selectedImage)
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showsCreateTable) {
            CreateTableFlowWireframe(
                currentPlayer: currentPlayer,
                cancel: { showsCreateTable = false },
                create: { name, avatarStyle, detectivePlayerIDs in
                    let newTable = createTable(name, avatarStyle, detectivePlayerIDs)
                    selectedTableIDs.insert(newTable.id)
                    showsCreateTable = false
                    DispatchQueue.main.async {
                        openCreatedTable(newTable.id)
                    }
                }
            )
        }
        .sheet(isPresented: $showsCustomDuration) {
            customDurationSheet
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: selectedPhotoItem) {
            guard let selectedPhotoItem else { return }
            Task {
                guard let data = try? await selectedPhotoItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                selectedImage = image
            }
        }
    }

    private var caseDetailsStep: some View {
        Group {
            casePhotoSection
            ForkensicsTextField(label: "Case title", prompt: "Give this mystery a name", text: $caseTitle)
            Text("Detectives see this title, so don’t give away the answer.")
                .font(.caption2)
                .foregroundStyle(ForkensicsColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForkensicsTextField(label: "Dish name", prompt: "What is the dish?", text: $dish)
            ForkensicsTextField(label: "Restaurant name", prompt: "Where is it from?", text: $restaurant)
            ForkensicsTextField(label: "Restaurant location (optional)", prompt: "City, State", text: $location)
            durationSection
            ForkensicsTextField(label: "Add a clue (optional)", prompt: "Give a small clue", text: $clue)

            if !canContinueDetails {
                Label("Add a photo, case title, dish name, and restaurant to continue.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(ForkensicsColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForkensicsPrimaryButton(
                title: "Next: Choose Tables",
                systemImage: "chevron.right",
                enabled: canContinueDetails
            ) {
                currentStep = 2
            }
        }
    }

    private var chooseTablesStep: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Text("WHO GETS THE CASE?")
                    .font(.system(size: 25, weight: .black))
                Text("Choose one or more tables. Everyone at those tables can investigate.")
                    .font(.subheadline)
                    .foregroundStyle(ForkensicsColor.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(tables) { table in
                tableChoiceRow(table)
            }

            Button {
                showsCreateTable = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(ForkensicsColor.orange)
                        .frame(width: 42, height: 42)
                        .background(ForkensicsColor.orange.opacity(0.12))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Create a New Table")
                            .font(.headline)
                            .foregroundStyle(ForkensicsColor.primaryText)
                        Text("Start a table and invite detectives.")
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(ForkensicsColor.mutedText)
                }
                .forkensicsCard()
                .overlay {
                    RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius)
                        .strokeBorder(ForkensicsColor.orange.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5]))
                }
            }
            .buttonStyle(ForkensicsPressButtonStyle())

            if selectedTableIDs.isEmpty {
                Label("Select at least one table to continue.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(ForkensicsColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForkensicsPrimaryButton(
                title: "Next: Review Case",
                systemImage: "chevron.right",
                enabled: !selectedTableIDs.isEmpty
            ) {
                currentStep = 3
            }
            ForkensicsSecondaryButton(title: "Back to Case Details") {
                currentStep = 1
            }
        }
    }

    private var reviewStep: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Text("READY TO SEND?")
                    .font(.system(size: 25, weight: .black))
                Text("Double-check the answer and recipients. Detectives only see the photo and clue.")
                    .font(.subheadline)
                    .foregroundStyle(ForkensicsColor.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let selectedImage {
                Image(uiImage: selectedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius))
                    .accessibilityLabel("Selected case photo")
            }

            VStack(spacing: 0) {
                reviewRow(label: "Case title", value: caseTitle)
                Divider().overlay(ForkensicsColor.line)
                reviewRow(label: "Dish", value: dish)
                Divider().overlay(ForkensicsColor.line)
                reviewRow(label: "Restaurant", value: restaurant)
                if !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider().overlay(ForkensicsColor.line)
                    reviewRow(label: "Location", value: location)
                }
                if !clue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider().overlay(ForkensicsColor.line)
                    reviewRow(label: "Private clue", value: clue)
                }
                Divider().overlay(ForkensicsColor.line)
                reviewRow(label: "Reveals in", value: hourLabel(durationHours))
            }
            .forkensicsCard()

            VStack(alignment: .leading, spacing: 10) {
                ForkensicsSectionLabel(text: "Sending to")
                ForEach(selectedTables) { table in
                    Label("\(table.name) · \(table.memberPlayerIDs.count) detectives", systemImage: "person.3.fill")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .forkensicsCard()

            Label("Your answer stays hidden until the case reveals.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(ForkensicsColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForkensicsPrimaryButton(
                title: "Send Case",
                systemImage: "paperplane.fill",
                providesLightHaptic: true,
                action: submitCase
            )
            ForkensicsSecondaryButton(title: "Back to Choose Tables") {
                currentStep = 2
            }
        }
    }

    private var caseSentStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 66))
                .foregroundStyle(ForkensicsColor.orange)
            Text("CASE SENT!")
                .font(.system(size: 34, weight: .black))
            Text(caseTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(ForkensicsColor.orange)
            Text("Your detectives are on the case. Their guesses and Table Talk stay hidden until they lock in.")
                .font(.subheadline)
                .foregroundStyle(ForkensicsColor.secondaryText)
                .multilineTextAlignment(.center)

            Text("Sent to \(selectedTables.count) \(selectedTables.count == 1 ? "table" : "tables")")
                .font(.headline)
                .foregroundStyle(ForkensicsColor.orange)
                .padding(.vertical, 8)

            Label("Reveals in \(hourLabel(durationHours))", systemImage: "clock.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ForkensicsColor.secondaryText)

            ForkensicsPrimaryButton(title: "View My Cases", systemImage: "folder", action: viewCases)
            ForkensicsSecondaryButton(title: "Post Another Case", action: resetCase)
        }
        .padding(.top, 28)
    }

    private var selectedTables: [WireframeTableRecord] {
        tables.filter { selectedTableIDs.contains($0.id) }
    }

    private func tableChoiceRow(_ table: WireframeTableRecord) -> some View {
        let isSelected = selectedTableIDs.contains(table.id)

        return Button {
            if isSelected {
                selectedTableIDs.remove(table.id)
            } else {
                selectedTableIDs.insert(table.id)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(ForkensicsColor.orange)
                    .frame(width: 42, height: 42)
                    .background(ForkensicsColor.orange.opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(table.name)
                        .font(.headline)
                        .foregroundStyle(ForkensicsColor.primaryText)
                    Text("\(table.memberPlayerIDs.count) detectives · \(table.detail)")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? ForkensicsColor.orange : ForkensicsColor.mutedText)
            }
            .forkensicsCard()
            .overlay {
                RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius)
                    .stroke(isSelected ? ForkensicsColor.orange : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(ForkensicsPressButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func reviewRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(ForkensicsColor.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    private func resetCase() {
        caseTitle = ""
        dish = ""
        restaurant = ""
        location = ""
        clue = ""
        durationHours = 2
        selectedPhotoItem = nil
        selectedImage = nil
        selectedTableIDs.removeAll()
        currentStep = 1
    }

    private func submitCase() {
        guard let selectedImage,
              let photoData = selectedImage.jpegData(compressionQuality: 0.88) ?? selectedImage.pngData()
        else { return }

        sendCase(
            WireframePostedCase(
                photoData: photoData,
                title: caseTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                dish: dish.trimmingCharacters(in: .whitespacesAndNewlines),
                restaurant: restaurant.trimmingCharacters(in: .whitespacesAndNewlines),
                location: location.trimmingCharacters(in: .whitespacesAndNewlines),
                clue: clue.trimmingCharacters(in: .whitespacesAndNewlines),
                tableNames: selectedTables.map(\.name),
                durationHours: durationHours,
                posterPlayerID: currentPlayer.id
            )
        )
        currentStep = 4
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForkensicsSectionLabel(text: "Set reveal time")

            HStack(spacing: 7) {
                ForEach(presetDurations, id: \.self) { hours in
                    durationPresetButton(hours)
                }

                Button {
                    customDurationHours = durationHours
                    showsCustomDuration = true
                } label: {
                    let isCustom = !presetDurations.contains(durationHours)
                    VStack(spacing: 5) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 17, weight: .medium))
                        Text(isCustom ? "\(durationHours)h" : "Custom")
                            .font(.system(size: 9, weight: .bold))
                            .lineLimit(1)
                        Text(isCustom ? "Custom" : "1–48h")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(isCustom ? ForkensicsColor.orange : ForkensicsColor.secondaryText)
                    }
                    .foregroundStyle(isCustom ? ForkensicsColor.orange : ForkensicsColor.primaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .background(isCustom ? ForkensicsColor.orange.opacity(0.12) : ForkensicsColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isCustom ? ForkensicsColor.orange : ForkensicsColor.line, lineWidth: isCustom ? 2 : 1)
                    }
                }
                .buttonStyle(ForkensicsPressButtonStyle())
            }

            Label(
                "Detectives have until the timer expires to lock in their guesses.",
                systemImage: "clock"
            )
            .font(.caption2)
            .foregroundStyle(ForkensicsColor.secondaryText)
        }
    }

    private func durationPresetButton(_ hours: Int) -> some View {
        let isSelected = durationHours == hours

        return Button {
            durationHours = hours
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 17, weight: .medium))
                Text("\(hours) Hours")
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(hours == 2 ? "(Default)" : " ")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(isSelected ? ForkensicsColor.orange : ForkensicsColor.secondaryText)
            }
            .foregroundStyle(isSelected ? ForkensicsColor.orange : ForkensicsColor.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(isSelected ? ForkensicsColor.orange.opacity(0.12) : ForkensicsColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? ForkensicsColor.orange : ForkensicsColor.line, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(ForkensicsPressButtonStyle())
        .accessibilityLabel("\(hourLabel(hours))\(hours == 2 ? ", default" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var customDurationSheet: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("CHOOSE 1–48 HOURS")
                    .font(.title3.weight(.black))

                Picker("Custom reveal time", selection: $customDurationHours) {
                    ForEach(1...48, id: \.self) { hours in
                        Text(hourLabel(hours)).tag(hours)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()

                Text("The case can still reveal sooner if every detective locks in.")
                    .font(.caption)
                    .foregroundStyle(ForkensicsColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .forkensicsScreen()
            .navigationTitle("Custom Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showsCustomDuration = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        durationHours = customDurationHours
                        showsCustomDuration = false
                    }
                    .fontWeight(.bold)
                }
            }
            .tint(ForkensicsColor.orange)
        }
    }

    private func hourLabel(_ hours: Int) -> String {
        "\(hours) \(hours == 1 ? "hour" : "hours")"
    }

    private var casePhotoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForkensicsSectionLabel(text: "Case photo")

            ZStack {
                RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius)
                    .fill(ForkensicsColor.surface)

                if let selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 230)
                        .clipped()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(ForkensicsColor.orange)
                        Text("ADD A FOOD PHOTO")
                            .font(.headline.weight(.black))
                        Text("Detectives use this photo to crack the case.")
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    .multilineTextAlignment(.center)
                    .padding()
                }
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius)
                    .stroke(ForkensicsColor.line, lineWidth: 1)
            }
            .accessibilityLabel(selectedImage == nil ? "No case photo selected" : "Selected case photo")

            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label(selectedImage == nil ? "Choose Photo" : "Replace Photo", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ForkensicsColor.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(ForkensicsColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(ForkensicsColor.line, lineWidth: 1)
                        }
                }
                .buttonStyle(ForkensicsPressButtonStyle())

                if cameraIsAvailable {
                    Button {
                        showsCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(ForkensicsColor.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(ForkensicsColor.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(ForkensicsColor.line, lineWidth: 1)
                            }
                    }
                    .buttonStyle(ForkensicsPressButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("PROTOTYPE SAMPLE PHOTOS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(ForkensicsColor.secondaryText)

                HStack(spacing: 8) {
                    ForEach(sampleFoodPhotos, id: \.name) { sample in
                        Button {
                            selectedPhotoItem = nil
                            selectedImage = UIImage(named: sample.name)
                        } label: {
                            Image(sample.name)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: 66)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(ForkensicsColor.line, lineWidth: 1)
                                }
                        }
                        .buttonStyle(ForkensicsPressButtonStyle())
                        .accessibilityLabel("Use sample photo: \(sample.label)")
                    }
                }
            }
        }
    }
}

private struct CreateTableFlowWireframe: View {
    private enum Step {
        case build
        case review
    }

    private enum TableAvatarStyle: String, CaseIterable, Identifiable {
        case charcoal
        case walnut
        case navy
        case marble

        var id: String { rawValue }

        var name: String {
            switch self {
            case .charcoal: return "Charcoal"
            case .walnut: return "Walnut"
            case .navy: return "Midnight"
            case .marble: return "Marble"
            }
        }

        var colors: [Color] {
            switch self {
            case .charcoal: return [Color(hex: 0x383838), Color(hex: 0x111111)]
            case .walnut: return [Color(hex: 0x9A542A), Color(hex: 0x3A1708)]
            case .navy: return [Color(hex: 0x243B5A), Color(hex: 0x07111F)]
            case .marble: return [Color(hex: 0xEFE9E2), Color(hex: 0x777777)]
            }
        }
    }

    let currentPlayer: WireframePlayer
    let cancel: () -> Void
    let create: (String, String, [String]) -> Void

    @State private var step: Step = .build
    @State private var tableName = ""
    @State private var selectedAvatar: TableAvatarStyle = .charcoal
    @State private var selectedPlayerIDs: Set<String> = []
    @State private var searchText = ""
    @State private var showsInviteSheet = false

    private var availablePlayers: [WireframePlayer] {
        WireframePlayerDirectory.players.filter { $0.id != currentPlayer.id }
    }

    private var filteredPlayers: [WireframePlayer] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availablePlayers }
        return availablePlayers.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.handle.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedPlayers: [WireframePlayer] {
        availablePlayers.filter { selectedPlayerIDs.contains($0.id) }
    }

    private var cleanTableName: String {
        tableName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canReview: Bool {
        !cleanTableName.isEmpty && !selectedPlayerIDs.isEmpty
    }

    var body: some View {
        Group {
            switch step {
            case .build:
                buildScreen
            case .review:
                reviewScreen
            }
        }
        .forkensicsScreen()
        .sheet(isPresented: $showsInviteSheet) {
            inviteDetectivesSheet
                .presentationDetents([.large])
        }
    }

    private var buildScreen: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(
                    showsAlert: false,
                    showsBackButton: true,
                    backAction: cancel
                )

                titleBlock(
                    title: "Build Your Table",
                    subtitle: "Give your table a name and invite the detectives who will crack cases with you."
                )

                tableNameField
                avatarPicker

                Divider().overlay(ForkensicsColor.line)

                VStack(alignment: .leading, spacing: 4) {
                    Text("ADD DETECTIVES")
                        .font(.headline.weight(.black))
                    Text("Choose from your friends or invite someone new.")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                inviteRow
                selectionSummary

                if !selectedPlayers.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(selectedPlayers) { player in
                            detectiveSelectionRow(player)
                            if player.id != selectedPlayers.last?.id {
                                Divider().overlay(ForkensicsColor.line)
                                    .padding(.leading, 54)
                            }
                        }
                    }
                    .forkensicsCard()
                }

                // Keep the final detective row comfortably above the pinned CTA.
                Color.clear.frame(height: 12)
            }
            .padding(ForkensicsSpacing.screen)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if !canReview {
                    Text(cleanTableName.isEmpty ? "Name your table to continue." : "Choose at least one detective.")
                        .font(.caption2)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                ForkensicsPrimaryButton(
                    title: "Next: Review Table",
                    systemImage: "chevron.right",
                    enabled: canReview,
                    providesLightHaptic: true
                ) {
                    step = .review
                }
            }
            .padding(.horizontal, ForkensicsSpacing.screen)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(ForkensicsColor.background.opacity(0.97))
        }
    }

    private var reviewScreen: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(
                    showsAlert: false,
                    showsBackButton: true,
                    backAction: { step = .build }
                )

                titleBlock(
                    title: "Review Your Table",
                    subtitle: "Double-check your table details and detectives before creating it."
                )

                HStack(spacing: 16) {
                    tableAvatar(selectedAvatar, size: 104, selected: true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(cleanTableName)
                            .font(.title3.weight(.black))
                        Text("\(selectedPlayers.count) \(selectedPlayers.count == 1 ? "detective" : "detectives") + you")
                            .font(.subheadline)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                        Text("You’re the table owner")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ForkensicsColor.orange)
                    }
                    Spacer()
                    editButton {
                        step = .build
                    }
                }
                .forkensicsCard()

                VStack(spacing: 0) {
                    HStack {
                        Text("YOUR DETECTIVES")
                            .font(.caption.weight(.black))
                        Spacer()
                        editButton {
                            step = .build
                        }
                    }
                    .padding(.bottom, 8)

                    ForEach(selectedPlayers) { player in
                        detectiveIdentityRow(player)
                        if player.id != selectedPlayers.last?.id {
                            Divider().overlay(ForkensicsColor.line)
                        }
                    }

                }
                .forkensicsCard()

                Label(
                    "You can invite more detectives or change your table settings anytime.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(ForkensicsColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .forkensicsCard()
            }
            .padding(ForkensicsSpacing.screen)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ForkensicsPrimaryButton(
                title: "Create Table",
                systemImage: "person.3.fill",
                providesLightHaptic: true
            ) {
                create(cleanTableName, selectedAvatar.rawValue, selectedPlayers.map(\.id))
            }
            .padding(.horizontal, ForkensicsSpacing.screen)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(ForkensicsColor.background.opacity(0.97))
        }
    }

    private func titleBlock(title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 25, weight: .black))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(ForkensicsColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var tableNameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TABLE NAME")
                .font(.caption2.weight(.bold))
                .foregroundStyle(ForkensicsColor.secondaryText)
            HStack {
                TextField("Name your table", text: $tableName)
                    .textInputAutocapitalization(.words)
                    .onChange(of: tableName) {
                        if tableName.count > 30 {
                            tableName = String(tableName.prefix(30))
                        }
                    }
                Text("\(tableName.count)/30")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ForkensicsColor.secondaryText)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .background(ForkensicsColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ForkensicsColor.line)
            }
            Text("Choose a name your detectives will recognize.")
                .font(.caption2)
                .foregroundStyle(ForkensicsColor.secondaryText)
        }
    }

    private var avatarPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TABLE AVATAR")
                .font(.caption2.weight(.bold))
                .foregroundStyle(ForkensicsColor.secondaryText)
            HStack(spacing: 13) {
                ForEach(TableAvatarStyle.allCases) { style in
                    Button {
                        selectedAvatar = style
                    } label: {
                        tableAvatar(style, size: 64, selected: selectedAvatar == style)
                    }
                    .buttonStyle(ForkensicsPressButtonStyle())
                    .accessibilityLabel("\(style.name) table avatar")
                    .accessibilityAddTraits(selectedAvatar == style ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            Text("You can change this later in your table settings.")
                .font(.caption2)
                .foregroundStyle(ForkensicsColor.secondaryText)
        }
    }

    private func tableAvatar(_ style: TableAvatarStyle, size: CGFloat, selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: style.colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(size * 0.15)
            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .fill(Color(hex: 0x8A5A38))
                    .frame(width: size * 0.18, height: size * 0.1)
                    .offset(y: -size * 0.42)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
            Circle()
                .stroke(selected ? ForkensicsColor.orange : ForkensicsColor.line, lineWidth: selected ? 3 : 1)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.27))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black, ForkensicsColor.orange)
                    .offset(x: size * 0.34, y: size * 0.34)
            }
        }
        .frame(width: size, height: size)
    }

    private var inviteRow: some View {
        Button {
            searchText = ""
            showsInviteSheet = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.badge.plus")
                    .font(.title3)
                    .foregroundStyle(ForkensicsColor.orange)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Invite a New Detective")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ForkensicsColor.primaryText)
                    Text("Choose people to add to this table")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(ForkensicsColor.mutedText)
            }
            .forkensicsCard()
            .overlay {
                RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius)
                    .strokeBorder(ForkensicsColor.orange.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [5]))
            }
        }
        .buttonStyle(ForkensicsPressButtonStyle())
    }

    private var inviteDetectivesSheet: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ADD DETECTIVES")
                        .font(.title2.weight(.black))
                    Text("Tap a detective to add them to \(cleanTableName.isEmpty ? "your table" : cleanTableName).")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
                Button {
                    showsInviteSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.bold))
                        .frame(width: 42, height: 42)
                        .background(ForkensicsColor.surface)
                        .clipShape(Circle())
                        .overlay { Circle().stroke(ForkensicsColor.line) }
                }
                .buttonStyle(ForkensicsPressButtonStyle())
                .accessibilityLabel("Close")
            }

            searchField
            selectionSummary

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredPlayers) { player in
                        detectiveSelectionRow(player)
                        if player.id != filteredPlayers.last?.id {
                            Divider().overlay(ForkensicsColor.line)
                                .padding(.leading, 54)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)

            ForkensicsPrimaryButton(
                title: selectedPlayerIDs.isEmpty
                    ? "Done"
                    : "Add \(selectedPlayerIDs.count) \(selectedPlayerIDs.count == 1 ? "Detective" : "Detectives")",
                systemImage: "person.badge.plus",
                providesLightHaptic: true
            ) {
                showsInviteSheet = false
            }
        }
        .padding(ForkensicsSpacing.screen)
        .forkensicsScreen()
    }

    private var selectionSummary: some View {
        HStack {
            Text("\(selectedPlayerIDs.count) selected • 19 maximum")
                .font(.caption.weight(.semibold))
                .foregroundStyle(selectedPlayerIDs.count == 19 ? ForkensicsColor.orange : ForkensicsColor.secondaryText)
            Spacer()
            Text("You’re included as owner")
                .font(.caption2)
                .foregroundStyle(ForkensicsColor.secondaryText)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ForkensicsColor.secondaryText)
            TextField("Search friends…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(ForkensicsColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ForkensicsColor.line)
        }
    }

    private func detectiveSelectionRow(_ player: WireframePlayer) -> some View {
        let isSelected = selectedPlayerIDs.contains(player.id)
        let selectionIsFull = selectedPlayerIDs.count >= 19

        return Button {
            if isSelected {
                selectedPlayerIDs.remove(player.id)
            } else if !selectionIsFull {
                selectedPlayerIDs.insert(player.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isSelected ? ForkensicsColor.orange : ForkensicsColor.mutedText)
                Text(player.initials)
                    .font(.caption.weight(.bold))
                    .frame(width: 42, height: 42)
                    .background(ForkensicsColor.raised)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ForkensicsColor.primaryText)
                    Text(player.handle)
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 9)
            .opacity(!isSelected && selectionIsFull ? 0.42 : 1)
        }
        .buttonStyle(ForkensicsPressButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func detectiveIdentityRow(_ player: WireframePlayer) -> some View {
        HStack(spacing: 12) {
            Text(player.initials)
                .font(.subheadline.weight(.bold))
                .frame(width: 48, height: 48)
                .background(ForkensicsColor.raised)
                .clipShape(Circle())
                .overlay { Circle().stroke(ForkensicsColor.line) }
            VStack(alignment: .leading, spacing: 3) {
                Text(player.name)
                    .font(.subheadline.weight(.semibold))
                Text(player.handle)
                    .font(.caption)
                    .foregroundStyle(ForkensicsColor.secondaryText)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }

    private func editButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Edit", systemImage: "pencil")
                .font(.caption.weight(.bold))
                .foregroundStyle(ForkensicsColor.orange)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(ForkensicsPressButtonStyle())
    }
}

private struct ForkensicsShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            DispatchQueue.main.async {
                completion(completed)
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ForkensicsCameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var image: UIImage?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: ForkensicsCameraPicker

        init(parent: ForkensicsCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct StepperHeader: View {
    let current: Int
    private let steps = ["Case Details", "Choose Tables", "Send Case"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { index in
                VStack(spacing: 5) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                        .background(index + 1 == current ? ForkensicsColor.orange : ForkensicsColor.surface)
                        .foregroundStyle(index + 1 == current ? Color.black : ForkensicsColor.secondaryText)
                        .clipShape(Circle())
                    Text(steps[index])
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(index + 1 == current ? ForkensicsColor.orange : ForkensicsColor.mutedText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                if index < steps.count - 1 {
                    Rectangle().fill(ForkensicsColor.line).frame(width: 20, height: 1)
                }
            }
        }
    }
}

struct LeaderboardWireframe: View {
    let currentPlayer: WireframePlayer
    let tableNames: [String]
    let entries: (String, WireframeLeaderboardPeriod) -> [WireframeLeaderboardEntry]
    let history: (String, String, WireframeLeaderboardPeriod) -> [WireframeLeaderboardCaseResult]

    @State private var selectedPeriod: WireframeLeaderboardPeriod = .thisMonth
    @State private var selectedTable: String
    @State private var selectedPlayer: WireframePlayer?

    init(
        currentPlayer: WireframePlayer,
        tableNames: [String],
        entries: @escaping (String, WireframeLeaderboardPeriod) -> [WireframeLeaderboardEntry],
        history: @escaping (String, String, WireframeLeaderboardPeriod) -> [WireframeLeaderboardCaseResult]
    ) {
        self.currentPlayer = currentPlayer
        self.tableNames = tableNames
        self.entries = entries
        self.history = history
        _selectedTable = State(initialValue: tableNames.first ?? "Schroeder Table")
    }

    private var standings: [WireframeLeaderboardEntry] {
        entries(selectedTable, selectedPeriod)
    }

    private var currentPlayerEntry: WireframeLeaderboardEntry? {
        standings.first(where: { $0.player.id == currentPlayer.id })
    }

    private var podiumEntries: [WireframeLeaderboardEntry] {
        let top = Array(standings.prefix(3))
        guard top.count == 3 else { return top }
        return [top[1], top[0], top[2]]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsHeader(title: "Leaderboard")

                periodSelector
                tableSelector

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedPeriod == .thisMonth ? "THIS MONTH" : "HALL OF FAME")
                        .font(.caption2.weight(.black))
                        .tracking(1.3)
                        .foregroundStyle(ForkensicsColor.orange)
                    Text("TABLE STANDINGS")
                        .font(.title2.weight(.black))
                    Text("Only points earned with \(selectedTable) count here.")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if standings.isEmpty {
                    emptyState
                } else {
                    if let currentPlayerEntry {
                        yourStanding(currentPlayerEntry)
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(podiumEntries) { entry in
                            Button {
                                selectedPlayer = entry.player
                            } label: {
                                podium(entry)
                            }
                            .buttonStyle(ForkensicsPressButtonStyle())
                        }
                    }

                    ForEach(Array(standings.dropFirst(3))) { entry in
                        leaderboardRow(entry)
                    }

                    Text("Posters do not earn points on their own cases. Tied totals share the same rank.")
                        .font(.caption2)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                }
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
        .sheet(item: $selectedPlayer) { player in
            LeaderboardHistorySheet(
                player: player,
                tableName: selectedTable,
                period: selectedPeriod,
                results: history(player.id, selectedTable, selectedPeriod)
            )
        }
    }

    private var periodSelector: some View {
        HStack(spacing: 0) {
            periodButton("This Month", period: .thisMonth)
            periodButton("Hall of Fame", period: .allTime)
        }
        .padding(4)
        .background(ForkensicsColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func periodButton(_ title: String, period: WireframeLeaderboardPeriod) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                selectedPeriod = period
            }
        } label: {
            Text(title.uppercased())
                .font(.caption2.weight(.black))
                .foregroundStyle(selectedPeriod == period ? Color.black : ForkensicsColor.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(selectedPeriod == period ? ForkensicsColor.orange : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(ForkensicsPressButtonStyle())
    }

    private var tableSelector: some View {
        Menu {
            ForEach(tableNames, id: \.self) { tableName in
                Button {
                    selectedTable = tableName
                } label: {
                    if tableName == selectedTable {
                        Label(tableName, systemImage: "checkmark")
                    } else {
                        Text(tableName)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(ForkensicsColor.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TABLE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ForkensicsColor.secondaryText)
                    Text(selectedTable)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ForkensicsColor.primaryText)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForkensicsColor.orange)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ForkensicsPressButtonStyle())
        .forkensicsCard()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "trophy")
                .font(.system(size: 38))
                .foregroundStyle(ForkensicsColor.orange)
            Text("No standings yet")
                .font(.headline)
            Text("Points appear here after detectives complete a revealed case for this table.")
                .font(.caption)
                .foregroundStyle(ForkensicsColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .forkensicsCard()
    }

    private func yourStanding(_ entry: WireframeLeaderboardEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "scope")
                .font(.title3)
                .foregroundStyle(ForkensicsColor.orange)
                .frame(width: 46, height: 46)
                .background(ForkensicsColor.orange.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("YOUR STANDING")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(ForkensicsColor.orange)
                Text("#\(entry.rank) · \(entry.points) points")
                    .font(.headline)
                if entry.latestCasePoints > 0 {
                    Text("+\(entry.latestCasePoints) from the latest reveal")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
            }
            Spacer()
            movementBadge(entry.movement)
        }
        .forkensicsCard()
    }

    private func podium(_ entry: WireframeLeaderboardEntry) -> some View {
        let firstName = entry.player.name.split(separator: " ").first.map(String.init) ?? entry.player.name
        return VStack(spacing: 7) {
            Text(entry.rank == 1 ? "👑" : "#\(entry.rank)")
                .font(entry.rank == 1 ? .title2 : .caption.weight(.black))
                .foregroundStyle(ForkensicsColor.orange)
            Text(entry.player.initials)
                .font(.headline.weight(.bold))
                .foregroundStyle(ForkensicsColor.primaryText)
                .frame(width: entry.rank == 1 ? 64 : 54, height: entry.rank == 1 ? 64 : 54)
                .background(ForkensicsColor.raised)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(entry.rank == 1 ? ForkensicsColor.orange : ForkensicsColor.line, lineWidth: 2)
                }
            Text(firstName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ForkensicsColor.primaryText)
                .lineLimit(1)
            Text("\(entry.points)")
                .font(.title3.weight(.black))
                .foregroundStyle(entry.rank == 1 ? ForkensicsColor.orange : ForkensicsColor.primaryText)
            Text("POINTS")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(ForkensicsColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, entry.rank == 1 ? 20 : 13)
        .background(ForkensicsColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(entry.rank == 1 ? ForkensicsColor.orange : ForkensicsColor.line)
        }
    }

    private func leaderboardRow(_ entry: WireframeLeaderboardEntry) -> some View {
        Button {
            selectedPlayer = entry.player
        } label: {
            HStack(spacing: 13) {
                Text("\(entry.rank)")
                    .font(.headline.weight(.black))
                    .foregroundStyle(ForkensicsColor.orange)
                    .frame(width: 28)
                Text(entry.player.initials)
                    .font(.caption.weight(.bold))
                    .frame(width: 40, height: 40)
                    .background(ForkensicsColor.raised)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.player.name + (entry.player.id == currentPlayer.id ? " (You)" : ""))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ForkensicsColor.primaryText)
                    Text("\(entry.caseCount) \(entry.caseCount == 1 ? "case" : "cases") · Last reveal +\(entry.latestCasePoints)")
                        .font(.caption2)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                Spacer()
                movementBadge(entry.movement)
                Text("\(entry.points)")
                    .font(.headline.weight(.black))
                    .foregroundStyle(ForkensicsColor.orange)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForkensicsColor.mutedText)
            }
            .forkensicsCard()
        }
        .buttonStyle(ForkensicsPressButtonStyle())
    }

    @ViewBuilder private func movementBadge(_ movement: Int?) -> some View {
        if let movement, movement != 0 {
            Label("\(abs(movement))", systemImage: movement > 0 ? "arrow.up" : "arrow.down")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(movement > 0 ? Color.green : ForkensicsColor.secondaryText)
        }
    }
}

struct LeaderboardHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let player: WireframePlayer
    let tableName: String
    let period: WireframeLeaderboardPeriod
    let results: [WireframeLeaderboardCaseResult]

    private var totalPoints: Int {
        results.reduce(0) { $0 + $1.totalPoints }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(period == .thisMonth ? "THIS MONTH" : "HALL OF FAME")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(ForkensicsColor.orange)
                        Text("SCORING HISTORY")
                            .font(.title3.weight(.black))
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.black))
                            .frame(width: 38, height: 38)
                            .background(ForkensicsColor.raised)
                            .clipShape(Circle())
                    }
                    .buttonStyle(ForkensicsPressButtonStyle())
                    .accessibilityLabel("Close")
                }

                HStack(spacing: 14) {
                    Text(player.initials)
                        .font(.headline.weight(.bold))
                        .frame(width: 56, height: 56)
                        .background(ForkensicsColor.raised)
                        .clipShape(Circle())
                        .overlay { Circle().stroke(ForkensicsColor.orange, lineWidth: 2) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.name)
                            .font(.headline)
                        Text(tableName)
                            .font(.caption)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(totalPoints)")
                            .font(.title2.weight(.black))
                            .foregroundStyle(ForkensicsColor.orange)
                        Text("POINTS")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(ForkensicsColor.secondaryText)
                    }
                }
                .forkensicsCard()

                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.caseTitle)
                                    .font(.subheadline.weight(.bold))
                                Text(result.postedAt.formatted(.dateTime.month(.abbreviated).day()))
                                    .font(.caption2)
                                    .foregroundStyle(ForkensicsColor.secondaryText)
                            }
                            Spacer()
                            Text("+\(result.totalPoints)")
                                .font(.headline.weight(.black))
                                .foregroundStyle(ForkensicsColor.orange)
                        }
                        scoreDetail(label: "Dish", points: result.dishPoints)
                        scoreDetail(label: "Place", points: result.placePoints)
                        if result.cluePenalty > 0 {
                            scoreDetail(label: "Private clue", points: -result.cluePenalty)
                        }
                    }
                    .forkensicsCard()
                }
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func scoreDetail(label: String, points: Int) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(ForkensicsColor.secondaryText)
            Spacer()
            Text(points >= 0 ? "+\(points)" : "\(points)")
                .font(.caption.weight(.bold))
                .foregroundStyle(points > 0 ? Color.green : ForkensicsColor.secondaryText)
        }
    }
}

struct AlertsWireframe: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForkensicsHeader(title: "Alerts", showsAlert: false, showsBackButton: true)
                PickerLikeTabs(labels: ["All", "Cases", "Social"], selection: 0)
                alert(icon: "checkmark.circle", title: "Case solved!", subtitle: "TonKotsu Ramen was solved by Table Talkers.")
                alert(icon: "person.2", title: "You were added to a table", subtitle: "Ben added you to Food Detectives.")
                alert(icon: "bubble.left", title: "New Table Talk comment", subtitle: "Sophia commented in Food Detectives.")
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }

    private func alert(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(ForkensicsColor.orange).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(ForkensicsColor.secondaryText)
            }
            Spacer()
            Circle().fill(ForkensicsColor.orange).frame(width: 7, height: 7)
        }
        .forkensicsCard()
    }
}
