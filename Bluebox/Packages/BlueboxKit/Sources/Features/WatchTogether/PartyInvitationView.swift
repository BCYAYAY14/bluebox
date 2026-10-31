import DesignSystem
import Domain
import SwiftUI
import Sync

// Join the Party (design/mockups-join-party-2026-10-31.html): the invitation
// a friend's link opens, and Join a Party…'s code boxes leading to the same
// page. It fills the window like a title page on the Mac and the screen on
// the iPhone, says who invited you, what's on, who's there and whether it has
// started, checks your copy, and turns into the lobby once you've joined.

/// The invitation, over everything (PartyHost puts it there).
struct PartyJoinScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let request: PartyJoinRequest

    /// `invitation`: one already looking at the room (the snapshot tests pass one in).
    init(request: PartyJoinRequest, invitation: PartyInvitation? = nil) {
        self.request = request
        _invitation = State(initialValue: invitation)
    }

    @State private var invitation: PartyInvitation?
    @State private var typed = ""
    @State private var changingName = false
    @State private var name = ""
    @State private var color = 0
    @State private var joined = false
    @State private var inviteOpen = false

    private var wide: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }

    private var peek: TogetherPeek? { invitation?.peek }
    private var title: TogetherTitle? { peek?.title }
    /// The party this invitation joined, once Join was pressed.
    private var party: WatchParty? {
        guard joined, let invitation, let p = app.party, p.invite == invitation.invite else { return nil }
        return p
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backdrop
            Group {
                if let problem {
                    centred { problemCard(problem) }
                } else if joined {
                    centred { lobbyCard }
                } else if wide {
                    wideLayout
                } else {
                    compactLayout
                }
            }
            .transition(.opacity)
            closeButton
        }
        .animation(Motion.snappy(reduceMotion), value: joined)
        .animation(Motion.appear, value: invitation?.backdrop)
        .background(Palette.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task {
            let profile = app.currentProfile
            name = profile.name; color = profile.color
            if let invite = request.invite { begin(invite) }
        }
        .task(id: title?.key) { await invitation?.titleChanged() }
        .onChange(of: typed) { _, code in codeChanged(code) }
        // The player opened for the party (it was playing, or the host picked something): it takes over.
        .onChange(of: app.activePlayer != nil) { _, open in if open, joined { close() } }
        .onChange(of: party?.phase == .watching) { _, watching in if watching { close() } }
        .onDisappear { if !joined { Task { await invitation?.stop() } } }
        #if os(macOS)
        .onExitCommand { close() }
        #endif
        .remoteModal(dismiss: { close() })
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Layouts

    /// Mac and iPad: the invitation on the left over the backdrop, who's there on the right.
    private var wideLayout: some View {
        HStack(alignment: .bottom, spacing: Spacing.xxxl) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if request.invite == nil { codeEntry.padding(.bottom, Spacing.l) }
                if invitation != nil {
                    headline
                    statusLine
                    joinAs.padding(.top, Spacing.xs)
                    joinButton.frame(maxWidth: 300).padding(.top, Spacing.s)
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            if invitation != nil {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    peopleList
                    copyLine
                }
                .frame(maxWidth: 320, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 56).padding(.bottom, 56).padding(.top, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// iPhone: the backdrop at the top, the invitation under it, the buttons in thumb reach.
    private var compactLayout: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if request.invite == nil {
                        codeEntry.padding(.top, 64).padding(.bottom, Spacing.l)
                    } else {
                        Color.clear.frame(height: 150)
                    }
                    if invitation != nil {
                        headline
                        statusLine
                        peopleFaces.padding(.top, Spacing.xs)
                        copyLine
                        joinAs.padding(.top, Spacing.xs)
                    }
                }
                .padding(.horizontal, Spacing.l + 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: Spacing.s) {
                joinButton
                Button("Not Now") { close() }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            }
            .padding(.horizontal, Spacing.l + 4).padding(.vertical, Spacing.m)
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(Spacing.xl)
            .frame(maxWidth: 400)
            .playerNoticeSurface()
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The backdrop

    private var backdrop: some View {
        GeometryReader { geo in
            // The title's backdrop, or Bluebox's generated art when it has none.
            if invitation?.backdrop != nil || title != nil {
                ArtworkView(url: invitation?.backdrop, fallbackTitle: title?.name ?? "", kind: .backdrop, pixelWidth: 1600,
                            showsFallbackTitle: false)
                    .frame(width: geo.size.width, height: wide ? geo.size.height : min(geo.size.height * 0.5, geo.size.width * 0.95))
                    .clipped()
                    .overlay {
                        if wide {
                            LinearGradient(stops: [.init(color: .black.opacity(0.92), location: 0.25), .init(color: .black.opacity(0.3), location: 0.75),
                                                   .init(color: .black.opacity(0.15), location: 1)], startPoint: .leading, endPoint: .trailing)
                            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                        } else {
                            LinearGradient(colors: [.clear, .black], startPoint: .init(x: 0.5, y: 0.3), endPoint: .bottom)
                        }
                    }
                    .opacity(joined || problem != nil ? 0.45 : 1)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var closeButton: some View {
        Button { close() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 32, height: 32)
                .background(Palette.glassFill, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(Palette.textPrimary)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
        .padding(Spacing.l)
    }

    // MARK: Joining by code

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Join a Party").font(Typography.pageTitle)
            Text("Type the code, or paste the invite link.")
                .font(.callout).foregroundStyle(Palette.textSecondary)
            PartyCodeBoxes(code: $typed) { invite in
                // The link's own server, before the boxes show its code (which alone would mean this device's server).
                begin(invite)
                typed = invite.code.value
            }
            .padding(.top, Spacing.xs)
            if TogetherJoinCode(typed) != nil, invitation == nil {
                Text("A code works only with a Bluebox server set up in Settings › Account & Sync. Ask for the link instead.")
                    .font(.caption).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func codeChanged(_ code: String) {
        guard request.invite == nil else { return }
        if let parsed = TogetherJoinCode(code) {
            guard invitation?.invite.code != parsed, let invite = app.invite(forCode: parsed) else { return }
            begin(invite)
        } else if let old = invitation {
            invitation = nil
            Task { await old.stop() }
        }
    }

    private func begin(_ invite: TogetherInvite) {
        guard invitation?.invite != invite else { return }
        let old = invitation
        let fresh = PartyInvitation(invite: invite, app: app)
        invitation = fresh
        Task {
            await old?.stop()
            await fresh.start()
        }
    }

    // MARK: What's on

    private var hostName: String? { peek?.host?.name }

    @ViewBuilder private var headline: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                if let host = peek?.host {
                    ProfileAvatar(symbol: host.symbol, color: host.color, size: wide ? 34 : 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("WATCH PARTY").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(Palette.brandBright)
                    if let hostName {
                        Text("\(hostName) invited you").font(.headline)
                    } else {
                        Text("You're invited").font(.headline)
                    }
                }
            }
            if let title {
                // Film and show names are never translated.
                Text(verbatim: title.name)
                    .font(wide ? Typography.titleHero : Font.largeTitle.weight(.black))
                    .lineLimit(2).minimumScaleFactor(0.7)
                if let meta = metaLine(title) {
                    Text(verbatim: meta).font(Typography.meta).foregroundStyle(Palette.textSecondary)
                }
            } else if peek?.situation == .quiet || peek?.situation == .picking {
                Text("Watch Party").font(wide ? Typography.titleHero : Font.largeTitle.weight(.black))
                Text("Code \(invitation?.invite.code.description ?? "")").font(Typography.meta).foregroundStyle(Palette.textSecondary)
            } else {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small).tint(Palette.brandBright)
                    Text("Getting ready…").font(.title2.weight(.bold)).foregroundStyle(Palette.textSecondary)
                }
                .padding(.vertical, Spacing.xs)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "2024 · S1·E2 · Pilot · 2h 46m"
    private func metaLine(_ title: TogetherTitle) -> String? {
        let runtime = title.release.duration.map {
            Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        }
        let parts = [invitation?.year.map(String.init), title.subtitle, runtime].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusLine: some View {
        if let peek {
            switch peek.situation {
            case .lobby:
                status(dot: Palette.textSecondary, Text("In the lobby · starts when \(hostName ?? String(localized: "the host")) presses Start"))
            case .picking:
                status(dot: Palette.textSecondary, Text("\(hostName ?? String(localized: "The host")) is picking something"))
            case .playing:
                TimelineView(.periodic(from: .now, by: 1)) { _ in playingLine }
            case .quiet:
                Text("Nobody in the party has answered yet. It may have ended, or everyone there has an older Bluebox.")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .looking, .locked, .ended, .unreachable:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var playingLine: some View {
        let head = peek?.partyPlayhead
        let duration = title?.release.duration
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Circle().fill(Palette.brandBright).frame(width: 7, height: 7)
                if let head, head.paused {
                    Text("Paused at \(TogetherRoom.timecode(head.position))").monospacedDigit()
                } else if let head {
                    Text("Playing · \(TogetherRoom.timecode(head.position))").monospacedDigit()
                } else {
                    Text("Under way")
                }
                if let head, let duration, duration > 0 {
                    ProgressView(value: min(head.position / duration, 1))
                        .tint(Palette.brand)
                        .frame(maxWidth: 140)
                }
            }
            .font(.callout.weight(.semibold))
            Text("You'll join at the same moment as everyone.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
        }
    }

    private func status(dot: Color, _ text: Text) -> some View {
        HStack(spacing: Spacing.s) {
            Circle().fill(dot).frame(width: 7, height: 7)
            text.font(.callout.weight(.semibold))
        }
    }

    // MARK: Who's there

    private static let shownPeople = 5

    @ViewBuilder private var peopleList: some View {
        if let peek, !peek.everyone.isEmpty {
            let people = peek.everyone
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(people.prefix(Self.shownPeople)) { p in
                    HStack(spacing: Spacing.s) {
                        ProfileAvatar(symbol: p.symbol, color: p.color, size: 26)
                        Text(verbatim: p.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: Spacing.m)
                        PartyReadiness(person: p, isHost: p.id == peek.settings?.host)
                    }
                    .accessibilityElement(children: .combine)
                }
                if people.count > Self.shownPeople {
                    Text("+\(people.count - Self.shownPeople) more").font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private var peopleFaces: some View {
        if let peek, !peek.everyone.isEmpty {
            let people = peek.everyone
            HStack(alignment: .top, spacing: Spacing.l) {
                ForEach(people.prefix(Self.shownPeople)) { p in
                    VStack(spacing: 3) {
                        ProfileAvatar(symbol: p.symbol, color: p.color, size: 34)
                        Text(verbatim: p.name).font(.caption.weight(.semibold)).lineLimit(1)
                        PartyReadiness(person: p, isHost: p.id == peek.settings?.host)
                            .font(.caption2).labelStyle(.titleOnly).lineLimit(1)
                    }
                    .frame(maxWidth: 64)
                    .accessibilityElement(children: .combine)
                }
                if people.count > Self.shownPeople {
                    Text("+\(people.count - Self.shownPeople)").font(.callout.weight(.bold)).foregroundStyle(Palette.textSecondary)
                        .frame(height: 34)
                }
            }
        }
    }

    // MARK: Your copy

    @ViewBuilder private var copyLine: some View {
        if let copy = invitation?.copy {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                switch copy {
                case .checking:
                    ProgressView().controlSize(.mini).tint(Palette.brandBright)
                    Text("Looking for your copy…").foregroundStyle(Palette.textSecondary)
                case .ready(let label):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brandBright)
                    Text("Your copy is ready · \(label)")
                case .sameLength(let label):
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(Palette.warning)
                    if label.isEmpty {
                        Text("A same-length copy, not the host's exact one. It should stay in step.")
                    } else {
                        Text("A same-length copy (\(label)), not the host's exact one. It should stay in step.")
                    }
                case .other:
                    Image(systemName: "circle.dashed").foregroundStyle(Palette.warning)
                    Text("A different copy. Bluebox checks it lines up when it opens.")
                case .missing:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warning)
                    Text("Not in your sources. Add an add-on, debrid service or server that has it in Settings › Sources.")
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.edge))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Who you join as

    @ViewBuilder private var joinAs: some View {
        let profile = app.currentProfile
        if changingName {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.m) {
                    ProfileAvatar(symbol: profile.symbol, color: color, size: 30)
                    TextField("Name for this party", text: $name)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, Spacing.s + 2).frame(height: 34)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.brandBright.opacity(0.8)))
                        .frame(maxWidth: 260)
                        .onSubmit { if wide, canJoin { join() } }
                }
                HStack(spacing: 6) {
                    ForEach(Palette.profileColors.indices, id: \.self) { i in
                        Button { color = i } label: {
                            Circle().fill(Palette.profileColors[i]).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.white, lineWidth: color == i ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(i + 1)")
                        .accessibilityAddTraits(color == i ? .isSelected : [])
                    }
                }
                .padding(.leading, 42)
                HStack(spacing: Spacing.m) {
                    Text("Just for this party; your profile stays \(profile.name).")
                        .font(.caption).foregroundStyle(Palette.textSecondary)
                    Button("Use My Profile") {
                        changingName = false; name = profile.name; color = profile.color
                    }
                    .buttonStyle(TextActionStyle())
                    .font(.caption.weight(.semibold))
                }
                .padding(.leading, 42)
            }
        } else {
            HStack(spacing: Spacing.m) {
                ProfileAvatar(symbol: profile.symbol, color: profile.color, size: 30)
                Text("Joining as \(Text(verbatim: profile.name).bold())").font(.callout)
                Button("Change") { changingName = true }
                    .buttonStyle(TextActionStyle())
                    .font(.callout.weight(.semibold))
            }
        }
    }

    // MARK: Join

    private var canJoin: Bool {
        guard invitation != nil, invitation?.problem == nil, !joined else { return false }
        switch peek?.situation {
        case .locked?, .ended?, .unreachable?: return false
        default: return true
        }
    }

    private var joinButton: some View {
        Button { join() } label: {
            Label("Join Party", systemImage: "person.2.fill")
        }
        .buttonStyle(PartyJoinButtonStyle())
        .disabled(!canJoin)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("partyJoin")
    }

    private func join() {
        guard canJoin, let invitation else { return }
        joined = true
        let chosenName = changingName ? name : nil, chosenColor = changingName ? color : nil
        Task { await invitation.join(as: chosenName, color: chosenColor) }
    }

    private func close() {
        app.partyJoinProblem = nil
        app.partyJoin = nil
    }

    // MARK: After Join: the lobby

    private var lobbyCard: some View {
        VStack(spacing: Spacing.m) {
            VStack(spacing: 4) {
                if let t = party?.title ?? title {
                    Text("Watch Party · \(Text(verbatim: t.name))").font(.headline).multilineTextAlignment(.center)
                } else {
                    Text("Watch Party").font(.headline)
                }
                Text(lobbyLine).font(.caption).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
            }
            if let party {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(party.people) { p in
                        HStack(spacing: Spacing.s) {
                            ProfileAvatar(symbol: p.symbol, color: p.color, size: 26)
                            if p.id == party.room.me.id { Text("You").font(.callout.weight(.semibold)) }
                            else { Text(verbatim: p.name).font(.callout.weight(.semibold)) }
                            Spacer(minLength: Spacing.m)
                            PartyReadiness(person: p, isHost: p.id == party.room.settings?.host)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: 300)
                HStack(spacing: Spacing.s) {
                    Button("Share Invite…") { inviteOpen = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .popover(isPresented: $inviteOpen) { PartyInviteCard(party: party) }
                    Button("Leave") {
                        Task { await app.leaveParty() }
                        close()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                ProgressView().controlSize(.small).tint(Palette.brandBright)
            }
        }
    }

    private var lobbyLine: String {
        guard let party else { return String(localized: "Joining the party…") }
        let host = party.room.hostParticipant?.name ?? String(localized: "the host")
        switch party.phase {
        case .finding(let name): return String(localized: "You're in. Finding your copy of \(name)…")
        case .watching: return String(localized: "You're in. Opening…")
        case .ended(let why): return why
        case .connecting:
            if party.isLobby { return String(localized: "You're in. Starts when \(host) presses Start.") }
            return party.title == nil ? String(localized: "You're in. \(host) is picking something.") : String(localized: "You're in.")
        }
    }

    // MARK: When you can't join

    private struct Problem {
        var symbol = "exclamationmark.triangle.fill"
        let headline: String
        let message: String
        let canRetry: Bool
    }

    private var problem: Problem? {
        let host = hostName ?? String(localized: "The host")
        if let why = app.partyJoinProblem {
            return Problem(headline: String(localized: "Couldn't join the party"), message: why, canRetry: true)
        }
        if joined, let party, case .failed(let why) = party.room.connection {
            return Problem(symbol: "wifi.exclamationmark", headline: String(localized: "\(host)'s server isn't answering"), message: why, canRetry: true)
        }
        guard !joined else { return nil }
        if let why = invitation?.problem {
            return Problem(symbol: "wifi.exclamationmark", headline: String(localized: "Couldn't reach the party's server"), message: why, canRetry: true)
        }
        switch peek?.situation {
        case .locked?:
            return Problem(symbol: "lock.fill", headline: String(localized: "\(host) locked this party"),
                           message: String(localized: "Nobody new can join right now. Ask \(hostName ?? String(localized: "the host")) to unlock it, then try again."),
                           canRetry: true)
        case .ended?:
            return Problem(symbol: "moon.zzz.fill", headline: String(localized: "This party has ended"),
                           message: String(localized: "Ask for a new invite if they start another."), canRetry: false)
        case .unreachable(let why)?:
            return Problem(symbol: "wifi.exclamationmark", headline: String(localized: "The party's server isn't answering"), message: why, canRetry: true)
        default:
            return nil
        }
    }

    private func problemCard(_ p: Problem) -> some View {
        VStack(spacing: Spacing.m) {
            if let host = peek?.host, let title {
                HStack(spacing: Spacing.s) {
                    ProfileAvatar(symbol: host.symbol, color: host.color, size: 22)
                    Text("\(host.name)'s party · \(Text(verbatim: title.name))").font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            Image(systemName: p.symbol)
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(p.headline).font(.headline).multilineTextAlignment(.center)
                Text(p.message).font(.callout).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Spacing.s) {
                if p.canRetry {
                    Button("Try Again") { retry() }
                        .buttonStyle(PartyJoinButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                Button("Close") { close() }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            }
            .frame(maxWidth: 260)
        }
    }

    private func retry() {
        app.partyJoinProblem = nil
        if joined {
            joined = false
            Task { await app.leaveParty() }
        }
        Task { await invitation?.retry() }
    }
}

/// Join Party: the one big button, in the theme colour.
private struct PartyJoinButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Filled(configuration: configuration) }

    struct Filled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(Typography.button)
                .padding(.horizontal, Spacing.xl).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(isEnabled ? Palette.brand.opacity(configuration.isPressed ? 0.8 : 1) : Palette.elevated,
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .foregroundStyle(isEnabled ? Color.white : Palette.textTertiary)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }
}

/// Eight boxes in two groups of four, like a verification code. Typing fills
/// them (only the code's letters and digits; a dash is skipped), and pasting
/// an invite link anywhere in them opens its party.
struct PartyCodeBoxes: View {
    @Binding var code: String
    let onInvite: (TogetherInvite) -> Void
    @State private var raw = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // The field takes the typing and pasting; the boxes draw it.
            TextField("Party code", text: $raw)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .keyboardType(.asciiCapable)
                #endif
                .textFieldStyle(.plain)
                .foregroundStyle(.clear)
                .tint(.clear)
                .opacity(0.02)
                .accessibilityIdentifier("partyCode")
            HStack(spacing: 6) {
                ForEach(0..<TogetherJoinCode.length, id: \.self) { i in
                    if i == TogetherJoinCode.length / 2 {
                        Text(verbatim: "–").font(.title3.weight(.bold)).foregroundStyle(Palette.textTertiary)
                    }
                    box(i)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .accessibilityHidden(true)
        }
        .fixedSize()
        .onAppear { raw = code; focused = true }
        .onChange(of: raw) { _, typed in take(typed) }
        .onChange(of: code) { _, c in if c != raw { raw = c } }
    }

    private func box(_ i: Int) -> some View {
        let chars = Array(code)
        let current = focused && i == min(chars.count, TogetherJoinCode.length - 1)
        return Text(verbatim: i < chars.count ? String(chars[i]) : "")
            .font(.system(size: 22, weight: .heavy, design: .monospaced))
            .frame(width: 36, height: 46)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(current ? Palette.brandBright : Color.white.opacity(0.18), lineWidth: current ? 2 : 1))
    }

    private func take(_ typed: String) {
        if let invite = TogetherInvite(text: typed) {
            onInvite(invite)
            return
        }
        let cleaned = String(typed.uppercased().filter(TogetherJoinCode.alphabet.contains).prefix(TogetherJoinCode.length))
        if cleaned != typed { raw = cleaned }
        if cleaned != code { code = cleaned }
    }
}
