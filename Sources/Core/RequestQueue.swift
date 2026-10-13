import Darwin
import Foundation

public final class RequestQueue {
    private let directoryDescriptor: Int32
    private static let maximumBytes = 16 * 1024
    private static let lifetime: TimeInterval = 120
    private static let futureTolerance: TimeInterval = 10

    public init(directory: URL) throws {
        guard directory.isFileURL, !directory.path.contains("\0") else { throw CoreError.invalidDirectory }
        // The containing App Group folder is supplied by the caller. Never create its parents.
        if directory.path.withCString({ mkdir($0, mode_t(0o700)) }) != 0 && errno != EEXIST {
            throw CoreError.systemCall(operation: "Create request folder", code: errno)
        }
        let descriptor = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw CoreError.systemCall(operation: "Open request folder", code: errno) }
        directoryDescriptor = descriptor
    }

    deinit { close(directoryDescriptor) }

    public func enqueue(_ request: CreationRequest) throws {
        try Self.validate(request)
        let data = try JSONEncoder().encode(request)
        guard data.count <= Self.maximumBytes else { throw CoreError.requestTooLarge }
        let temporaryName = ".pending-\(UUID().uuidString)"
        let descriptor = temporaryName.withCString {
            openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw CoreError.systemCall(operation: "Stage request", code: errno) }
        defer {
            close(descriptor)
            temporaryName.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
        }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CoreError.systemCall(operation: "Write request", code: errno)
                }
                guard count > 0 else { throw CoreError.systemCall(operation: "Write request", code: EIO) }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw CoreError.systemCall(operation: "Save request", code: errno) }
        let filename = Self.filename(request.id)
        let result = temporaryName.withCString { temporary in
            filename.withCString { final in renameatx_np(directoryDescriptor, temporary, directoryDescriptor, final, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else { throw CoreError.systemCall(operation: "Publish request", code: errno) }
    }

    public func consume(id: UUID, now: Date = Date()) throws -> CreationRequest {
        let claimedName = ".claimed-\(id.uuidString)-\(UUID().uuidString)"
        let filename = Self.filename(id)
        let result = filename.withCString { original in
            claimedName.withCString { claimed in renameatx_np(directoryDescriptor, original, directoryDescriptor, claimed, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else { throw CoreError.systemCall(operation: "Claim request", code: errno) }
        defer { claimedName.withCString { _ = unlinkat(directoryDescriptor, $0, 0) } }

        let request = try readRequest(named: claimedName)
        guard request.id == id else { throw CoreError.invalidRequest }
        try Self.validate(request)
        let age = now.timeIntervalSince(request.createdAt)
        guard age.isFinite else { throw CoreError.invalidRequest }
        guard age <= Self.lifetime else { throw CoreError.requestExpired }
        guard age >= -Self.futureTolerance else { throw CoreError.requestInFuture }
        return request
    }

    public func prune(now: Date = Date()) throws {
        // Re-open through the pinned descriptor so replacing the path cannot redirect pruning.
        let listingDescriptor = openat(directoryDescriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard listingDescriptor >= 0 else { throw CoreError.systemCall(operation: "List request folder", code: errno) }
        guard let listing = fdopendir(listingDescriptor) else {
            let code = errno
            close(listingDescriptor)
            throw CoreError.systemCall(operation: "List request folder", code: code)
        }
        defer { closedir(listing) }

        while let entry = readdir(listing) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            // Temporary and claimed files may belong to active writers/readers. Remove only
            // stale ones, using their metadata without following symbolic links.
            if name.hasPrefix(".pending-") || name.hasPrefix(".claimed-") {
                var metadata = stat()
                let result = name.withCString { fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW) }
                if result == 0 {
                    let modifiedAt = Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
                    if now.timeIntervalSince(modifiedAt) > Self.lifetime {
                        name.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
                    }
                }
                continue
            }
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))), name == Self.filename(id) else { continue }
            do {
                let request = try readRequest(named: name)
                try Self.validate(request)
                let age = now.timeIntervalSince(request.createdAt)
                if request.id != id || !age.isFinite || age > Self.lifetime || age < -Self.futureTolerance {
                    name.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
                }
            } catch {
                // A concurrent consumer may already have removed this entry. unlinkat is
                // intentionally best effort and never follows an untrusted request symlink.
                name.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
            }
        }
    }

    private func readRequest(named name: String) throws -> CreationRequest {
        let descriptor = name.withCString { openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw CoreError.systemCall(operation: "Read request", code: errno) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw CoreError.systemCall(operation: "Inspect request", code: errno) }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else { throw CoreError.unsafeQueueFile }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes else { throw CoreError.requestTooLarge }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CoreError.systemCall(operation: "Read request", code: errno)
            }
            guard data.count + count <= Self.maximumBytes else { throw CoreError.requestTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        do { return try JSONDecoder().decode(CreationRequest.self, from: data) }
        catch { throw CoreError.invalidRequest }
    }

    private static func validate(_ request: CreationRequest) throws {
        let path = request.targetPath
        guard request.createdAt.timeIntervalSinceReferenceDate.isFinite,
              path.hasPrefix("/"), !path.contains("\0"),
              path == "/" || (!path.hasSuffix("/") && !path.contains("//")),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CoreError.invalidRequest
        }
    }

    private static func filename(_ id: UUID) -> String { "\(id.uuidString).json" }
}
