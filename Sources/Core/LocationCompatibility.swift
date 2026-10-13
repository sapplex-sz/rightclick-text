import Foundation

/// Classifies known macOS cloud storage locations without accessing the filesystem.
/// Resolve bookmarks and symbolic links before calling when the visible location
/// (for example, an iCloud-backed Desktop) differs from its actual storage path.
public enum LocationCompatibility: Equatable {
    case standard
    case iCloudDrive
    case fileProvider

    public static func classify(path: String) -> Self {
        guard path.hasPrefix("/"), !path.contains("\0") else { return .standard }

        // Normalize only path syntax. Do not expand a tilde or consult the current
        // user's home directory: another account's absolute path must classify alike.
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }

        guard components.count >= 4,
              components[0] == "Users",
              components[2] == "Library" else { return .standard }

        switch components[3] {
        case "Mobile Documents": return .iCloudDrive
        case "CloudStorage": return .fileProvider
        default: return .standard
        }
    }
}
