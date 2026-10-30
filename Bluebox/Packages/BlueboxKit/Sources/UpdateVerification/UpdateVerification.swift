#if os(macOS)
import CryptoKit
import Foundation
import Security

/// Checks a new Bluebox.app before the Mac updater (Apps/macOSUpdater) swaps
/// it in: its code signature must be valid and made with the "Bluebox Open
/// Source" certificate every public release is signed with (scripts/publish.sh),
/// so a DMG swapped on GitHub, in transit or on disk is refused even when its
/// bundle ID is right. Foundation and Security only, so the unsandboxed
/// updater links nothing else.
public enum UpdateVerification {
    public static let bundleID = "app.bluebox.Bluebox.mac"
    /// SHA-1 of the "Bluebox Open Source" certificate (self-signed, so it is
    /// both the leaf and the anchor). Changing it means every installed copy
    /// refuses the next update: only change it together with a release that
    /// users download by hand.
    public static let pinnedLeafSHA1 = "8DA48EE5DF68786C0B40A9D6689453892A1F75D0"

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
        public init(message: String) { self.message = message }
    }

    /// The designated requirement the new app must meet.
    public static func requirement(bundleID: String = bundleID, leafSHA1: String = pinnedLeafSHA1) -> String {
        "identifier \"\(bundleID)\" and certificate leaf = H\"\(leafSHA1.lowercased())\""
    }

    /// Throws unless `app` is validly signed (every architecture, nested code
    /// included, strict) by the pinned certificate with the given identifier.
    public static func verifySignature(of app: URL, bundleID: String = bundleID, leafSHA1: String = pinnedLeafSHA1) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure(message: "The download doesn't hold a signed app.")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(self.requirement(bundleID: bundleID, leafSHA1: leafSHA1) as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw Failure(message: "The updater's signing requirement is invalid.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "status \(status)"
            if status == errSecCSReqFailed {
                throw Failure(message: "The download isn't signed by Bluebox's release certificate, so it wasn't installed. (\(detail))")
            }
            throw Failure(message: "The download's code signature is broken, so it wasn't installed. (\(detail))")
        }
    }

    /// Throws when `expected` (GitHub's `sha256:<hex>` asset digest) is given
    /// and doesn't match the file. Nil skips the check (an older release
    /// without digests).
    public static func verifyDigest(of file: URL, expected: String?) throws {
        guard let expected else { return }
        let want = expected.lowercased().replacingOccurrences(of: "sha256:", with: "")
        guard want.count == 64, want.allSatisfy(\.isHexDigit) else {
            throw Failure(message: "GitHub's checksum for the download is unreadable.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let got = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard got == want else { throw Failure(message: "The download doesn't match GitHub's checksum, so it wasn't installed.") }
    }

    /// Throws when the new app's version is older than the installed one's, so
    /// an old (validly signed) release can't be pushed over a newer one. A
    /// version that isn't numbers ("dev") is never compared.
    public static func checkNotOlder(_ new: URL, than installed: URL) throws {
        func version(_ app: URL) -> [Int]? {
            guard let text = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
            let parts = text.split(separator: ".").map { Int($0) }
            return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
        }
        guard let a = version(new), let b = version(installed) else { return }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y {
                if x < y { throw Failure(message: "The download is an older Bluebox than this one, so it wasn't installed.") }
                return
            }
        }
    }
}
#endif
