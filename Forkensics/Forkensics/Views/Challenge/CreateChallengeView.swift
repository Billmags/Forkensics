import SwiftUI

struct CreateChallengeView: View {
    @EnvironmentObject var dataService: MockDataService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedColor = "orange"
    @State private var dishText = ""
    @State private var aliasText = ""
    @State private var restaurantText = ""
    @State private var cityText = ""
    @State private var storyText = ""
    @State private var durationHours: Double = 2

    private let colorOptions = ["orange", "red", "blue", "green", "purple", "yellow", "pink", "teal"]

    private let durationOptions: [(label: String, hours: Double)] = [
        ("1 hour", 1), ("2 hours", 2), ("4 hours", 4),
        ("8 hours", 8), ("12 hours", 12), ("24 hours", 24), ("48 hours", 48)
    ]

    private var canPost: Bool {
        !dishText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !restaurantText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !cityText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                whatSection
                whereSection
                durationSection
                storySection
            }
            .navigationTitle("New Challenge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { post() }
                        .bold()
                        .disabled(!canPost)
                }
            }
        }
    }

    // MARK: - Sections

    private var photoSection: some View {
        Section("Photo") {
            VStack(spacing: 12) {
                ChallengeImageView(colorName: selectedColor, size: 120)
                    .frame(maxWidth: .infinity)
                Text("Prototype: pick a color. Real photos in a future step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                colorGrid
            }
            .padding(.vertical, 4)
        }
    }

    private var colorGrid: some View {
        let columns = Array(repeating: GridItem(.flexible()), count: 8)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(colorOptions, id: \.self) { color in
                colorSwatch(color)
            }
        }
    }

    private func colorSwatch(_ color: String) -> some View {
        let isSelected = color == selectedColor
        return ChallengeImageView(colorName: color, size: 32)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary, lineWidth: 2)
                }
            }
            .onTapGesture { selectedColor = color }
    }

    private var whatSection: some View {
        Section {
            LabeledContent("Dish") {
                TextField("e.g. Chicken Parmigiana", text: $dishText)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Also known as") {
                TextField("e.g. chicken parm, chicken parmigiana", text: $aliasText)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("What?")
        } footer: {
            Text("Comma-separate accepted alternate names.")
        }
    }

    private var whereSection: some View {
        Section {
            LabeledContent("Restaurant") {
                TextField("e.g. Rao's", text: $restaurantText)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("City") {
                TextField("e.g. New York", text: $cityText)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Where?")
        } footer: {
            Text("Players must match both restaurant and city for the Where? point.")
        }
    }

    private var durationSection: some View {
        Section("Auto-close") {
            Picker("Duration", selection: $durationHours) {
                ForEach(durationOptions, id: \.hours) { opt in
                    Text(opt.label).tag(opt.hours)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var storySection: some View {
        Section("Optional Story (shown after reveal)") {
            TextEditor(text: $storyText)
                .frame(minHeight: 80)
        }
    }

    // MARK: - Actions

    private func post() {
        let aliases = aliasText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        dataService.createChallenge(
            imageColor: selectedColor,
            dish: dishText,
            aliases: aliases,
            restaurant: restaurantText,
            city: cityText,
            story: storyText.isEmpty ? nil : storyText,
            duration: durationHours * 3600
        )
        dismiss()
    }
}

struct CreateChallengeView_Previews: PreviewProvider {
    static var previews: some View {
        CreateChallengeView()
            .environmentObject(MockDataService())
    }
}
