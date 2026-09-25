import GoogleSignIn
import UIKit
import os

/// Google Sign-In limited to the `drive.file` scope. Tokens are stored by the
/// Google Sign-In SDK in the Keychain; this app never persists them itself.
@MainActor
final class GoogleAuth: ObservableObject {
    static let driveScope = "https://www.googleapis.com/auth/drive.file"

    enum AuthError: LocalizedError {
        case notSignedIn, noWindow, scopeDenied
        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Not signed in to Google."
            case .noWindow: return "Couldn't find a window to present sign-in."
            case .scopeDenied: return "Drive access wasn't granted. Sign in again and allow access to files Coach Bridge creates."
            }
        }
    }

    @Published private(set) var email: String?
    @Published private(set) var hasDriveScope = false
    @Published var lastError: String?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "google")

    var isSignedIn: Bool { email != nil }

    func restore() async {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            update(user)
            log.info("Restored previous Google sign-in")
        } catch {
            update(nil)
            log.error("Restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func signIn() async {
        lastError = nil
        guard let presenter = Self.topViewController() else { lastError = AuthError.noWindow.localizedDescription; return }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter, hint: nil, additionalScopes: [Self.driveScope])
            var user = result.user
            if !(user.grantedScopes ?? []).contains(Self.driveScope) {
                user = try await user.addScopes([Self.driveScope], presenting: presenter).user
            }
            update(user)
            log.info("Signed in; drive.file granted: \(self.hasDriveScope, privacy: .public)")
        } catch let error as GIDSignInError where error.code == .canceled {
            log.info("Sign-in cancelled")
        } catch {
            lastError = error.localizedDescription
            log.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Signs out and revokes the grant, so the app loses Drive access entirely.
    func signOut() async {
        do { try await GIDSignIn.sharedInstance.disconnect() } catch { GIDSignIn.sharedInstance.signOut() }
        update(nil)
        log.info("Signed out and disconnected")
    }

    /// A valid access token, refreshed if it's about to expire.
    func accessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw AuthError.notSignedIn }
        guard (user.grantedScopes ?? []).contains(Self.driveScope) else { throw AuthError.scopeDenied }
        let fresh = try await user.refreshTokensIfNeeded()
        return fresh.accessToken.tokenString
    }

    private func update(_ user: GIDGoogleUser?) {
        email = user?.profile?.email
        hasDriveScope = (user?.grantedScopes ?? []).contains(Self.driveScope)
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
