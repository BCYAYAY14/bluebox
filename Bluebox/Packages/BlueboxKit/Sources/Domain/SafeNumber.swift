import Foundation

/// Whole numbers read from data Bluebox doesn't control (add-on answers,
/// metadata, release names). `Int64(someDouble)` traps when the value is out
/// of range, so a stray `1e30` would end the process; these return nil instead.
public enum SafeNumber {
    /// The value as a whole number when it is finite, has no fractional part
    /// and lies in `range`; nil otherwise. A fraction is malformed for an index
    /// or a byte count, so `2.5` is refused rather than rounded.
    public static func int64(_ value: Double, in range: ClosedRange<Int64> = .min ... .max) -> Int64? {
        // Int64(exactly:) is nil for NaN, infinities, fractions and anything past ±2^63.
        guard let whole = Int64(exactly: value), range.contains(whole) else { return nil }
        return whole
    }

    /// A string holding a whole number (`"42"`) or one written as a decimal
    /// (`"42.0"`, `"4.2e1"`), under the same rules.
    public static func int64(_ text: String, in range: ClosedRange<Int64> = .min ... .max) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let exact = Int64(trimmed) { return range.contains(exact) ? exact : nil }
        guard let value = Double(trimmed) else { return nil }
        return int64(value, in: range)
    }

    /// `value` rounded down, when it is finite and the result lies in `range`.
    /// For quantities where a fraction is normal (1.5 GB in bytes).
    public static func int64(roundingDown value: Double, in range: ClosedRange<Int64> = .min ... .max) -> Int64? {
        guard value.isFinite else { return nil }
        return int64(value.rounded(.down), in: range)
    }
}
