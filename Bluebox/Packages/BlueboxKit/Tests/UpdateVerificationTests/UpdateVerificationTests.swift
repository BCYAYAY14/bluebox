#if os(macOS)
import CryptoKit
import Foundation
import Testing
import UpdateVerification

/// The Mac updater's checks on a new Bluebox.app (security review BB-02).
@Suite(.serialized) struct UpdateVerificationTests {
    let work: URL

    init() throws {
        work = FileManager.default.temporaryDirectory.appending(path: "UpdateVerificationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    /// A minimal app bundle with a real (compiled) executable.
    private func makeApp(_ name: String, bundleID: String = UpdateVerification.bundleID, version: String = "1.0.5") throws -> URL {
        let app = work.appending(path: "\(name).app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "T",
                                    "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let source = work.appending(path: "\(name).c")
        try "int main(void){return 0;}".write(to: source, atomically: true, encoding: .utf8)
        try run("/usr/bin/xcrun", "clang", "-o", macOS.appending(path: "T").path, source.path)
        return app
    }

    @discardableResult
    private func run(_ tool: String, _ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw UpdateVerification.Failure(message: "\(tool) failed: \(text)") }
        return text
    }

    /// The SHA-1 of a code-signing identity on this Mac, if it has one.
    private func identity() -> String? {
        guard let out = try? run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning") else { return nil }
        return out.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ")
            guard parts.count > 1, parts[1].count == 40 else { return nil }
            return String(parts[1])
        }.first
    }

    @Test func requirementPinsIdentifierAndLeaf() {
        #expect(UpdateVerification.requirement()
            == #"identifier "app.bluebox.Bluebox.mac" and certificate leaf = H"8da48ee5df68786c0b40a9d6689453892a1f75d0""#)
    }

    @Test func unsignedAndAdHocAppsAreRefused() throws {
        let unsigned = try makeApp("Unsigned")
        // clang ad-hoc signs the executable on Apple silicon, but the bundle isn't sealed.
        #expect(throws: UpdateVerification.Failure.self) { try UpdateVerification.verifySignature(of: unsigned) }
        let adHoc = try makeApp("AdHoc")
        try run("/usr/bin/codesign", "-f", "-s", "-", adHoc.path)
        #expect(throws: UpdateVerification.Failure.self) { try UpdateVerification.verifySignature(of: adHoc) }
    }

    @Test func onlyThePinnedCertificateAndIdentifierPass() throws {
        guard let sha1 = identity() else { return }  // no signing identity on this Mac
        let app = try makeApp("Signed")
        try run("/usr/bin/codesign", "-f", "-s", sha1, app.path)
        try UpdateVerification.verifySignature(of: app, leafSHA1: sha1)
        if sha1.uppercased() != UpdateVerification.pinnedLeafSHA1 {
            // Another developer's (or an attacker's) valid signature isn't Bluebox's.
            #expect(throws: UpdateVerification.Failure.self) { try UpdateVerification.verifySignature(of: app) }
        }
        let other = try makeApp("OtherID", bundleID: "com.example.NotBluebox")
        try run("/usr/bin/codesign", "-f", "-s", sha1, other.path)
        #expect(throws: UpdateVerification.Failure.self) { try UpdateVerification.verifySignature(of: other, leafSHA1: sha1) }
    }

    @Test func aModifiedAppIsRefused() throws {
        guard let sha1 = identity() else { return }
        let app = try makeApp("Tampered")
        try run("/usr/bin/codesign", "-f", "-s", sha1, app.path)
        try Data("payload".utf8).write(to: app.appending(path: "Contents/MacOS/extra"))
        #expect(throws: UpdateVerification.Failure.self) { try UpdateVerification.verifySignature(of: app, leafSHA1: sha1) }
    }

    @Test func digest() throws {
        let file = work.appending(path: "Bluebox.dmg")
        try Data("dmg bytes".utf8).write(to: file)
        let hex = SHA256.hash(data: Data("dmg bytes".utf8)).map { String(format: "%02x", $0) }.joined()
        try UpdateVerification.verifyDigest(of: file, expected: "sha256:" + hex)
        try UpdateVerification.verifyDigest(of: file, expected: "sha256:" + hex.uppercased())
        try UpdateVerification.verifyDigest(of: file, expected: nil)
        #expect(throws: UpdateVerification.Failure.self) {
            try UpdateVerification.verifyDigest(of: file, expected: "sha256:" + String(repeating: "0", count: 64))
        }
        #expect(throws: UpdateVerification.Failure.self) { try UpdateVerification.verifyDigest(of: file, expected: "sha256:zz") }
    }

    @Test func olderVersionsAreRefused() throws {
        let installed = try makeApp("Installed", version: "1.0.14")
        try UpdateVerification.checkNotOlder(try makeApp("Newer", version: "1.0.15"), than: installed)
        try UpdateVerification.checkNotOlder(try makeApp("Same", version: "1.0.14"), than: installed)
        try UpdateVerification.checkNotOlder(try makeApp("Dev", version: "dev"), than: installed)
        #expect(throws: UpdateVerification.Failure.self) {
            try UpdateVerification.checkNotOlder(try makeApp("Older", version: "1.0.9"), than: installed)
        }
    }
}
#endif
