import AppKit
import Darwin
import OSLog

@main
enum CreationWorkerMain {
    static func main() {
        let delegate = CreationWorkerListener()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime(delegate) {}
    }
}

private final class CreationWorkerListener: NSObject, NSXPCListenerDelegate {
    private let worker = CreationWorker()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(CreationServiceConfiguration.requirement(for: CreationServiceConfiguration.hostIdentifier))
        connection.exportedInterface = NSXPCInterface(with: CreationServiceProtocol.self)
        connection.exportedObject = worker
        connection.resume()
        return true
    }
}

/// Fresh process for each request. In particular, an implicit pasteboard grant
/// must never remain available to a later request in the same worker process.
private final class CreationWorker: NSObject, CreationServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    private var replied = false
    private let log = Logger(subsystem: CreationServiceConfiguration.hostIdentifier, category: "CreationService")

    func create(pasteboardName: String, changeCount: Int, allowedDirectories: [String],
                useChineseName: Bool, deadline: Double,
                reply: @escaping @Sendable (String, Int32, Int32) -> Void) {
        lock.lock()
        let alreadyUsed = used
        used = true
        lock.unlock()
        guard !alreadyUsed else { reply("error.service.busy", EBUSY, getpid()); return }
        let remaining = deadline - Date().timeIntervalSince1970
        guard remaining.isFinite, remaining > 0, remaining <= 15,
              !pasteboardName.isEmpty, pasteboardName.utf8.count <= 1024,
              !pasteboardName.contains("\0"), !allowedDirectories.isEmpty,
              allowedDirectories.count <= 1024 else {
            finish("error.request", EINVAL, reply: reply)
            return
        }
        // This watchdog performs no filesystem I/O, and can stop a stalled cloud
        // operation even when the main run loop is blocked. Never retry a timeout.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining) { _exit(124) }
        DispatchQueue.main.async {
            self.handle(name: pasteboardName, changeCount: changeCount, allowed: allowedDirectories,
                        chinese: useChineseName, deadline: deadline, reply: reply)
        }
    }

    @MainActor
    private func handle(name: String, changeCount: Int, allowed: [String], chinese: Bool,
                        deadline: Double, reply: @escaping @Sendable (String, Int32, Int32) -> Void) {
        log.notice("Worker PID=\(getpid(), privacy: .public) received one request")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        guard pasteboard.changeCount == changeCount,
              let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [NSURL],
              objects.count == 1, let original = objects.first,
              pasteboard.changeCount == changeCount else {
            finish("error.service.selection", EINVAL, reply: reply)
            return
        }
        let supplied = original as URL
        guard supplied.isFileURL, !supplied.path.contains("\0") else {
            finish("error.service.selection", EINVAL, reply: reply)
            return
        }
        let scoped = supplied.startAccessingSecurityScopedResource()
        defer { if scoped { supplied.stopAccessingSecurityScopedResource() } }
        let folder = original.isFileReferenceURL() ? (original.filePathURL ?? supplied) : supplied
        withExtendedLifetime((pasteboard, original, supplied)) {
            do {
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true else {
                    finish("error.destination", ENOTDIR, reply: reply)
                    return
                }
                let canonical = folder.path.withCString { path -> String? in
                    guard let resolved = realpath(path, nil) else { return nil }
                    defer { free(resolved) }
                    return String(validatingCString: resolved)
                }
                guard let canonical,
                      ServiceDirectoryPolicy.allows(canonicalDirectory: canonical, configuredPaths: allowed) else {
                    finish("error.permission", EACCES, reply: reply)
                    return
                }
                guard pasteboard.changeCount == changeCount, Date().timeIntervalSince1970 < deadline else {
                    finish("error.request", EAGAIN, reply: reply)
                    return
                }
                // A searchable pinned descriptor avoids directory enumeration and
                // keeps collision-safe child creation inside the selected folder.
                _ = try TextFileCreator.create(in: folder, baseName: chinese ? "新建文本" : "New Text File")
                // Leave Finder in its directory context. Selecting the new TXT
                // changes Services input to a file and hides directory services.
                finish("", 0, reply: reply)
            } catch {
                let code: Int32
                if case let CoreError.systemCall(_, failure) = error { code = failure }
                else { code = (error as NSError).domain == NSCocoaErrorDomain ? EACCES : EIO }
                let key: String
                switch code {
                case EACCES, EPERM: key = "error.permission"
                case ENOSPC, EDQUOT: key = "error.diskFull"
                case EROFS: key = "error.readOnly"
                case ENOENT, ENOTDIR: key = "error.location"
                default: key = error as? CoreError == .filenameLimitReached ? "error.nameLimit" : "error.fileOperation"
                }
                finish(key, code, reply: reply)
            }
        }
    }

    func acknowledgeCompletion() {
        lock.lock()
        let mayExit = replied
        lock.unlock()
        if mayExit { _exit(0) }
    }

    private func finish(_ key: String, _ code: Int32,
                        reply: @escaping @Sendable (String, Int32, Int32) -> Void) {
        log.notice("Worker PID=\(getpid(), privacy: .public) result=\(key, privacy: .public) errno=\(code, privacy: .public)")
        lock.lock(); replied = true; lock.unlock()
        reply(key, code, getpid())
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { _exit(0) }
    }
}
