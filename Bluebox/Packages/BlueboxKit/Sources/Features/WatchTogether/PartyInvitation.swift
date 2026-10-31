import Domain
import Foundation
import Observation
import Sync

/// Join the Party: what the invitation knows before you join. It signs in to
/// the party's server, looks at the room (`TogetherPeek`) for who's hosting,
/// what's on, who's there and whether it has started, and checks this
/// device's copy of the title. Join hands its sign-in on to the party.
@MainActor @Observable
public final class PartyInvitation {
    /// "Your copy", once the party's title is known.
    public enum Copy: Equatable, Sendable {
        case checking
        /// The same release (or the same file): "2160p · WEB-DL".
        case ready(String)
        /// Another release of the same length, which lines up.
        case sameLength(String)
        /// Some copy, checked for its length when it opens.
        case other
        /// Nothing in this device's sources.
        case missing
    }

    // Settable inside the module so the snapshot tests can draw each state without a server.
    public let invite: TogetherInvite
    public internal(set) var peek: TogetherPeek?
    /// Couldn't sign in to the party's server.
    public internal(set) var problem: String?
    public internal(set) var copy: Copy?
    /// The title's backdrop and year, once the party says what's on.
    public internal(set) var backdrop: URL?
    public internal(set) var year: Int?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var access: PartyAccess?
    /// The title whose art and copy were last looked up.
    @ObservationIgnored var lookedUp: String?

    init(invite: TogetherInvite, app: AppModel) {
        self.invite = invite; self.app = app
    }

    /// Signs in and starts looking at the room.
    func start() async {
        guard let app, peek == nil else { return }
        problem = nil
        do {
            let access = try await app.partyAccess(for: invite)
            self.access = access
            let p = TogetherPeek(id: app.prefs.deviceID,
                                 transport: TogetherRealtimeRoom(config: access.config, code: invite.code, token: access.token))
            peek = p
            await p.start()
        } catch {
            problem = UserFacingError.message(for: error)
        }
    }

    func stop() async {
        let p = peek
        peek = nil
        await p?.stop()
    }

    /// Try Again: a fresh sign-in and a fresh look.
    func retry() async {
        await stop()
        access = nil; lookedUp = nil; copy = nil
        await start()
    }

    /// The party said what's on: its art, and whether this device has a copy.
    func titleChanged() async {
        guard let app, let title = peek?.title, lookedUp != title.key else { return }
        lookedUp = title.key
        let key = MediaKey(rawValue: title.key)
        copy = .checking
        if let t = await app.title(for: key.seriesKey ?? key) {
            backdrop = app.imageURL(t.backdrop ?? t.poster, width: 1280)
            year = t.year
        }
        let found = await app.partyCopy(of: title)
        if peek?.title?.key == title.key { copy = found }
    }

    /// Joins, reusing this sign-in; the room takes over from the look.
    func join(as name: String?, color: Int?) async {
        guard let app else { return }
        let access = access
        await stop()
        await app.joinParty(invite, as: name, color: color, access: access)
    }
}
