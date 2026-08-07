import SwiftUI

struct PosterControlsView: View {
    @EnvironmentObject var dataService: MockDataService
    let challenge: Challenge

    @State private var dishText = ""
    @State private var aliasText = ""
    @State private var restaurantText = ""
    @State private var cityText = ""
    @State private var hintText = ""
    @State private var showCancelConfirm = false
    @State private var cancelReason = ""
    @State private var showRevealConfirm = false
    @State private var isEditingAnswer = false

    private var secret: ChallengeSecret? { dataService.secret(for: challenge.id) }
    private var canEdit: Bool { secret?.hasFirstGuess == false }
    private var guessCount: Int {
        Set(dataService.guessAttempts(for: challenge.id).map(\.playerId)).count
    }
    private var eligibleCount: Int { dataService.activeEligibles(for: challenge.id).count }
    private var canReveal: Bool { guessCount >= 2 }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Photo placeholder
                ChallengeImageView(colorName: challenge.imageColor, size: 180)
                    .padding(.top, 12)

                // Deadline
                VStack(spacing: 4) {
                    Text("Your Challenge")
                        .font(.headline)
                    Text(challenge.timeRemainingDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Guess counter
                guessCounterCard

                // Answer section
                answerSection

                // Hints
                hintSection

                // Actions
                actionButtons

                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationTitle("Poster Controls")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { prefill() }
        .confirmationDialog("Reveal Challenge?", isPresented: $showRevealConfirm, titleVisibility: .visible) {
            Button("Reveal Now") { dataService.revealChallenge(challenge.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will score all guesses and show the results to everyone.")
        }
        .alert("Cancel Challenge", isPresented: $showCancelConfirm) {
            TextField("Reason (optional)", text: $cancelReason)
            Button("Cancel Challenge", role: .destructive) {
                dataService.cancelChallenge(challenge.id, reason: cancelReason)
            }
            Button("Never Mind", role: .cancel) {}
        } message: {
            Text("No points will be awarded. This cannot be undone.")
        }
    }

    // MARK: - Guess Counter

    private var guessCounterCard: some View {
        HStack(spacing: 20) {
            VStack {
                Text("\(guessCount)").font(.title.bold())
                Text("guessed").font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 40)
            VStack {
                Text("\(eligibleCount - guessCount)").font(.title.bold())
                Text("remaining").font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 40)
            VStack {
                Text("\(eligibleCount)").font(.title.bold())
                Text("eligible").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Answer Section

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Answer")
                    .font(.headline)
                Spacer()
                if canEdit {
                    Button(isEditingAnswer ? "Done" : "Edit") {
                        isEditingAnswer.toggle()
                        if !isEditingAnswer { saveAnswer() }
                    }
                    .font(.subheadline)
                } else {
                    Label("Locked — first guess received", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(spacing: 0) {
                answerRow(icon: "fork.knife", tint: .blue, label: "Dish",
                          text: $dishText, placeholder: "Canonical dish name", editable: canEdit && isEditingAnswer)
                Divider().padding(.leading, 52)
                answerRow(icon: "text.quote", tint: .blue, label: "Also known as",
                          text: $aliasText, placeholder: "Comma-separated aliases", editable: canEdit && isEditingAnswer)
                Divider().padding(.leading, 52)
                answerRow(icon: "building.2", tint: .orange, label: "Restaurant",
                          text: $restaurantText, placeholder: "Restaurant name", editable: canEdit && isEditingAnswer)
                Divider().padding(.leading, 52)
                answerRow(icon: "mappin", tint: .orange, label: "City",
                          text: $cityText, placeholder: "City", editable: canEdit && isEditingAnswer)
            }
            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func answerRow(icon: String, tint: Color, label: String,
                            text: Binding<String>, placeholder: String, editable: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                if editable {
                    TextField(placeholder, text: text)
                        .font(.body)
                        .padding(.bottom, 12)
                } else {
                    Text(text.wrappedValue.isEmpty ? "—" : text.wrappedValue)
                        .font(.body)
                        .foregroundStyle(text.wrappedValue.isEmpty ? .tertiary : .primary)
                        .padding(.bottom, 12)
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func saveAnswer() {
        let aliases = aliasText.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        dataService.updateSecret(for: challenge.id, dish: dishText, aliases: aliases,
                                  restaurant: restaurantText, city: cityText)
    }

    // MARK: - Hint Section

    private var hintSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hints")
                .font(.headline)

            let hints = dataService.hints(for: challenge.id)
            if !hints.isEmpty {
                ForEach(hints) { hint in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hint.text).font(.subheadline)
                            Text(hint.postedAt.formatted(.relative(presentation: .named)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            HStack(spacing: 10) {
                TextField("Add a hint…", text: $hintText)
                    .textFieldStyle(.roundedBorder)
                Button("Post") {
                    dataService.postHint(for: challenge.id, text: hintText)
                    hintText = ""
                }
                .buttonStyle(.bordered)
                .disabled(hintText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                showRevealConfirm = true
            } label: {
                Label("Reveal Now", systemImage: "eye.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canReveal ? Color.green : Color.secondary.opacity(0.2))
                    .foregroundStyle(canReveal ? .white : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .font(.headline)
            }
            .disabled(!canReveal)

            if !canReveal {
                Text("At least 2 players must guess before you can reveal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(role: .destructive) {
                showCancelConfirm = true
            } label: {
                Label("Cancel Challenge", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .font(.headline)
            }
        }
    }

    // MARK: - Prefill

    private func prefill() {
        guard let s = secret else { return }
        dishText = s.canonicalDish
        aliasText = s.dishAliases.joined(separator: ", ")
        restaurantText = s.canonicalRestaurant
        cityText = s.canonicalCity
    }
}
