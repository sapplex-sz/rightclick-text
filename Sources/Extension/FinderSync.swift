import AppKit
import FinderSync
import OSLog

final class FinderSync: FIFinderSync {
    private static let log = Logger(subsystem: "com.sapplex.RightClickText.FinderExtension", category: "Finder")
    private var refreshTimer: Timer?
    private var refreshTarget: RefreshTarget?
    private var monitoredURLs: Set<URL> = []
    private let menuTargetLock = NSLock()
    private var menuTargets: [Int: MenuTarget] = [:]
    private static let menuTargetLifetime: TimeInterval = 120
    private static let maximumMenuTargets = 64

    override init() {
        super.init()
        reloadLocations()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reloadLocations),
            name: AppConfiguration.locationsDidChange, object: nil)
        // Coalesced fallback for notifications lost while the extension is suspended.
        let target = RefreshTarget(finder: self)
        refreshTarget = target
        refreshTimer = Timer.scheduledTimer(timeInterval: 30, target: target,
            selector: #selector(RefreshTarget.refresh), userInfo: nil, repeats: true)
        refreshTimer?.tolerance = 10
    }

    deinit {
        refreshTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc fileprivate func reloadLocations() {
        do {
            let paths = try MonitoredLocations.read()
            let urls = Set(paths.map { URL(fileURLWithPath: $0.path, isDirectory: true) })
            if urls != monitoredURLs {
                FIFinderSyncController.default().directoryURLs = urls
                monitoredURLs = urls
                Self.log.info("Updated monitored directory count: \(urls.count, privacy: .public)")
            }
        } catch {
            FIFinderSyncController.default().directoryURLs = []
            monitoredURLs = []
            Self.log.error("Cannot read monitored locations; no directories will be monitored.")
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        Self.log.debug("Finder requested menu kind: \(menuKind.rawValue, privacy: .public)")
        let controller = FIFinderSyncController.default()
        let target: URL
        let context: RequestContext
        switch menuKind {
        case .contextualMenuForContainer:
            guard let url = controller.targetedURL() else { return nil }
            target = url
            context = .container
        case .contextualMenuForItems:
            guard let selection = controller.selectedItemURLs(), selection.count == 1,
                  let url = selection.first else { return nil }
            target = url
            context = .items
        case .contextualMenuForSidebar:
            guard let url = controller.targetedURL() else { return nil }
            target = url
            context = .sidebar
        default: return nil
        }
        guard target.isFileURL else { return nil }
        // Never inspect the user's filesystem in this process. The host has the grant
        // and checks both the original target and the eventual destination.
        let action = NSMenuItem(title: L10n.text("finder.newText"), action: #selector(createText(_:)), keyEquivalent: "")
        action.target = self
        action.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        // Finder presents a copy of this menu in another process. Keep custom
        // objects here and pass only the menu item's scalar tag across that boundary.
        action.tag = rememberTarget(path: target.standardizedFileURL.path, context: context)
        Self.log.notice("Prepared Finder menu token=\(action.tag, privacy: .public) context=\(context.rawValue, privacy: .public)")
        let menu = NSMenu()
        menu.addItem(action)
        return menu
    }

    override func beginObservingDirectory(at url: URL) {
        Self.log.debug("Finder began observing a monitored directory.")
    }

    @objc private func createText(_ sender: NSMenuItem) {
        Self.log.notice("Finder menu action received token=\(sender.tag, privacy: .public)")
        guard let target = takeTarget(tag: sender.tag) else {
            Self.log.error("Finder menu token was missing, expired, or already consumed.")
            Self.showError()
            return
        }
        do {
            let queue = try AppConfiguration.requestQueue()
            try queue.prune()
            let request = CreationRequest(targetPath: target.path, context: target.context)
            try queue.enqueue(request)
            Self.log.notice("Enqueued Finder request id=\(request.id.uuidString, privacy: .public) context=\(target.context.rawValue, privacy: .public)")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            // Address the containing application explicitly, so another app registering
            // the same URL scheme cannot intercept a Finder request.
            let hostURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            NSWorkspace.shared.open([RequestLink.url(for: request.id)], withApplicationAt: hostURL,
                configuration: configuration) { _, error in
                if let error {
                    let detail = error as NSError
                    Self.log.error("Finder request delivery failed domain=\(detail.domain, privacy: .public) code=\(detail.code, privacy: .public)")
                    Self.showError()
                } else {
                    Self.log.notice("Delivered Finder request id=\(request.id.uuidString, privacy: .public)")
                }
            }
        } catch {
            let detail = error as NSError
            Self.log.error("Finder request enqueue failed domain=\(detail.domain, privacy: .public) code=\(detail.code, privacy: .public)")
            Self.showError()
        }
    }

    private func rememberTarget(path: String, context: RequestContext) -> Int {
        menuTargetLock.lock()
        defer { menuTargetLock.unlock() }
        let now = Date()
        menuTargets = menuTargets.filter { _, target in
            let age = now.timeIntervalSince(target.createdAt)
            return age >= 0 && age <= Self.menuTargetLifetime
        }
        if menuTargets.count >= Self.maximumMenuTargets,
           let oldest = menuTargets.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            menuTargets.removeValue(forKey: oldest)
        }
        var tag = Int(Int32.random(in: 1...Int32.max))
        while menuTargets[tag] != nil { tag = Int(Int32.random(in: 1...Int32.max)) }
        menuTargets[tag] = MenuTarget(path: path, context: context, createdAt: now)
        return tag
    }

    private func takeTarget(tag: Int) -> MenuTarget? {
        menuTargetLock.lock()
        defer { menuTargetLock.unlock() }
        guard let target = menuTargets.removeValue(forKey: tag) else { return nil }
        let age = Date().timeIntervalSince(target.createdAt)
        guard age >= 0 && age <= Self.menuTargetLifetime else { return nil }
        return target
    }

    private static func showError() {
        log.error("Unable to deliver a Finder creation request.")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = L10n.text("error.extension.title")
            alert.informativeText = L10n.text("error.extension.help")
            alert.addButton(withTitle: L10n.text("action.done"))
            alert.runModal()
        }
    }
}

private final class RefreshTarget: NSObject {
    weak var finder: FinderSync?
    init(finder: FinderSync) { self.finder = finder }
    @objc func refresh() { finder?.reloadLocations() }
}

private struct MenuTarget {
    let path: String
    let context: RequestContext
    let createdAt: Date
}
