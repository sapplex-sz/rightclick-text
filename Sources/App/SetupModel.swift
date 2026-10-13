import AppKit
import Combine
import FinderSync

@MainActor
final class SetupModel: ObservableObject {
    @Published var folders: [FolderGrant] = []
    @Published var extensionEnabled = false
    @Published var errorMessage: String?

    var hasCloudFolders: Bool {
        folders.contains { LocationCompatibility.classify(path: $0.path) != .standard }
    }

    var statusKey: String {
        guard extensionEnabled, !folders.isEmpty else { return "status.setup" }
        return hasCloudFolders ? "status.cloud" : "status.ready"
    }

    func reload() {
        extensionEnabled = FIFinderSyncController.isExtensionEnabled
        do { folders = try FolderAccessStore().refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func refreshExtensionState() { extensionEnabled = FIFinderSyncController.isExtensionEnabled }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("folder.panel.title")
        panel.message = L10n.text("folder.panel.message")
        panel.prompt = L10n.text("folder.panel.allow")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            do {
                try FolderAccessStore().add(panel.urls)
                self?.reload()
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func removeFolder(_ id: UUID) {
        do { try FolderAccessStore().remove(id: id); reload() }
        catch { errorMessage = error.localizedDescription }
    }

    func openExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    func revealFolder(_ folder: FolderGrant) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }
}
