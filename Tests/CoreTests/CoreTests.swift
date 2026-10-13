import Darwin
import Foundation
import XCTest
@testable import RightClickTextCore

final class CoreTests: XCTestCase {
    private var temporary: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        temporary = fileManager.temporaryDirectory.appendingPathComponent("RightClickTextTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        temporary = temporary.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let temporary { try fileManager.removeItem(at: temporary) }
    }

    func testCreatesAnEmptyTXTFile() throws {
        let url = try TextFileCreator.create(in: temporary, baseName: "新建文本文档")
        XCTAssertEqual(url.lastPathComponent, "新建文本文档.txt")
        XCTAssertEqual(try Data(contentsOf: url), Data())
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
    }

    func testExistingFilesAndSymbolicLinksAreNeverOverwritten() throws {
        let existing = temporary.appendingPathComponent("Untitled.txt")
        let outside = temporary.appendingPathComponent("valuable.txt")
        try Data("original".utf8).write(to: existing)
        try Data("valuable".utf8).write(to: outside)
        try fileManager.createSymbolicLink(at: temporary.appendingPathComponent("Untitled 2.txt"), withDestinationURL: outside)
        let created = try TextFileCreator.create(in: temporary, baseName: "Untitled")
        XCTAssertEqual(created.lastPathComponent, "Untitled 3.txt")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "valuable")
    }

    func testConcurrentCreationProducesDistinctEmptyFiles() throws {
        let results = LockedResults<URL>()
        let directory = temporary!
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do { results.append(.success(try TextFileCreator.create(in: directory, baseName: "Untitled"))) }
            catch { results.append(.failure(error)) }
        }
        let values = try results.values.map { try $0.get() }
        XCTAssertEqual(values.count, 64)
        XCTAssertEqual(Set(values.map(\.lastPathComponent)).count, 64)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: directory.path).count, 64)
        for value in values { XCTAssertEqual(try Data(contentsOf: value).count, 0) }
    }

    func testInvalidNamesAndMissingOrNonDirectoryDestinationsFail() throws {
        for name in ["", ".", "..", "../escape", "folder/file", "bad\0name"] {
            XCTAssertThrowsError(try TextFileCreator.create(in: temporary, baseName: name))
        }
        let absent = temporary.appendingPathComponent("missing")
        XCTAssertThrowsError(try TextFileCreator.create(in: absent, baseName: "Untitled"))
        XCTAssertFalse(fileManager.fileExists(atPath: absent.path))
        let file = temporary.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertThrowsError(try TextFileCreator.create(in: file, baseName: "Untitled"))
        XCTAssertThrowsError(try TextFileCreator.create(in: URL(string: "https://example.com")!, baseName: "Untitled"))
    }

    func testReadOnlyFolderFailsWithoutCreatingAnything() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can bypass directory permissions.") }
        XCTAssertEqual(chmod(temporary.path, 0o500), 0)
        defer { chmod(temporary.path, 0o700) }
        XCTAssertThrowsError(try TextFileCreator.create(in: temporary, baseName: "Untitled"))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: temporary.path), [])
    }

    func testSymbolicLinkDestinationIsRejected() throws {
        let folder = temporary.appendingPathComponent("real", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        let link = temporary.appendingPathComponent("link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try TextFileCreator.create(in: link, baseName: "Untitled"))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: folder.path), [])
    }

    func testFilenameExhaustionPreservesAllExistingFiles() throws {
        for index in 1...10_000 {
            let name = index == 1 ? "Untitled.txt" : "Untitled \(index).txt"
            let path = temporary.appendingPathComponent(name).path
            let descriptor = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            if descriptor >= 0 { close(descriptor) }
        }
        XCTAssertThrowsError(try TextFileCreator.create(in: temporary, baseName: "Untitled")) {
            XCTAssertEqual($0 as? CoreError, .filenameLimitReached)
        }
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: temporary.path).count, 10_000)
    }

    func testAuthorizationUsesPathComponentsAndExistingTargets() throws {
        let root = temporary.appendingPathComponent("allowed", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let sibling = temporary.appendingPathComponent("allowed-extra", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sibling, withIntermediateDirectories: false)
        let file = nested.appendingPathComponent("existing.txt")
        try Data().write(to: file)
        XCTAssertTrue(AuthorizedPath.contains(root, in: root))
        XCTAssertTrue(AuthorizedPath.contains(nested, in: root))
        XCTAssertTrue(AuthorizedPath.contains(file, in: root))
        XCTAssertFalse(AuthorizedPath.contains(sibling, in: root))
        XCTAssertFalse(AuthorizedPath.contains(temporary, in: root))
        XCTAssertFalse(AuthorizedPath.contains(root.appendingPathComponent("missing"), in: root))
        XCTAssertFalse(AuthorizedPath.contains(URL(string: "https://example.com")!, in: root))
    }

    func testAuthorizationRejectsSymlinkEscapeAndAcceptsInternalLinks() throws {
        let root = temporary.appendingPathComponent("allowed", isDirectory: true)
        let inside = root.appendingPathComponent("inside", isDirectory: true)
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: inside, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: false)
        let escape = root.appendingPathComponent("escape")
        let internalLink = root.appendingPathComponent("internal")
        try fileManager.createSymbolicLink(at: escape, withDestinationURL: outside)
        try fileManager.createSymbolicLink(at: internalLink, withDestinationURL: inside)
        XCTAssertFalse(AuthorizedPath.contains(escape, in: root))
        XCTAssertTrue(AuthorizedPath.contains(internalLink, in: root))
    }

    func testQueueRoundTripAndReplayRejection() throws {
        let directory = temporary.appendingPathComponent("queue", isDirectory: true)
        let queue = try RequestQueue(directory: directory)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let request = CreationRequest(createdAt: now, targetPath: temporary.path, context: .container)
        try queue.enqueue(request)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: directory.path), ["\(request.id.uuidString).json"])
        XCTAssertEqual(try queue.consume(id: request.id, now: now), request)
        XCTAssertThrowsError(try queue.consume(id: request.id, now: now))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: directory.path), [])
    }

    func testConcurrentConsumersClaimRequestOnlyOnce() throws {
        let directory = temporary.appendingPathComponent("queue", isDirectory: true)
        let queue = try RequestQueue(directory: directory)
        let request = CreationRequest(targetPath: temporary.path, context: .items)
        try queue.enqueue(request)
        let results = LockedResults<CreationRequest>()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do { results.append(.success(try queue.consume(id: request.id))) }
            catch { results.append(.failure(error)) }
        }
        let successes = results.values.compactMap { try? $0.get() }
        XCTAssertEqual(successes, [request])
        XCTAssertEqual(results.values.count, 32)
    }

    func testDuplicateEnqueueDoesNotOverwriteOriginal() throws {
        let queue = try RequestQueue(directory: temporary.appendingPathComponent("queue"))
        let original = CreationRequest(targetPath: temporary.path, context: .container)
        try queue.enqueue(original)
        let duplicate = CreationRequest(id: original.id, targetPath: "/", context: .items)
        XCTAssertThrowsError(try queue.enqueue(duplicate))
        XCTAssertEqual(try queue.consume(id: original.id), original)
    }

    func testTimestampBoundariesAndRejectedRequestConsumption() throws {
        let queue = try RequestQueue(directory: temporary.appendingPathComponent("queue"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for age in [-10.0, 120.0] {
            let request = CreationRequest(createdAt: now.addingTimeInterval(-age), targetPath: "/", context: .container)
            try queue.enqueue(request)
            XCTAssertEqual(try queue.consume(id: request.id, now: now), request)
        }
        for (age, expected) in [(120.001, CoreError.requestExpired), (-10.001, CoreError.requestInFuture)] {
            let request = CreationRequest(createdAt: now.addingTimeInterval(-age), targetPath: "/", context: .container)
            try queue.enqueue(request)
            XCTAssertThrowsError(try queue.consume(id: request.id, now: now)) { XCTAssertEqual($0 as? CoreError, expected) }
            XCTAssertThrowsError(try queue.consume(id: request.id, now: now))
        }
    }

    func testNonCanonicalAndNULPathsAreRejected() throws {
        let directory = temporary.appendingPathComponent("queue")
        let queue = try RequestQueue(directory: directory)
        for path in ["", "relative/path", "~/Desktop", "/a//b", "/a/./b", "/a/../b", "/a/", "/a\0/b"] {
            let request = CreationRequest(targetPath: path, context: .container)
            XCTAssertThrowsError(try queue.enqueue(request))
            try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("\(request.id.uuidString).json"))
            XCTAssertThrowsError(try queue.consume(id: request.id))
        }
    }

    func testMalformedWrongIDWrongTypeUnknownFieldAndOversizedRequestsAreRejected() throws {
        let directory = temporary.appendingPathComponent("queue")
        let queue = try RequestQueue(directory: directory)
        let request = CreationRequest(targetPath: temporary.path, context: .container)
        let valid = try JSONEncoder().encode(request)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var cases = [Data("not json".utf8), Data(repeating: 65, count: 16 * 1024 + 1)]
        object["context"] = "unexpected"
        cases.append(try JSONSerialization.data(withJSONObject: object))
        object["context"] = "container"
        object["unexpected"] = true
        cases.append(try JSONSerialization.data(withJSONObject: object))
        object.removeValue(forKey: "unexpected")
        object["targetPath"] = 42
        cases.append(try JSONSerialization.data(withJSONObject: object))
        for data in cases {
            try data.write(to: directory.appendingPathComponent("\(request.id.uuidString).json"))
            XCTAssertThrowsError(try queue.consume(id: request.id))
        }
        let wrongID = UUID()
        try valid.write(to: directory.appendingPathComponent("\(wrongID.uuidString).json"))
        XCTAssertThrowsError(try queue.consume(id: wrongID)) { XCTAssertEqual($0 as? CoreError, .invalidRequest) }
    }

    func testQueueRejectsSymlinksHardLinksAndFIFOWithoutReadingTargets() throws {
        let directory = temporary.appendingPathComponent("queue")
        let queue = try RequestQueue(directory: directory)
        let request = CreationRequest(targetPath: temporary.path, context: .container)
        let destination = temporary.appendingPathComponent("valuable.json")
        let original = try JSONEncoder().encode(request)
        try original.write(to: destination)
        let entry = directory.appendingPathComponent("\(request.id.uuidString).json")
        try fileManager.createSymbolicLink(at: entry, withDestinationURL: destination)
        XCTAssertThrowsError(try queue.consume(id: request.id))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(link(destination.path, entry.path), 0)
        XCTAssertThrowsError(try queue.consume(id: request.id)) { XCTAssertEqual($0 as? CoreError, .unsafeQueueFile) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(mkfifo(entry.path, 0o600), 0)
        XCTAssertThrowsError(try queue.consume(id: request.id)) { XCTAssertEqual($0 as? CoreError, .unsafeQueueFile) }
    }

    func testQueueRejectsSymlinkDirectoryAndMissingParent() throws {
        let real = temporary.appendingPathComponent("real")
        try fileManager.createDirectory(at: real, withIntermediateDirectories: false)
        let alias = temporary.appendingPathComponent("alias")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertThrowsError(try RequestQueue(directory: alias))
        XCTAssertThrowsError(try RequestQueue(directory: temporary.appendingPathComponent("missing/queue")))
    }

    func testPruneRemovesStaleMalformedAndUnsafeEntriesButPreservesFreshRequests() throws {
        let directory = temporary.appendingPathComponent("queue")
        let queue = try RequestQueue(directory: directory)
        let now = Date()
        let fresh = CreationRequest(createdAt: now, targetPath: temporary.path, context: .sidebar)
        let stale = CreationRequest(createdAt: now.addingTimeInterval(-121), targetPath: temporary.path, context: .container)
        let future = CreationRequest(createdAt: now.addingTimeInterval(11), targetPath: temporary.path, context: .items)
        for request in [fresh, stale, future] { try queue.enqueue(request) }
        let malformed = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("bad".utf8).write(to: malformed)
        let untouched = temporary.appendingPathComponent("untouched")
        try Data("keep".utf8).write(to: untouched)
        try fileManager.createSymbolicLink(at: directory.appendingPathComponent("\(UUID().uuidString).json"), withDestinationURL: untouched)
        let oldPending = directory.appendingPathComponent(".pending-abandoned")
        let livePending = directory.appendingPathComponent(".pending-active")
        try Data().write(to: oldPending)
        try Data().write(to: livePending)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-121)], ofItemAtPath: oldPending.path)
        try queue.prune(now: now)
        XCTAssertEqual(Set(try fileManager.contentsOfDirectory(atPath: directory.path)), Set(["\(fresh.id.uuidString).json", ".pending-active"]))
        XCTAssertEqual(try String(contentsOf: untouched, encoding: .utf8), "keep")
        XCTAssertEqual(try queue.consume(id: fresh.id, now: now), fresh)
    }

    func testRequestLinkRoundTrip() {
        let id = UUID()
        XCTAssertEqual(RequestLink.requestID(from: RequestLink.url(for: id)), id)
        XCTAssertEqual(RequestLink.requestID(from: URL(string: "rightclicktext://create/\(id.uuidString.lowercased())")!), id)
    }

    func testRequestLinksRejectOtherActionsPathsAndCredentials() {
        let id = UUID().uuidString
        let invalid = [
            "https://create/\(id)", "rightclicktext://delete/\(id)", "rightclicktext://CREATE/\(id)",
            "rightclicktext://%63reate/\(id)", "rightclicktext://user@create/\(id)",
            "rightclicktext://user:password@create/\(id)", "rightclicktext://create:80/\(id)",
            "rightclicktext://create/\(id)?path=/tmp", "rightclicktext://create/\(id)?",
            "rightclicktext://create/\(id)#x", "rightclicktext://create/\(id)#",
            "rightclicktext://create/\(id)/extra", "rightclicktext://create//\(id)",
            "rightclicktext://create/../\(id)", "rightclicktext://create/\(id)/",
            "rightclicktext://create/not-a-uuid", "rightclicktext://create/", "rightclicktext://create",
            "rightclicktext://create/\(id.replacingOccurrences(of: "-", with: ""))",
            "rightclicktext://create/%41\(id.dropFirst())"
        ]
        for value in invalid {
            guard let url = URL(string: value) else { continue }
            XCTAssertNil(RequestLink.requestID(from: url), value)
        }
    }
}

private final class LockedResults<Value> {
    private let lock = NSLock()
    private var storage: [Result<Value, Error>] = []
    func append(_ value: Result<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
    var values: [Result<Value, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
