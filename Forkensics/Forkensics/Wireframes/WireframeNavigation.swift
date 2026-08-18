import SwiftUI

struct ForkensicsRootWireframe: View {
    @EnvironmentObject private var authService: AuthService
    @State private var phase: LaunchPhase

    init(initialPhase: LaunchPhase = .splash) {
        _phase = State(initialValue: initialPhase)
    }

    var body: some View {
        Group {
            switch phase {
            case .splash:
                SplashWireframe()
                    .task {
                        try? await Task.sleep(for: .milliseconds(850))
                        guard !Task.isCancelled else { return }
                        if authService.isSignedIn {
                            let alias = await authService.fetchAlias()
                            withAnimation(.easeInOut(duration: 0.28)) {
                                phase = alias == nil ? .chooseAlias : .signedIn
                            }
                        } else {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                phase = .welcome
                            }
                        }
                    }
            case .welcome:
                WelcomeWireframe(
                    startSample: { phase = .sampleGuess },
                    signIn: { phase = .signIn }
                )
            case .sampleGuess:
                SampleGuessWireframe(lockGuess: { phase = .sampleReveal })
            case .sampleReveal:
                SampleRevealWireframe(playForReal: { phase = .accountChoice })
            case .accountChoice:
                AccountChoiceWireframe(
                    continueWithApple: {
                        Task { try? await authService.signInWithApple() }
                    },
                    continueWithEmail: { phase = .createAccount },
                    signIn: { phase = .signIn }
                )
            case .signIn:
                SignInWireframe(
                    continueWithApple: {
                        Task { try? await authService.signInWithApple() }
                    },
                    signIn: { email, password in
                        Task { try? await authService.signIn(email: email, password: password) }
                    },
                    createAccount: { phase = .createAccount },
                    forgotPassword: { phase = .forgotPassword }
                )
            case .createAccount:
                CreateAccountWireframe(
                    complete: { email, password in
                        Task { try? await authService.signUp(email: email, password: password) }
                    },
                    signIn: { phase = .signIn }
                )
            case .forgotPassword:
                ForgotPasswordWireframe(
                    send: { email in
                        Task {
                            try? await authService.resetPassword(email: email)
                            phase = .checkEmail
                        }
                    },
                    signIn: { phase = .signIn }
                )
            case .checkEmail:
                CheckEmailWireframe(signIn: { phase = .signIn })
            case .chooseAlias:
                ChooseAliasWireframe { alias in
                    try await authService.saveAlias(alias)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        phase = .signedIn
                    }
                }
            case .signedIn:
                ForkensicsMainShell()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
        // Drive phase from real Supabase session state.
        .onChange(of: authService.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                Task {
                    let alias = await authService.fetchAlias()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        phase = alias == nil ? .chooseAlias : .signedIn
                    }
                }
            } else if phase == .signedIn || phase == .chooseAlias {
                withAnimation(.easeInOut(duration: 0.2)) {
                    phase = .welcome
                }
            }
        }
    }
}

struct ForkensicsMainShell: View {
    @State private var selection: ForkensicsTab = .cases
    @State private var path: [WireframeRoute] = []
    @StateObject private var challengeStore = WireframeChallengeStore()
    @StateObject private var tableStore = WireframeTableStore()

    var body: some View {
        NavigationStack(path: $path) {
            tabContent
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ForkensicsTabBar(selection: tabSelection)
                }
                .navigationDestination(for: WireframeRoute.self) { route in
                    destination(for: route)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            ForkensicsTabBar(selection: tabSelection)
                        }
                        .navigationBarBackButtonHidden(true)
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
        .toolbar(.hidden, for: .navigationBar)
        .tint(ForkensicsColor.orange)
        .onReceive(NotificationCenter.default.publisher(for: .forkensicsOpenCase)) { notification in
            guard let caseID = notification.userInfo?[ForkensicsNotificationKeys.caseID] as? String else {
                return
            }
            openCaseFromNotification(caseID)
        }
        .task {
            if let caseID = UserDefaults.standard.string(forKey: ForkensicsNotificationKeys.pendingCaseID) {
                openCaseFromNotification(caseID)
            }
        }
    }

    private var tabSelection: Binding<ForkensicsTab> {
        Binding(
            get: { selection },
            set: { newSelection in
                selection = newSelection
                path.removeAll()
            }
        )
    }

    @ViewBuilder private var tabContent: some View {
        switch selection {
        case .cases:
            CasesHomeWireframe(
                postedCases: challengeStore.postedCases.filter(challengeStore.postedByCurrentPlayer),
                incomingCases: challengeStore.postedCases.filter(challengeStore.isAvailableToCurrentPlayer),
                lockedCaseIDs: Set(
                    challengeStore.postedCases.compactMap {
                        challengeStore.guess(for: $0.id) == nil ? nil : $0.id
                    }
                ),
                revealedCaseIDs: Set(
                    challengeStore.postedCases.filter { challengeStore.isRevealed($0) }.map(\.id)
                ),
                openCase: { path.append(.activeCase) },
                openPostedCase: { path.append(.postedCase($0.id)) },
                openIncomingCase: { item in
                    if challengeStore.isRevealed(item) {
                        path.append(.postedCaseRevealed(item.id))
                    } else if challengeStore.guess(for: item.id) != nil {
                        path.append(.postedCaseLockedIn(item.id))
                    } else {
                        path.append(.investigatePostedCase(item.id))
                    }
                },
                openAlerts: { path.append(.alerts) }
            )
        case .tableTalk:
            LocalTableTalkHomeWireframe(
                currentPlayer: challengeStore.currentPlayer,
                conversations: tableTalkConversations,
                openConversation: { conversation in
                    path.append(.postedCaseTableTalk(conversation.item.id, conversation.tableName))
                }
            )
        case .post:
            PostCaseWireframe(
                viewCases: { selection = .cases },
                sendCase: { postedCase in
                    challengeStore.add(postedCase)
                    Task {
                        await ForkensicsNotificationService.shared.scheduleNewCase(
                            postedCase,
                            posterName: challengeStore.currentPlayer.name
                        )
                    }
                },
                currentPlayer: challengeStore.currentPlayer,
                tables: tableStore.tables(for: challengeStore.currentPlayerID),
                createTable: { name, avatarStyle, detectivePlayerIDs in
                    tableStore.create(
                        name: name,
                        avatarStyle: avatarStyle,
                        ownerPlayerID: challengeStore.currentPlayerID,
                        detectivePlayerIDs: detectivePlayerIDs
                    )
                },
                openCreatedTable: { tableID in
                    selection = .profile
                    path = [.myTables, .tableDetail(tableID)]
                }
            )
        case .leaderboard:
            LeaderboardWireframe(
                currentPlayer: challengeStore.currentPlayer,
                tableNames: WireframePlayerDirectory.tables(for: challengeStore.currentPlayerID),
                entries: { tableName, period in
                    challengeStore.leaderboard(for: tableName, period: period)
                },
                history: { playerID, tableName, period in
                    challengeStore.leaderboardHistory(
                        for: playerID,
                        tableName: tableName,
                        period: period
                    )
                }
            )
        case .profile:
            ProfileWireframe(
                currentPlayer: challengeStore.currentPlayer,
                switchPlayer: { playerID in
                    challengeStore.switchPlayer(to: playerID)
                    path.removeAll()
                },
                openTables: { path.append(.myTables) }
            )
        }
    }

    @ViewBuilder private func destination(for route: WireframeRoute) -> some View {
        switch route {
        case .activeCase:
            ActiveCaseWireframe(makeGuess: { path.append(.makeGuessWithClue) })
        case .postedCase(let id):
            if let postedCase = challengeStore.postedCases.first(where: { $0.id == id }) {
                PostedCaseDetailWireframe(
                    item: postedCase,
                    guessCount: challengeStore.guesses(for: postedCase.id).count,
                    isRevealed: challengeStore.isRevealed(postedCase),
                    openTable: { tableName in
                        path.append(.postedCaseTable(postedCase.id, tableName))
                    },
                    forceReveal: {
                        challengeStore.forceReveal(postedCase)
                    },
                    close: { path = [] }
                )
            } else {
                MissingPostedCaseWireframe(close: { path = [] })
            }
        case .postedCaseTable(let id, let tableName):
            if let postedCase = challengeStore.postedCases.first(where: { $0.id == id }) {
                let tableGuesses = challengeStore.guesses(for: id, tableName: tableName)
                PostedCaseTableStatusWireframe(
                    item: postedCase,
                    tableName: tableName,
                    guesses: tableGuesses,
                    isRevealed: challengeStore.isRevealed(postedCase),
                    scoreForPlayer: { playerID in
                        challengeStore.score(for: postedCase, playerID: playerID)
                    },
                    openTableTalk: {
                        path.append(.postedCaseTableTalk(postedCase.id, tableName))
                    }
                )
            } else {
                MissingPostedCaseWireframe(close: { path = [] })
            }
        case .investigatePostedCase(let id):
            if let item = challengeStore.postedCases.first(where: { $0.id == id }) {
                ActivePostedCaseWireframe(
                    item: item,
                    poster: WireframePlayerDirectory.player(id: item.posterPlayerID),
                    tableName: challengeStore.commonTableName(for: item),
                    makeGuess: { path.append(.makePostedGuess(id)) }
                )
            } else {
                MissingPostedCaseWireframe(close: { path = [] })
            }
        case .makePostedGuess(let id):
            if let item = challengeStore.postedCases.first(where: { $0.id == id }) {
                PostedCaseGuessWireframe(
                    item: item,
                    poster: WireframePlayerDirectory.player(id: item.posterPlayerID),
                    tableName: challengeStore.commonTableName(for: item),
                    clueRevealed: challengeStore.hasUsedClue(for: id),
                    openClue: { path.append(.postedClueConfirmation(id)) },
                    lockIn: { dish, restaurant in
                        challengeStore.lockGuess(for: id, dish: dish, restaurant: restaurant)
                        path = [.postedCaseLockedIn(id)]
                    }
                )
            } else {
                MissingPostedCaseWireframe(close: { path = [] })
            }
        case .postedClueConfirmation(let id):
            ClueConfirmationWireframe(
                reveal: {
                    challengeStore.useClue(for: id)
                    _ = path.popLast()
                },
                cancel: { _ = path.popLast() }
            )
        case .postedCaseLockedIn(let id):
            if let item = challengeStore.postedCases.first(where: { $0.id == id }) {
                let tableName = challengeStore.commonTableName(for: item)
                let guessedIDs = Set(challengeStore.guesses(for: id, tableName: tableName).map(\.playerID))
                PostedCaseLockedInWireframe(
                    item: item,
                    tableName: tableName,
                    detectives: tableDetectives(tableName, guessedPlayerIDs: guessedIDs),
                    isRevealed: challengeStore.isRevealed(item),
                    openTableTalk: { path.append(.postedCaseTableTalk(id, tableName)) },
                    viewResults: { path = [.postedCaseRevealed(id)] },
                    viewCases: { path.removeAll() }
                )
            } else {
                MissingPostedCaseWireframe(close: { path = [] })
            }
        case .postedCaseTableTalk(let id, let tableName):
            if let item = challengeStore.postedCases.first(where: { $0.id == id }) {
                let guessedIDs = Set(challengeStore.guesses(for: id, tableName: tableName).map(\.playerID))
                PostedCaseTableTalkWireframe(
                    item: item,
                    tableName: tableName,
                    currentPlayer: challengeStore.currentPlayer,
                    detectives: tableDetectives(tableName, guessedPlayerIDs: guessedIDs),
                    messages: challengeStore.messages(for: id, tableName: tableName),
                    revealed: challengeStore.isRevealed(item),
                    send: { text in
                        challengeStore.sendMessage(for: id, tableName: tableName, text: text)
                    }
                )
            } else {
                MissingPostedCaseWireframe(close: { path = [] })
            }
        case .postedCaseRevealed(let id):
            if let item = challengeStore.postedCases.first(where: { $0.id == id }) {
                PostedCaseRevealWireframe(
                    item: item,
                    guess: challengeStore.guess(for: id),
                    score: challengeStore.score(for: item),
                    viewCases: { path.removeAll() }
                )
            } else {
                MissingPostedCaseWireframe(close: { path = [] })
            }
        case .makeGuessNoClue:
            MakeGuessWireframe(clueState: .unavailable, openClue: {}, lockIn: showLockedIn)
        case .makeGuessWithClue:
            MakeGuessWireframe(
                clueState: .available,
                openClue: { path.append(.clueConfirmation) },
                lockIn: showLockedIn
            )
        case .clueConfirmation:
            ClueConfirmationWireframe(
                reveal: { path.append(.makeGuessClueRevealed) },
                cancel: { _ = path.popLast() }
            )
        case .makeGuessClueRevealed:
            MakeGuessWireframe(clueState: .revealed, openClue: {}, lockIn: showLockedIn)
        case .lockedIn:
            LockedInWireframe(
                openTableTalk: { path.append(.activeTableTalk) },
                viewCases: { path.removeAll() }
            )
        case .activeTableTalk:
            CaseTableTalkWireframe(revealed: false)
        case .revealedTableTalk:
            CaseTableTalkWireframe(revealed: true)
        case .caseRevealed:
            CaseRevealedWireframe(
                scoreBreakdown: { path.append(.scoreBreakdown) },
                nextCase: { path.removeAll() }
            )
        case .scoreBreakdown:
            ScoreBreakdownWireframe()
        case .alerts:
            AlertsWireframe()
        case .myTables:
            MyTablesWireframe(
                currentPlayer: challengeStore.currentPlayer,
                tables: tableStore.tables(for: challengeStore.currentPlayerID),
                openTable: { path.append(.tableDetail($0)) },
                createTable: { name, avatarStyle, detectivePlayerIDs in
                    tableStore.create(
                        name: name,
                        avatarStyle: avatarStyle,
                        ownerPlayerID: challengeStore.currentPlayerID,
                        detectivePlayerIDs: detectivePlayerIDs
                    )
                },
                openCreatedTable: { path.append(.tableDetail($0)) }
            )
        case .tableDetail(let id):
            if let table = tableStore.table(id: id) {
                TableDetailManagementWireframe(
                    table: table,
                    currentPlayer: challengeStore.currentPlayer,
                    close: { _ = path.popLast() },
                    updateTable: { name, detail, avatarStyle in
                        tableStore.update(
                            id: id,
                            name: name,
                            detail: detail,
                            avatarStyle: avatarStyle
                        )
                    },
                    removeDetective: { playerID in
                        tableStore.removeDetective(playerID, from: id)
                    },
                    deleteTable: {
                        tableStore.delete(id)
                        _ = path.popLast()
                    },
                    leaveTable: {
                        tableStore.leave(id, playerID: challengeStore.currentPlayerID)
                        _ = path.popLast()
                    }
                )
            } else {
                MissingTableWireframe(close: { _ = path.popLast() })
            }
        }
    }

    private func showLockedIn() {
        path = [.lockedIn]
    }

    private func openCaseFromNotification(_ caseID: String) {
        guard let id = UUID(uuidString: caseID),
              let item = challengeStore.postedCases.first(where: { $0.id == id }) else {
            return
        }

        UserDefaults.standard.removeObject(forKey: ForkensicsNotificationKeys.pendingCaseID)
        selection = .cases

        if challengeStore.postedByCurrentPlayer(item) {
            path = [.postedCase(id)]
        } else if challengeStore.isRevealed(item) {
            path = [.postedCaseRevealed(id)]
        } else if challengeStore.guess(for: id) != nil {
            path = [.postedCaseLockedIn(id)]
        } else if challengeStore.isAvailableToCurrentPlayer(item) {
            path = [.investigatePostedCase(id)]
        } else {
            path.removeAll()
        }
    }

    private func tableDetectives(
        _ tableName: String,
        guessedPlayerIDs: Set<String>
    ) -> [WireframeDetective] {
        WireframePlayerDirectory.players(in: tableName).map { player in
            WireframeDetective(
                player.id == challengeStore.currentPlayerID ? "You" : player.name,
                initials: player.initials,
                isLocked: guessedPlayerIDs.contains(player.id)
            )
        }
    }

    private var tableTalkConversations: [WireframeConversationSummary] {
        challengeStore.postedCases.flatMap { item -> [WireframeConversationSummary] in
            let revealed = challengeStore.isRevealed(item)
            let tableNames: [String]

            if item.posterPlayerID == challengeStore.currentPlayerID {
                tableNames = revealed ? item.tableNames : []
            } else if challengeStore.isAvailableToCurrentPlayer(item),
                      challengeStore.guess(for: item.id) != nil {
                tableNames = [challengeStore.commonTableName(for: item)]
            } else {
                tableNames = []
            }

            return tableNames.map { tableName in
                let messages = challengeStore.messages(for: item.id, tableName: tableName)
                return WireframeConversationSummary(
                    item: item,
                    tableName: tableName,
                    revealed: revealed,
                    lockedCount: challengeStore.guesses(for: item.id, tableName: tableName).count,
                    messagePreview: messages.last?.text ?? "No messages yet—start the investigation."
                )
            }
        }
    }
}
