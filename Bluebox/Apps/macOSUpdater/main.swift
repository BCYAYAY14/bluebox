import Foundation
import OSLog

let log = Logger(subsystem: "app.bluebox", category: "updater")

// Bluebox's Mac updater: an XPC service outside the app's sandbox, so it can
// mount the new DMG and put the new Bluebox.app where the old one is, which
// the sandboxed app itself isn't allowed to do. Only Bluebox can reach it
// (embedded services answer their own app alone).

/// Must match `BlueboxUpdaterProtocol` in Features/UpdateInstaller.swift.
@objc(BlueboxUpdaterProtocol) protocol BlueboxUpdaterProtocol {
    /// Mounts `dmgFile` (downloaded by the app), checks the Bluebox.app inside
    /// it, and swaps it in for the app at `appPath`. Then, once process `pid`
    /// has quit, opens the new one. Replies nil, or what went wrong.
    func install(dmgFile: URL, appPath: String, relaunchAfter pid: Int32, reply: @escaping (String?) -> Void)
}

final class Updater: NSObject, BlueboxUpdaterProtocol {
    static let bundleID = "app.bluebox.Bluebox.mac"

    func install(dmgFile: URL, appPath: String, relaunchAfter pid: Int32, reply: @escaping (String?) -> Void) {
        nonisolated(unsafe) let reply = reply
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Self.install(dmg: dmgFile, app: URL(fileURLWithPath: appPath))
                Self.relaunch(appPath, after: pid)
                log.notice("installed; relaunching after \(pid, privacy: .public) quits")
                reply(nil)
            } catch {
                let message = (error as? UpdateError)?.message ?? error.localizedDescription
                log.error("failed: \(message, privacy: .public)")
                reply(message)
            }
        }
    }

    struct UpdateError: Error { let message: String }

    static func install(dmg: URL, app: URL) throws {
        let fm = FileManager.default
        log.notice("installing \(dmg.path, privacy: .public) over \(app.path, privacy: .public)")
        guard dmg.isFileURL, fm.fileExists(atPath: dmg.path) else { throw UpdateError(message: "The download is missing.") }
        let folder = app.deletingLastPathComponent()
        guard app.pathExtension == "app", fm.isWritableFile(atPath: folder.path) else {
            throw UpdateError(message: "Bluebox can't replace itself in \(folder.path). Move it to Applications, or download the update from GitHub.")
        }
        let work = fm.temporaryDirectory.appending(path: "BlueboxUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // The app's own downloads are quarantined; this copy is checked below instead.
        try? run("/usr/bin/xattr", "-d", "com.apple.quarantine", dmg.path)
        let mount = work.appending(path: "mount", directoryHint: .isDirectory)
        log.notice("mounting")
        try run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-noverify",
                "-mountpoint", mount.path, timeout: 90)
        defer { try? run("/usr/bin/hdiutil", "detach", mount.path, "-force", timeout: 30) }

        let new = mount.appending(path: "Bluebox.app")
        guard let info = Bundle(url: new)?.infoDictionary, info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError(message: "The download doesn't hold Bluebox.")
        }
        // Copied next to the old app first, so the swap is a rename on one disk.
        let staged = folder.appending(path: ".Bluebox-update.app")
        try? fm.removeItem(at: staged)
        log.notice("copying")
        try run("/usr/bin/ditto", new.path, staged.path, timeout: 120)
        try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path)
        log.notice("swapping")
        do {
            _ = try fm.replaceItemAt(app, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? (error as NSError).code
            if code == Int(EPERM) || code == NSFileWriteNoPermissionError {
                throw UpdateError(message: "macOS didn't let Bluebox replace itself. Turn on Bluebox in System Settings › Privacy & Security › App Management, then try again. Nothing was changed.")
            }
            throw UpdateError(message: "Bluebox couldn't replace itself: \(error.localizedDescription) Nothing was changed.")
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
    static func run(_ tool: String, _ args: String..., timeout: TimeInterval = 30) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        // A tool that hangs (a mount waiting on something) is stopped, not waited on forever.
        let watchdog = DispatchWorkItem { if p.isRunning { log.error("\(tool, privacy: .public) timed out"); p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
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
