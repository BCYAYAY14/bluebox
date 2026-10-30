import CryptoKit
import Foundation

/// Profile PINs (4 digits), kept in the Keychain and never in preferences.
/// Only a salted SHA-256 of the PIN is stored, under one Keychain item per
/// profile on this device. A Keychain that can't be read counts as locked:
/// a child shouldn't get in because the Keychain is misbehaving.
public struct ProfileLockStore: Sendable {
    public static let pinLength = 4
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) { self.secrets = secrets }

    static func account(_ profileID: String) -> String { "profile.pin.\(profileID)" }

    /// True for exactly four ASCII digits.
    public static func isValid(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// True when the profile has a PIN, or when the Keychain can't say.
    public func hasPIN(_ profileID: String) -> Bool {
        guard case .success(let stored) = stored(profileID) else { return true }
        return stored != nil
    }

    /// Sets, or with nil removes, a profile's PIN.
    public func setPIN(_ pin: String?, for profileID: String) throws {
        guard let pin else { try secrets.write(nil, for: Self.account(profileID)); return }
        guard Self.isValid(pin) else { throw ProfileLockError.invalidPIN }
        let salt = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        try secrets.write("v1:\(Data(salt).base64EncodedString()):\(Self.digest(pin, salt: salt))", for: Self.account(profileID))
    }

    /// True when `pin` is the profile's PIN, or when it has none. False when
    /// the Keychain can't be read.
    public func verify(_ pin: String, for profileID: String) -> Bool {
        guard case .success(let read) = stored(profileID) else { return false }
        guard let stored = read else { return true }
        let parts = stored.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1", let salt = Data(base64Encoded: String(parts[1])) else { return false }
        return Self.digest(pin, salt: Array(salt)) == parts[2]
    }

    /// The stored hash, nil for no PIN, or the Keychain's error
    /// (`try?` would fold an error into "no PIN").
    private func stored(_ profileID: String) -> Result<String?, any Error> {
        Result { try secrets.read(Self.account(profileID)) }
    }

    static func digest(_ pin: String, salt: [UInt8]) -> String {
        SHA256.hash(data: Data(salt) + Data(pin.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ProfileLockError: Error, Equatable, LocalizedError {
    case invalidPIN
    public var errorDescription: String? { "A PIN is four digits." }
}
