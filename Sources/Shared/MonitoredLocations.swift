import Foundation

struct MonitoredLocation: Codable, Identifiable, Equatable {
    let id: UUID
    let path: String
    let name: String
}

enum MonitoredLocations {
    private static func fileURL() throws -> URL {
        try AppConfiguration.groupContainer().appendingPathComponent("Locations.json")
    }

    static func read() throws -> [MonitoredLocation] {
        let url = try fileURL()
        do {
            return try JSONDecoder().decode([MonitoredLocation].self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    static func write(_ locations: [MonitoredLocation]) throws {
        try JSONEncoder().encode(locations).write(to: fileURL(), options: .atomic)
        // A notification only asks the extension to reload its own protected group file.
        // It never carries a request, a path, or a security-scoped bookmark.
        DistributedNotificationCenter.default().postNotificationName(
            AppConfiguration.locationsDidChange, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
