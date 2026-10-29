import DesignSystem
import Domain
import SwiftUI

/// Full-screen "Who's watching?", shown at launch when there's more than one
/// profile and from the profile menu. Big avatars with names, as on Netflix:
/// a white ring on the last profile (Return opens it), arrow keys and Tab move
/// it, a padlock and PIN entry for locked profiles, and a KIDS mark. Esc keeps
/// the current profile when the picker was opened from the menu.
struct ProfilePickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.profileSwitchFlight) private var flight
    /// Opened from the profile menu: a close button keeps the current profile.
    /// At launch it's a gate, so there's none.
    var canClose = false
    /// Opens straight on this profile's PIN (a shortcut chose a locked profile).
    var pinFor: String?
    let onDone: () -> Void
    let manage: () -> Void
    /// iPhone and iPad: Add Profile pushes inside Settings' stack. nil (Mac):
    /// the editor opens in a sheet over the picker.
    var addProfile: (() -> Void)?
    @State private var appeared = false
    @State private var chosen: String?
    @State private var adding = false
    @State private var focusIndex = 0
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var unlocking: Profile?
    @FocusState private var gridFocused: Bool

    private var profiles: [Profile] { app.profiles.filter { !$0.isRemoved } }

    var body: some View {
        Group {
            if let unlocking {
                ProfilePINEntry(profile: unlocking, done: { _ in commit(unlocking) },
                                cancel: { withAnimation(Motion.standard(reduceMotion)) { self.unlocking = nil } })
                    .transition(.opacity)
            } else {
                grid
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            BlueboxWordmark(size: 26).padding(.top, Spacing.s)
        }
        .overlay(alignment: .topTrailing) {
            if canClose && unlocking == nil {
                Button(action: onDone) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Palette.elevated))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(.cancelAction)
                .padding(.trailing, Spacing.s)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("profilePickerClose")
                .opacity(appeared ? 1 : 0)
            }
        }
        .background {
            ZStack {
                Palette.background
                RadialGradient(colors: [Palette.navyGlow.opacity(0.75), .clear], center: .init(x: 0.5, y: 0.35),
                               startRadius: 0, endRadius: 520)
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(.white)
        .onAppear {
            focusIndex = profiles.firstIndex { $0.id == app.currentProfileID } ?? 0
            if let pinFor, let p = profiles.first(where: { $0.id == pinFor }) { unlocking = p }
            withAnimation(Motion.spatial(reduceMotion).delay(0.05)) { appeared = true }
        }
        #if DEBUG
        .task {
            // Screenshots of the switch: `-auto-switch-to Mia` picks her after a moment.
            guard let name = AppModel.reviewValue("-auto-switch-to"), let p = profiles.first(where: { $0.name == name }) else { return }
            try? await Task.sleep(for: .seconds(2.5))
            focusIndex = profiles.firstIndex(of: p) ?? focusIndex
            choose(p)
        }
        #endif
        .selectionHaptic(chosen)
        .sheet(isPresented: $adding) { ProfileEditorSheet(profile: nil) }
        .accessibilityIdentifier("profilePicker")
    }

    private var grid: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 600
            let size: CGFloat = compact ? 104 : min(150, max(116, geo.size.width / 9))
            ScrollView {
                VStack(spacing: compact ? Spacing.xxl : Spacing.xxxl) {
                    Text("Who's Watching?")
                        .font(compact ? .title2.weight(.semibold) : .system(size: 44, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                        .opacity(appeared ? 1 : 0)
                    tiles(size: size, compact: compact)
                    VStack(spacing: Spacing.m) {
                        Button(action: manage) {
                            Label("Manage Profiles", systemImage: "pencil")
                        }
                        .buttonStyle(OutlinedButtonStyle())
                        .accessibilityIdentifier("manageProfiles")
                        #if os(macOS)
                        Text(hint).font(.caption).foregroundStyle(Palette.textTertiary)
                        #endif
                    }
                    .opacity(appeared ? 1 : 0)
                }
                // Centred in the screen, a little above the middle, as on Netflix.
                .padding(.vertical, Spacing.xxxl)
                .frame(maxWidth: .infinity, minHeight: geo.size.height * 0.9)
                .padding(.horizontal, Spacing.l)
            }
            .scrollBounceBehavior(.basedOnSize)
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onAppear { gridFocused = true }
            .onKeyPress(.leftArrow) { move(-1); return .handled }
            .onKeyPress(.rightArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(compact ? -2 : -1); return .handled }
            .onKeyPress(.downArrow) { move(compact ? 2 : 1); return .handled }
            .onKeyPress(.tab, phases: .down) { press in move(press.modifiers.contains(.shift) ? -1 : 1); return .handled }
            .onKeyPress(.return) {
                guard profiles.indices.contains(focusIndex) else { return .ignored }
                choose(profiles[focusIndex])
                return .handled
            }
            .onKeyPress(.escape) {
                guard canClose else { return .ignored }
                onDone()
                return .handled
            }
        }
    }

    #if os(macOS)
    private var hint: String {
        let keys = profiles.count > 1 ? " · ⌃⌘1–\(min(profiles.count, ProfileShortcuts.count)) switch from anywhere" : ""
        return canClose ? "Esc keeps \(app.currentProfile.name)\(keys)" : "Return opens the profile with the ring\(keys)"
    }
    #endif

    private func move(_ delta: Int) {
        guard !profiles.isEmpty else { return }
        focusIndex = min(max(focusIndex + delta, 0), profiles.count - 1)
    }

    private func tiles(size: CGFloat, compact: Bool) -> some View {
        let columns = compact ? [GridItem(.fixed(size + 24), spacing: Spacing.xl), GridItem(.fixed(size + 24), spacing: Spacing.xl)]
                              : [GridItem(.adaptive(minimum: size + 24, maximum: size + 40), spacing: Spacing.xl)]
        let profiles = self.profiles
        return LazyVGrid(columns: columns, spacing: Spacing.xl) {
            ForEach(Array(profiles.enumerated()), id: \.element.id) { i, p in
                ProfileTile(profile: p, size: size, isCurrent: p.id == app.currentProfileID,
                            hasRing: i == focusIndex, isChosen: chosen == p.id, isLocked: app.isLocked(p.id),
                            reportFrame: { tileFrames[p.id] = $0 }) {
                    focusIndex = i
                    choose(p)
                }
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.9)
                .animation(Motion.spatial(reduceMotion).delay(Double(i) * 0.05), value: appeared)
            }
            if profiles.count < 5 {
                AddProfileTile(size: size) { if let addProfile { addProfile() } else { adding = true } }
                    .opacity(appeared ? 1 : 0)
                    .animation(Motion.spatial(reduceMotion).delay(Double(profiles.count) * 0.05), value: appeared)
            }
        }
        .frame(maxWidth: compact ? nil : (size + 64) * CGFloat(min(profiles.count + 1, 5)))
    }

    private func choose(_ p: Profile) {
        if p.id == app.currentProfileID && canClose { onDone(); return }
        if app.isLocked(p.id) && p.id != app.currentProfileID {
            withAnimation(Motion.standard(reduceMotion)) { unlocking = p }
            return
        }
        commit(p)
    }

    /// The chosen avatar flies to the top bar as the picker fades; the library
    /// switches underneath at the same time (no wait).
    private func commit(_ p: Profile) {
        chosen = p.id
        // From the PIN screen the tile isn't on screen: the picker just fades.
        if !reduceMotion, unlocking == nil, let frame = tileFrames[p.id] {
            flight?.fly(symbol: p.symbol, color: p.color, from: frame)
        }
        Task {
            await app.switchProfile(to: p.id)
            onDone()
        }
    }
}

private struct ProfileTile: View {
    let profile: Profile
    let size: CGFloat
    let isCurrent: Bool
    /// The last profile, or where the arrow keys have moved: Return opens it.
    let hasRing: Bool
    let isChosen: Bool
    let isLocked: Bool
    /// The avatar square's frame (global), where the switch animation starts.
    let reportFrame: (CGRect) -> Void
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.m) {
                ProfileBadge(symbol: profile.symbol, color: profile.color, size: size)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { reportFrame($0) }
                    .overlay(alignment: .bottom) {
                        if profile.isKids {
                            Text("KIDS")
                                .font(.system(size: max(10, size * 0.09), weight: .black))
                                .tracking(0.6)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.white, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .padding(.bottom, size * 0.07)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: size * 0.12 + 4, style: .continuous)
                        .strokeBorder(.white.opacity(hasRing || isChosen ? 1 : hovering ? 0.6 : 0), lineWidth: 3)
                        .padding(-5))
                    .scaleEffect(isChosen && !reduceMotion ? 1.06 : (hovering && !reduceMotion ? 1.04 : 1))
                    .shadow(color: Palette.brand.opacity(hovering || isChosen ? 0.45 : 0), radius: 18)
                    .frame(width: size, height: size)
                HStack(spacing: 5) {
                    if isLocked {
                        Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold))
                    }
                    Text(profile.name).lineLimit(1)
                }
                .font(.headline)
                .foregroundStyle(hovering || hasRing || isCurrent ? Palette.textPrimary : Palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(haptic: true))
        .onHover { hovering = $0 }
        .animation(Motion.snappy(reduceMotion), value: hovering)
        .animation(Motion.snappy(reduceMotion), value: hasRing)
        .animation(Motion.snappy(reduceMotion), value: isChosen)
        .accessibilityLabel(profile.name)
        .accessibilityValue([isCurrent ? "Current profile" : nil, isLocked ? "Locked" : nil, profile.isKids ? "Kids" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("profile.\(profile.name)")
    }
}

private struct AddProfileTile: View {
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.m) {
                RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .overlay(Image(systemName: "plus").font(.system(size: size * 0.32, weight: .regular))
                        .foregroundStyle(.white.opacity(hovering ? 1 : 0.7)))
                    .frame(width: size, height: size)
                Text("Add Profile").font(.headline).foregroundStyle(Palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityIdentifier("addProfileTile")
    }
}

/// An outlined, text-coloured button ("Manage Profiles").
struct OutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .tracking(1)
            .padding(.horizontal, Spacing.xl)
            .frame(minHeight: 44)
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(.white.opacity(configuration.isPressed ? 0.9 : 0.5), lineWidth: 1))
            .foregroundStyle(configuration.isPressed ? .white : Palette.textSecondary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
