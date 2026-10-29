#if DEBUG
import Domain
import Foundation

extension AppModel {
    /// Screenshots of profiles (`-seed-profiles` with `-ui-testing`): Brian,
    /// Sam with a PIN (1234), Mia, and a Kids profile, as in the mockups.
    public func seedProfilesForReview() {
        var me = currentProfile
        me.name = "Brian"
        updateProfile(me)
        let sam = addProfile(name: "Sam", symbol: "star.fill", color: 2, maturity: .age16)
        try? setPIN("1234", for: sam.id)
        addProfile(name: "Mia", symbol: "heart.fill", color: 13)
        addProfile(name: "Kids", symbol: "pawprint.fill", color: 8, maturity: .age7, isKids: true)
    }

    /// Launch arguments for profile screenshots, after the library opens.
    static var reviewArguments: [String] { ProcessInfo.processInfo.arguments }

    static func reviewValue(_ flag: String) -> String? {
        let args = reviewArguments
        return args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
}
#endif
