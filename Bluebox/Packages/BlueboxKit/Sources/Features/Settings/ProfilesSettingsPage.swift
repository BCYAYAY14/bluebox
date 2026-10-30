import DesignSystem
import Domain
import SwiftUI

/// Settings › Profiles: everyone sharing this library. Each row pushes the
/// profile's editor page (`SettingsRoute`), inside Settings' own stack.
struct ProfilesSection: View {
    @Environment(AppModel.self) private var app
    /// A locked profile chosen with Switch: its PIN first.
    @State private var unlocking: Profile?

    var body: some View {
        Section {
            ForEach(app.profiles) { p in
                HStack(spacing: Spacing.m) {
                    NavigationLink(value: SettingsRoute.editProfile(p.id)) {
                        HStack(spacing: Spacing.m) {
                            ProfileBadge(symbol: p.symbol, color: p.color, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(p.name).foregroundStyle(Palette.textPrimary)
                                    if app.isLocked(p.id) {
                                        Image(systemName: "lock.fill").font(.caption2.weight(.bold)).foregroundStyle(Palette.textSecondary)
                                            .accessibilityLabel("Locked")
                                    }
                                }
                                if let detail = detail(p) {
                                    Text(detail).font(.caption).foregroundStyle(Palette.textSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsRowPressStyle())
                    .accessibilityIdentifier("editProfile.\(p.name)")
                    if p.id == app.currentProfileID {
                        Text("Watching").font(.subheadline).foregroundStyle(Palette.textSecondary)
                    } else {
                        Button("Switch") {
                            if app.isLocked(p.id) { unlocking = p } else { Task { await app.switchProfile(to: p.id) } }
                        }
                        .buttonStyle(TextActionStyle())
                    }
                    SettingsChevron()
                }
                .settingsRow(p.id == app.currentProfileID ? "Edit Profile" : "Profile \(p.id)")
            }
            NavigationLink(value: SettingsRoute.newProfile) {
                Text("Add Profile…").foregroundStyle(Palette.brandBright).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SettingsRowPressStyle())
            .accessibilityIdentifier("addProfileButton")
            .settingsRow("Add Profile")
            .sheet(item: $unlocking) { p in
                ProfilePINEntry(profile: p, done: { _ in
                    unlocking = nil
                    Task { await app.switchProfile(to: p.id) }
                }, cancel: { unlocking = nil })
                #if os(macOS)
                .frame(minWidth: 380, minHeight: 460)
                #endif
                .background(Palette.background.ignoresSafeArea())
                .preferredColorScheme(.dark)
                .environment(app)
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("Each profile has its own My List, progress, languages and subtitle style. Sources and downloads are shared. Trakt syncs with the first profile. Maturity limits and PINs stay on this device.")
        }
    }

    private func detail(_ p: Profile) -> String? {
        var parts: [String] = []
        if p.isKids { parts.append("Kids") } else if p.maturity != .all { parts.append(p.maturity.title) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Editor

/// Create and edit a profile on a full page (not a form sheet): a big avatar
/// with a symbol gallery and colour swatches, a tall name field, then
/// Maturity, Kids profile, Profile lock and Languages and Playback. Changes
/// to an existing profile save as you go.
struct ProfileEditorPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    /// nil: a new profile.
    let profile: Profile?
    /// Called after a new profile is created (the picker's sheet closes).
    var created: (() -> Void)?

    @State private var name = ""
    @State private var symbol = Profile.symbols[0]
    @State private var color = 0
    @State private var maturity: MaturityRating = .all
    @State private var isKids = false
    /// nil: the default for the profile (off for Kids).
    @State private var allowsUnrated: Bool?
    @State private var loaded = false
    @State private var confirmingDelete = false
    /// A locked profile that isn't the one watching asks for its PIN before editing.
    @State private var unlocked = false
    @FocusState private var nameFocused: Bool

    private var wide: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }

    private var isNew: Bool { profile == nil }

    var body: some View {
        Group {
            if app.settingsNeedsPIN {
                // A restricted profile watching: its PIN before editing itself or adding
                // a profile (Settings asks too; this covers the Mac picker's Add Profile).
                SettingsPINGate { dismiss() }
            } else if let profile, app.isLocked(profile.id), profile.id != app.currentProfileID, !unlocked {
                ProfilePINEntry(profile: profile, done: { _ in unlocked = true }, cancel: { dismiss() })
            } else {
                editor
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .foregroundStyle(Palette.textPrimary)
        .navigationTitle(isNew ? "Add Profile" : "Edit Profile")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: load)
        .confirmationDialog("Delete this profile?", isPresented: $confirmingDelete) {
            Button("Delete Profile", role: .destructive) {
                if let profile { Task { await app.deleteProfile(profile.id); dismiss() } }
            }
        } message: {
            Text("Its My List and watch progress are removed from all your devices.")
        }
        .accessibilityIdentifier("profileEditor")
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Text(isNew ? "Add Profile" : "Edit Profile")
                    .font(SettingsMetrics.titleFont)
                    .accessibilityAddTraits(.isHeader)
                if wide {
                    HStack(alignment: .top, spacing: Spacing.xxl) {
                        avatarColumn.frame(width: 232)
                        VStack(alignment: .leading, spacing: Spacing.l) {
                            nameField
                            rows
                        }
                        .padding(.top, Spacing.xxl)
                    }
                } else {
                    avatarColumn
                    nameField
                    rows
                }
            }
            .frame(maxWidth: SettingsMetrics.maxWidth, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.pageInset)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.xxxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .toggleStyle(SettingsSwitchStyle())
        .textFieldStyle(SettingsFieldStyle())
    }

    // MARK: Avatar

    private var avatarColumn: some View {
        VStack(alignment: wide ? .center : .leading, spacing: Spacing.l) {
            ProfileBadge(symbol: symbol, color: color, size: wide ? 120 : 96)
                .overlay(alignment: .bottom) {
                    if isKids {
                        Text("KIDS").font(.system(size: 11, weight: .black)).tracking(0.6).foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.white, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(.bottom, 9)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.smooth(duration: 0.2), value: color)
                .accessibilityIdentifier("editorAvatar")
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: wide ? 4 : 8)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Profile.symbols, id: \.self) { s in
                    Button { symbol = s; saveIfExisting() } label: {
                        Image(systemName: s)
                            .font(.system(size: wide ? 18 : 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: wide ? 44 : 38)
                            .background(s == symbol ? Palette.elevated : Palette.surface,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(s == symbol ? 1 : 0), lineWidth: 2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityLabel(ProfileEditorPage.symbolName(s))
                    .accessibilityAddTraits(s == symbol ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Symbol")
            let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
            LazyVGrid(columns: swatchColumns, spacing: 8) {
                ForEach(Palette.profileColors.indices, id: \.self) { i in
                    Button { color = i; saveIfExisting() } label: {
                        Circle().fill(Palette.profileColor(i))
                            .frame(width: 22, height: 22)
                            .padding(3)
                            .overlay(Circle().strokeBorder(.white.opacity(i == color ? 1 : 0), lineWidth: 2))
                            .frame(minWidth: 30, minHeight: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Colour \(i + 1)")
                    .accessibilityAddTraits(i == color ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Colour")
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(.caption).foregroundStyle(Palette.textTertiary)
            TextField("Name", text: $name)
                .font(.title3.weight(.semibold))
                .focused($nameFocused)
                .onSubmit { if isNew { create() } }
                .onChange(of: name) { saveIfExisting() }
                .accessibilityIdentifier("profileNameField")
        }
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.edge))
        .textFieldStyle(.plain)
    }

    // MARK: Rows

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            row {
                Text("Maturity")
                Spacer(minLength: Spacing.m)
                maturityChips
            }
            hairline
            row {
                Toggle("Kids profile", isOn: $isKids)
                    .onChange(of: isKids) { saveIfExisting() }
                    .accessibilityIdentifier("kidsToggle")
            }
            if isKids || maturity != .all {
                hairline
                row {
                    Toggle("Allow Unrated Titles", isOn: Binding(get: { allowsUnrated ?? !isKids },
                                                                 set: { allowsUnrated = $0; saveIfExisting() }))
                        .accessibilityIdentifier("allowUnratedToggle")
                }
                .settingsRow("Allow Unrated Titles")
            }
            Text(maturityFooter)
                .font(.footnote).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.s)
            if let profile {
                hairline
                NavigationLink { ProfileLockPage(profile: profile) } label: {
                    row {
                        Text("Profile Lock")
                        Spacer(minLength: Spacing.m)
                        Text(app.isLocked(profile.id) ? "4-digit PIN" : "Off").foregroundStyle(Palette.textSecondary)
                        SettingsChevron()
                    }
                }
                .buttonStyle(SettingsRowPressStyle())
                .accessibilityIdentifier("profileLockRow")
                hairline
                NavigationLink { ProfileLanguagesPage(profileID: profile.id) } label: {
                    row {
                        Text("Languages and Playback")
                        Spacer(minLength: Spacing.m)
                        Text(app.profileSettingsSummary(profile.id)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        SettingsChevron()
                    }
                }
                .buttonStyle(SettingsRowPressStyle())
                if !profile.isDefault {
                    hairline
                    Button("Delete Profile", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.destructive)
                        .font(SettingsMetrics.rowFont.weight(.semibold))
                        .frame(minHeight: SettingsMetrics.rowHeight)
                        .padding(.top, Spacing.s)
                }
            } else {
                Button { create() } label: {
                    Text("Add Profile").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
                .padding(.top, Spacing.l)
                .accessibilityIdentifier("createProfile")
            }
        }
        .font(SettingsMetrics.rowFont)
    }

    private var maturityChips: some View {
        HStack(spacing: 4) {
            ForEach(MaturityRating.ordered) { m in
                let allowed = !isKids || m <= .age7
                let on = (isKids ? min(maturity, .age7) : maturity) == m
                Button { maturity = m; saveIfExisting() } label: {
                    Text(m.title)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(on ? Palette.brand : Palette.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? .clear : Palette.edge))
                        .foregroundStyle(on ? .white : Palette.textSecondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(!allowed)
                .accessibilityLabel("Maturity \(m.title)")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("maturity.\(m.title)")
            }
        }
    }

    private var maturityFooter: String {
        let limit = isKids ? min(maturity, .age7) : maturity
        let base = isKids
            ? "Kids profiles show titles rated 7+ or under, and family titles where there's no rating."
            : limit.summary
        guard limit != .all || isKids else { return base }
        let unrated = (allowsUnrated ?? !isKids)
            ? " Ratings come from TMDB; titles without one still play."
            : " Ratings come from TMDB; titles without one don\u{2019}t play."
        let ownPIN = profile.map { app.isLocked($0.id) } == true
        let grownUpPIN = isKids && app.profiles.contains { !$0.isKids && app.isLocked($0.id) }
        let lock = ownPIN || grownUpPIN
            ? " Settings asks for a PIN while this profile is watching."
            : " Add a Profile Lock so Settings asks for a PIN while this profile is watching."
        return base + unrated + lock
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Spacing.m) { content() }
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowHeight, alignment: .leading)
            .padding(.vertical, SettingsMetrics.rowPadding / 2)
            .contentShape(Rectangle())
    }

    private var hairline: some View { Rectangle().fill(SettingsMetrics.hairline).frame(height: 1) }

    // MARK: Saving

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let profile {
            name = profile.name; symbol = profile.symbol; color = profile.color
            maturity = profile.maturity; isKids = profile.isKids; allowsUnrated = profile.allowsUnrated
        } else {
            // A different colour from the profiles that exist, if there is one.
            let used = Set(app.profiles.map(\.color))
            color = Palette.profileColors.indices.first { !used.contains($0) } ?? app.profiles.count % Palette.profileColors.count
            symbol = Profile.symbols[app.profiles.count % Profile.symbols.count]
            nameFocused = true
        }
    }

    private func saveIfExisting() {
        guard loaded, let id = profile?.id, var p = app.profiles.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard p.name != trimmed || p.symbol != symbol || p.color != color || p.maturity != maturity || p.isKids != isKids
                || p.allowsUnrated != allowsUnrated else { return }
        p.name = trimmed; p.symbol = symbol; p.color = color; p.maturity = maturity; p.isKids = isKids
        p.allowsUnrated = allowsUnrated
        app.updateProfile(p)
    }

    private func create() {
        guard isNew, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.addProfile(name: name, symbol: symbol, color: color, maturity: maturity, isKids: isKids, allowsUnrated: allowsUnrated)
        if let created { created() } else { dismiss() }
    }

    /// "pawprint.fill" → "Pawprint".
    static func symbolName(_ symbol: String) -> String {
        (symbol.split(separator: ".").first.map(String.init) ?? symbol).capitalizedSentence
    }
}

/// Profile Lock: set, change or remove the 4-digit PIN. Kept in the Keychain.
struct ProfileLockPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    @State private var choosing = false
    @State private var error: String?

    var body: some View {
        Group {
            if choosing || !app.isLocked(profile.id) {
                ProfilePINEntry(profile: profile, mode: .set, done: { pin in
                    do {
                        try app.setPIN(pin, for: profile.id)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }, cancel: { if app.isLocked(profile.id) { choosing = false } else { dismiss() } })
            } else {
                SettingsForm(title: "Profile Lock") {
                    Section {
                        Button("Change PIN") { choosing = true }
                            .accessibilityIdentifier("changePIN")
                        Button("Turn Off Profile Lock", role: .destructive) {
                            try? app.setPIN(nil, for: profile.id)
                            dismiss()
                        }
                        .accessibilityIdentifier("removePIN")
                    } footer: {
                        Text(error ?? "\(profile.name)\u{2019}s profile asks for this PIN when it's opened on this device. It's kept in the Keychain.")
                    }
                }
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Profile Lock")
    }
}

/// The editor in a sheet: Add Profile in the Mac's "Who's watching?" (iPhone
/// and iPad push it inside Settings instead), and debug screenshots.
struct ProfileEditorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let profile: Profile?

    var body: some View {
        NavigationStack {
            ProfileEditorPage(profile: profile, created: { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(profile == nil ? "Cancel" : "Done") { dismiss() } }
                }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 560)
        #endif
        .preferredColorScheme(.dark)
        .tint(Palette.brand)
        .blueboxMenuHost()
    }
}
