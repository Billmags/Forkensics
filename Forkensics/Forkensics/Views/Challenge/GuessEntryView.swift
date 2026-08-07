import SwiftUI

struct GuessEntryView: View {
    @EnvironmentObject var dataService: MockDataService
    let challenge: Challenge

    @State private var whatText = ""
    @State private var whereRestaurant = ""
    @State private var whereCity = ""
    @State private var submitted = false
    @FocusState private var focusedField: Field?

    enum Field { case what, restaurant, city }

    private var isEditing: Bool {
        dataService.currentPlayerLatestGuess(for: challenge.id) != nil
    }

    private var canSubmit: Bool {
        !whatText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !whereRestaurant.trimmingCharacters(in: .whitespaces).isEmpty &&
        !whereCity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var posterName: String {
        dataService.player(for: challenge.posterId)?.displayName ?? "the poster"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Photo
                ChallengeImageView(colorName: challenge.imageColor, size: 180)
                    .padding(.top, 12)

                VStack(spacing: 4) {
                    Text("\(posterName) posted a challenge!")
                        .font(.headline)
                    Text(challenge.timeRemainingDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Hints
                hintSection

                // Guess form
                VStack(spacing: 0) {
                    guessSection(
                        title: "What?",
                        subtitle: "Name the dish",
                        icon: "fork.knife",
                        tint: .blue,
                        field: $whatText,
                        focusTag: .what,
                        placeholder: "e.g. Chicken Parmigiana"
                    )
                    Divider().padding(.leading, 56)
                    guessSection(
                        title: "Where? — Restaurant",
                        subtitle: "Name of the restaurant",
                        icon: "building.2",
                        tint: .orange,
                        field: $whereRestaurant,
                        focusTag: .restaurant,
                        placeholder: "e.g. Rao's"
                    )
                    Divider().padding(.leading, 56)
                    guessSection(
                        title: "Where? — City",
                        subtitle: "City only",
                        icon: "mappin",
                        tint: .orange,
                        field: $whereCity,
                        focusTag: .city,
                        placeholder: "e.g. New York"
                    )
                }
                .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))

                // Note about both required
                Text("Both restaurant name and city are required for the Where? point.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button(action: submitGuess) {
                    Label(isEditing ? "Update Guess" : "Submit Guess", systemImage: isEditing ? "arrow.triangle.2.circlepath" : "paperplane.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canSubmit ? Color.accentColor : Color.secondary.opacity(0.2))
                        .foregroundStyle(canSubmit ? .white : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .font(.headline)
                }
                .disabled(!canSubmit)

                if isEditing {
                    Text("Editing replaces your previous guess. Your new server receipt time is used for ranking.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationTitle("Your Guess")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { prefillIfEditing() }
    }

    private func guessSection(title: String, subtitle: String, icon: String, tint: Color,
                               field: Binding<String>, focusTag: Field, placeholder: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 30)
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                TextField(placeholder, text: field)
                    .font(.body)
                    .focused($focusedField, equals: focusTag)
                    .submitLabel(focusTag == .city ? .done : .next)
                    .onSubmit {
                        switch focusTag {
                        case .what:       focusedField = .restaurant
                        case .restaurant: focusedField = .city
                        case .city:       focusedField = nil
                        }
                    }
                    .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 14)
    }

    private var hintSection: some View {
        let hints = dataService.hints(for: challenge.id)
        return Group {
            if !hints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hints from \(posterName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
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
                        .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private func prefillIfEditing() {
        if let prev = dataService.currentPlayerLatestGuess(for: challenge.id) {
            whatText = prev.whatText
            whereRestaurant = prev.whereRestaurant
            whereCity = prev.whereCity
        }
    }

    private func submitGuess() {
        guard canSubmit else { return }
        focusedField = nil
        dataService.submitGuess(for: challenge.id, what: whatText,
                                 restaurant: whereRestaurant, city: whereCity)
        submitted = true
    }
}
