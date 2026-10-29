import AuthenticationServices
import CryptoKit
import DesignSystem
import SwiftUI
import Sync

/// Settings › Account & Sync. Signed out, it's a Netflix-style card: set up
/// a server from an access token (or a link from another device), then a
/// username and password; signed in, a Netflix-style Account page.
struct AccountSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var confirmDisconnect = false
    /// "Enter URL and key instead".
    @State private var manual = false

    var body: some View {
        let account = app.account
        let setupRunning = app.serverSetup.isRunning
        Group {
            if account.isSignedIn {
                AccountScreen(card: false) { AccountOverview() }
            } else {
                AccountScreen {
                    if !account.isConfigured {
                        if setupRunning {
                            AccountSetupProgressView()
                        } else if manual {
                            AccountManualConnectView(manual: $manual)
                        } else {
                            AccountConnectView(manual: $manual)
                        }
                    } else {
                        AccountSignInView()
                        AccountServerRows(confirmDisconnect: $confirmDisconnect).padding(.top, Spacing.l)
                    }
                    TraktRows().padding(.top, Spacing.l)
                }
                // Each step starts at the top, rather than where the last one was scrolled to.
                .id("\(account.isConfigured)-\(setupRunning)-\(manual)")
            }
        }
        .animation(.smooth(duration: 0.3), value: account.isConfigured)
        .animation(.smooth(duration: 0.3), value: account.isSignedIn)
        .animation(.smooth(duration: 0.3), value: setupRunning)
        #if DEBUG
        // Screenshots: `-preview-account manual` opens "Enter URL and key instead".
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-preview-account"), args.indices.contains(i + 1), args[i + 1] == "manual" { manual = true }
        }
        #endif
    }
}

/// Sign in with Apple, exchanged for a Supabase session.
struct AppleSignInButton: View {
    @Environment(AppModel.self) private var app
    @Binding var message: String?
    @State private var nonce = ""

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            nonce = AppleNonce.random()
            request.requestedScopes = [.email]
            request.nonce = AppleNonce.sha256(nonce)
        } onCompletion: { result in
            switch result {
            case .success(let auth):
                guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                      let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                    message = "Apple didn't return a sign-in token."; return
                }
                let raw = nonce
                Task {
                    do { try await app.account.signInWithApple(idToken: token, nonce: raw) }
                    catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                }
            case .failure(let error):
                if (error as? ASAuthorizationError)?.code != .canceled { message = error.localizedDescription }
            }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: AccountTheme.buttonHeight)
        .accessibilityIdentifier("appleSignInButton")
    }
}

enum AppleNonce {
    static func random(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &rng)! })
    }
    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
