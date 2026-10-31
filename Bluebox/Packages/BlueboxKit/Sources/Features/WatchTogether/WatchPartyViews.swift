import DesignSystem
import Domain
import Sync
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The Watch Party's UI (design/mockups-watch-party-2026-10-31.html): the
// panel beside the video on the Mac (over it in landscape on iPhone, under it
// upright), the pill of faces, reactions floating up, messages over the film
// while the chat is closed, the lobby, up next, and Join a Party….

// MARK: - The panel

/// Chat, reactions and who's here, in a column beside the video.
struct PartyPanel: View {
    @Environment(AppModel.self) private var app
    let party: WatchParty
    /// iPhone: over the video (landscape) or under it (upright); a little denser.
    var compact = false
    @State private var draft = ""
    @State private var inviteOpen = false
    @State private var hostMenuOpen = false
    @FocusState private var typing: Bool

    static let width: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.separator)
            messages
            if let problem = party.copyProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Palette.warning)
                    .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.elevated)
            }
            reactionPad
            input
        }
        .frame(maxHeight: .infinity)
        .background(Palette.chrome)
        .foregroundStyle(Palette.textPrimary)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text("Watch Party").font(.headline)
                Spacer(minLength: 0)
                Button("Invite") { inviteOpen = true }
                    .buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.brandBright)
                    .popover(isPresented: $inviteOpen) { PartyInviteCard(party: party).environment(app) }
                    .accessibilityIdentifier("partyInvite")
                BlueboxMenu("Party") { partyMenu } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold))
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel("Party Options")
                Button { party.chatOpen = false } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).foregroundStyle(Palette.textSecondary)
                .accessibilityLabel("Close Chat")
                .help("Close the chat (⌘/)")
            }
            HStack(spacing: Spacing.s) {
                PartyFaces(people: party.people, size: 22)
                Text(hereLine).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s + 2)
    }

    private var hereLine: String {
        let people = party.people
        let away = people.filter(\.away).map { $0.id == party.room.me.id ? "you" : $0.name }
        var line = "\(people.count) here"
        if !away.isEmpty { line += " · " + ListFormatter.localizedString(byJoining: away) + " away" }
        if let host = party.room.hostParticipant, host.id != party.room.me.id { line += " · \(host.name) hosts" }
        return line
    }

    @BlueboxMenuBuilder private var partyMenu: [BlueboxMenuEntry] {
        BlueboxMenuSection {
            if party.away {
                BlueboxMenuButton("Catch Up", systemImage: "forward.end.fill") { party.catchUp() }
            } else {
                BlueboxMenuButton("Step Away", systemImage: "cup.and.saucer", subtitle: "Pause just for you") { party.stepAway() }
            }
            BlueboxMenuButton(party.muted ? "Unmute Party" : "Mute Party", systemImage: party.muted ? "bell" : "bell.slash",
                              checked: party.muted) { party.muted.toggle() }
        }
        if party.isHost {
            let settings = party.room.settings
            BlueboxMenuSection("Host") {
                BlueboxMenuButton("Only I Control Playback", systemImage: "av.remote", checked: settings?.hostOnlyControls == true) {
                    party.room.setHostOnlyControls(!(settings?.hostOnlyControls ?? false))
                }
                BlueboxMenuButton("Lock the Party", systemImage: "lock", subtitle: "Nobody new can join", checked: settings?.locked == true) {
                    party.room.setLocked(!(settings?.locked ?? false))
                }
                for p in party.room.others.values.sorted(by: { $0.name < $1.name }) {
                    BlueboxMenuButton("Make \(p.name) the Host", systemImage: "crown") { party.room.makeHost(p.id) }
                }
                for p in party.room.others.values.sorted(by: { $0.name < $1.name }) {
                    BlueboxMenuButton("Remove \(p.name)…", systemImage: "person.badge.minus", role: .destructive) { party.room.remove(p.id) }
                }
            }
            BlueboxMenuSection {
                BlueboxMenuButton("End Party for Everyone", systemImage: "xmark.circle", role: .destructive) {
                    Task { await app.endPartyForEveryone() }
                }
            }
        } else {
            BlueboxMenuSection {
                BlueboxMenuButton("Leave Party", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await app.leaveParty() }
                }
            }
        }
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.s + 2) {
                    ForEach(party.room.feed) { item in
                        switch item {
                        case .event(_, let text, _):
                            Text(text).font(.caption).foregroundStyle(Palette.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .message(let m):
                            PartyMessageRow(party: party, message: m)
                        }
                    }
                    let typingNames = party.room.typingNames
                    if !typingNames.isEmpty {
                        Text(ListFormatter.localizedString(byJoining: typingNames) + (typingNames.count == 1 ? " is typing…" : " are typing…"))
                            .font(.caption.italic()).foregroundStyle(Palette.textTertiary)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
            }
            .scrollIndicators(.hidden)
            .onChange(of: party.room.feed.count, initial: true) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    // MARK: Reactions and input

    private var reactionPad: some View {
        HStack(spacing: 0) {
            ForEach(Array(TogetherReaction.quick.enumerated()), id: \.offset) { i, emoji in
                Button { party.react(emoji) } label: {
                    Text(emoji).font(.system(size: compact ? 20 : 22)).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(PressableStyle())
                .help("React \(emoji) (⌥\(i + 1))")
                .accessibilityLabel("React \(emoji)")
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(Palette.surface)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let reply = party.replyingTo {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "arrowshape.turn.up.left.fill").font(.caption2)
                    Text("\(reply.name): \(reply.text)").font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { party.replyingTo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Cancel Reply")
                }
                .foregroundStyle(Palette.textSecondary)
            }
            HStack(spacing: Spacing.s) {
                TextField(party.isLobby ? "Say hello…" : "Message · @ to mention", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($typing)
                    .onSubmit(send)
                    .onChange(of: draft) { _, text in
                        if text.count > TogetherChatMessage.maxLength { draft = String(text.prefix(TogetherChatMessage.maxLength)) }
                        if !text.isEmpty { party.room.typing() }
                    }
                    .accessibilityIdentifier("partyMessage")
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Palette.textTertiary : Palette.brandBright)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Send")
            }
            .padding(.horizontal, Spacing.s + 2).padding(.vertical, Spacing.s)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .padding(Spacing.s + 2)
    }

    private func send() {
        let text = draft
        draft = ""
        party.send(text)
        typing = true
    }
}

/// One chat line: avatar, name and film time, the reply it quotes, the text
/// with @mentions picked out, and reaction counts. Hover (or hold) to reply or react.
private struct PartyMessageRow: View {
    let party: WatchParty
    let message: TogetherChatMessage
    @State private var hovering = false

    var body: some View {
        let mine = message.from == party.room.me.id
        let mentioned = party.mentionedIDs.contains(message.id)
        HStack(alignment: .top, spacing: Spacing.s) {
            ProfileAvatar(symbol: message.symbol, color: message.color, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(mine ? "You" : message.name).font(.caption.weight(.bold))
                    if let at = message.position {
                        Text(TogetherRoom.timecode(at)).font(.caption2.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                    }
                }
                if let reply = message.replyTo {
                    Text("\(reply.name): \(reply.text)").font(.caption2).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        .padding(.leading, Spacing.s)
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.textTertiary).frame(width: 2) }
                }
                Text(Self.styled(message.text)).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                let counts = party.room.reactionCounts(on: message.id)
                if !counts.isEmpty {
                    HStack(spacing: Spacing.xs) {
                        ForEach(counts, id: \.emoji) { c in
                            Button { party.react(c.emoji, to: message) } label: {
                                Text("\(c.emoji) \(c.count)").font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Palette.elevated, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(mentioned ? Spacing.xs : 0)
        .background(mentioned ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 2) {
                    Button { party.replyingTo = message } label: { Image(systemName: "arrowshape.turn.up.left") }
                        .help("Reply")
                    ForEach(TogetherReaction.quick.prefix(3), id: \.self) { e in
                        Button { party.react(e, to: message) } label: { Text(e) }
                    }
                }
                .buttonStyle(.plain).font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Palette.elevated, in: Capsule())
            }
        }
        .onHover { hovering = $0 }
        .blueboxContextMenu(mine ? String(localized: "Your Message") : message.name) {
            BlueboxMenuButton("Reply", systemImage: "arrowshape.turn.up.left") { party.replyingTo = message }
            BlueboxMenuSection(String(localized: "React")) {
                for e in TogetherReaction.quick { BlueboxMenuButton(e) { party.react(e, to: message) } }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Reply") { party.replyingTo = message }
    }

    /// @mentions in the brand colour.
    static func styled(_ text: String) -> AttributedString {
        var s = AttributedString(text)
        var search = s.startIndex
        while let r = s[search...].range(of: "@") {
            var end = r.upperBound
            while end < s.endIndex, s.characters[end] != " " { end = s.index(afterCharacter: end) }
            s[r.lowerBound..<end].foregroundColor = Palette.brandBright
            s[r.lowerBound..<end].font = .callout.weight(.semibold)
            search = end
            if search >= s.endIndex { break }
        }
        return s
    }
}

/// The overlapping faces of everyone here.
struct PartyFaces: View {
    let people: [TogetherParticipant]
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(people.prefix(5)) { p in
                ProfileAvatar(symbol: p.symbol, color: p.color, size: size)
                    // A ring of the background between overlapping faces.
                    .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).strokeBorder(Palette.background, lineWidth: 1.5))
                    .opacity(p.away ? 0.45 : 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The code, Share Invite… and Copy Link, and who's joined.
struct PartyInviteCard: View {
    let party: WatchParty
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Invite to the party").font(.headline)
            Text(party.invite.code.description)
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel("Code \(party.invite.code.value.map(String.init).joined(separator: " "))")
            Text("Friends with Bluebox open the link, or type the code in File › Join a Party… if they use your server.")
                .font(.caption).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.s) {
                ShareLink(item: party.invite.url, subject: Text("Join my Watch Party"),
                          message: Text("Join my Watch Party in Bluebox: \(party.title?.name ?? "")")) {
                    Label("Share Invite…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(party.invite.url.absoluteString, forType: .string)
                    #else
                    UIPasteboard.general.url = party.invite.url
                    #endif
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link") }
                .buttonStyle(SecondaryButtonStyle())
            }
            if party.room.settings?.locked == true {
                Label("The party is locked: nobody new can join.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(Spacing.l)
        .frame(width: 320)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Over the video

/// What the party puts over the film: the pill, floating reactions, messages
/// while the chat is closed, the lobby, up next, and stepping away.
struct PartyOverlay: View {
    @Environment(AppModel.self) private var app
    let party: WatchParty
    let controlsShown: Bool
    /// Room left for the top bar and the bottom bar.
    let topInset: CGFloat
    let bottomInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// With the controls hidden: clear of the Mac's window buttons, which come back on hover.
    #if os(macOS)
    static let restingTop: CGFloat = 40
    #else
    static let restingTop: CGFloat = Spacing.m
    #endif

    var body: some View {
        ZStack {
            // The pill of faces, top left, while the chat is closed.
            if !party.chatOpen {
                Button { party.chatOpen = true } label: {
                    HStack(spacing: Spacing.s) {
                        PartyFaces(people: party.people, size: 20)
                        Text("\(party.people.count) watching").font(.caption.weight(.semibold))
                            + Text(" · \(party.stateLine)").font(.caption).foregroundColor(Palette.textSecondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .playerNoticeSurface()
                }
                .buttonStyle(PressableStyle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, controlsShown ? topInset : Self.restingTop)
                .padding(.leading, Spacing.l)
                .accessibilityLabel("Open the party chat")
            }

            floats
            if !party.chatOpen, !party.bubbles.isEmpty { bubbles }

            if party.away { awayBanner }
            else if !party.room.canControl, controlsShown, let host = party.room.hostParticipant {
                Text("\(host.name) has the remote").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .playerNoticeSurface()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, topInset)
                    .allowsHitTesting(false)
            }

            if party.isLobby || party.countdown != nil {
                PartyLobby(party: party).zIndex(3)
            } else if let next = party.room.upNext {
                PartyUpNextCard(party: party, next: next).zIndex(3)
            }
            if case .finding(let name) = party.phase {
                PartyStatusCard(text: "Finding your copy of \(name)…")
            }
        }
        .animation(Motion.snappy(reduceMotion), value: party.bubbles)
        .animation(Motion.snappy(reduceMotion), value: party.away)
    }

    private var floats: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: party.floats.isEmpty)) { context in
            ZStack(alignment: .bottomTrailing) {
                ForEach(party.floats) { f in
                    let age = context.date.timeIntervalSince(f.born)
                    let t = min(max(age / WatchParty.floatLife, 0), 1)
                    HStack(spacing: 2) {
                        Text(f.emoji).font(.system(size: 34))
                        if f.count > 1 { Text("×\(f.count)").font(.headline.weight(.heavy)).shadow(radius: 3) }
                    }
                    .offset(x: -CGFloat(f.lane) * 90, y: reduceMotion ? 0 : -CGFloat(t) * 220)
                    .opacity(t < 0.75 ? 1 : (1 - t) * 4)
                    .scaleEffect(reduceMotion ? 1 : 0.8 + min(t * 4, 1) * 0.3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, Spacing.xl)
            .padding(.bottom, bottomInset + Spacing.l)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var bubbles: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(party.bubbles) { m in
                HStack(spacing: Spacing.s) {
                    ProfileAvatar(symbol: m.symbol, color: m.color, size: 20)
                    (Text(m.name).font(.caption.weight(.bold)) + Text("  " + m.text).font(.caption))
                        .lineLimit(2)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .playerNoticeSurface()
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, Spacing.l)
        .padding(.bottom, bottomInset + Spacing.s)
        .onTapGesture { party.chatOpen = true }
    }

    private var awayBanner: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text("You stepped away").font(.callout.weight(.semibold))
                if let at = party.room.partyPlayhead {
                    Text("The party is at \(TogetherRoom.timecode(at.position))").font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            Button("Catch Up") { party.catchUp() }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.small)
                .accessibilityIdentifier("partyCatchUp")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .playerNoticeSurface()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, topInset)
        .padding(.trailing, Spacing.l)
        .transition(.opacity)
    }
}

/// A small card in the middle: "Finding your copy…", "Joining…".
struct PartyStatusCard: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Palette.brandBright)
            Text(text).font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .playerNoticeSurface()
    }
}

/// Before it starts: who's ready, the code, and the host's Start · 3, 2, 1.
struct PartyLobby: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app
    let party: WatchParty
    @State private var inviteOpen = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            if let n = party.countdown {
                Text("\(n)")
                    .font(.system(size: 120, weight: .black, design: .rounded))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.snappy(reduceMotion), value: n)
                    .accessibilityLabel("Starting in \(n)")
            } else {
                card
            }
        }
    }

    private var card: some View {
        VStack(spacing: Spacing.m) {
            VStack(spacing: 4) {
                Text("Watch Party · \(party.title?.name ?? "Getting ready")").font(.headline)
                Text(party.isHost ? "Starts when you press Start. Others can still join later."
                                  : "Starts when \(party.room.hostParticipant?.name ?? "the host") presses Start.")
                    .font(.caption).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
            }
            Text(party.invite.code.description).font(.system(size: 22, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(party.people) { p in
                    HStack(spacing: Spacing.s) {
                        ProfileAvatar(symbol: p.symbol, color: p.color, size: 26)
                        Text(p.id == party.room.me.id ? "You" : p.name).font(.callout.weight(.semibold))
                        Spacer(minLength: Spacing.m)
                        readiness(p)
                    }
                }
            }
            .frame(maxWidth: 300)
            HStack(spacing: Spacing.s) {
                Button("Share Invite…") { inviteOpen = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .popover(isPresented: $inviteOpen) { PartyInviteCard(party: party) }
                if party.isHost {
                    Button("Start · 3, 2, 1") { party.startTogether() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(party.room.title == nil)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("partyStart")
                } else {
                    Button("Leave") { Task { await app.leaveParty() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: 400)
        .playerNoticeSurface()
        .padding(Spacing.l)
    }

    @ViewBuilder private func readiness(_ p: TogetherParticipant) -> some View {
        let host = p.id == party.room.settings?.host
        switch p.status {
        case .ready where p.match == .sameLength:
            Text("Same-length copy" + (host ? " · host" : "")).font(.caption).foregroundStyle(Palette.warning)
        case .ready:
            Label("Ready" + (host ? " · host" : ""), systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(Palette.brandBright)
        case .loading:
            Text("Loading…").font(.caption).foregroundStyle(Palette.textSecondary)
        case .buffering:
            Text("Buffering…").font(.caption).foregroundStyle(Palette.textSecondary)
        case .unavailable(let why):
            Text(why.isEmpty ? "Can't play it" : why).font(.caption).foregroundStyle(Palette.warning).lineLimit(1)
        }
    }
}

/// The episode ended: the next one for everyone in ten seconds (anyone can
/// cancel), and the party's queue under it.
struct PartyUpNextCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let party: WatchParty
    let next: TogetherUpNext

    var body: some View {
        VStack(spacing: Spacing.s) {
            if let n = party.upNextRemaining {
                Text("\(n)").font(.system(size: 44, weight: .black, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true)).animation(Motion.snappy(reduceMotion), value: n)
            } else {
                ProgressView().controlSize(.small).tint(Palette.brandBright)
            }
            Text("\(next.item.subtitle ?? next.item.name) for everyone").font(.headline)
            Text(party.upNextRemaining == nil ? "Finding everyone's copy…" : "Everyone's copy is ready")
                .font(.caption).foregroundStyle(Palette.textSecondary)
            HStack(spacing: Spacing.s) {
                Button("Play Now") { party.room.playUpNextNow() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Cancel") { party.room.cancelUpNext() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            PartyQueueList(party: party)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: 380)
        .playerNoticeSurface()
    }
}

/// "Up next in the party": the host's list (the host can take things off it).
struct PartyQueueList: View {
    let party: WatchParty

    var body: some View {
        let queue = (party.room.settings?.queue ?? []).filter { $0.id != party.room.upNext?.item.id }
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("UP NEXT IN THE PARTY").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(Palette.textTertiary)
                ForEach(Array(queue.enumerated()), id: \.element.id) { i, item in
                    HStack {
                        Text("\(i + 1). \(item.name)" + (item.subtitle.map { " \($0)" } ?? "")).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        if party.isHost {
                            Button { party.room.dequeue(item.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(Palette.textSecondary)
                                .accessibilityLabel("Remove \(item.name) from the queue")
                        }
                    }
                }
                if party.isHost {
                    Text("Add more with a title's Play ▾ or right-click › Add to Party Queue.")
                        .font(.caption2).foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(Spacing.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }
}

/// 💬 in the player's top bar, with a count of unread messages.
struct PartyChatButton: View {
    let party: WatchParty

    var body: some View {
        PlayerIconButton(symbol: party.chatOpen ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right",
                         label: party.chatOpen ? "Close Party Chat" : "Open Party Chat") {
            party.chatOpen.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if party.unread > 0, !party.chatOpen {
                Text("\(min(party.unread, 99))").font(.caption2.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Palette.brand, in: Capsule())
                    .offset(x: -2, y: 4)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("partyChat")
        .help("Party chat (⌘/)")
    }
}

// MARK: - Joining

/// Join a Party…: type a code or paste a link, or confirm an invite that was
/// opened, as your profile (or another name for this party).
struct PartyJoinSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: PartyJoinRequest
    @State private var typed = ""
    @State private var name = ""
    @State private var changingName = false
    @State private var joining = false

    private var invite: TogetherInvite? {
        if let invite = request.invite { return invite }
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let invite = TogetherInvite(url: url) { return invite }
        return TogetherJoinCode(text).flatMap { app.invite(forCode: $0) }
    }

    var body: some View {
        let profile = app.currentProfile
        // The app's usual form sheet (as Add Plex Server and Fix Match are), not a card drawn inside a sheet.
        NavigationStack {
            Form {
                if let opened = request.invite {
                    Section {
                        LabeledContent("Code", value: opened.code.description)
                        LabeledContent("Server", value: opened.projectURL.host() ?? String(localized: "A Bluebox server"))
                    }
                } else {
                    Section {
                        TextField("Code or Invite Link", text: $typed)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                            .accessibilityIdentifier("partyCode")
                    } footer: {
                        if !typed.isEmpty, invite == nil {
                            Text(TogetherJoinCode(typed) != nil ? "A code works only with a Bluebox server set up in Settings › Account & Sync. Ask for the link instead."
                                                                : "That isn't a party code or invite link.")
                                .foregroundStyle(Palette.warning)
                        } else {
                            Text("Paste the invite link, or type the code if the party is on your Bluebox server.")
                        }
                    }
                }
                Section {
                    HStack(spacing: Spacing.m) {
                        ProfileAvatar(symbol: profile.symbol, color: profile.color, size: 30)
                        if changingName {
                            TextField("Name for this party", text: $name)
                        } else {
                            Text(verbatim: profile.name)
                        }
                    }
                    Button(changingName ? "Use My Profile Name" : "Change for this party") {
                        if changingName { changingName = false } else { name = profile.name; changingName = true }
                    }
                } header: {
                    Text("Join As")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(request.invite == nil ? "Join a Party" : "Join the Watch Party")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard let invite else { return }
                        joining = true
                        Task {
                            await app.joinParty(invite, as: changingName ? name : nil)
                            dismiss()
                        }
                    } label: {
                        if joining { ProgressView().controlSize(.small) } else { Text("Join") }
                    }
                    .disabled(invite == nil || joining)
                    .accessibilityIdentifier("partyJoin")
                }
            }
        }
        .frame(minWidth: 380, minHeight: 320)
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

/// While joining, before the player opens: "Joining…", "Waiting for the host…", "Finding your copy…".
struct PartyJoiningBanner: View {
    @Environment(AppModel.self) private var app
    let party: WatchParty

    var body: some View {
        HStack(spacing: Spacing.m) {
            ProgressView().controlSize(.small).tint(Palette.brandBright)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.callout.weight(.semibold))
                Text("Watch Party · \(party.invite.code.description)").font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Button("Leave") { Task { await app.leaveParty() } }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .playerNoticeSurface()
        .padding(Spacing.l)
    }

    private var headline: String {
        switch party.phase {
        case .connecting:
            if case .failed(let why) = party.room.connection { return why }
            return party.room.connection == .connected ? "Waiting for the host to pick something…" : "Joining the party…"
        case .finding(let name): return "Finding your copy of \(name)…"
        case .watching: return "Opening…"
        case .ended(let why): return why
        }
    }
}

/// On the app's root: the Join a Party sheet, and the joining banner while a
/// party has no player open yet.
struct PartyHost: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            .overlay(alignment: .bottom) {
                if let party = app.party, app.activePlayer == nil {
                    PartyJoiningBanner(party: party).transition(Motion.slide(from: .bottom, reduceMotion))
                }
            }
            .animation(Motion.snappy(reduceMotion), value: app.party == nil || app.activePlayer != nil)
            .sheet(item: $app.partyJoin) { request in PartyJoinSheet(request: request).environment(app) }
    }
}
