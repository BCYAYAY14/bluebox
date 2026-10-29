import Foundation

/// A person sharing this library, with their own My List and watch progress.
/// Every install has the default profile; others are added in Settings.
public struct Profile: Codable, Sendable, Hashable, Identifiable {
    public static let defaultID = "default"
    /// The avatar gallery. The first eight are the original set (stored
    /// profiles may use any of them); the rest were added with the editor page.
    public static let symbols = [
        "person.fill", "star.fill", "heart.fill", "moon.fill", "leaf.fill", "flame.fill", "pawprint.fill", "gamecontroller.fill",
        "bolt.fill", "sun.max.fill", "cloud.fill", "snowflake", "music.note", "film.fill", "book.fill", "sparkles",
        "crown.fill", "airplane", "bicycle", "tortoise.fill", "hare.fill", "fish.fill", "bird.fill", "ladybug.fill",
    ]

    public let id: String
    public var name: String
    public var symbol: String
    /// Index into the app's profile color palette.
    public var color: Int
    public var isRemoved: Bool
    public var updatedAt: Date
    /// The oldest certification this profile may see. Kept on this device
    /// (the sync schema has no column for it), like the PIN.
    public var maturity: MaturityRating
    /// A Kids profile: marked in the picker, capped at 7+, and limited to
    /// family titles where the certification isn't known.
    public var isKids: Bool

    public init(id: String, name: String, symbol: String = "person.fill", color: Int = 0, isRemoved: Bool = false,
                updatedAt: Date, maturity: MaturityRating = .all, isKids: Bool = false) {
        self.id = id; self.name = name; self.symbol = symbol; self.color = color
        self.isRemoved = isRemoved; self.updatedAt = updatedAt
        self.maturity = maturity; self.isKids = isKids
    }

    public var isDefault: Bool { id == Self.defaultID }

    /// The limit in force: a Kids profile never goes above 7+.
    public var effectiveMaturity: MaturityRating { isKids ? min(maturity, .age7) : maturity }

    /// What catalogue and search rows may show for this profile; nil shows everything.
    public var contentFilter: ContentFilter? {
        let limit = effectiveMaturity
        guard limit != .all || isKids else { return nil }
        return ContentFilter(maximum: limit, familyOnlyWhenUnrated: isKids)
    }

    public static func makeDefault(name: String = "Me") -> Profile {
        Profile(id: defaultID, name: name, updatedAt: Date(timeIntervalSince1970: 0))
    }

    private enum CodingKeys: String, CodingKey { case id, name, symbol, color, isRemoved, updatedAt, maturity, isKids }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "person.fill"
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        isRemoved = try c.decodeIfPresent(Bool.self, forKey: .isRemoved) ?? false
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        // Added with Kids profiles: older stored profiles have neither.
        maturity = try c.decodeIfPresent(MaturityRating.self, forKey: .maturity) ?? .all
        isKids = try c.decodeIfPresent(Bool.self, forKey: .isKids) ?? false
    }
}

public enum ProfileMerge {
    /// Same rule as the server: newer wins; on a tie, present beats removed.
    public static func incomingWins(_ incoming: Profile, over existing: Profile?) -> Bool {
        guard let existing else { return true }
        if incoming.updatedAt != existing.updatedAt { return incoming.updatedAt > existing.updatedAt }
        return existing.isRemoved && !incoming.isRemoved
    }
}

/// ⌃⌘1–4 (and the Profiles menu): the nth profile in the order the picker shows them.
public enum ProfileShortcuts {
    public static let count = 4

    /// The profile for digit 1…4, or nil when there's no such profile.
    public static func profile(forDigit digit: Int, in profiles: [Profile]) -> Profile? {
        let active = profiles.filter { !$0.isRemoved }
        guard (1...count).contains(digit), active.indices.contains(digit - 1) else { return nil }
        return active[digit - 1]
    }

    /// The digit that switches to `id`, if it has one.
    public static func digit(for id: String, in profiles: [Profile]) -> Int? {
        let active = profiles.filter { !$0.isRemoved }
        guard let i = active.firstIndex(where: { $0.id == id }), i < count else { return nil }
        return i + 1
    }
}

// MARK: - Maturity

/// Age limits for a profile, drawn from TMDB certifications: All, 7+, 13+, 16+, 18+.
public enum MaturityRating: Int, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case age7 = 7, age13 = 13, age16 = 16, age18 = 18
    /// No limit.
    case all = 99

    public var id: Int { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The order the editor shows them in.
    public static let ordered: [MaturityRating] = [.all, .age7, .age13, .age16, .age18]

    public var title: String {
        switch self {
        case .all: "All"
        case .age7: "7+"
        case .age13: "13+"
        case .age16: "16+"
        case .age18: "18+"
        }
    }

    /// What the limit lets through, for the editor's footer.
    public var summary: String {
        switch self {
        case .all: "Every title, whatever its rating."
        case .age7: "Rated for 7 and under, such as G, PG and TV‑Y7."
        case .age13: "Rated up to 13, such as PG‑13. TV‑14 and R are hidden."
        case .age16: "Rated up to 16, such as TV‑14 and 15. R and TV‑MA are hidden."
        case .age18: "Everything rated 18 or under."
        }
    }

    /// The minimum age a certification asks for, or nil when it isn't one
    /// Bluebox knows. Covers US film and TV ratings, the UK, Germany,
    /// France, Australia and the plain age numbers most countries use.
    public static func minimumAge(forCertification raw: String) -> Int? {
        let c = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .replacingOccurrences(of: "‑", with: "-").replacingOccurrences(of: "_", with: "-")
        guard !c.isEmpty, c != "NR", c != "NOT RATED", c != "UNRATED" else { return nil }
        let table: [String: Int] = [
            // US film
            "G": 0, "PG": 7, "PG-13": 13, "R": 17, "NC-17": 18, "X": 18,
            // US TV
            "TV-Y": 0, "TV-Y7": 7, "TV-Y7-FV": 7, "TV-G": 0, "TV-PG": 7, "TV-14": 14, "TV-MA": 17,
            // UK
            "U": 0, "12A": 12, "R18": 18,
            // France, Germany, Netherlands, Brazil, Spain
            "TP": 0, "FSK 0": 0, "FSK 6": 6, "FSK 12": 12, "FSK 16": 16, "FSK 18": 18, "AL": 0, "L": 0,
            // Australia
            "E": 0, "M": 15, "MA15+": 15, "MA 15+": 15, "R18+": 18, "R 18+": 18, "X18+": 18,
        ]
        if let age = table[c] { return age }
        // "12", "16+", "-12", "APTA 7", "K-15"… : the number is the age.
        let digits = c.filter(\.isNumber)
        if let n = Int(digits), (1...21).contains(n) { return n }
        return nil
    }
}

/// Which titles a profile's rows may show.
public struct ContentFilter: Sendable, Hashable {
    public var maximum: MaturityRating
    /// Kids: a title with no known certification shows only when its genres
    /// are Family, Animation or Kids.
    public var familyOnlyWhenUnrated: Bool

    /// TMDB genre IDs that count as family viewing (movie and TV lists).
    public static let familyGenres: Set<Int> = [10751, 16, 10762]

    public init(maximum: MaturityRating, familyOnlyWhenUnrated: Bool = false) {
        self.maximum = maximum; self.familyOnlyWhenUnrated = familyOnlyWhenUnrated
    }

    /// Whether `title` may show, given its certification if one is known.
    public func allows(_ title: Title, certification: String?) -> Bool {
        if let certification, let age = MaturityRating.minimumAge(forCertification: certification) {
            return maximum == .all || age <= maximum.rawValue
        }
        guard familyOnlyWhenUnrated else { return true }
        return !Self.familyGenres.isDisjoint(with: title.genreIDs)
    }

    /// Whether a title page with this certification may play.
    public func allows(certification: String?) -> Bool {
        guard let certification, let age = MaturityRating.minimumAge(forCertification: certification) else { return true }
        return maximum == .all || age <= maximum.rawValue
    }
}
