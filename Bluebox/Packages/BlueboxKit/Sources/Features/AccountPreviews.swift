#if DEBUG
import Foundation
import Persistence
import Sync

extension AppModel {
    /// Screenshots: `-ui-testing -open-settings account -preview-account <state>`
    /// draws an account screen without a Supabase account or network. States:
    /// `working`, `failed`, `choose`, `create`, `sign-in`, `signed-in`. Debug builds only.
    func previewAccountForReview(_ state: String) {
        guard !account.isConfigured else { return }
        // A hosted-looking address that's never contacted unless something syncs.
        let config = SupabaseConfig(url: "https://abcdefghijklmnopqrst.supabase.co",
                                    publishableKey: "sb_publishable_ReviewOnlyKeyNotReal0000")!
        switch state {
        case "working":
            serverSetup.preview(.working(.creatingServer))
        case "failed":
            serverSetup.preview(.failed(SupabaseAutoSetup.Failure.stillStarting.errorDescription ?? ""))
        case "choose":
            serverSetup.preview(.choosingProject(
                reason: SupabaseAutoSetup.Failure.projectLimit([]).errorDescription ?? "",
                projects: [ManagedProject(ref: "qwertyuiopasdfghjklz", name: "Recipes", region: "eu-west-2", status: "ACTIVE_HEALTHY"),
                           ManagedProject(ref: "zxcvbnmlkjhgfdsapoiu", name: "Side project", region: "us-east-1", status: "ACTIVE_HEALTHY")]))
        case "create":
            account.configure(config)
            serverSetup.preview(.idle, needsFirstAccount: true)
        case "sign-in":
            account.configure(config)
        case "signed-in":
            // A session the stand-in Keychain hands to the new client, far from expiring.
            let session = AuthSession(accessToken: "review", refreshToken: "review", expiresAt: .distantFuture,
                                      userID: "review", email: "brian@\(BlueboxUsername.emailDomain)")
            if let json = try? JSONEncoder().encode(session) {
                try? secrets.write(String(decoding: json, as: UTF8.self), for: SecretAccount.supabaseSession)
            }
            account.configure(config)
        default:
            break
        }
    }
}
#endif
