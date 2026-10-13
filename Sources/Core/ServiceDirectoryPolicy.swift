import Foundation

/// A restriction only: these paths never grant access to the service worker.
/// The host publishes canonical folder paths; the worker canonicalizes the input
/// using only the capability supplied by the original Finder pasteboard.
public enum ServiceDirectoryPolicy {
    public static func allows(canonicalDirectory: String, configuredPaths: [String]) -> Bool {
        guard let target = components(canonicalDirectory),
              !configuredPaths.isEmpty, configuredPaths.count <= 1024 else { return false }
        return configuredPaths.contains { root in
            guard let parts = components(root), target.count >= parts.count else { return false }
            return target.prefix(parts.count).elementsEqual(parts)
        }
    }

    private static func components(_ path: String) -> [String]? {
        guard path.hasPrefix("/"), path.utf8.count <= 16384,
              !path.contains("\0"), !path.contains("//"),
              path == "/" || !path.hasSuffix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains("."), !parts.contains("..") else { return nil }
        return ["/"] + parts
    }
}
