import Addons
import Domain
import Foundation
import Playback
import Sync

/// Join a Party…: an invite that was opened (confirm it), or nothing yet (type a code or paste a link).
public struct PartyJoinRequest: Identifiable, Equatable {
    public let id = UUID()
    public var invite: TogetherInvite?

    public init(invite: TogetherInvite? = nil) { self.invite = invite }
}

/// A sign-in to the party's server: this account's, or a guest's for the party's length.
public struct PartyAccess: Sendable {
    public let config: SupabaseConfig
    public let token: @Sendable () async throws -> String
}

enum PartyInviteError: LocalizedError {
    case noServer
    var errorDescription: String? { String(localized: "The link is missing its server. Ask for a new invite.") }
}

// MARK: - Watch Party

/// Starting, joining and leaving a Watch Party, and finding each device's copy
/// of what it watches. A party is a room on the host's Bluebox server (the
/// Supabase project in Settings › Account & Sync); friends on another server
/// join it as guests through the invite link.
extension AppModel {
    /// A party needs a Bluebox server to meet on.
    public var canStartParty: Bool { account.isConfigured }

    /// Start a Party: a room with a code straight away, then the title opens
    /// paused in the lobby until you press Start.
    public func startParty(_ item: NowPlayingItem) async {
        guard canStartParty else {
            alert = AppAlert(title: "Watch Party needs a Bluebox server",
                             message: "A party meets on your Bluebox server. Set one up in Settings › Account & Sync, then start the party again.")
            return
        }
        if party != nil { await leaveParty() }
        do {
            let (config, token) = try await account.partyAccess(project: nil)
            let code = TogetherJoinCode.random()
            let invite = TogetherInvite(code: code, projectURL: config.url, publishableKey: config.publishableKey)
            let room = TogetherRoom(me: partyMe(), transport: TogetherRealtimeRoom(config: config, code: code, token: token))
            room.host(lobby: true)
            let p = makeParty(room: room, invite: invite)
            await room.join()
            await openForParty(p, match: .exact) { await self.play(item, autoplay: false) }
            if party === p, activePlayer == nil { await leaveParty() }  // it didn't open (the alert said why)
        } catch {
            alert = AppAlert(title: "Couldn't start the party", message: UserFacingError.message(for: error))
        }
    }

    /// Signs in to the server an invite leads to: this account when it's the
    /// same server, otherwise a guest. The invitation looks at the party with
    /// it, and joining reuses it rather than signing in as a second guest.
    func partyAccess(for invite: TogetherInvite) async throws -> PartyAccess {
        guard let project = SupabaseConfig(url: invite.projectURL.absoluteString, publishableKey: invite.publishableKey) else {
            throw PartyInviteError.noServer
        }
        let (config, token) = try await account.partyAccess(project: project)
        return PartyAccess(config: config, token: token)
    }

    /// Joins the party an invite leads to, as you (or the name and colour you chose for it).
    /// While the invitation is up, a problem shows on it instead of in an alert.
    public func joinParty(_ invite: TogetherInvite, as name: String? = nil, color: Int? = nil, access: PartyAccess? = nil) async {
        if party != nil { await leaveParty() }
        partyJoinProblem = nil
        do {
            let access = if let access { access } else { try await partyAccess(for: invite) }
            let room = TogetherRoom(me: partyMe(name: name, color: color),
                                    transport: TogetherRealtimeRoom(config: access.config, code: invite.code, token: access.token))
            _ = makeParty(room: room, invite: invite)
            await room.join()
        } catch {
            let message = UserFacingError.message(for: error)
            if partyJoin != nil { partyJoinProblem = message } else { alert = AppAlert(title: "Couldn't join the party", message: message) }
        }
    }

    /// A code typed into Join a Party…: a room on this device's own server.
    public func invite(forCode code: TogetherJoinCode) -> TogetherInvite? {
        guard let config = account.partyConfig else { return nil }
        return TogetherInvite(code: code, projectURL: config.url, publishableKey: config.publishableKey)
    }

    public func leaveParty() async {
        guard let p = party else { return }
        party = nil
        p.stop()
        activePlayer?.autoplayNext = settings.autoplayNextEpisode
        await p.room.leave()
    }

    /// The host's End Party for Everyone.
    public func endPartyForEveryone() async {
        party?.room.endForEveryone()
        await leaveParty()
    }

    /// The host's Add to Party Queue (a poster's menu, or an episode's).
    public func addToParty(_ item: NowPlayingItem) {
        guard let party, party.isHost else { return }
        party.room.enqueue(TogetherQueueItem(key: item.key.rawValue, name: item.title, subtitle: item.subtitle))
        toast = AppToast("Added to the party", message: [item.title, item.subtitle].compactMap { $0 }.joined(separator: " · "),
                         style: .success)
    }

    func partyEnded(_ p: WatchParty, reason: String) async {
        guard party === p else { return }
        party = nil
        p.stop()
        activePlayer?.autoplayNext = settings.autoplayNextEpisode
        await p.room.leave()
        // Turned away while the invitation is still up (locked, removed): it says so there.
        if partyJoin != nil { partyJoinProblem = reason } else { alert = AppAlert(title: "The party's over", message: reason) }
    }

    // MARK: Inside

    private func partyMe(name: String? = nil, color: Int? = nil) -> TogetherParticipant {
        let profile = currentProfile
        let chosen = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TogetherParticipant(id: prefs.deviceID, name: chosen?.isEmpty == false ? String(chosen!.prefix(40)) : profile.name,
                                   symbol: profile.symbol, color: color ?? profile.color, joinedAt: Date())
    }

    private func makeParty(room: TogetherRoom, invite: TogetherInvite) -> WatchParty {
        let p = WatchParty(room: room, invite: invite, app: self)
        room.onTitle = { [weak self, weak p] title in
            guard let self, let p else { return }
            Task { await self.partyTitleChanged(title, in: p) }
        }
        room.onUpNext = { [weak self, weak p] next in
            guard let self, let p else { return }
            Task {
                if await self.hasCopy(MediaKey(rawValue: next.item.key)) { p.room.upNextFound(next.id) }
            }
        }
        room.onUpNextDue = { [weak self, weak p] next in
            guard let self, let p, p.isHost else { return }
            Task { await self.openUpNext(next, in: p) }
        }
        party = p
        return p
    }

    /// Opens something for the party, then joins the new player to the room.
    private func openForParty(_ p: WatchParty, match: TogetherRelease.Match?, _ open: () async -> Void) async {
        partyIsSwitching = true
        await open()
        partyIsSwitching = false
        guard party === p else { return }
        guard let session = activePlayer else {
            p.failed("Bluebox couldn't open it on this device.")
            return
        }
        p.attach(session, match: match)
    }

    /// Someone (the host) started a title: find this device's copy and open it paused.
    func partyTitleChanged(_ title: TogetherTitle, in p: WatchParty) async {
        guard party === p, !p.isHost else { return }
        p.finding(title.name)
        let key = MediaKey(rawValue: title.key)
        let art = await self.title(for: key.seriesKey ?? key).flatMap { imageURL($0.backdrop ?? $0.poster, width: 640) }
        let item = NowPlayingItem(key: key, title: title.name, subtitle: title.subtitle, artworkURL: art)
        let found = await findCopy(of: title, item: item)
        guard party === p else { return }
        await openForParty(p, match: found.match, found.open)
    }

    /// The best copy this device has of the party's release: the same torrent,
    /// the same file, then anything (checked for the same length once it opens).
    func findCopy(of title: TogetherTitle, item: NowPlayingItem) async
        -> (open: @MainActor () async -> Void, match: TogetherRelease.Match?, label: String?) {
        let key = item.key
        var best: (match: TogetherRelease.Match, label: String, open: @MainActor () async -> Void)?
        if addonSettings.isEnabled, let releases = try? await releases(for: key),
           let hit = title.release.bestMatch(in: releases) {
            best = (hit.match, TogetherRelease(hit.release).label,
                    { await self.play(item, release: hit.release, resume: false, autoplay: false) })
        }
        // This library's own copies: downloads, folders, media servers.
        let own = await registry.availability(for: key).variants.filter { $0.sourceID != addons.id }
        for v in own {
            let release = TogetherRelease(v, duration: v.duration)
            let m = title.release.match(release)
            if m != .none, m > (best?.match ?? .none) {
                best = (m, release.label, { await self.play(item, variant: v, resume: false, autoplay: false) })
            }
        }
        if let best { return (best.open, best.match, best.label) }
        return ({ await self.play(item, resume: false, autoplay: false) }, nil, nil)
    }

    /// The invitation's "Your copy": how this device's best copy of the
    /// party's release matches, before joining.
    func partyCopy(of title: TogetherTitle) async -> PartyInvitation.Copy {
        let key = MediaKey(rawValue: title.key)
        let found = await findCopy(of: title, item: NowPlayingItem(key: key, title: title.name, subtitle: title.subtitle))
        switch found.match {
        case .exact?, .sameFile?: return .ready(found.label ?? title.release.label)
        case .sameLength?: return .sameLength(found.label ?? "")
        case .none?, nil: return await hasCopy(key) ? .other : .missing
        }
    }

    /// Whether this device can play `key` at all (up next waits for everyone's copy).
    func hasCopy(_ key: MediaKey) async -> Bool {
        if await registry.availability(for: key).variants.contains(where: { $0.sourceID != addons.id }) { return true }
        guard addonSettings.isEnabled else { return false }
        return (try? await releases(for: key))?.isEmpty == false
    }

    /// The host's episode ended: the queue's first, or the next episode, for everyone.
    func proposeNext(after key: MediaKey, in p: WatchParty) async {
        guard party === p, p.isHost else { return }
        if let first = p.room.settings?.queue.first {
            p.room.proposeUpNext(first, fromQueue: true)
            return
        }
        guard let seriesKey = key.seriesKey, let (s, e) = key.episodeNumbers,
              let detail = try? await metadata.detail(for: seriesKey),
              let (ns, ne) = SeriesCursor.next(after: s, e, seasons: detail.seasons),
              let nextKey = seriesKey.episode(season: ns, episode: ne) else { return }
        let episode = try? await metadata.season(ns, of: seriesKey).episodes.first { $0.number == ne }
        p.room.proposeUpNext(TogetherQueueItem(key: nextKey.rawValue, name: detail.title.name,
                                               subtitle: "S\(ns)·E\(ne)" + (episode.map { " · \($0.name)" } ?? "")),
                             fromQueue: false)
    }

    /// Up next is due: the host opens it (and tells the room once it knows its length).
    private func openUpNext(_ next: TogetherUpNext, in p: WatchParty) async {
        let key = MediaKey(rawValue: next.item.key)
        let art = await self.title(for: key.seriesKey ?? key).flatMap { imageURL($0.backdrop ?? $0.poster, width: 640) }
        let item = NowPlayingItem(key: key, title: next.item.name, subtitle: next.item.subtitle, artworkURL: art)
        await openForParty(p, match: .exact) { await self.play(item) }
    }
}

#if DEBUG
// MARK: - A demo party, for looking at the UI without a server

extension AppModel {
    /// `-demo-party` (with `-test-link`): wraps what's playing in a party with
    /// three scripted guests. `-demo-party-lobby` holds it in the lobby;
    /// `-demo-party-closed` starts with the chat closed (the pill and bubbles).
    func startDemoParty(lobby: Bool, chatOpen: Bool) async {
        for _ in 0..<60 where activePlayer?.snapshot.duration == nil { try? await Task.sleep(for: .milliseconds(500)) }
        guard let session = activePlayer else { return }
        let invite = TogetherInvite(code: TogetherJoinCode("K7QM2XDP")!, projectURL: URL(string: "https://demo.supabase.co")!,
                                    publishableKey: "sb_publishable_demo")
        let room = TogetherRoom(me: partyMe(), transport: DemoPartyTransport(lobby: lobby))
        room.host(lobby: lobby)
        let p = makeParty(room: room, invite: invite)
        p.chatOpen = chatOpen
        await room.join()
        if lobby, session.appearsPlaying { session.togglePlayPause() }
        p.attach(session, match: .exact)
        if !lobby, !session.appearsPlaying { session.togglePlayPause() }
    }
}

/// Sam, Alex and Mia, saying and doing things on a script.
final class DemoPartyTransport: TogetherTransport, @unchecked Sendable {
    let lobby: Bool
    init(lobby: Bool) { self.lobby = lobby }

    func start(onMessage: @escaping @Sendable (TogetherMessage) -> Void,
               onConnection: @escaping @Sendable (TogetherConnection) -> Void) async {
        onConnection(.connected)
        let lobby = lobby
        Task {
            let now = Date()
            let sam = TogetherParticipant(id: "demo-sam", name: "Sam", symbol: "star.fill", color: 1, joinedAt: now.addingTimeInterval(5),
                                          status: .ready, match: .exact)
            let alex = TogetherParticipant(id: "demo-alex", name: "Alex", symbol: "flame.fill", color: 3, joinedAt: now.addingTimeInterval(6),
                                           status: lobby ? .loading : .ready, match: .exact)
            let mia = TogetherParticipant(id: "demo-mia", name: "Mia", symbol: "leaf.fill", color: 5, joinedAt: now.addingTimeInterval(7),
                                          status: .ready, away: !lobby, match: .sameLength)
            for p in [sam, alex, mia] { onMessage(.hello(p)) }
            func say(_ who: TogetherParticipant, _ text: String, reply: TogetherChatMessage? = nil, mentions: [String] = []) -> TogetherChatMessage {
                let m = TogetherChatMessage(from: who.id, name: who.name, symbol: who.symbol, color: who.color, text: text, sentAt: Date(),
                                            position: 3_952, replyTo: reply.map { .init(id: $0.id, name: $0.name, text: $0.text) },
                                            mentions: mentions)
                onMessage(.chat(m))
                return m
            }
            try? await Task.sleep(for: .seconds(1))
            let first = say(sam, "here it comes")
            try? await Task.sleep(for: .seconds(1.5))
            onMessage(.typing(from: alex.id))
            try? await Task.sleep(for: .seconds(1.5))
            let second = say(alex, "@Sam NO WAY", reply: first, mentions: [sam.id])
            for (i, e) in ["😂", "😂", "😂", "🔥"].enumerated() {
                onMessage(.reaction(TogetherReaction(from: [sam, mia, alex, sam][i].id, name: "", emoji: e, sentAt: Date(),
                                                     onMessage: second.id)))
            }
            try? await Task.sleep(for: .seconds(2))
            _ = say(sam, "the sandworm 😭")
            onMessage(.typing(from: alex.id))
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                onMessage(.reaction(TogetherReaction(from: sam.id, name: sam.name, emoji: TogetherReaction.quick.randomElement()!, sentAt: Date())))
                onMessage(.presence(sam)); onMessage(.presence(alex)); onMessage(.presence(mia))
            }
        }
    }

    func send(_ message: TogetherMessage) async -> Bool { true }
    func stop() async {}
}
#endif
