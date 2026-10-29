import Foundation

// Bluebox's Mac updater: an XPC service outside the app's sandbox, so it can
// mount the new DMG and put the new Bluebox.app where the old one is, which
// the sandboxed app itself isn't allowed to do. Only Bluebox can reach it
// (embedded services answer their own app alone).

/// Must match `BlueboxUpdaterProtocol` in Features/UpdateInstaller.swift.
@objc(BlueboxUpdaterProtocol) protocol BlueboxUpdaterProtocol {
    /// Downloads `dmg`, checks the Bluebox.app inside it, and swaps it in for
    /// the app at `appPath`. Then, once process `pid` has quit, opens the new
    /// one. Replies nil, or what went wrong.
    func install(dmg: URL, appPath: String, relaunchAfter pid: Int32, reply: @escaping (String?) -> Void)
}

final class Updater: NSObject, BlueboxUpdaterProtocol {
    static let bundleID = "app.bluebox.Bluebox.mac"

    func install(dmg: URL, appPath: String, relaunchAfter pid: Int32, reply: @escaping (String?) -> Void) {
        nonisolated(unsafe) let reply = reply
        Task {
            do {
                try await Self.install(dmg: dmg, app: URL(fileURLWithPath: appPath))
                Self.relaunch(appPath, after: pid)
                reply(nil)
            } catch {
                reply((error as? UpdateError)?.message ?? error.localizedDescription)
            }
        }
    }

    struct UpdateError: Error { let message: String }

    static func install(dmg: URL, app: URL) async throws {
        // Only Bluebox's own releases, from GitHub.
        guard dmg.scheme == "https", dmg.host() == "github.com",
              dmg.path().hasPrefix("/BCYAYAY14/bluebox/releases/") else {
            throw UpdateError(message: "That download isn't one of Bluebox's releases.")
        }
        guard app.pathExtension == "app", FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw UpdateError(message: "Bluebox can't replace itself in \(app.deletingLastPathComponent().path). Move it to Applications, or download the update from GitHub.")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "BlueboxUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (downloaded, response) = try await URLSession.shared.download(from: dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(message: "The download failed.") }
        let image = work.appending(path: "Bluebox.dmg")
        try fm.moveItem(at: downloaded, to: image)

        let mount = work.appending(path: "mount", directoryHint: .isDirectory)
        try run("/usr/bin/hdiutil", "attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path)
        defer { try? run("/usr/bin/hdiutil", "detach", mount.path, "-force") }

        let new = mount.appending(path: "Bluebox.app")
        guard let info = Bundle(url: new)?.infoDictionary, info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError(message: "The download doesn't hold Bluebox.")
        }
        // Copied next to the old app first, so the swap is a rename on one disk.
        let staged = app.deletingLastPathComponent().appending(path: ".Bluebox-update.app")
        try? fm.removeItem(at: staged)
        try run("/usr/bin/ditto", new.path, staged.path)
        try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path)
        do {
            _ = try fm.replaceItemAt(app, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw UpdateError(message: "Bluebox couldn't replace itself: \(error.localizedDescription)")
        }
    }

    /// A shell outside this service that waits for Bluebox to quit, then opens
    /// it again. Its own session, so it outlives the service.
    static func relaunch(_ appPath: String, after pid: Int32) {
        let script = "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.3; done; /usr/bin/open \"$1\""
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID))
        let args = ["/bin/sh", "-c", script, String(pid), appPath]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var child: pid_t = 0
        posix_spawn(&child, "/bin/sh", nil, &attrs, &argv, environ)
        argv.forEach { free($0) }
        posix_spawnattr_destroy(&attrs)
    }

    @discardableResult
    static func run(_ tool: String, _ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw UpdateError(message: "\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: BlueboxUpdaterProtocol.self)
        connection.exportedObject = Updater()
        connection.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
