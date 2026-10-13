import SwiftUI
import AppKit
import Combine

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @Environment(\.colorScheme) private var colorScheme
    var showPrivacy: () -> Void
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.38, green: 0.80, blue: 0.70) : Color(red: 0.06, green: 0.47, blue: 0.42)
    }
    var tutorialSnapshot: TutorialSnapshot? = nil
    private let statusTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("app.name")).font(.system(size: 15, weight: .semibold))
                    Text("RIGHTCLICK TEXT").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.8).foregroundStyle(.secondary)
                }
                Spacer()
                Label(L10n.text("badge.local"), systemImage: "lock.shield")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 27)

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 21) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("hero.title"))
                            .font(.system(size: 33, weight: .semibold)).tracking(-0.9)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.text("hero.subtitle"))
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    extensionCard
                    foldersCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                preview.frame(width: 264)
            }
            Spacer(minLength: 12)
            Divider().padding(.bottom, 15)
            HStack {
                Circle().fill(model.extensionEnabled && !model.folders.isEmpty
                    ? (model.hasCloudFolders ? Color.orange : accent) : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(L10n.text(model.statusKey))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("privacy.title"), action: showPrivacy).buttonStyle(.plain)
                Text("·").foregroundStyle(.tertiary)
                Link(L10n.text("action.support"), destination: URL(string: "mailto:sapplex@icloud.com")!)
                Text("1.0.0").foregroundStyle(.tertiary).padding(.leading, 8)
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 36).padding(.top, 42).padding(.bottom, 22)
        .frame(width: 880, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .onReceive(statusTimer) { _ in model.refreshExtensionState() }
        .alert(L10n.text("error.setup.title"), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) { Button(L10n.text("action.done"), role: .cancel) { model.errorMessage = nil } }
        message: { Text(model.errorMessage ?? "") }
    }

    private var extensionCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                stepNumber("01", complete: model.extensionEnabled)
                Text(L10n.text("step.extension")).font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.extensionEnabled {
                    Label(L10n.text("extension.enabled"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                }
            }
            Text(L10n.text("extension.description")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            HStack {
                Button(L10n.text("extension.settings")) { model.openExtensionSettings() }
                    .controlSize(.regular)
                Spacer()
                Text(L10n.text("extension.path")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }.padding(16).background(cardBackground)
    }

    private var foldersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                stepNumber("02", complete: !model.folders.isEmpty)
                Text(L10n.text("step.folders")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { model.chooseFolders() } label: {
                    Label(L10n.text("folder.add"), systemImage: "plus")
                }.controlSize(.small)
            }
            if model.folders.isEmpty {
                Text(L10n.text("folder.description"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.folders) { folder in
                            HStack(spacing: 9) {
                                Image(systemName: "folder.fill").foregroundStyle(accent.opacity(0.8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(folder.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    if LocationCompatibility.classify(path: folder.path) != .standard {
                                        Label(L10n.text("folder.cloudHelp"), systemImage: "exclamationmark.triangle")
                                            .font(.system(size: 10)).foregroundStyle(.orange)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                                Button { model.revealFolder(folder) } label: { Image(systemName: "arrow.up.forward.square") }
                                    .help(L10n.text("folder.reveal")).accessibilityLabel(L10n.text("folder.reveal") + " " + folder.name)
                                Button { model.removeFolder(folder.id) } label: { Image(systemName: "minus.circle") }
                                    .help(L10n.text("folder.remove")).accessibilityLabel(L10n.text("folder.remove") + " " + folder.name)
                            }.buttonStyle(.plain).padding(.vertical, 3)
                        }
                    }
                }.frame(height: 78)
            }
            Text(L10n.text("folder.footnote")).font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(16).background(cardBackground)
    }

    private func stepNumber(_ text: String, complete: Bool) -> some View {
        Text(complete ? "✓" : text).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(accent).frame(width: 25, height: 25)
            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.055), lineWidth: 1))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageTutorialView(preferCloudService: model.hasCloudFolders, snapshot: tutorialSnapshot)
            Text(L10n.text("tutorial.footnote"))
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6).padding(.top, 7).padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("preview.title")).font(.system(size: 14, weight: .semibold))
                feature("doc.on.doc", "preview.safeNames")
                Text(L10n.text("preview.limit"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3).padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 6)
        }
    }

    private func feature(_ symbol: String, _ key: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 15).foregroundStyle(accent)
            Text(L10n.text(key)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}
