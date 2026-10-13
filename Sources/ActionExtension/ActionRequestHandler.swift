import AppKit
import OSLog
import UniformTypeIdentifiers

/// A Finder Quick Action forwards one selected file or folder to the containing app.
/// Persistent security-scoped bookmarks remain exclusively in that app.
final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    private static let log = Logger(subsystem: "com.sapplex.RightClickText.ActionExtension", category: "QuickAction")

    func beginRequest(with context: NSExtensionContext) {
        let lifetime = ActionRequestLifetime(context: context)
        guard context.inputItems.count == 1,
              let item = context.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments, attachments.count == 1,
              let provider = attachments.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            lifetime.cancel(AppError.invalidDestination)
            return
        }

        // Load the URL representation itself. loadFileRepresentation can copy a
        // directory into temporary storage, which is never a valid destination.
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            if let error {
                Self.log.error("Unable to load the selected folder URL.")
                lifetime.cancel(error)
                return
            }
            do {
                guard let folder = Self.fileURL(from: item), folder.isFileURL,
                      !folder.path.contains("\0") else { throw AppError.invalidDestination }
                let target = folder.standardizedFileURL
                let locations = try MonitoredLocations.read()
                guard locations.contains(where: { Self.isWithin(target, path: $0.path) }) else {
                    throw AppError.missingPermission
                }
                // The extension never opens the selected item. The containing app
                // validates its type and canonical boundary under the saved grant.
                // Folders receive the new file; other items use their parent folder.
                let queue = try AppConfiguration.requestQueue()
                try queue.prune()
                let request = CreationRequest(targetPath: target.path, context: .items)
                try queue.enqueue(request)
                Self.log.info("Delivering a folder creation request to the containing app.")
                lifetime.openContainingApp(requestURL: RequestLink.url(for: request.id))
            } catch {
                Self.log.error("Unable to deliver a Quick Action creation request.")
                lifetime.cancel(error)
            }
        }
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        // Foundation bridges NSURL to URL while preserving its supplied authority.
        if let url = item as? URL { return url }
        if let data = item as? Data, !data.isEmpty, data.count <= 16 * 1024 {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        return nil
    }

    private static func isWithin(_ target: URL, path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        // This is only a lexical preflight. Resolving the granted root here could
        // fail because this extension does not own the containing app's bookmark.
        // The app repeats the check using real paths under its security scope.
        let rootParts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let targetParts = target.pathComponents
        return targetParts.count >= rootParts.count && Array(targetParts.prefix(rootParts.count)) == rootParts
    }
}

/// Foundation's context is not Sendable. It is retained immutably here, then used
/// only on the main queue after beginRequest has finished reading its inputs.
/// Each provider callback takes exactly one terminal route: cancel or app-open.
private final class ActionRequestLifetime: @unchecked Sendable {
    private let context: NSExtensionContext

    init(context: NSExtensionContext) { self.context = context }

    func cancel(_ error: Error) {
        DispatchQueue.main.async { self.context.cancelRequest(withError: error) }
    }

    func openContainingApp(requestURL: URL) {
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            // Address this extension's containing app, never a URL-scheme handler
            // that another installed application may have registered.
            let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            guard hostURL.pathExtension == "app" else {
                self.context.cancelRequest(withError: AppError.locationUnavailable)
                return
            }
            NSWorkspace.shared.open([requestURL], withApplicationAt: hostURL,
                                    configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.context.cancelRequest(withError: error)
                    } else {
                        // Preserve every original provider. An action must not tell
                        // Finder that the selected folder should be replaced/deleted.
                        self.context.completeRequest(returningItems: self.context.inputItems,
                                                     completionHandler: nil)
                    }
                }
            }
        }
    }
}
