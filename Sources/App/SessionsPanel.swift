import AppKit
import SwiftUI
import Combine

struct PanelActions {
    var open: (Session) -> Void = { _ in }
    var close: () -> Void = {}
    var test: () -> Void = {}
    var quit: () -> Void = {}
    var alwaysVisibleChanged: () -> Void = {}
    var sizeChanged: () -> Void = {}
    var resetKitten: () -> Void = {}
}

final class PanelUI: ObservableObject {
    @Published var highlight: Set<String> = []
    /// Demo only: a row shown as hovered, and where each row sits in the panel.
    @Published var demoHover: String?
    var rowFrames: [String: CGRect] = [:]
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

final class SessionsPanelController: NSObject, NSWindowDelegate {
    enum Anchor { case statusItem(NSRect), near(NSRect) }

    let store: SessionStore
    let ui = PanelUI()
    var actions = PanelActions()
    private var panel: KeyPanel?
    private var anchor: Anchor = .near(.zero)
    private(set) var lastClosed = Date.distantPast
    private var sizeWatch: AnyCancellable?

    init(store: SessionStore) {
        self.store = store
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: NSRect? { panel?.frame }

    func show(anchor: Anchor, highlight: Set<String>) {
        self.anchor = anchor
        ui.highlight = highlight
        let p = panel ?? makePanel()
        panel = p
        layout()
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        sizeWatch = store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.layout() } }
    }

    func close() {
        sizeWatch = nil
        if panel?.isVisible == true { lastClosed = Date() }
        panel?.orderOut(nil)
        ui.highlight = []
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func makePanel() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        let root = SessionsView(store: store, ui: ui, actions: { [weak self] in self?.actions ?? PanelActions() })
            .defaultAppStorage(KittenSettings.store)
        p.contentView = NSHostingView(rootView: root)
        return p
    }

    private func layout() {
        guard let p = panel, let content = p.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var origin: NSPoint
        switch anchor {
        case .statusItem(let r):
            let screen = NSScreen.screens.first { $0.frame.intersects(r) } ?? NSScreen.main
            let vf = screen?.visibleFrame ?? r
            origin = NSPoint(x: min(max(r.midX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8),
                             y: r.minY - size.height - 6)
        case .near(let k):
            // Next to the kitten: above it if there's room, otherwise below.
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: k.midX, y: k.midY)) } ?? NSScreen.main
            let vf = screen?.visibleFrame ?? .zero
            var x = k.midX > vf.midX ? k.maxX - size.width : k.minX
            var y = k.maxY + 6
            if y + size.height > vf.maxY { y = k.minY - size.height - 6 }
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
            y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
            origin = NSPoint(x: x, y: y)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.invalidateShadow()
    }
}

// MARK: - Views

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct SessionsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: PanelUI
    let actions: () -> PanelActions

    @AppStorage("sound") private var sound = true
    @AppStorage("renudge") private var renudge = true
    @AppStorage("quietWhenFocused") private var quiet = false
    @AppStorage("alwaysVisible") private var always = true
    @AppStorage("kittenScale") private var scale = 4
    @State private var login = LaunchAgent.isInstalled

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 400)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var summary: String {
        let s = store.sessions
        if s.isEmpty { return "No Claude sessions open" }
        var parts: [String] = []
        func add(_ n: Int, _ label: String) { if n > 0 { parts.append("\(n) \(label)") } }
        add(s.filter { $0.state == .needsYou }.count, "need you")
        add(s.filter { $0.state == .working || $0.state == .shell }.count, "working")
        add(s.filter { $0.state == .done }.count, "done")
        add(s.filter { $0.state == .idle || $0.state == .unknown }.count, "idle")
        add(s.filter { $0.state == .error }.count, "errored")
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 10) {
            MiniKitten(mood: store.sessions.contains { $0.state == .working || $0.state == .shell } ? .plain : .sleepy)
                .frame(width: 52, height: 52)
                .padding(.vertical, -6)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Kitten")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(summary)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { actions().close() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if store.sessions.isEmpty {
            VStack(spacing: 6) {
                MiniKitten(mood: .sleepy).frame(width: 78, height: 78)
                Text("All quiet… zzz")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Start `claude` in a terminal and I'll keep watch 🐾")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let rows = VStack(spacing: 2) {
                    ForEach(store.sessions) { s in
                        SessionRow(s: s, now: tl.date.timeIntervalSince1970,
                                   highlighted: ui.highlight.contains(s.id),
                                   forcedHover: ui.demoHover == s.id,
                                   onOpen: { actions().open(s) })
                            .background(GeometryReader { g in
                                Color.clear
                                    .onAppear { ui.rowFrames[s.id] = g.frame(in: .global) }
                                    .onChange(of: g.frame(in: .global)) { _, f in ui.rowFrames[s.id] = f }
                            })
                    }
                }
                .padding(6)
                if store.sessions.count > 4 {
                    ScrollView { rows }.frame(height: 430)
                } else {
                    rows
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Toggle("Purr sound", isOn: $sound)
                Toggle("Keep nudging", isOn: $renudge)
                    .help("Hop again every 25 seconds until you click me")
                Toggle("Open at login", isOn: $login)
                    .onChange(of: login) { _, on in LaunchAgent.set(on) }
            }
            HStack(spacing: 8) {
                Text("Kitten size")
                Picker("Kitten size", selection: $scale) {
                    ForEach(KittenController.sizes, id: \.scale) { Text($0.label).tag($0.scale) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: scale) { _, _ in actions().sizeChanged() }
            }
            Toggle("Always show the kitten (drag it anywhere you like)", isOn: $always)
                .onChange(of: always) { _, _ in actions().alwaysVisibleChanged() }
            Toggle("Stay quiet if I'm already looking at that terminal", isOn: $quiet)
            HStack {
                Button("Test nudge 🐾") { actions().test() }
                Button("Put kitten back in the corner") { actions().resetKitten() }
                Spacer()
                Button("Quit Kitten") { actions().quit() }
            }
            .controlSize(.small)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11.5, design: .rounded))
        .padding(12)
    }
}

struct SessionRow: View {
    let s: Session
    let now: Double
    let highlighted: Bool
    var forcedHover = false
    let onOpen: () -> Void
    @State private var hover = false

    private var color: Color {
        switch s.state {
        case .working: return claudeOrange
        case .shell: return .blue
        case .needsYou: return Color(.sRGB, red: 0.86, green: 0.6, blue: 0.05, opacity: 1)
        case .done: return .green
        case .error: return .red
        case .idle, .unknown: return .secondary
        }
    }

    private var symbol: String {
        switch s.state {
        case .working: return "pawprint.fill"
        case .shell: return "terminal.fill"
        case .needsYou: return "hand.raised.fill"
        case .done: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "moon.zzz.fill"
        case .unknown: return "questionmark"
        }
    }

    private var timeText: String {
        let d = formatDuration(now - s.since)
        switch s.state {
        case .working, .shell: return "for \(d)"
        case .needsYou: return "waiting \(d)"
        case .done, .error: return "\(d) ago"
        case .idle, .unknown: return "idle \(d)"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, isActive: s.state == .working || s.state == .needsYou)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    if highlighted {
                        Text("NEW")
                            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(claudeOrange))
                    }
                    Spacer(minLength: 4)
                    Text(timeText)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(s.activity)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(2)
                if (s.state == .done || s.state == .error), let m = s.hook?.lastMessage {
                    Text(m)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let p = s.hook?.lastPrompt {
                    Label { Text(p).lineLimit(1) } icon: { Image(systemName: "text.bubble") }
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(s.shortPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover || forcedHover ? Color.primary.opacity(0.08) : (highlighted ? claudeOrange.opacity(0.09) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onOpen)
        .help("Click to jump to this session's window")
        .contextMenu {
            Button("Go to its terminal", action: onOpen)
            Button("Show folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)])
            }
            Button("Copy resume command") {
                let cmd = "cd \(shellQuote(s.cwd)) && claude --resume \(s.sessionId)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            }
        }
    }
}

private func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Login item

enum LaunchAgent {
    static let label = "dev.claudekitten.app"
    static var plistURL: URL {
        KittenPaths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func set(_ on: Bool) {
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: plistURL, options: .atomic)
            }
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}
