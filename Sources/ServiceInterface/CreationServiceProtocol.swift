import Foundation

enum CreationServiceConfiguration {
    static let hostIdentifier = "com.sapplex.RightClickText"
    static let workerIdentifier = hostIdentifier + ".CreationService"
    static func requirement(for identifier: String) -> String {
        // TN3127: the Mac App Store re-signs with Apple's certificate, whose OU
        // is not our Team ID. Keep the exact identifier in both signing branches.
        "anchor apple generic and identifier \"\(identifier)\" and (" +
        "certificate leaf[field.1.2.840.113635.100.6.1.9] exists or (" +
        "certificate 1[field.1.2.840.113635.100.6.2.6] exists and " +
        "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and " +
        "certificate leaf[subject.OU] = \"8D9AHY5YW8\"))"
    }
}

/// Only a pasteboard locator and restrictions cross this boundary. The host never
/// sends a directory capability, bookmark, file URL or file descriptor.
@objc(RightClickTextCreationServiceProtocol)
protocol CreationServiceProtocol {
    func create(pasteboardName: String, changeCount: Int, allowedDirectories: [String],
                useChineseName: Bool, deadline: Double,
                reply: @escaping @Sendable (String, Int32, Int32) -> Void)
    func acknowledgeCompletion()
}
