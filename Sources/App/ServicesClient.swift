import AppKit
import Darwin
import OSLog

@MainActor
enum ServicesClient {
    private static let log = Logger(subsystem: CreationServiceConfiguration.hostIdentifier, category: "Services")

    static func create(from pasteboard: NSPasteboard) -> String? {
        let allowed: [String]
        do { allowed = try MonitoredLocations.read().map(\.path) }
        catch { return L10n.text("error.request") }
        guard !allowed.isEmpty else { return L10n.text("error.permission") }

        let deadline = Date().addingTimeInterval(12)
        let result = ServiceReplyBox()
        let connection = NSXPCConnection(serviceName: CreationServiceConfiguration.workerIdentifier)
        connection.remoteObjectInterface = NSXPCInterface(with: CreationServiceProtocol.self)
        connection.setCodeSigningRequirement(CreationServiceConfiguration.requirement(for: CreationServiceConfiguration.workerIdentifier))
        connection.interruptionHandler = {
            result.markInterrupted()
            result.finish(.init(key: "error.service.unavailable", code: ECONNRESET, pid: 0))
        }
        connection.invalidationHandler = {
            result.finish(.init(key: "error.service.unavailable", code: ECONNRESET, pid: 0))
        }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            result.finish(.init(key: "error.service.unavailable", code: ECONNREFUSED, pid: 0))
        }) as? CreationServiceProtocol else { return L10n.text("error.service.unavailable") }

        return withExtendedLifetime(pasteboard) {
            // Do not read the URLs in this process: it can hold the user's saved
            // folder permissions for other features. The isolated worker must read
            // the original service pasteboard and obtain its own temporary access.
            proxy.create(pasteboardName: pasteboard.name.rawValue, changeCount: pasteboard.changeCount,
                allowedDirectories: allowed, useChineseName: L10n.text("file.baseName") == "新建文本",
                deadline: deadline.timeIntervalSince1970) { key, code, pid in
                result.finish(.init(key: key, code: code, pid: pid))
            }
            while result.value == nil && Date() < deadline {
                RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.02)))
            }
            guard let reply = result.value else {
                log.error("Service timed out; no automatic retry.")
                return L10n.text("error.service.timeout")
            }
            log.notice("Creation worker PID=\(reply.pid, privacy: .public) result=\(reply.key, privacy: .public) errno=\(reply.code, privacy: .public)")
            if reply.pid != 0 {
                proxy.acknowledgeCompletion()
                let exitDeadline = min(deadline, Date().addingTimeInterval(1))
                while !result.interrupted && Date() < exitDeadline {
                    RunLoop.current.run(until: min(exitDeadline, Date().addingTimeInterval(0.02)))
                }
            }
            return reply.key.isEmpty ? nil : L10n.text(reply.key)
        }
    }
}

private struct ServiceReply: Sendable {
    let key: String
    let code: Int32
    let pid: Int32
}

private final class ServiceReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ServiceReply?
    private var workerInterrupted = false
    func finish(_ result: ServiceReply) {
        lock.lock(); defer { lock.unlock() }
        if stored == nil { stored = result }
    }
    func markInterrupted() {
        lock.lock(); defer { lock.unlock() }
        workerInterrupted = true
    }
    var value: ServiceReply? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    var interrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return workerInterrupted
    }
}
