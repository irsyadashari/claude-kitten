import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let kitten = KittenController()
    lazy var panel = SessionsPanelController(store: store)

    private var statusItem: NSStatusItem!
    private var pending: [Nudge] = []
    private var lastSound = Date.distantPast
    private var watch: AnyCancellable?
    private var iconCache: [String: NSImage] = [:]

    private var defaults: UserDefaults { KittenSettings.store }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bid = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil) // another kitten is already on duty
            return
        }
        defaults.register(defaults: ["sound": true, "renudge": true, "quietWhenFocused": false, "alwaysVisible": true, "kittenScale": 4])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusClicked)
        }

        kitten.onTap = { [weak self] in self?.kittenTapped() }
        kitten.onDismiss = { [weak self] in self?.dismissAll() }
        kitten.onRenudge = { [weak self] count in self?.renudge(count) }

        panel.actions = PanelActions(
            open: { [weak self] s in
                self?.panel.close()
                if !HostApp.activate(for: s) { NSSound.beep() }
            },
            close: { [weak self] in self?.panel.close() },
            test: { [weak self] in
                self?.panel.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.testNudge() }
            },
            quit: { NSApp.terminate(nil) },
            alwaysVisibleChanged: { [weak self] in self?.kitten.applyVisibilityPreference() },
            sizeChanged: { [weak self] in self?.kitten.applySize() },
            resetKitten: { [weak self] in
                self?.panel.close()
                self?.kitten.resetPosition()
            }
        )

        store.onNudge = { [weak self] n in self?.receive(n) }
        store.onClear = { [weak self] key in self?.clear(key) }
        store.pendingSince = { [weak self] key in self?.pending.first { $0.sessionKey == key }?.at }
        store.start()

        watch = store.$sessions.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        updateIcon()
        kitten.applyVisibilityPreference()

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.wokeUp() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.kitten.reposition()
        }

        if defaults.object(forKey: "welcomed") == nil {
            defaults.set(true, forKey: "welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.receive(Nudge(id: "welcome", kind: .meow(ok: true), name: "Claude Kitten",
                                    detail: "Hi! I'm on duty now. I'll pop up right here whenever Claude finishes or needs you.",
                                    at: Date(), sessionKey: nil))
            }
        }
    }

    // MARK: Nudges

    private func receive(_ n: Nudge) {
        if let key = n.sessionKey, defaults.bool(forKey: "quietWhenFocused"),
           let s = store.sessions.first(where: { $0.id == key }), HostApp.isFrontmost(for: s) {
            return
        }
        if panel.isVisible {
            if let key = n.sessionKey { panel.ui.highlight.insert(key) }
            purr()
            return
        }
        pending.removeAll { $0.id == n.id }
        pending.append(n)
        kitten.show(pending)
        purr()
        updateIcon()
    }

    private func clear(_ key: String) {
        let before = pending.count
        pending.removeAll { $0.sessionKey == key }
        guard pending.count != before else { return }
        if pending.isEmpty { kitten.settle(wave: false) } else { kitten.update(pending) }
        updateIcon()
    }

    private func dismissAll() {
        pending.removeAll()
        kitten.settle(wave: true)
        updateIcon()
    }

    private func renudge(_ count: Int) {
        guard defaults.bool(forKey: "renudge") else { return }
        kitten.bump()
        if count % 5 == 0 && count <= 15 { purr(force: true) } // a soft purr every ~2 minutes, 3 times max
    }

    private func purr(force: Bool = false) {
        guard defaults.bool(forKey: "sound") else { return }
        guard force || Date().timeIntervalSince(lastSound) > 2 else { return }
        lastSound = Date()
        NSSound(named: "Purr")?.play()
    }

    private func testNudge() {
        receive(Nudge(id: "test-\(Date().timeIntervalSince1970)", kind: .done, name: "Kitten test",
                      detail: "This is how I'll tell you Claude finished. Click me to see every session!",
                      footnote: "took 2m 05s", at: Date(), sessionKey: nil))
    }

    // MARK: Panel

    private enum Source { case kitten, menuBar }

    private func kittenTapped() {
        // A click on the kitten while its panel is open just closes the panel.
        if panel.isVisible { panel.close(); return }
        if Date().timeIntervalSince(panel.lastClosed) < 0.3 { return }
        openPanel(from: .kitten)
    }

    private func openPanel(from source: Source) {
        let keys = Set(pending.compactMap(\.sessionKey))
        pending.removeAll()
        kitten.settle(wave: true)
        updateIcon()
        switch source {
        case .kitten:
            panel.show(anchor: .near(kitten.kittenFrame), highlight: keys)
        case .menuBar:
            let frame = statusItem.button?.window?.frame ?? .zero
            panel.show(anchor: .statusItem(frame), highlight: keys)
        }
    }

    @objc private func statusClicked() {
        if panel.isVisible { panel.close() } else { openPanel(from: .menuBar) }
    }

    private func wokeUp() {
        store.rescanSoon()
        kitten.reposition()
        updateIcon()
    }

    // MARK: Menu bar icon

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let working = store.sessions.filter { $0.state == .working || $0.state == .shell }.count
        let needs = store.sessions.contains { $0.state == .needsYou }
        let blink = working == 0 && pending.isEmpty && !needs
        let badge = !pending.isEmpty || needs
        let key = "\(blink)-\(badge)"
        let img = iconCache[key] ?? PixelPainter.faceImage(blink: blink, badge: badge)
        iconCache[key] = img
        button.image = img
        button.title = working > 0 ? " \(working)" : ""
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let total = store.sessions.count
        let mood: KittenMood = working > 0 ? .working : (needs ? .alert : .sleepy)
        let hint = (total == 0 ? "No Claude sessions right now" :
            working > 0 ? "\(working) working · click for sessions" : "All quiet · click for sessions")
            + " · drag me anywhere"
        kitten.setRestMood(mood, hint: hint)
        button.toolTip = total == 0 ? "Claude Kitten · no sessions" :
            "Claude Kitten · \(total) session\(total == 1 ? "" : "s"), \(working) working"
    }
}
