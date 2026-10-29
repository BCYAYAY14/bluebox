import Foundation

/// A Postgres `timestamptz` held as whole microseconds since 1970, so cursor
/// values round-trip exactly (a `Date` can't represent every microsecond).
public struct SyncTimestamp: Hashable, Comparable, Codable, Sendable {
    public var microseconds: Int64

    public init(microseconds: Int64) { self.microseconds = microseconds }
    public init(_ date: Date) { microseconds = date.millisecondsSince1970 * 1000 }

    public static func < (a: Self, b: Self) -> Bool { a.microseconds < b.microseconds }

    /// The nearest millisecond, which is the precision Bluebox writes.
    public var date: Date {
        let ms = microseconds >= 0 ? (microseconds + 500) / 1000 : (microseconds - 500) / 1000
        return Date(millisecondsSince1970: ms)
    }

    public func adding(seconds: Int64) -> Self { Self(microseconds: microseconds + seconds * 1_000_000) }

    /// Parses PostgREST output such as `2026-10-27T01:02:03.123456+00:00`,
    /// `2026-10-27T01:02:03Z` or `2026-10-27 01:02:03.5+11`.
    public init?(iso string: String) {
        let s = Array(string.utf8)
        var i = 0
        func number(_ digits: Int) -> Int64? {
            guard i + digits <= s.count else { return nil }
            var v: Int64 = 0
            for _ in 0..<digits {
                let c = s[i]
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int64(c - 48); i += 1
            }
            return v
        }
        func expect(_ c: UInt8) -> Bool {
            guard i < s.count, s[i] == c else { return false }
            i += 1; return true
        }
        guard let y = number(4), expect(45), let mo = number(2), expect(45), let d = number(2),
              i < s.count, s[i] == 84 || s[i] == 32 else { return nil }  // 'T' or ' '
        i += 1
        guard let h = number(2), expect(58), let mi = number(2), expect(58), let sec = number(2) else { return nil }
        var micros: Int64 = 0
        if i < s.count, s[i] == 46 {  // '.'
            i += 1
            var digits = 0
            while i < s.count, s[i] >= 48, s[i] <= 57 {
                if digits < 6 { micros = micros * 10 + Int64(s[i] - 48) }
                digits += 1; i += 1
            }
            guard digits > 0 else { return nil }
            if digits < 6 { for _ in digits..<6 { micros *= 10 } }
        }
        var offset: Int64 = 0
        if i < s.count {
            if s[i] == 90 { i += 1 }  // 'Z'
            else if s[i] == 43 || s[i] == 45 {  // '+' / '-'
                let sign: Int64 = s[i] == 43 ? 1 : -1
                i += 1
                guard let oh = number(2) else { return nil }
                var om: Int64 = 0
                if i < s.count {
                    _ = expect(58)
                    guard let m = number(2) else { return nil }
                    om = m
                }
                offset = sign * (oh * 3600 + om * 60)
            } else { return nil }
        }
        guard i == s.count, (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61 else { return nil }
        let days = Self.daysFromCivil(y, mo, d)
        let seconds = days * 86_400 + h * 3600 + mi * 60 + sec - offset
        microseconds = seconds * 1_000_000 + micros
    }

    /// `YYYY-MM-DDTHH:MM:SS.ffffffZ`, UTC.
    public var iso: String {
        let secs = microseconds >= 0 ? microseconds / 1_000_000 : (microseconds - 999_999) / 1_000_000
        let frac = microseconds - secs * 1_000_000
        let days = secs >= 0 ? secs / 86_400 : (secs - 86_399) / 86_400
        let rem = secs - days * 86_400
        let (y, m, d) = Self.civilFromDays(days)
        func pad(_ v: Int64, _ n: Int) -> String {
            let t = String(v); return String(repeating: "0", count: max(0, n - t.count)) + t
        }
        return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(rem / 3600, 2)):\(pad(rem % 3600 / 60, 2)):\(pad(rem % 60, 2)).\(pad(frac, 6))Z"
    }

    // Howard Hinnant's civil-date algorithms (proleptic Gregorian, UTC).
    static func daysFromCivil(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ z0: Int64) -> (Int64, Int64, Int64) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, m, d)
    }
}
