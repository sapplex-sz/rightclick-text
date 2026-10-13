import AppKit
import SwiftUI

@main
enum RightClickTextMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let model = SetupModel()
    private var receivedExternalAction = false
    private var activeRequests = 0
    private var handlingService = false
    private let worker = DispatchQueue(label: "com.sapplex.RightClickText.creation", qos: .userInitiated)

    func applicationWillFinishLaunching(_ notification: Notification) {
        installMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        // Launch Services owns the static NSServices registration. Refreshing the
        // global Services cache here invalidates Finder's current folder context.
        // Launch Services delivers an initial URL during launch. Delay the setup window so
        // a Finder action can run quietly without flashing a window or Dock icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if !self.receivedExternalAction {
                self.showSetup()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedExternalAction = true
        for url in urls {
            guard let id = RequestLink.requestID(from: url) else { continue }
            processRequest(id)
        }
        finishIfIdle()
    }

    private func processRequest(_ id: UUID) {
        performCreation {
            try AppConfiguration.requestQueue().consume(id: id)
        }
    }

    @objc func createTextFile(_ pasteboard: NSPasteboard, userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        error.pointee = nil
        receivedExternalAction = true
        guard !handlingService else {
            error.pointee = L10n.text("error.service.busy") as NSString
            return
        }
        handlingService = true
        activeRequests += 1
        defer {
            activeRequests -= 1
            handlingService = false
            finishIfIdle()
        }
        if let failure = ServicesClient.create(from: pasteboard) {
            error.pointee = failure as NSString
        }
    }

    private func performCreation(_ requestProvider: @escaping @Sendable () throws -> CreationRequest) {
        let baseName = L10n.text("file.baseName")
        performFileCreation {
            let request = try requestProvider()
            return try FolderAccessStore().create(request, baseName: baseName)
        }
    }

    private func performFileCreation(_ create: @escaping @Sendable () throws -> CreatedTextFile) {
        activeRequests += 1
        worker.async { [weak self] in
            let result: Result<CreatedTextFile, Error> = Result(catching: create)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activeRequests -= 1
                switch result {
                case .success(let file):
                    // AppKit needs the source grant while it vends access to Finder.
                    withExtendedLifetime(file) {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                case .failure(let error): self.presentCreationError(error)
                }
                self.finishIfIdle()
            }
        }
    }

    private func presentCreationError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("error.create.title")
        alert.informativeText = friendlyMessage(error) + "\n\n" + L10n.text("error.create.help")
        alert.addButton(withTitle: L10n.text("action.settings"))
        alert.addButton(withTitle: L10n.text("action.close"))
        if alert.runModal() == .alertFirstButtonReturn { showSetup() }
    }

    private func friendlyMessage(_ error: Error) -> String {
        guard let core = error as? CoreError else { return error.localizedDescription }
        switch core {
        case .invalidDirectory: return L10n.text("error.destination")
        case .filenameLimitReached: return L10n.text("error.nameLimit")
        case .systemCall(_, let code):
            switch code {
            case EACCES, EPERM: return L10n.text("error.permission")
            case EROFS: return L10n.text("error.readOnly")
            case ENOSPC, EDQUOT: return L10n.text("error.diskFull")
            case ENOENT, ENOTDIR: return L10n.text("error.location")
            default: return L10n.text("error.fileOperation")
            }
        default: return L10n.text("error.request")
        }
    }

    private func finishIfIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.activeRequests == 0, self.window?.isVisible != true,
                  NSApp.modalWindow == nil else { return }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.refreshExtensionState() }

    @objc func showSetup() {
        NSApp.setActivationPolicy(.regular)
        model.reload()
        if window == nil {
            let content = SetupView(model: model, showPrivacy: { [weak self] in self?.showPrivacy() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = L10n.text("app.name")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: content)
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { finishIfIdle() }

    @objc private func showPrivacy() {
        let alert = NSAlert()
        alert.messageText = L10n.text("privacy.title")
        alert.informativeText = L10n.text("privacy.body")
        alert.addButton(withTitle: L10n.text("action.done"))
        alert.runModal()
    }

    @objc private func contactSupport() {
        if let url = URL(string: "mailto:sapplex@icloud.com?subject=RightClick%20Text%20Support") {
            NSWorkspace.shared.open(url)
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = appMenu
        menu.addItem(root)
        appMenu.addItem(withTitle: L10n.text("action.settings"), action: #selector(showSetup), keyEquivalent: ",")
        appMenu.addItem(withTitle: L10n.text("privacy.title"), action: #selector(showPrivacy), keyEquivalent: "")
        appMenu.addItem(withTitle: L10n.text("action.support"), action: #selector(contactSupport), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("action.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
    }
}
