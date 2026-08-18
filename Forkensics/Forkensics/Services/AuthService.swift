import Foundation
import Supabase
import AuthenticationServices
import CryptoKit

// MARK: - AuthService

@MainActor
final class AuthService: NSObject, ObservableObject {

    // MARK: Published state

    @Published private(set) var session: Session?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    var isSignedIn: Bool { session != nil }

    // MARK: Private

    let client: SupabaseClient
    private var currentNonce: String?
    private var appleSignInContinuation: CheckedContinuation<Void, Error>?

    // MARK: Init

    override init() {
        client = SupabaseClient(
            supabaseURL: URL(string: SupabaseConfig.url)!,
            supabaseKey: SupabaseConfig.anonKey
        )
        super.init()

        // Observe session changes emitted by the Supabase auth client.
        Task { [weak self] in
            guard let self else { return }
            for await (_, session) in await client.auth.authStateChanges {
                self.session = session
            }
        }
    }

    // MARK: - Sign In with Apple

    func signInWithApple() async throws {
        let nonce = randomNonceString()
        currentNonce = nonce

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.appleSignInContinuation = continuation

            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - Email / password auth

    func signIn(email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await client.auth.signIn(email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func signUp(email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await client.auth.signUp(email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func resetPassword(email: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await client.auth.resetPasswordForEmail(email)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func signOut() async {
        try? await client.auth.signOut()
        session = nil
    }

    // MARK: - Profile

    private struct DisplayNameRow: Decodable {
        let display_name: String?
    }

    /// Returns the current user's display name, or nil if not yet set.
    func fetchAlias() async -> String? {
        guard let session else { return nil }
        do {
            let row: DisplayNameRow = try await client
                .from("profiles")
                .select("display_name")
                .eq("id", value: session.user.id.uuidString)
                .single()
                .execute()
                .value
            return row.display_name.flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            return nil
        }
    }

    /// Updates the current user's display name.
    /// The profile row is auto-created by the handle_new_user trigger on signup.
    func saveAlias(_ alias: String) async throws {
        guard let session else { return }
        try await client
            .from("profiles")
            .update(["display_name": alias])
            .eq("id", value: session.user.id.uuidString)
            .execute()
    }

    // MARK: - Nonce helpers (Apple Sign In)

    private func randomNonceString(length: Int = 32) -> String {
        let charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._"
        var result = ""
        var remaining = length
        while remaining > 0 {
            let randoms: [UInt8] = (0 ..< 16).map { _ in
                var byte: UInt8 = 0
                let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
                if status != errSecSuccess {
                    fatalError("SecRandomCopyBytes failed: \(status)")
                }
                return byte
            }
            for byte in randoms {
                guard remaining > 0 else { break }
                if byte < charset.count {
                    result.append(charset[charset.index(charset.startIndex, offsetBy: Int(byte))])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AuthService: ASAuthorizationControllerDelegate {

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            Task { @MainActor in
                self.appleSignInContinuation?.resume(throwing: AuthServiceError.invalidAppleToken)
                self.appleSignInContinuation = nil
            }
            return
        }

        Task { @MainActor in
            let nonce = self.currentNonce
            do {
                try await client.auth.signInWithIdToken(
                    credentials: OpenIDConnectCredentials(
                        provider: .apple,
                        idToken: idToken,
                        nonce: nonce
                    )
                )
                self.appleSignInContinuation?.resume()
            } catch {
                self.appleSignInContinuation?.resume(throwing: error)
            }
            self.appleSignInContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            self.appleSignInContinuation?.resume(throwing: error)
            self.appleSignInContinuation = nil
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AuthService: ASAuthorizationControllerPresentationContextProviding {

    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
                ?? ASPresentationAnchor()
        }
    }
}

// MARK: - Errors

enum AuthServiceError: LocalizedError {
    case invalidAppleToken

    var errorDescription: String? {
        switch self {
        case .invalidAppleToken:
            return "Apple Sign In returned an invalid credential. Please try again."
        }
    }
}
