import Domain
import Testing

@Suite struct SafeNumberTests {
    @Test func wholeNumbersInRange() {
        #expect(SafeNumber.int64(42.0) == 42)
        #expect(SafeNumber.int64(-7.0) == -7)
        #expect(SafeNumber.int64(0.0, in: 0...10) == 0)
        #expect(SafeNumber.int64(10.0, in: 0...10) == 10)
        #expect(SafeNumber.int64(11.0, in: 0...10) == nil)
        #expect(SafeNumber.int64(-1.0, in: 0...10) == nil)
    }

    @Test func hugeAndNonFiniteValuesAreNilNotATrap() {
        #expect(SafeNumber.int64(1e30) == nil)
        #expect(SafeNumber.int64(-1e30) == nil)
        #expect(SafeNumber.int64(.infinity) == nil)
        #expect(SafeNumber.int64(-.infinity) == nil)
        #expect(SafeNumber.int64(.nan) == nil)
        #expect(SafeNumber.int64(Double.greatestFiniteMagnitude) == nil)
        // 2^63 is one past Int64.max; -2^63 is exactly Int64.min.
        #expect(SafeNumber.int64(9_223_372_036_854_775_808.0) == nil)
        #expect(SafeNumber.int64(-9_223_372_036_854_775_808.0) == .min)
    }

    @Test func fractionsAreRefusedUnlessRoundingIsAsked() {
        #expect(SafeNumber.int64(2.5) == nil)
        #expect(SafeNumber.int64(-0.5) == nil)
        #expect(SafeNumber.int64(roundingDown: 2.9) == 2)
        #expect(SafeNumber.int64(roundingDown: 1e30) == nil)
        #expect(SafeNumber.int64(roundingDown: .nan) == nil)
    }

    @Test func strings() {
        #expect(SafeNumber.int64("42") == 42)
        #expect(SafeNumber.int64(" 42 ") == 42)
        #expect(SafeNumber.int64("42.0") == 42)
        #expect(SafeNumber.int64("4.2e1") == 42)
        #expect(SafeNumber.int64("9223372036854775807") == .max)
        #expect(SafeNumber.int64("9223372036854775808") == nil)
        #expect(SafeNumber.int64("1e30") == nil)
        #expect(SafeNumber.int64("nan") == nil)
        #expect(SafeNumber.int64("inf") == nil)
        #expect(SafeNumber.int64("2.5") == nil)
        #expect(SafeNumber.int64("twelve") == nil)
        #expect(SafeNumber.int64("") == nil)
        #expect(SafeNumber.int64("50", in: 0...10) == nil)
    }
}
