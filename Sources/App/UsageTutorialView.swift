import AppKit
import SwiftUI

enum TutorialRoute: String, CaseIterable {
    case direct, cloudService

    var title: String { L10n.text("tutorial.route." + rawValue) }
    func instruction(_ step: Int) -> String {
        let key = step < 2 || (self == .cloudService && step == 2)
            ? "tutorial.\(rawValue).step\(step)" : "tutorial.step\(step)"
        return L10n.text(key)
    }
}

// Also used by the development renderer to inspect each state without waiting for playback.
struct TutorialSnapshot {
    let route: TutorialRoute
    let time: TimeInterval
    var reduceMotion: Bool = false
}

private struct TutorialFrame {
    static let duration: TimeInterval = 18
    static let stops: [TimeInterval] = [1.4, 6.4, 9.8, 16.6]
    let time: TimeInterval

    init(_ elapsed: TimeInterval) {
        time = max(0, elapsed).truncatingRemainder(dividingBy: Self.duration)
    }

    var step: Int { time < 3.4 ? 0 : time < 7.8 ? 1 : time < 11.8 ? 2 : 3 }
    var hasFile: Bool { time >= 7.8 }
    var showsMenu: Bool { time >= 2.3 && time < 7.8 }
    var editing: Bool { time >= 12.6 && time < 16.2 }
    var finished: Bool { time >= 16.2 }

    func ramp(_ start: Double, _ end: Double) -> Double {
        let x = min(1, max(0, (time - start) / (end - start)))
        return x * x * (3 - 2 * x)
    }

    func point(on route: TutorialRoute) -> CGPoint {
        let target = route == .cloudService ? CGPoint(x: 120, y: 83) : CGPoint(x: 144, y: 72)
        let menu = route == .direct ? CGPoint(x: 152, y: 116) : CGPoint(x: 131, y: 112)
        let action = route == .direct ? menu : CGPoint(x: 161, y: 144)
        var points: [(Double, CGPoint)] = [
            (0, CGPoint(x: 211, y: 145)), (1.8, target), (3.5, target),
            (4.5, menu), (5.0, menu), (6.0, action), (7.8, action)
        ]
        if route == .cloudService {
            points += [(8.25, target), (8.65, target),
                       (9.4, CGPoint(x: 120, y: 125)), (10.2, CGPoint(x: 120, y: 125)),
                       (11.2, CGPoint(x: 186, y: 139))]
        } else {
            points.append((8.8, CGPoint(x: 186, y: 139)))
        }
        for index in 1..<points.count where time < points[index].0 {
            let a = points[index - 1], b = points[index]
            let f = ramp(a.0, b.0)
            return CGPoint(x: a.1.x + (b.1.x - a.1.x) * f, y: a.1.y + (b.1.y - a.1.y) * f)
        }
        return points.last!.1
    }
}

/// A local, illustrated tutorial. It never invokes Finder, file creation, or permission APIs.
struct UsageTutorialView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var route: TutorialRoute
    @State private var elapsed: TimeInterval = 0
    @State private var resumedAt: Date?
    @State private var paused = false
    @State private var visibleAndActive = false
    private let snapshot: TutorialSnapshot?
    private var reduceMotion: Bool { snapshot?.reduceMotion ?? systemReduceMotion }

    init(preferCloudService: Bool = false, snapshot: TutorialSnapshot? = nil) {
        _route = State(initialValue: snapshot?.route ?? (preferCloudService ? .cloudService : .direct))
        self.snapshot = snapshot
    }

    private var blue: Color {
        colorScheme == .dark ? Color(red: 0.49, green: 0.77, blue: 0.98) : Color(red: 0.08, green: 0.37, blue: 0.67)
    }
    private let selection = Color(red: 0.14, green: 0.46, blue: 0.79)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: resumedAt == nil)) { context in
            let frame = TutorialFrame(snapshot?.time ?? position(at: context.date))
            VStack(spacing: 9) {
                HStack {
                    Label(L10n.text("tutorial.title"), systemImage: "play.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(L10n.text("tutorial.illustration"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    ForEach(TutorialRoute.allCases, id: \.self) { option in
                        Button { select(option) } label: {
                            Text(option.title).font(.system(size: 10, weight: route == option ? .semibold : .regular))
                                .frame(maxWidth: .infinity).frame(height: 23)
                                .background(route == option ? blue.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).foregroundStyle(route == option ? blue : .secondary)
                        .accessibilityAddTraits(route == option ? .isSelected : [])
                    }
                }
                scene(frame)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("tutorial.accessibility." + route.rawValue))

                HStack(alignment: .top, spacing: 7) {
                    Text(String(format: "%02d", frame.step + 1))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(blue).padding(.top, 1)
                    Text(route.instruction(frame.step))
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 30, alignment: .top)
                // VoiceOver gets a stable full description above, not a changing announcement.
                .accessibilityHidden(true)

                HStack(spacing: 7) {
                    ForEach(0..<4) { step in
                        Button { jump(to: step) } label: {
                            Capsule().fill(step == frame.step ? blue : blue.opacity(0.18))
                                .frame(width: 25, height: 3).frame(height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(step + 1). " + route.instruction(step))
                        .accessibilityAddTraits(step == frame.step ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                    if reduceMotion {
                        playbackButton("forward.end.fill", "tutorial.next") { jump(to: (frame.step + 1) % 4) }
                    } else {
                        playbackButton(paused ? "play.fill" : "pause.fill", paused ? "tutorial.play" : "tutorial.pause") {
                            paused.toggle(); updateClock()
                        }
                    }
                    playbackButton("arrow.counterclockwise", "tutorial.replay") { restart() }
                }
            }
            .padding(12)
            .background(blue.opacity(colorScheme == .dark ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(blue.opacity(0.12), lineWidth: 1))
        }
        .background(TutorialWindowObserver { active in
            visibleAndActive = active
            updateClock()
        })
        .onChange(of: reduceMotion) { _ in
            if reduceMotion { elapsed = TutorialFrame.stops[TutorialFrame(position(at: Date())).step]; resumedAt = nil }
            updateClock()
        }
        .onDisappear { updateClock(forcePause: true) }
    }

    private func playbackButton(_ symbol: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(blue)
            .help(L10n.text(key)).accessibilityLabel(L10n.text(key))
    }

    private func scene(_ frame: TutorialFrame) -> some View {
        let cloudFolderOpened = route == .cloudService && frame.time >= 8.7
        let fileAppearsAt: Double = route == .cloudService ? 8.7 : 7.8
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor))
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(0..<3) { _ in Circle().fill(Color.secondary.opacity(0.23)).frame(width: 5, height: 5) }
                    Image(systemName: route == .cloudService ? "icloud" : "folder")
                        .padding(.leading, 5)
                    Text(route == .cloudService ? (cloudFolderOpened ? "iCloud Drive / " + L10n.text("tutorial.folder") : "iCloud Drive") : L10n.text("tutorial.folder"))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(height: 27)
                    .background(Color.primary.opacity(0.035))
                Divider().opacity(0.4)
                Spacer()
            }
            if route == .cloudService && !cloudFolderOpened {
                VStack(spacing: 9) {
                    Image(systemName: "folder.fill").font(.system(size: 37)).foregroundStyle(blue)
                    Text(L10n.text("tutorial.folder")).font(.system(size: 10)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(height: 18)
                        .background(selection, in: RoundedRectangle(cornerRadius: 3))
                }.frame(width: 186, height: 97).position(x: 120, y: 92)
            } else if frame.hasFile {
                document(frame)
                    .scaleEffect(reduceMotion ? 1 : 0.85 + 0.15 * frame.ramp(fileAppearsAt, fileAppearsAt + 0.5))
                    .opacity(reduceMotion ? 1 : frame.ramp(fileAppearsAt, fileAppearsAt + 0.35))
                    .position(x: 120, y: 92)
            } else {
                Text(L10n.text("tutorial.empty"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(width: 240, height: 120).offset(y: 28)
            }
            if frame.showsMenu { contextMenu(frame) }
            if frame.step == 3 {
                HStack(spacing: 4) {
                    Image(systemName: frame.finished ? "checkmark" : "return")
                    Text(L10n.text(frame.finished ? "tutorial.done" : "tutorial.return"))
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(blue)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    .frame(width: 240, height: 161, alignment: .bottomTrailing)
                    .offset(x: -8, y: -6)
            }
            if frame.time < 11.8 {
                let point = frame.point(on: route)
                let clickTime = route == .cloudService && frame.step == 2
                    ? (frame.time < 8.7 ? 8.3 : 9.6) : frame.time < 3.4 ? 2.0 : 6.7
                let pulse = max(0, min(1, (frame.time - clickTime) / 0.55))
                Circle().stroke(blue.opacity(pulse > 0 && pulse < 1 ? 1 - pulse : 0), lineWidth: 1.5)
                    .frame(width: 10 + 26 * pulse, height: 10 + 26 * pulse)
                    .position(x: point.x + 3, y: point.y + 3)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Color.primary)
                    .shadow(color: Color(nsColor: .controlBackgroundColor), radius: 1)
                    .position(x: point.x + 5, y: point.y + 8)
            }
        }
        .frame(height: 166)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .allowsHitTesting(false)
        .opacity(reduceMotion ? 1 : frame.time > 17.5 ? 1 - frame.ramp(17.5, 18) : frame.ramp(0, 0.35))
    }

    private func contextMenu(_ frame: TutorialFrame) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 1) {
                menuRow("folder.badge.plus", L10n.text("tutorial.newFolder"), selected: false)
                Divider().padding(.horizontal, 5)
                menuRow(route == .direct ? "doc.badge.plus" : "gearshape", L10n.text(route == .direct ? "finder.newText" : "tutorial.services"),
                        selected: frame.time >= 4.1, chevron: route == .cloudService)
            }
            .padding(4).frame(width: 181).background(menuBackground)
            .offset(x: route == .direct ? 30 : 10, y: 77)
            if route == .cloudService && frame.time >= 5.0 {
                menuRow("doc.badge.plus", L10n.text("finder.newText"), selected: frame.time >= 5.8)
                    .padding(4).frame(width: 181).background(menuBackground)
                    .offset(x: 46, y: 128)
            }
        }
    }

    private var menuBackground: some View {
        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 3)
    }

    private func menuRow(_ symbol: String, _ title: String, selected: Bool, chevron: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 12)
            Text(title).lineLimit(1)
            Spacer(minLength: 1)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)) }
        }.font(.system(size: 10)).padding(.horizontal, 6).frame(height: 21)
            .foregroundStyle(selected ? Color.white : .primary)
            .background(selected ? selection : .clear, in: RoundedRectangle(cornerRadius: 3))
    }

    private func document(_ frame: TutorialFrame) -> some View {
        let original = L10n.text("file.baseName")
        let renamed = L10n.text("tutorial.renamed")
        let typed = Int(Double(renamed.count) * frame.ramp(13.2, 15.2))
        let name = frame.time < 13.2 ? original : String(renamed.prefix(typed))
        let selected = route == .direct || frame.time >= 9.6
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection.opacity(0.23), lineWidth: 1))
                VStack(spacing: 5) {
                    Text("TXT").font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(red: 0.08, green: 0.37, blue: 0.67))
                    Capsule().fill(selection.opacity(0.15)).frame(width: 22, height: 2)
                    Capsule().fill(selection.opacity(0.15)).frame(width: 22, height: 2)
                    Capsule().fill(selection.opacity(0.15)).frame(width: 14, height: 2)
                }
            }.frame(width: 43, height: 55)
                .padding(5).background(selected ? selection.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 0) {
                Text(name).background(frame.editing && frame.time < 13.2 ? selection.opacity(0.25) : .clear)
                if frame.editing && frame.time >= 13.2 { Rectangle().fill(blue).frame(width: 1, height: 11) }
                Text(".txt")
            }
            .font(.system(size: 10)).lineLimit(1)
            .foregroundStyle(frame.editing || !selected ? Color.primary : Color.white)
            .padding(.horizontal, 5).frame(height: 18)
            .background(frame.editing ? Color(nsColor: .textBackgroundColor) : selected ? selection : .clear, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(frame.editing ? blue : .clear, lineWidth: 1))
        }.frame(width: 186, height: 97)
    }

    private func position(at date: Date) -> TimeInterval {
        elapsed + (resumedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    private func updateClock(forcePause: Bool = false) {
        let now = Date()
        elapsed = position(at: now).truncatingRemainder(dividingBy: TutorialFrame.duration)
        resumedAt = !forcePause && snapshot == nil && !reduceMotion && !paused && visibleAndActive ? now : nil
    }

    private func select(_ option: TutorialRoute) { route = option; restart() }

    private func restart() {
        elapsed = reduceMotion ? TutorialFrame.stops[0] : 0
        resumedAt = nil
        paused = false
        updateClock()
    }

    private func jump(to step: Int) {
        elapsed = TutorialFrame.stops[step]
        resumedAt = nil
        paused = true
    }
}

// NSHostingView is hosted by AppKit, so SwiftUI scenePhase is not the lifecycle source.
private struct TutorialWindowObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(onChange: onChange) }
    func updateNSView(_ nsView: ObserverView, context: Context) { nsView.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: (Bool) -> Void
        private var lastValue: Bool?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                NSApplication.didHideNotification, NSApplication.didUnhideNotification]
            for name in names {
                NotificationCenter.default.addObserver(self, selector: #selector(windowActivityChanged), name: name, object: nil)
            }
            DispatchQueue.main.async { [weak self] in self?.publishVisibility() }
        }

        @objc private func windowActivityChanged(_ notification: Notification) {
            // Defer state updates until AppKit finishes the window transition.
            DispatchQueue.main.async { [weak self] in self?.publishVisibility() }
        }

        private func publishVisibility() {
            let value = NSApp.isActive && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true
            guard lastValue != value else { return }
            lastValue = value
            onChange(value)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
