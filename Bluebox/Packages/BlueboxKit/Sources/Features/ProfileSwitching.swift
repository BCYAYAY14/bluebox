import DesignSystem
import Domain
import Persistence
import SwiftUI
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

// MARK: - The switch animation

/// Switching profiles from "Who's watching?": the chosen avatar flies into
/// the top bar's avatar slot while the picker fades and Home rebuilds under
/// it. About 0.45 s on a smooth spring with no bounce; with Reduce Motion
/// it's a plain cross-fade and nothing flies.
@Observable @MainActor
final class ProfileSwitchFlight {
    struct Flight: Equatable {
        let symbol: String
        let color: Int
        /// Where the tile was (global coordinates).
        let from: CGRect
    }

    static let duration: Double = {
        #if DEBUG
        // Screenshots of the motion: `-slow-profile-switch` runs it ten times slower.
        if ProcessInfo.processInfo.arguments.contains("-slow-profile-switch") { return 4.5 }
        #endif
        return 0.45
    }()
    static var animation: Animation { .smooth(duration: duration, extraBounce: 0) }

    /// The visible top-bar avatar (global coordinates), reported by `ProfileMenu`.
    var slot: CGRect = .zero
    private(set) var flight: Flight?
    private(set) var landed = false
    /// Home's rows fade back in after a switch.
    private(set) var contentHidden = false

    /// Starts the flight from `from` to the avatar slot. Returns at once.
    func fly(symbol: String, color: Int, from: CGRect) {
        guard slot != .zero, from != .zero else { return }
        flight = Flight(symbol: symbol, color: color, from: from)
        landed = false
        Task { @MainActor in
            await Task.yield()  // draw it at the tile first
            withAnimation(Self.animation) { self.landed = true }
            try? await Task.sleep(for: .seconds(Self.duration))
            withAnimation(.easeOut(duration: 0.12)) { self.flight = nil }
        }
    }

    /// Home fades out briefly while the new profile's library loads, then back in.
    func rebuild(reduceMotion: Bool, _ work: @escaping @MainActor () async -> Void) async {
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.12)) { contentHidden = true }
        await work()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : Self.animation) { contentHidden = false }
    }
}

/// Draws the flying avatar over everything.
struct ProfileFlightLayer: View {
    let flight: ProfileSwitchFlight

    var body: some View {
        GeometryReader { proxy in
            if let f = flight.flight {
                let origin = proxy.frame(in: .global).origin
                let target = flight.landed ? flight.slot : f.from
                let scale = f.from.width > 0 ? target.width / f.from.width : 1
                ProfileBadge(symbol: f.symbol, color: f.color, size: f.from.width)
                    .overlay(RoundedRectangle(cornerRadius: f.from.width * 0.12, style: .continuous)
                        .strokeBorder(.white, lineWidth: flight.landed ? 0 : 3))
                    .scaleEffect(scale)
                    .position(x: target.midX - origin.x, y: target.midY - origin.y)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    @Entry var profileSwitchFlight: ProfileSwitchFlight? = nil
}

// MARK: - PIN entry

/// "Enter Sam's PIN": the avatar, four digit boxes, and a keypad on iPhone
/// and iPad (a keyboard types the digits everywhere). Also sets a new PIN,
/// asking for it twice.
struct ProfilePINEntry: View {
    enum Mode: Equatable {
        /// Unlocks the profile.
        case unlock
        /// Chooses a new PIN (twice).
        case set
    }

    let profile: Profile
    var mode: Mode = .unlock
    /// Unlock: the PIN was right. Set: the new PIN, confirmed.
    let done: (String) -> Void
    let cancel: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var digits = ""
    @State private var firstEntry: String?
    @State private var message: String?
    @State private var shake = 0
    @State private var failures = 0
    @State private var lockedUntil: Date?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Spacing.xl)
            ProfileBadge(symbol: profile.symbol, color: profile.color, size: 84)
            Text(title)
                .font(.title2.weight(.bold))
                .padding(.top, Spacing.l)
                .accessibilityAddTraits(.isHeader)
            Text(message ?? subtitle)
                .font(.subheadline)
                .foregroundStyle(message == nil ? Palette.textSecondary : Palette.destructive)
                .padding(.top, Spacing.xs)
                .accessibilityIdentifier("pinMessage")
            boxes
                .padding(.top, Spacing.xl)
                .modifier(Shake(amount: reduceMotion ? 0 : 8, shakes: CGFloat(shake)))
            HStack(spacing: Spacing.l) {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("pinCancel")
                if mode == .unlock {
                    Button("Forgot PIN?") { forgot() }
                        .accessibilityIdentifier("pinForgot")
                }
            }
            .buttonStyle(TextActionStyle())
            .padding(.top, Spacing.l)
            Spacer(minLength: Spacing.xl)
            #if os(iOS)
            keypad
            #endif
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(Palette.textPrimary)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            if press.key == .delete || press.characters == "\u{7F}" { backspace(); return .handled }
            if let c = press.characters.first, c.isASCII, c.isNumber { type(c); return .handled }
            return .ignored
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pinEntry")
    }

    private var title: String {
        switch mode {
        case .unlock: "Enter \(profile.name)\u{2019}s PIN"
        case .set: firstEntry == nil ? "Choose a PIN" : "Enter It Again"
        }
    }

    private var subtitle: String {
        switch mode {
        case .unlock: "to open \(profile.name)\u{2019}s profile"
        case .set: "Four digits, asked for when someone opens \(profile.name)."
        }
    }

    private var boxes: some View {
        HStack(spacing: 12) {
            ForEach(0..<ProfileLockStore.pinLength, id: \.self) { i in
                let filled = i < digits.count
                let current = i == digits.count
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.surface)
                    .frame(width: 52, height: 62)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(current ? Color.white : Color.white.opacity(0.15), lineWidth: current ? 2 : 1))
                    .overlay(Circle().fill(.white).frame(width: 12, height: 12).opacity(filled ? 1 : 0))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("PIN")
        .accessibilityValue("\(digits.count) of 4 digits entered")
    }

    #if os(iOS)
    private var keypad: some View {
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                if k.isEmpty {
                    Color.clear.frame(height: 52)
                } else {
                    Button {
                        if k == "⌫" { backspace() } else if let c = k.first { type(c) }
                    } label: {
                        Group {
                            if k == "⌫" { Image(systemName: "delete.left") } else { Text(k) }
                        }
                        .font(.title2.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(haptic: true))
                    .accessibilityLabel(k == "⌫" ? "Delete" : k)
                    .accessibilityIdentifier("pinKey.\(k)")
                }
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: 420)
        .background(Palette.chrome)
    }
    #endif

    private func type(_ c: Character) {
        if let until = lockedUntil, until > .now {
            message = "Too many tries. Wait \(Int(until.timeIntervalSinceNow.rounded(.up))) seconds."
            return
        }
        guard digits.count < ProfileLockStore.pinLength else { return }
        digits.append(c)
        if digits.count == ProfileLockStore.pinLength { finish() }
    }

    private func backspace() { if !digits.isEmpty { digits.removeLast() } }

    private func finish() {
        let pin = digits
        switch mode {
        case .unlock:
            if app.verifyPIN(pin, for: profile.id) {
                done(pin)
            } else {
                failures += 1
                if failures >= 5 {
                    lockedUntil = Date.now.addingTimeInterval(30)
                    failures = 0
                    reject("Too many tries. Wait 30 seconds.")
                } else {
                    reject("That PIN isn\u{2019}t right.")
                }
            }
        case .set:
            if let first = firstEntry {
                if first == pin { done(pin) } else { firstEntry = nil; reject("Those didn\u{2019}t match. Try again.") }
            } else {
                firstEntry = pin
                message = nil
                digits = ""
            }
        }
    }

    private func reject(_ text: String) {
        message = text
        withAnimation(.linear(duration: 0.3)) { shake += 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            digits = ""
        }
    }

    /// The device owner (Touch ID, Face ID or the device password) can take
    /// the lock off and open the profile.
    private func forgot() {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "Remove the lock from Manage Profiles on a profile you can open."
            return
        }
        let id = profile.id
        Task { @MainActor in
            do {
                let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                          localizedReason: "remove the PIN from \(profile.name)\u{2019}s profile")
                guard ok else { return }
                try? app.setPIN(nil, for: id)
                done("")
            } catch {
                message = "The PIN is still on."
            }
        }
        #endif
    }
}

/// A short horizontal shake for a wrong PIN.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(shakes * .pi * 4), y: 0))
    }
}

// MARK: - Shared tag

/// "Shared" beside things every profile sees the same (Downloads), once
/// there's more than one profile.
struct SharedTag: View {
    var body: some View {
        Text("Shared")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.edge))
            .help("Every profile on this device sees these")
            .accessibilityLabel("Shared with every profile")
            .accessibilityIdentifier("sharedTag")
    }
}
