import SwiftUI

struct SplashWireframe: View {
    var body: some View {
        VStack {
            Spacer()
            ForkensicsBrandView()
            Spacer()
        }
        .padding(ForkensicsSpacing.screen)
        .forkensicsScreen()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Forkensics launch screen")
    }
}

struct WelcomeWireframe: View {
    let startSample: () -> Void
    let signIn: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                HStack {
                    ForkensicsBrandView(compact: true)
                    Spacer()
                    Button("Sign In", action: signIn)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ForkensicsColor.primaryText)
                        .buttonStyle(ForkensicsPressButtonStyle())
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("EVERY DISH\nHIDES A STORY.")
                        .font(.system(size: 42, weight: .black))
                        .tracking(-1.3)
                        .minimumScaleFactor(0.72)
                    Text("Can you crack the dish—before your friends find the place?")
                        .font(.title3)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                FoodPhotoPlaceholder(
                    height: 330,
                    label: "Chicken Parmigiana with spaghetti and basil",
                    imageName: "ChickenParmigiana"
                )

                ForkensicsPrimaryButton(
                    title: "Crack Your First Case",
                    providesLightHaptic: true,
                    action: startSample
                )
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }
}

struct SampleGuessWireframe: View {
    private enum TypingStage: Equatable {
        case dish
        case restaurant
        case complete
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dish = ""
    @State private var restaurant = ""
    @State private var typingStage: TypingStage = .dish
    @State private var dishFocused = false
    @State private var restaurantFocused = false
    @State private var skipRequested = false
    let lockGuess: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        Text("SAMPLE CASE")
                            .font(.caption.weight(.bold))
                            .tracking(2)
                        Spacer()
                        if typingStage != .complete {
                            Button("Skip Typing", action: skipTyping)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(ForkensicsColor.orange)
                                .buttonStyle(ForkensicsPressButtonStyle())
                        }
                    }
                    .padding(.top, 12)

                    FoodPhotoPlaceholder(
                        height: 250,
                        label: "Chicken Parmigiana with spaghetti and basil",
                        imageName: "ChickenParmigiana"
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        ForkensicsSectionLabel(text: "Step 1 of 2")
                        Text("Crack the dish.")
                            .font(.title2.weight(.bold))
                        ForkensicsTextField(
                            label: "Dish",
                            prompt: "Enter dish name",
                            text: $dish,
                            focus: $dishFocused
                        )
                        .allowsHitTesting(typingStage == .complete)
                    }
                    .id("sample-dish")

                    VStack(alignment: .leading, spacing: 10) {
                        ForkensicsSectionLabel(text: "Step 2 of 2")
                        Text("Nail the place.")
                            .font(.title2.weight(.bold))
                        Text("Omaha, Nebraska")
                            .font(.subheadline)
                            .foregroundStyle(ForkensicsColor.secondaryText)
                        ForkensicsTextField(
                            label: "Restaurant",
                            prompt: "Enter restaurant name",
                            text: $restaurant,
                            focus: $restaurantFocused
                        )
                        .allowsHitTesting(typingStage == .complete)
                    }
                    .id("sample-restaurant")

                    ForkensicsPrimaryButton(
                        title: "Lock In Guess",
                        systemImage: "lock",
                        enabled: typingStage == .complete && !dish.isEmpty && !restaurant.isEmpty,
                        providesLightHaptic: true,
                        action: lockGuess
                    )
                    .id("sample-lock")
                }
                .padding(ForkensicsSpacing.screen)
            }
            .onChange(of: typingStage) { _, newStage in
                let target: String
                switch newStage {
                case .dish: target = "sample-dish"
                case .restaurant: target = "sample-restaurant"
                case .complete: target = "sample-lock"
                }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(target, anchor: newStage == .complete ? .bottom : .center)
                }
            }
        }
        .forkensicsScreen()
        .task {
            await animateSampleGuess()
        }
    }

    @MainActor
    private func animateSampleGuess() async {
        if reduceMotion {
            skipTyping()
            return
        }

        await pause(milliseconds: 700)
        guard !skipRequested else { return }

        dishFocused = true
        await pause(milliseconds: 550)
        guard !skipRequested else { return }

        await type("Chicken Parmigiana", delayMilliseconds: 82) { dish = $0 }
        guard !skipRequested else { return }

        await pause(milliseconds: 900)
        guard !skipRequested else { return }

        typingStage = .restaurant
        dishFocused = false
        restaurantFocused = true
        await pause(milliseconds: 450)
        guard !skipRequested else { return }

        await type("Trattoria Roma", delayMilliseconds: 82) { restaurant = $0 }
        guard !skipRequested else { return }

        await pause(milliseconds: 900)
        guard !skipRequested else { return }

        restaurantFocused = false
        await pause(milliseconds: 550)
        guard !skipRequested else { return }

        typingStage = .complete
    }

    @MainActor
    private func type(
        _ fullValue: String,
        delayMilliseconds: Int,
        update: (String) -> Void
    ) async {
        var value = ""
        for character in fullValue {
            guard !Task.isCancelled, !skipRequested else { return }
            value.append(character)
            update(value)
            await pause(milliseconds: delayMilliseconds)
        }
    }

    @MainActor
    private func pause(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    @MainActor
    private func skipTyping() {
        skipRequested = true
        dish = "Chicken Parmigiana"
        restaurant = "Trattoria Roma"
        dishFocused = false
        restaurantFocused = false
        typingStage = .complete
    }
}

struct SampleRevealWireframe: View {
    let playForReal: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForkensicsRevealCelebration(
                    eyebrow: "Sample case solved",
                    title: "CASE CRACKED!",
                    subtitle: "You cracked the dish and nailed the place.",
                    points: 200
                )
                .padding(.top, 6)

                FoodPhotoPlaceholder(
                    height: 235,
                    label: "Chicken Parmigiana with spaghetti and basil",
                    imageName: "ChickenParmigiana"
                )

                VStack(spacing: 0) {
                    revealRow(icon: "fork.knife", label: "Dish", value: "Chicken Parmigiana")
                    Divider().overlay(ForkensicsColor.line)
                    revealRow(icon: "storefront", label: "Restaurant", value: "Trattoria Roma")
                    Divider().overlay(ForkensicsColor.line)
                    revealRow(icon: "mappin", label: "Location", value: "Omaha, Nebraska")
                }
                .forkensicsCard()

                ForkensicsPrimaryButton(
                    title: "Play for Real",
                    providesLightHaptic: true,
                    action: playForReal
                )
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }

    private func revealRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(ForkensicsColor.orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ForkensicsColor.secondaryText)
                Text(value).font(.body.weight(.semibold))
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}

struct AccountChoiceWireframe: View {
    let continueWithApple: () -> Void
    let continueWithEmail: () -> Void
    let signIn: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ForkensicsBrandView()
                    .padding(.top, 54)

                Text("Ready to play\nfor real?")
                    .font(.system(size: 36, weight: .black))
                    .multilineTextAlignment(.center)

                Text("Join your people.\nPost a case.\nSee who cracks it first.")
                    .font(.title3)
                    .foregroundStyle(ForkensicsColor.secondaryText)
                    .multilineTextAlignment(.center)

                Button(action: continueWithApple) {
                    Label("Continue with Apple", systemImage: "apple.logo")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 54)
                        .foregroundStyle(Color.black)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(ForkensicsPressButtonStyle())

                HStack {
                    Rectangle().fill(ForkensicsColor.line).frame(height: 1)
                    Text("OR").font(.caption).foregroundStyle(ForkensicsColor.secondaryText)
                    Rectangle().fill(ForkensicsColor.line).frame(height: 1)
                }

                ForkensicsSecondaryButton(title: "Continue with Email", action: continueWithEmail)

                Button(action: signIn) {
                    Text("Already have an account? ") + Text("Sign In").foregroundColor(ForkensicsColor.orange)
                }
                .font(.subheadline)
                .foregroundStyle(ForkensicsColor.secondaryText)
                .buttonStyle(ForkensicsPressButtonStyle())

                Text("Your food photos stay yours. Forkensics never generates or alters what you post.")
                    .font(.caption)
                    .foregroundStyle(ForkensicsColor.mutedText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }
}

struct SignInWireframe: View {
    @State private var email = ""
    @State private var password = ""
    let continueWithApple: () -> Void
    let signIn: (String, String) -> Void
    let createAccount: () -> Void
    let forgotPassword: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForkensicsBrandView()
                    .padding(.top, 48)
                VStack(spacing: 8) {
                    Text("Welcome back, Detective.")
                        .font(.system(size: 30, weight: .black))
                        .multilineTextAlignment(.center)
                    Text("Sign in to continue your investigations.")
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }

                Button(action: continueWithApple) {
                    Label("Continue with Apple", systemImage: "apple.logo")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                        .foregroundStyle(Color.black)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(ForkensicsPressButtonStyle())

                ForkensicsTextField(label: "Email address", prompt: "detective@example.com", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                ForkensicsTextField(label: "Password", prompt: "Password", text: $password, secure: true)

                Button("Forgot password?", action: forgotPassword)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ForkensicsColor.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .buttonStyle(ForkensicsPressButtonStyle())

                ForkensicsPrimaryButton(title: "Sign In") { signIn(email, password) }

                Button(action: createAccount) {
                    Text("New detective? ") + Text("Create an account").foregroundColor(ForkensicsColor.orange)
                }
                .font(.subheadline)
                .foregroundStyle(ForkensicsColor.secondaryText)
                .buttonStyle(ForkensicsPressButtonStyle())
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }
}

struct CreateAccountWireframe: View {
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    let complete: (String, String) -> Void
    let signIn: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForkensicsBrandView()
                    .padding(.top, 36)
                Text("Create your account")
                    .font(.system(size: 31, weight: .black))
                Text("Start your investigations.")
                    .foregroundStyle(ForkensicsColor.secondaryText)
                ForkensicsTextField(label: "Full name", prompt: "Maggie Schroeder", text: $name)
                ForkensicsTextField(label: "Email address", prompt: "detective@example.com", text: $email)
                ForkensicsTextField(label: "Password", prompt: "At least 8 characters", text: $password, secure: true)
                ForkensicsPrimaryButton(title: "Create Account") { complete(email, password) }
                Button("Already a detective? Sign In", action: signIn)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ForkensicsColor.orange)
                    .buttonStyle(ForkensicsPressButtonStyle())
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }
}

struct ForgotPasswordWireframe: View {
    @State private var email = ""
    let send: (String) -> Void
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ForkensicsBrandView()
            Text("Forgot password?")
                .font(.system(size: 32, weight: .black))
            Text("Enter your email and we’ll send a link to reset your password.")
                .foregroundStyle(ForkensicsColor.secondaryText)
                .multilineTextAlignment(.center)
            ForkensicsTextField(label: "Email address", prompt: "detective@example.com", text: $email)
            ForkensicsPrimaryButton(title: "Send Reset Link") { send(email) }
            Button("Remember your password? Sign In", action: signIn)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ForkensicsColor.orange)
                .buttonStyle(ForkensicsPressButtonStyle())
            Spacer()
        }
        .padding(ForkensicsSpacing.screen)
        .forkensicsScreen()
    }
}

struct ChooseAliasWireframe: View {
    @State private var alias = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    let save: (String) async throws -> Void

    private var isValid: Bool {
        let t = alias.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.count <= 20 &&
            t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ForkensicsBrandView()
                    .padding(.top, 54)

                VStack(spacing: 10) {
                    Text("Choose your\ndetective alias.")
                        .font(.system(size: 32, weight: .black))
                        .multilineTextAlignment(.center)
                    Text("This is how other detectives will know you.")
                        .foregroundStyle(ForkensicsColor.secondaryText)
                        .multilineTextAlignment(.center)
                }

                ForkensicsTextField(
                    label: "Alias",
                    prompt: "e.g. SherlockFork",
                    text: $alias
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Text("3–20 characters. Letters, numbers, and underscores only.")
                    .font(.caption)
                    .foregroundStyle(ForkensicsColor.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForkensicsPrimaryButton(
                    title: isLoading ? "Saving…" : "Start Investigating",
                    enabled: isValid && !isLoading,
                    providesLightHaptic: true
                ) {
                    Task {
                        isLoading = true
                        errorMessage = nil
                        do {
                            try await save(alias.trimmingCharacters(in: .whitespaces))
                        } catch {
                            errorMessage = error.localizedDescription
                            isLoading = false
                        }
                    }
                }
            }
            .padding(ForkensicsSpacing.screen)
        }
        .forkensicsScreen()
    }
}

struct CheckEmailWireframe: View {
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ForkensicsBrandView()
            Image(systemName: "envelope.open")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(ForkensicsColor.orange)
            Text("Check your email")
                .font(.system(size: 32, weight: .black))
            Text("We sent a password reset link to detective@email.com.")
                .foregroundStyle(ForkensicsColor.secondaryText)
                .multilineTextAlignment(.center)
            ForkensicsPrimaryButton(title: "Back to Sign In", action: signIn)
            Spacer()
        }
        .padding(ForkensicsSpacing.screen)
        .forkensicsScreen()
    }
}
