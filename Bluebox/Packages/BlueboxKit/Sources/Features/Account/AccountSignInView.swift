import DesignSystem
import SwiftUI
import Sync

/// Connected but signed out: sign in with a username and password, or
/// create the account (first device, right after setup). No email anywhere.
/// Card content for `AccountScreen`.
struct AccountSignInView: View {
    @Environment(AppModel.self) private var app
    /// Nil follows setup: a new server opens on Create, everything else on Sign In.
    @State private var creatingChoice: Bool?
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var reveal = false
    @State private var working = false
    @State private var usernameError: String?
    @State private var passwordError: String?
    @State private var confirmError: String?
    @State private var message: String?
    @State private var passwordFocused = false
    @State private var confirmFocused = false

    private var creating: Bool { creatingChoice ?? app.serverSetup.needsFirstAccount }

    var body: some View {
        let account = app.account
        if creating {
            AccountTitle(title: "Create Your Account",
                         subtitle: Text("You'll sign in with this on your other devices. No email needed."))
        } else {
            AccountTitle(title: "Sign In",
                         subtitle: Text("Use the username and password you made when you set up sync."))
        }

        VStack(alignment: .leading, spacing: Spacing.l) {
            FloatingField("Username", text: $username, error: usernameError, contentType: .username, submitLabel: .next) {
                passwordFocused = true
            }
            .accessibilityIdentifier("usernameField")

            FloatingField(label: "Password", text: $password, secure: !reveal, error: passwordError, contentType: .password,
                          submitLabel: creating ? .next : .go,
                          onSubmit: { if creating { confirmFocused = true } else { submit() } },
                          isFocused: $passwordFocused) {
                RevealButton(revealed: $reveal)
                FieldPasteButton { password = $0 }
            }
            .accessibilityIdentifier("passwordField")

            if creating {
                FloatingField(label: "Confirm password", text: $confirm, secure: !reveal, error: confirmError,
                              contentType: .password, submitLabel: .go, onSubmit: submit, isFocused: $confirmFocused) {
                    FieldPasteButton { confirm = $0 }
                }
                .accessibilityIdentifier("confirmPasswordField")
            }

            AccountPrimaryButton(title: creating ? "Create Account" : "Sign In",
                                 workingTitle: creating ? "Creating account…" : "Signing in…",
                                 working: working,
                                 disabled: username.isEmpty || password.isEmpty || (creating && confirm.isEmpty),
                                 action: submit)
                .padding(.top, Spacing.xs)
                .accessibilityIdentifier(creating ? "createAccountButton" : "signInButton")

            if let message {
                AccountErrorText(text: message).accessibilityIdentifier("signInError")
            } else if case .failed(let reason) = account.status {
                AccountErrorText(text: reason)
            }
            linkEvent

            HStack(spacing: 4) {
                Text(creating ? "Already have an account?" : "New here?")
                    .foregroundStyle(Palette.textSecondary)
                AccountTextButton(creating ? "Sign in" : "Create an account") {
                    withAnimation(.smooth(duration: 0.25)) { creatingChoice = !creating }
                    clearErrors()
                }
                .accessibilityIdentifier(creating ? "showSignInButton" : "showCreateAccountButton")
            }
            .font(.subheadline)

            if creating {
                Text("Usernames are 3 to 32 letters, numbers, dots, dashes or underscores. Passwords need at least \(BlueboxUsername.passwordLengths.lowerBound) characters. Bluebox can't reset a forgotten password, so keep it somewhere safe.")
                    .font(.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if account.appleSignInAvailable {
                HStack(spacing: Spacing.m) {
                    Hairline(); Text("or").font(.footnote).foregroundStyle(Palette.textTertiary); Hairline()
                }
                AppleSignInButton(message: $message)
            }
        }
        .onChange(of: username) { usernameError = nil; message = nil }
        .onChange(of: password) { passwordError = nil; confirmError = nil; message = nil }
        .onChange(of: confirm) { confirmError = nil; message = nil }
    }

    @ViewBuilder private var linkEvent: some View {
        switch app.account.linkEvent {
        case .working: AccountWorkingText(text: "Signing in from the link…")
        case .failed(let why): AccountErrorText(text: why).accessibilityIdentifier("signInLinkError")
        default: EmptyView()
        }
    }

    private func clearErrors() {
        usernameError = nil; passwordError = nil; confirmError = nil; message = nil
    }

    /// Checks the fields here first, so a typo gets a precise message without a round trip.
    private func submit() {
        guard !working else { return }
        clearErrors()
        if case .failure(let problem) = BlueboxUsername.check(username) {
            usernameError = problem.errorDescription
            return
        }
        if creating {
            if let why = BlueboxUsername.checkPassword(password) { passwordError = why; return }
            if confirm != password { confirmError = "The passwords don't match."; return }
        } else if password.isEmpty {
            passwordError = "Enter your password."
            return
        }
        working = true
        let create = creating
        Task {
            defer { working = false }
            do {
                if create {
                    try await app.account.createAccount(username: username, password: password)
                } else {
                    try await app.account.signIn(username: username, password: password)
                }
                password = ""; confirm = ""
            } catch let e as SyncError {
                switch e {
                case .invalidUsername(let why): usernameError = why
                case .usernameTaken: usernameError = e.errorDescription
                case .weakPassword(let why): passwordError = why
                default: message = e.errorDescription
                }
            } catch {
                message = AccountModel.describe(error)
            }
        }
    }
}
