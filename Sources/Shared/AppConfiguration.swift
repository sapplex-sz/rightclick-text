import Foundation

enum AppConfiguration {
    static var groupIdentifier: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RCTAppGroupIdentifier") as? String,
              !value.isEmpty, !value.contains("$(") else {
            preconditionFailure("The signed app must define RCTAppGroupIdentifier.")
        }
        return value
    }

    static var locationsDidChange: Notification.Name {
        Notification.Name(groupIdentifier + ".locationsChanged")
    }

    static func groupContainer() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else { throw AppError.sharedContainerUnavailable }
        return url
    }

    static func requestQueue() throws -> RequestQueue {
        try RequestQueue(directory: groupContainer().appendingPathComponent("Requests", isDirectory: true))
    }
}

enum L10n {
    static func text(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}

enum AppError: LocalizedError {
    case sharedContainerUnavailable, missingPermission, locationUnavailable, invalidDestination
    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable: return L10n.text("error.sharedContainer")
        case .missingPermission: return L10n.text("error.permission")
        case .locationUnavailable: return L10n.text("error.location")
        case .invalidDestination: return L10n.text("error.destination")
        }
    }
}
