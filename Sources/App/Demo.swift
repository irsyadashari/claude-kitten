import AppKit
import SwiftUI

// `ClaudeKitten --demo [out.mov]` plays a scripted walkthrough on a clean, made-up desktop
// (fake terminal, fake sessions, fake cursor) and can record it with screencapture.
// It uses its own settings store, so it never changes the user's kitten.

struct TermLine: Identifiable {
    let id = UUID()
    var text: String
    var color: Color
}

final class DemoModel: ObservableObject {
    @Published var caption = ""
    @Published var lines: [TermLine] = []
    @Published var flash = false
}

struct DemoStage: View {
    @ObservedObject var m: DemoModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.17, green: 0.15, blue: 0.32),
                                    Color(red: 0.48, green: 0.27, blue: 0.42),
                                    Color(red: 0.86, green: 0.52, blue: 0.40)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            terminal
                .frame(width: 500, height: 290)
                .offset(x: 40, y: 92)

            HStack {
                Spacer()
                Text(m.caption)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                    .id(m.caption)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                Spacer()
            }
            .padding(.top, 22)
            .animation(.easeOut(duration: 0.35), value: m.caption)
        }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                Spacer()
                Text("~/my-app — claude").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.55))
                Spacer()
                Color.clear.frame(width: 50, height: 1)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.white.opacity(0.06))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(m.lines) { l in
                    Text(l.text).foregroundColor(l.color).transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, design: .monospaced))
            .padding(14)
            .animation(.easeOut(duration: 0.25), value: m.lines.count)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.11, green: 0.11, blue: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(m.flash ? claudeOrange : Color.white.opacity(0.12), lineWidth: m.flash ? 3 : 1))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .animation(.easeInOut(duration: 0.25), value: m.flash)
    }
}

final class CursorModel: ObservableObject {
    @Published var clickAt = Date.distantPast
}

struct FakeCursor: View {
    @ObservedObject var m: CursorModel
    static let half: CGFloat = 40

    var body: some View {
        TimelineView(.animation) { tl in
            let age = tl.date.timeIntervalSince(m.clickAt)
            ZStack(alignment: .topLeading) {
                if age < 0.45 {
                    Circle()
                        .stroke(claudeOrange.opacity(1 - age / 0.45), lineWidth: 3)
                        .frame(width: 10 + age * 80, height: 10 + age * 80)
                        .position(x: Self.half, y: Self.half)
                }
                Image(nsImage: NSCursor.arrow.image)
                    .resizable()
                    .frame(width: NSCursor.arrow.image.size.width * 1.4, height: NSCursor.arrow.image.size.height * 1.4)
                    .scaleEffect(age < 0.15 ? 0.85 : 1, anchor: .topLeading)
                    .offset(x: Self.half - NSCursor.arrow.hotSpot.x * 1.4, y: Self.half - NSCursor.arrow.hotSpot.y * 1.4)
            }
            .frame(width: Self.half * 2, height: Self.half * 2, alignment: .topLeading)
        }
    }
}

final class DemoDirector {
    let model = DemoModel()
    let cursorModel = CursorModel()
    let store = SessionStore()
    let kitten: KittenController
    let panel: SessionsPanelController
    private let stage: NSWindow
    private let cursor: NSPanel
    let stageRect: NSRect
    private var cursorPos: NSPoint
    private var pending: [Nudge] = []
    private var recorder: Process?

    init() {
        let vf = (NSScreen.screens.first ?? NSScreen.main)!.visibleFrame
        let size = NSSize(width: min(1040, vf.width - 40), height: min(760, vf.height - 20))
        stageRect = NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height)

        let suite = "dev.claudekitten.demo"
        UserDefaults().removePersistentDomain(forName: suite)
        let d = UserDefaults(suiteName: suite)!
        KittenSettings.store = d
        d.set(true, forKey: "alwaysVisible")
        d.set(false, forKey: "sound")
        d.set(false, forKey: "renudge")
        d.set(true, forKey: "quietWhenFocused")
        d.set(4, forKey: "kittenScale")
        d.set(stageRect.maxX - 104 - 28, forKey: "kittenX")
        d.set(stageRect.minY + 14, forKey: "kittenY")

        stage = NSWindow(contentRect: stageRect, styleMask: [.borderless], backing: .buffered, defer: false)
        stage.level = NSWindow.Level(rawValue: 2)
        stage.contentView = NSHostingView(rootView: DemoStage(m: model))
        stage.collectionBehavior = [.canJoinAllSpaces]

        cursor = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: FakeCursor.half * 2, height: FakeCursor.half * 2),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        cursor.isOpaque = false
        cursor.backgroundColor = .clear
        cursor.level = .screenSaver
        cursor.ignoresMouseEvents = true
        cursor.contentView = NSHostingView(rootView: FakeCursor(m: cursorModel))
        cursorPos = NSPoint(x: stageRect.midX, y: stageRect.midY)

        kitten = KittenController()
        panel = SessionsPanelController(store: store)
    }

    func start(recordTo path: String?) {
        store.loadDemo(Self.sessions())
        // Park the real mouse pointer outside the recorded area.
        CGWarpMouseCursorPosition(CGPoint(x: 4, y: 4))
        stage.orderFrontRegardless()
        placeCursor(cursorPos)
        cursor.orderFrontRegardless()

        panel.actions = PanelActions(open: { [weak self] _ in self?.panel.close() }, close: { [weak self] in self?.panel.close() })
        kitten.onTap = {}
        kitten.onDismiss = {}

        let total = 47.0
        if let path {
            // screencapture wants a top-left origin.
            let screenH = NSScreen.screens.first!.frame.height
            let r = stageRect
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-v", "-V", "\(Int(total))", "-R",
                           "\(Int(r.minX)),\(Int(screenH - r.maxY)),\(Int(r.width)),\(Int(r.height))", path]
            try? p.run()
            recorder = p
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 1.5) {
            self.recorder?.waitUntilExit()
            NSApp.terminate(nil)
        }
    }

    // MARK: Script

    private func at(_ t: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f)
    }

    private func line(_ text: String, _ color: Color = .white.opacity(0.85)) {
        model.lines.append(TermLine(text: text, color: color))
    }

    private func play() {
        let dim = Color.white.opacity(0.5)
        let orange = claudeOrange
        model.caption = "Meet Claude Kitten 🐾"
        kitten.setRestMood(.working, hint: "")
        kitten.applyVisibilityPreference()
        line("$ claude", dim)
        at(1.2) { self.line("> add a dark mode toggle to the settings page") }
        at(2.4) {
            self.model.caption = "While Claude works, the kitten kneads in its box"
            self.line("⏺ Reading SettingsView.swift", orange)
        }
        at(3.6) { self.line("⏺ Editing SettingsView.swift", orange) }
        at(4.8) { self.line("⏺ Editing Theme.swift", orange) }
        at(6.0) { self.line("⏺ Running: swift test", orange) }
        at(7.6) {
            self.line("  ⎿ 42 tests passed", .green)
            self.line("⏺ Done! Dark mode is in and all 42 tests pass.")
        }

        // 1. It tells you when Claude is done.
        at(8.2) {
            self.model.caption = "When Claude finishes, it pops up to tell you ✨"
            self.kitten.setRestMood(.sleepy, hint: "")
            self.nudge(Nudge(id: "p1", kind: .done, name: "my-app",
                             detail: "Done! Dark mode is in and all 42 tests pass.",
                             footnote: "took 2m 14s", at: Date(), sessionKey: "p1"))
        }
        at(12.5) {
            self.model.caption = "…and when Claude needs your OK 👀"
            self.nudge(Nudge(id: "p2", kind: .needsYou, name: "api-server",
                             detail: "Wants permission · Running: deploy to staging", at: Date(), sessionKey: "p2"))
        }

        // 2. Click it to see every session.
        at(16.5) {
            self.model.caption = "Click the kitten to see every session"
            self.move(to: NSPoint(x: self.kitten.kittenFrame.midX, y: self.kitten.kittenFrame.midY - 6), in: 1.1)
        }
        at(17.8) {
            self.click()
            let keys = Set(self.pending.compactMap(\.sessionKey))
            self.pending.removeAll()
            self.kitten.settle(wave: true)
            self.panel.show(anchor: .near(self.kitten.kittenFrame), highlight: keys)
        }
        at(19.0) { self.model.caption = "What each one is doing, your last prompt, and Claude's reply" }
        at(19.6) { self.moveToRow("p3", in: 0.9) }
        at(21.4) { self.moveToRow("p2", in: 0.6) }
        at(23.4) {
            self.model.caption = "Click a session to jump to its terminal"
            self.moveToRow("p1", in: 0.6)
        }
        at(25.2) {
            self.click()
            self.panel.ui.demoHover = nil
            self.panel.close()
            self.model.flash = true
        }
        at(26.2) { self.model.flash = false }

        // 3. Drag it anywhere.
        at(27.0) {
            self.model.caption = "Drag it anywhere, so it never gets in your way"
            self.move(to: NSPoint(x: self.kitten.kittenFrame.midX, y: self.kitten.kittenFrame.midY), in: 0.8)
        }
        at(28.0) {
            // Cursor holds the kitten by its middle; drop it fully inside the stage, bottom-left.
            let half = self.kitten.kittenFrame.width / 2
            self.drag(to: NSPoint(x: self.stageRect.minX + 40 + half, y: self.stageRect.minY + 14 + half), in: 1.8)
        }

        // 4. Pick a size.
        at(31.0) {
            self.model.caption = "Pick a size, from Tiny to Huge"
            self.move(to: NSPoint(x: self.stageRect.midX + 120, y: self.stageRect.midY - 60), in: 0.8)
        }
        at(31.8) { self.setSize(6) }
        at(33.2) { self.setSize(2) }
        at(34.6) { self.setSize(4) }

        // 5. Any shell command.
        at(36.0) {
            self.model.caption = "Works for any shell command, too: long-command; meow"
            self.line("$ npm run build; meow", dim)
        }
        at(37.4) {
            self.nudge(Nudge(id: "meow", kind: .meow(ok: true), name: "my-app",
                             detail: "npm run build finished ✅ (48s)", at: Date(), sessionKey: nil))
        }
        at(42.0) {
            self.kitten.settle(wave: true)
            self.model.caption = "Install it with ./install.sh 🐾"
        }
    }

    // MARK: Helpers

    private func nudge(_ n: Nudge) {
        pending.removeAll { $0.id == n.id }
        pending.append(n)
        kitten.show(pending)
    }

    private func setSize(_ scale: Int) {
        KittenSettings.store.set(scale, forKey: "kittenScale")
        kitten.applySize()
    }

    private func moveToRow(_ id: String, in secs: Double) {
        guard let f = panel.frame, let r = panel.ui.rowFrames[id] else { return }
        let target = NSPoint(x: f.minX + r.minX + 120, y: f.maxY - r.midY)
        move(to: target, in: secs, done: { self.panel.ui.demoHover = id })
    }

    private func click() { cursorModel.clickAt = Date() }

    private func placeCursor(_ p: NSPoint) {
        cursorPos = p
        cursor.setFrameOrigin(NSPoint(x: p.x - FakeCursor.half, y: p.y - FakeCursor.half))
    }

    private func move(to target: NSPoint, in secs: Double, step: ((NSPoint) -> Void)? = nil, done: (() -> Void)? = nil) {
        let from = cursorPos
        let start = Date()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let k = min(1, Date().timeIntervalSince(start) / secs)
            let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
            let p = NSPoint(x: from.x + (target.x - from.x) * e, y: from.y + (target.y - from.y) * e)
            self.placeCursor(p)
            step?(p)
            if k >= 1 { timer.invalidate(); done?() }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Carries the kitten along with the cursor.
    private func drag(to target: NSPoint, in secs: Double) {
        let grab = NSPoint(x: cursorPos.x - kitten.kittenFrame.minX, y: cursorPos.y - kitten.kittenFrame.minY)
        click()
        move(to: target, in: secs, step: { p in
            self.kitten.demoPlace(NSPoint(x: p.x - grab.x, y: p.y - grab.y), held: true)
        }, done: {
            self.kitten.demoPlace(NSPoint(x: target.x - grab.x, y: target.y - grab.y), held: false)
        })
    }

    static func sessions() -> [Session] {
        let now = Date().timeIntervalSince1970
        func hook(_ id: String, _ status: String, prompt: String?, message: String?, needs: String? = nil,
                  activity: String? = nil, secs: Double? = nil) -> HookState {
            var h = HookState(sessionId: id)
            h.status = status
            h.lastPrompt = prompt
            h.lastMessage = message
            h.needsMessage = needs
            h.activity = activity
            h.lastTurnSeconds = secs
            h.updatedAt = now
            return h
        }
        var list: [Session] = []
        var a = Session(id: "p2", sessionId: "demo-2", name: "api-server", cwd: "~/code/api-server")
        a.hook = hook("demo-2", "needs_you", prompt: "ship the new rate limiter to staging", message: nil,
                      needs: "Wants permission · Running: deploy to staging")
        a.state = .needsYou; a.since = now - 4; a.activity = "Wants permission · Running: deploy to staging"
        list.append(a)
        var b = Session(id: "p3", sessionId: "demo-3", name: "docs-site", cwd: "~/code/docs-site")
        b.hook = hook("demo-3", "working", prompt: "rewrite the getting started guide", message: nil)
        b.state = .working; b.since = now - 95; b.activity = "Editing getting-started.md"
        list.append(b)
        var c = Session(id: "p1", sessionId: "demo-1", name: "my-app", cwd: "~/code/my-app")
        c.hook = hook("demo-1", "done", prompt: "add a dark mode toggle to the settings page",
                      message: "Done! Dark mode is in and all 42 tests pass.", secs: 134)
        c.state = .done; c.since = now - 9; c.activity = "Finished in 2m 14s"
        list.append(c)
        var d = Session(id: "p4", sessionId: "demo-4", name: "data-pipeline", cwd: "~/code/data-pipeline")
        d.hook = hook("demo-4", "idle", prompt: "why is the nightly job slow?",
                      message: "The join on events was missing an index. Added one; it now runs in 4 minutes.")
        d.state = .idle; d.since = now - 1260; d.activity = "Ready for your next message"
        list.append(d)
        return list
    }
}
