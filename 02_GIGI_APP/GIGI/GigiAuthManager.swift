import Foundation
import GoogleSignIn
import SwiftUI
import Combine

@MainActor
class GigiAuthManager: ObservableObject {
    static let shared = GigiAuthManager()

    @Published var isSignedIn = false
    @Published var userName = ""
    @Published var userEmail = ""
    @Published var userPhoto: URL?
    @Published var isLoading = false
    @Published var errorMessage = ""

    private let clientID = "828342254195-dnrgigjogy3veckt6ef177baie3vdrek.apps.googleusercontent.com"

    // Scopes necessari per Gemini API
    private let scopes = [
        "https://www.googleapis.com/auth/generative-language.retriever",
        "email",
        "profile"
    ]

    init() {
        GigiDebugLogger.log("GigiAuthManager init started")
        // Configura Google Sign In
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        // Ripristina sessione precedente
        restorePreviousSignIn()
        GigiDebugLogger.log("GigiAuthManager init finished")
    }

    // MARK: - Ripristina sessione
    private func restorePreviousSignIn() {
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
            guard let self else { return }
            if let user {
                Task { @MainActor in
                    self.updateUser(user)
                }
            }
        }
    }

    // MARK: - Sign In
    func signIn() {
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            errorMessage = "Cannot find root view controller."
            return
        }

        isLoading = true
        errorMessage = ""

        GIDSignIn.sharedInstance.signIn(
            withPresenting: rootVC,
            hint: nil,
            additionalScopes: scopes
        ) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.isLoading = false
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                if let user = result?.user {
                    self.updateUser(user)
                }
            }
        }
    }

    // MARK: - Sign Out
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        isSignedIn = false
        userName = ""
        userEmail = ""
        userPhoto = nil
        print("GIGI Auth: Signed out.")
    }

    // MARK: - Aggiorna stato utente
    private func updateUser(_ user: GIDGoogleUser) {
        isSignedIn = true
        userName = user.profile?.name ?? ""
        userEmail = user.profile?.email ?? ""
        userPhoto = user.profile?.imageURL(withDimension: 64)
        print("GIGI Auth: Signed in as \(userEmail)")
    }

    // MARK: - Ottieni access token fresco
    func freshAccessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw GigiAuthError.notSignedIn
        }

        return try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { user, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token = user?.accessToken.tokenString {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: GigiAuthError.noToken)
                }
            }
        }
    }

    // MARK: - Handle URL redirect OAuth
    func handle(_ url: URL) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
}

enum GigiAuthError: LocalizedError {
    case notSignedIn
    case noToken

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to Google."
        case .noToken: return "Could not get access token."
        }
    }
}
