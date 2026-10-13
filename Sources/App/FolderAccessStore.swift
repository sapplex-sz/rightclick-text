import Foundation

struct FolderGrant: Codable, Identifiable {
    let id: UUID
    var bookmark: Data
    var path: String
    var name: String
}

/// Owns one already-started security scope until the last reference is released.
/// Immutable URLs let the worker transfer the lease safely to the main actor.
final class CreatedTextFile: Sendable {
    let url: URL
    private let securityScopedURL: URL?

    /// A non-nil scope transfers ownership of one successful startAccessing call.
    init(url: URL, securityScopedURL: URL?) {
        self.url = url
        self.securityScopedURL = securityScopedURL
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}

/// Security-scoped bookmarks never leave the containing app's private sandbox.
final class FolderAccessStore {
    private let fileURL: URL

    init() throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("RightClickText", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("FolderAccess.json")
    }

    func read() throws -> [FolderGrant] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([FolderGrant].self, from: Data(contentsOf: fileURL))
    }

    private func save(_ grants: [FolderGrant]) throws {
        try JSONEncoder().encode(grants).write(to: fileURL, options: .atomic)
        try publish(grants)
    }

    func publish(_ grants: [FolderGrant]) throws {
        try MonitoredLocations.write(grants.map { MonitoredLocation(id: $0.id, path: $0.path, name: $0.name) })
    }

    func add(_ urls: [URL]) throws {
        var grants = try read()
        for selectedURL in urls {
            let accessing = selectedURL.startAccessingSecurityScopedResource()
            defer { if accessing { selectedURL.stopAccessingSecurityScopedResource() } }
            let url = selectedURL.resolvingSymlinksInPath().standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values.isDirectory == true, values.isPackage != true else { throw AppError.invalidDestination }
            let bookmark = try selectedURL.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            )
            if let index = grants.firstIndex(where: { $0.path == url.path }) {
                grants[index].bookmark = bookmark
                grants[index].name = url.lastPathComponent
            } else {
                grants.append(FolderGrant(id: UUID(), bookmark: bookmark, path: url.path, name: url.lastPathComponent))
            }
        }
        try save(grants)
    }

    func remove(id: UUID) throws {
        try save(read().filter { $0.id != id })
    }

    /// Resolve moved/stale bookmarks on a deliberate app launch; offline grants remain visible for removal.
    func refresh() throws -> [FolderGrant] {
        var grants = try read()
        for index in grants.indices {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: grants[index].bookmark,
                                     options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            grants[index].path = canonical.path
            grants[index].name = canonical.lastPathComponent
            if stale, let data = try? url.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil) { grants[index].bookmark = data }
        }
        try save(grants)
        return grants
    }

    /// Called from a serial worker. Each operation reads a fresh atomic snapshot of the grants.
    func create(_ request: CreationRequest, baseName: String) throws -> CreatedTextFile {
        let target = URL(fileURLWithPath: request.targetPath)
        let grants = try read()
        guard !grants.isEmpty else { throw AppError.missingPermission }
        for grant in grants {
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: grant.bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            guard root.startAccessingSecurityScopedResource() else { continue }
            var transferredAccess = false
            defer {
                if !transferredAccess { root.stopAccessingSecurityScopedResource() }
            }
            guard AuthorizedPath.contains(target, in: root) else { continue }
            let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL
            let values = try canonicalTarget.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let destination: URL
            switch request.context {
            case .container, .sidebar:
                guard values.isDirectory == true, values.isPackage != true else { throw AppError.invalidDestination }
                destination = canonicalTarget
            case .items:
                destination = values.isDirectory == true && values.isPackage != true
                    ? canonicalTarget : canonicalTarget.deletingLastPathComponent()
            }
            guard AuthorizedPath.contains(destination, in: root) else { continue }
            let file = try TextFileCreator.create(in: destination, baseName: baseName)
            let createdFile = CreatedTextFile(url: file, securityScopedURL: root)
            transferredAccess = true
            return createdFile
        }
        throw AppError.missingPermission
    }
}
