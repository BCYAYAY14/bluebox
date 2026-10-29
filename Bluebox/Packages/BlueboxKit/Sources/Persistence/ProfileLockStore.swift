import CryptoKit
import Foundation

/// Profile PINs (4 digits), kept in the Keychain and never in preferences.
/// Only a salted SHA-256 of the PIN is stored, under one Keychain item per
/// profile on this device.
public struct ProfileLockStore: Sendable {
    public static let pinLength = 4
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) { self.secrets = secrets }

    static func account(_ profileID: String) -> String { "profile.pin.\(profileID)" }

    /// True for exactly four ASCII digits.
    public static func isValid(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public func hasPIN(_ profileID: String) -> Bool {
        ((try? secrets.read(Self.account(profileID))) ?? nil) != nil
    }

    /// Sets, or with nil removes, a profile's PIN.
    public func setPIN(_ pin: String?, for profileID: String) throws {
        guard let pin else { try secrets.write(nil, for: Self.account(profileID)); return }
        guard Self.isValid(pin) else { throw ProfileLockError.invalidPIN }
        let salt = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        try secrets.write("v1:\(Data(salt).base64EncodedString()):\(Self.digest(pin, salt: salt))", for: Self.account(profileID))
    }

    /// True when `pin` is the profile's PIN, or when it has none.
    public func verify(_ pin: String, for profileID: String) -> Bool {
        guard let stored = (try? secrets.read(Self.account(profileID))) ?? nil else { return true }
        let parts = stored.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1", let salt = Data(base64Encoded: String(parts[1])) else { return false }
        return Self.digest(pin, salt: Array(salt)) == parts[2]
    }

    static func digest(_ pin: String, salt: [UInt8]) -> String {
        SHA256.hash(data: Data(salt) + Data(pin.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ProfileLockError: Error, Equatable, LocalizedError {
    case invalidPIN
    public var errorDescription: String? { "A PIN is four digits." }
}
