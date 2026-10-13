import Darwin
import Foundation

public enum CoreError: Error, Equatable, LocalizedError {
    case invalidDirectory
    case invalidBaseName
    case filenameLimitReached
    case invalidRequest
    case requestExpired
    case requestInFuture
    case requestTooLarge
    case unsafeQueueFile
    case systemCall(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: return "The destination must be an existing folder."
        case .invalidBaseName: return "The document name is invalid."
        case .filenameLimitReached: return "Too many documents already use this name."
        case .invalidRequest: return "The creation request is invalid."
        case .requestExpired: return "The creation request has expired."
        case .requestInFuture: return "The creation request has an invalid timestamp."
        case .requestTooLarge: return "The creation request is too large."
        case .unsafeQueueFile: return "The creation request is not a regular private file."
        case let .systemCall(operation, code): return "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

public enum TextFileCreator {
    /// Exclusively creates an empty file relative to a pinned directory descriptor.
    /// The caller must hold the directory's security-scoped access for this entire call.
    public static func create(in directory: URL, baseName: String) throws -> URL {
        guard directory.isFileURL, !directory.path.contains("\0") else { throw CoreError.invalidDirectory }
        guard !baseName.isEmpty, baseName != ".", baseName != "..",
              !baseName.contains("/"), !baseName.contains("\0") else { throw CoreError.invalidBaseName }

        // openat needs a searchable directory, not permission to enumerate it.
        // Finder's temporary cloud-folder grant may not allow an O_RDONLY open.
        // O_SEARCH is public on the minimum supported macOS 13 and still pins the
        // directory for exclusive child creation without following its symlink.
        let folder = directory.path.withCString { open($0, O_SEARCH | O_NOFOLLOW | O_CLOEXEC) }
        guard folder >= 0 else { throw CoreError.systemCall(operation: "Open destination folder", code: errno) }
        defer { close(folder) }

        for number in 1...10_000 {
            let filename = number == 1 ? "\(baseName).txt" : "\(baseName) \(number).txt"
            let file = filename.withCString {
                openat(folder, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o666))
            }
            if file >= 0 {
                close(file)
                return directory.appendingPathComponent(filename, isDirectory: false)
            }
            let code = errno
            guard code == EEXIST else { throw CoreError.systemCall(operation: "Create text document", code: code) }
        }
        throw CoreError.filenameLimitReached
    }
}

public enum AuthorizedPath {
    /// Both URLs must exist. Resolving the real filesystem paths prevents sibling-prefix
    /// matches and symbolic links inside a granted folder from escaping that folder.
    public static func contains(_ target: URL, in root: URL) -> Bool {
        guard let targetPath = canonicalPath(target), let rootPath = canonicalPath(root) else { return false }
        let targetParts = URL(fileURLWithPath: targetPath).pathComponents
        let rootParts = URL(fileURLWithPath: rootPath).pathComponents
        return targetParts.count >= rootParts.count && Array(targetParts.prefix(rootParts.count)) == rootParts
    }

    private static func canonicalPath(_ url: URL) -> String? {
        guard url.isFileURL, !url.path.contains("\0") else { return nil }
        return url.path.withCString { path in
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(validatingCString: resolved)
        }
    }
}
