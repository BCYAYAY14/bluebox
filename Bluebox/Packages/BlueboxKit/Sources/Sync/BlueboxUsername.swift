import Foundation

/// Bluebox signs in with a username and password. Supabase Auth needs an
/// email address, so a username is stored as `<username>@bluebox.invalid`.
///
/// Why `.invalid`: hosted Supabase Auth (GoTrue) only checks an address's
/// format when an account is created (`validateEmail` → `checkmail.ValidateFormat`
/// in supabase/auth `internal/api/mail.go`). Its stricter check, which refuses
/// reserved names such as `.invalid`, `.test`, `.local` and `example.com` and
/// looks up MX records, runs only just before an email is sent
/// (`internal/mailer/validateclient`). Bluebox turns off confirmation emails
/// (`mailer_autoconfirm`) and never asks for one, so that check never runs.
/// `.invalid` is reserved by RFC 2606 and RFC 6761 and can never resolve, so
/// even if a project did try to send an email, nobody would receive it.
public enum BlueboxUsername {
    public static let emailDomain = "bluebox.invalid"
    public static let lengths = 3...32
    /// Supabase Auth hashes with bcrypt, which reads at most 72 bytes.
    public static let passwordLengths = SupabaseAutoSetup.passwordMinLength...72

    /// Lower-cased and trimmed, or why it can't be a username.
    public static func check(_ raw: String) -> Result<String, Problem> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.isEmpty { return .failure(.empty) }
        guard name.allSatisfy(isAllowed) else { return .failure(.characters) }
        guard lengths.contains(name.count) else { return .failure(.length) }
        // An address can't start or end with a dot or have two in a row (RFC 5322).
        guard let first = name.first, let last = name.last, first.isLetter || first.isNumber,
              last.isLetter || last.isNumber, !name.contains("..") else { return .failure(.edges) }
        return .success(name)
    }

    public enum Problem: Error, Equatable, Sendable, LocalizedError {
        case empty, length, characters, edges

        public var errorDescription: String? {
            switch self {
            case .empty: "Enter a username."
            case .length: "Use 3 to 32 characters."
            case .characters: "Use only letters, numbers, dots, dashes and underscores."
            case .edges: "Start and end with a letter or number, with no two dots in a row."
            }
        }
    }

    public static func checkPassword(_ password: String) -> String? {
        if password.isEmpty { return "Enter a password." }
        if password.utf8.count < passwordLengths.lowerBound { return "Use at least \(passwordLengths.lowerBound) characters." }
        if password.utf8.count > passwordLengths.upperBound { return "Use at most \(passwordLengths.upperBound) characters." }
        return nil
    }

    /// The address Supabase stores for a username.
    public static func email(for username: String) throws -> String {
        switch check(username) {
        case .success(let name): "\(name)@\(emailDomain)"
        case .failure(let problem): throw problem
        }
    }

    /// The username in a stored address, or nil for a real email address
    /// (an account from before usernames, or Sign in with Apple).
    public static func username(fromEmail email: String?) -> String? {
        guard let email = email?.lowercased(), email.hasSuffix("@" + emailDomain) else { return nil }
        let name = String(email.dropLast(emailDomain.count + 1))
        return name.isEmpty ? nil : name
    }

    private static func isAllowed(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")
    }
}
