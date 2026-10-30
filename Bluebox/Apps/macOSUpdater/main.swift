import Foundation
import OSLog
import UpdateVerification

let log = Logger(subsystem: "app.bluebox", category: "updater")

// Bluebox's Mac updater: an XPC service outside the app's sandbox, so it can
// mount the new DMG and put the new Bluebox.app where the old one is, which
// the sandboxed app itself isn't allowed to do. Only Bluebox can reach it
// (embedded services answer their own app alone).

/// Must match `BlueboxUpdaterProtocol` in Features/UpdateInstaller.swift.
@objc(BlueboxUpdaterProtocol) protocol BlueboxUpdaterProtocol {
    /// Copies the DMG the app downloaded (an open file, since this service
    /// can't count on reaching the app's container by path), checks it against
    /// GitHub's `sha256:` digest when there is one, mounts it, checks the
    /// Bluebox.app inside it is signed by Bluebox's release certificate, and
    /// swaps it in for the app at `appPath`. Then, once process `pid` has quit,
    /// opens the new one. Replies nil, or what went wrong.
    func install(dmg: FileHandle, sha256: String?, appPath: String, relaunchAfter pid: Int32, reply: @escaping (String?) -> Void)
}

final class Updater: NSObject, BlueboxUpdaterProtocol {
    static let bundleID = UpdateVerification.bundleID

    func install(dmg: FileHandle, sha256: String?, appPath: String, relaunchAfter pid: Int32, reply: @escaping (String?) -> Void) {
        nonisolated(unsafe) let reply = reply
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Self.install(dmg: dmg, sha256: sha256, app: URL(fileURLWithPath: appPath))
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

    static func install(dmg handle: FileHandle, sha256: String?, app: URL) throws {
        let fm = FileManager.default
        log.notice("installing over \(app.path, privacy: .public)")
        let folder = app.deletingLastPathComponent()
        guard app.pathExtension == "app", fm.isWritableFile(atPath: folder.path) else {
            throw UpdateError(message: "Bluebox can't replace itself in \(folder.path). Move it to Applications, or download the update from GitHub.")
        }
        let work = fm.temporaryDirectory.appending(path: "BlueboxUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // hdiutil is its own process, and macOS keeps it out of the app's
        // container, so the DMG is copied here first, from the open file.
        let dmg = work.appending(path: "Bluebox.dmg")
        log.notice("copying the download")
        do {
            try handle.seek(toOffset: 0)
            guard fm.createFile(atPath: dmg.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let out = try FileHandle(forWritingTo: dmg)
            defer { try? out.close() }
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        } catch {
            throw UpdateError(message: "Bluebox couldn't read the download: \(error.localizedDescription) Nothing was changed.")
        }
        do {
            try UpdateVerification.verifyDigest(of: dmg, expected: sha256)
        } catch let failure as UpdateVerification.Failure {
            throw UpdateError(message: failure.message + " Nothing was changed.")
        }
        let mount = work.appending(path: "mount", directoryHint: .isDirectory)
        log.notice("mounting")
        // hdiutil checks the image's own checksums (no -noverify).
        try run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                "-mountpoint", mount.path, timeout: 180)
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
        // The copy is what gets installed, so the copy is what's checked: signed
        // by Bluebox's release certificate, and not older than this app.
        log.notice("verifying")
        do {
            try UpdateVerification.verifySignature(of: staged)
            try UpdateVerification.checkNotOlder(staged, than: app)
        } catch let failure as UpdateVerification.Failure {
            try? fm.removeItem(at: staged)
            throw UpdateError(message: failure.message + " Nothing was changed.")
        }
        // Only now that the signature is known to be Bluebox's: the release
        // certificate is self-signed and not notarized, so Gatekeeper would
        // refuse to open a quarantined copy.
        try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path)
        log.notice("swapping")
        let backupName = ".Bluebox-previous.app"
        let backup = folder.appending(path: backupName)
        try? fm.removeItem(at: backup)
        do {
            _ = try fm.replaceItemAt(app, withItemAt: staged, backupItemName: backupName, options: .withoutDeletingBackupItem)
        } catch {
            try? fm.removeItem(at: staged)
            let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? (error as NSError).code
            if code == Int(EPERM) || code == NSFileWriteNoPermissionError {
                throw UpdateError(message: "macOS didn't let Bluebox replace itself. Turn on Bluebox in System Settings › Privacy & Security › App Management, then try again. Nothing was changed.")
            }
            throw UpdateError(message: "Bluebox couldn't replace itself: \(error.localizedDescription) Nothing was changed.")
        }
        // The swapped-in app is checked once more; if it fails, the old one goes back.
        do {
            try UpdateVerification.verifySignature(of: app)
        } catch {
            log.error("installed copy failed verification; restoring the previous version")
            if fm.fileExists(atPath: backup.path) { _ = try? fm.replaceItemAt(app, withItemAt: backup) }
            throw UpdateError(message: "The installed copy didn't verify, so the previous Bluebox was put back.")
        }
        // The previous version goes to the Trash, so it can be put back by hand.
        if fm.fileExists(atPath: backup.path) {
            do {
                var trashed: NSURL?
                try fm.trashItem(at: backup, resultingItemURL: &trashed)
                if let trashed { try? fm.moveItem(at: trashed as URL, to: (trashed as URL).deletingLastPathComponent().appending(path: "Bluebox (previous version).app")) }
            } catch {
                try? fm.removeItem(at: backup)
            }
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
        // hdiutil warns that `attach -mountpoint` is deprecated; that isn't the error.
        let text = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { !$0.contains("WARNING:") && !$0.contains("is deprecated") && !$0.contains("instead.") }
            .joined(separator: "\n")
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
