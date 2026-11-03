import AppKit
import Combine

enum SState: String {
    case working, shell, needsYou, done, idle, error, unknown

    var sortRank: Int {
        switch self {
        case .needsYou: return 0
        case .error: return 1
        case .working: return 2
        case .shell: return 3
        case .done: return 4
        case .idle: return 5
        case .unknown: return 6
        }
    }
}

struct Session: Identifiable, Equatable {
    let id: String
    var pid: Int32?
    var sessionId: String
    var name: String
    var cwd: String
    var entrypoint: String?
    var configDir: String?
    var regStatus: String?
    var regStatusAt: Double?
    var startedAt: Double?
    var hook: HookState?
    var state: SState = .unknown
    var since: Double = 0
    var activity: String = ""

    var project: String { (cwd as NSString).lastPathComponent }
    var shortPath: String {
        let home = KittenPaths.home.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
}

struct Nudge: Identifiable, Equatable {
    enum Kind: Equatable { case done, needsYou, error, meow(ok: Bool?) }
    let id: String
    var kind: Kind
    var name: String
    var detail: String?
    var footnote: String?
    var at: Date
    var sessionKey: String?
}

private struct RegEntry {
    var pid: Int32
    var sessionId: String
    var cwd: String
    var name: String?
    var status: String?
    var statusUpdatedAt: Double?
    var startedAt: Double?
    var entrypoint: String?
    var configDir: String
}

func formatDuration(_ secs: Double) -> String {
    let s = Int(max(0, secs).rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
    return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
}

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    var onNudge: ((Nudge) -> Void)?
    var onClear: ((String) -> Void)?
    /// When the currently pending nudge for a session was raised, if any.
    var pendingSince: ((String) -> Date?)?

    private var timer: Timer?
    private var prev: [String: Session] = [:]
    private var lastNudgeAt: [String: Double] = [:]
    private var configDirs: [URL] = []
    private var lastDirScan = Date.distantPast

    func start() {
        KittenPaths.ensure()
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Demo only: show made-up sessions instead of real ones.
    func loadDemo(_ list: [Session]) { sessions = list }

    func rescanSoon() { lastDirScan = .distantPast; refresh() }

    func refresh() {
        let now = Date().timeIntervalSince1970
        scanDirsIfNeeded()
        let regs = loadRegistry()
        let hooks = loadHooks()

        var result: [Session] = []
        for r in regs {
            let h = hooks[r.sessionId]
                ?? hooks.values.filter { $0.pid == r.pid }.max { $0.updatedAt < $1.updatedAt }
            var s = Session(id: "p\(r.pid)", pid: r.pid, sessionId: r.sessionId,
                            name: r.name ?? (r.cwd as NSString).lastPathComponent,
                            cwd: r.cwd, entrypoint: r.entrypoint, configDir: r.configDir,
                            regStatus: r.status, regStatusAt: r.statusUpdatedAt,
                            startedAt: r.startedAt, hook: h)
            derive(&s)
            result.append(s)
        }

        // If Claude's session registry is ever missing, fall back to what the hooks know.
        if configDirs.isEmpty {
            for h in hooks.values {
                let cwd = h.cwd ?? KittenPaths.home.path
                var s = Session(id: h.pid.map { "p\($0)" } ?? "s\(h.sessionId)", pid: h.pid,
                                sessionId: h.sessionId, name: (cwd as NSString).lastPathComponent,
                                cwd: cwd, configDir: h.configDir, hook: h)
                derive(&s)
                result.append(s)
            }
        }

        for s in result { checkTransitions(s, now: now) }
        let ids = Set(result.map(\.id))
        for key in prev.keys where !ids.contains(key) { onClear?(key) }
        prev = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        result.sort {
            if $0.state.sortRank != $1.state.sortRank { return $0.state.sortRank < $1.state.sortRank }
            return $0.since > $1.since
        }
        if result != sessions { sessions = result }

        processMeows(now: now)
    }

    // MARK: State

    private func derive(_ s: inout Session) {
        let h = s.hook
        let hookState: SState? = h.map {
            switch $0.status {
            case "working": return .working
            case "needs_you": return .needsYou
            case "done": return .done
            case "error": return .error
            default: return .idle
            }
        }
        let regState: SState? = s.regStatus.map { st in
            switch st {
            case "busy": return .working
            case "shell": return .shell
            case "idle": return .idle
            default:
                let l = st.lowercased()
                if l.contains("wait") || l.contains("perm") || l.contains("input") { return .needsYou }
                return .working
            }
        }
        let hT = h?.updatedAt ?? 0
        let rT = s.regStatusAt ?? 0

        var state: SState
        var fromHook = false
        switch (hookState, regState) {
        case (nil, nil):
            state = .unknown
        case (let a?, nil):
            state = a; fromHook = true
        case (nil, let b?):
            state = b
        case (let a?, let b?):
            if b == .idle && (a == .done || a == .error) {
                state = a; fromHook = true
            } else if b == .shell {
                if a == .needsYou && hT > rT { state = .needsYou; fromHook = true } else { state = .shell }
            } else if hT >= rT - 0.5 {
                state = (a == .idle && b == .working) ? .working : a
                fromHook = state == a
            } else {
                state = b
            }
        }
        s.state = state

        switch state {
        case .working:
            s.since = fromHook ? (h?.turnStartedAt ?? hT) : rT
            s.activity = fromHook ? (h?.activity ?? "Thinking…") : "Working…"
        case .shell:
            s.since = rT
            s.activity = "Running a shell command"
        case .needsYou:
            s.since = fromHook ? hT : rT
            s.activity = h?.needsMessage ?? "Waiting for your answer"
        case .done:
            s.since = hT
            if let secs = h?.lastTurnSeconds, secs >= 1 {
                s.activity = "Finished in \(formatDuration(secs))"
            } else {
                s.activity = "Finished"
            }
        case .error:
            s.since = hT
            s.activity = "Stopped with an error"
        case .idle:
            s.since = max(rT, fromHook ? hT : 0)
            s.activity = "Ready for your next message"
        case .unknown:
            s.since = max(rT, hT)
            s.activity = s.regStatus ?? "Unknown"
        }
        if s.since == 0 { s.since = s.startedAt ?? Date().timeIntervalSince1970 }
    }

    private func checkTransitions(_ s: Session, now: Double) {
        let old = prev[s.id]

        // Hook-driven nudges (precise: done, needs you, error).
        if let h = s.hook, let at = h.nudgeAt, at > (lastNudgeAt[s.id] ?? now - 15) {
            lastNudgeAt[s.id] = at
            switch h.nudgeKind {
            case "needs_you":
                // Give it a few seconds: if the prompt is answered (or auto-approved) quickly, stay quiet.
                let key = s.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, let cur = self.prev[key], cur.state == .needsYou,
                          cur.hook?.nudgeAt == at else { return }
                    self.emit(cur, kind: .needsYou)
                }
            case "error":
                emit(s, kind: .error)
            default:
                emit(s, kind: .done)
            }
        }

        // Registry-only fallback for sessions started before the hooks were installed.
        if s.hook == nil, let o = old {
            let wasBusy = o.regStatus == "busy" || o.regStatus == "shell"
            if wasBusy && s.regStatus == "idle" { emit(s, kind: .done) }
            if o.state != .needsYou && s.state == .needsYou { emit(s, kind: .needsYou) }
        }

        // The user has picked this session back up: drop its pending nudge.
        if let pendingAt = pendingSince?(s.id)?.timeIntervalSince1970 {
            var resumed = false
            if let h = s.hook, h.updatedAt > pendingAt + 0.5,
               ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(h.lastEvent),
               s.state == .working {
                resumed = true
            }
            if let o = old, o.regStatus == "idle", s.regStatus == "busy",
               (s.regStatusAt ?? 0) > pendingAt + 0.5 {
                resumed = true
            }
            if resumed { onClear?(s.id) }
        }
    }

    private func emit(_ s: Session, kind: Nudge.Kind) {
        var detail: String?
        var foot: String?
        switch kind {
        case .done:
            detail = s.hook?.lastMessage
            if let secs = s.hook?.lastTurnSeconds, secs >= 5 { foot = "took \(formatDuration(secs))" }
        case .needsYou:
            detail = s.hook?.needsMessage ?? "Claude is waiting for you"
        case .error:
            detail = s.hook?.lastMessage
        case .meow:
            break
        }
        onNudge?(Nudge(id: s.id, kind: kind, name: s.name, detail: detail, footnote: foot,
                       at: Date(), sessionKey: s.id))
    }

    private func processMeows(now: Double) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: KittenPaths.events, includingPropertiesForKeys: nil) else { return }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let ev = try? JSONDecoder().decode(MeowEvent.self, from: data),
                  now - ev.at < 600 else { continue }
            let place = ev.cwd.map { ($0 as NSString).lastPathComponent } ?? "your shell"
            onNudge?(Nudge(id: "meow-\(ev.at)", kind: .meow(ok: ev.ok), name: place,
                           detail: ev.message, at: Date(), sessionKey: nil))
        }
    }

    // MARK: Loading

    private func scanDirsIfNeeded() {
        guard Date().timeIntervalSince(lastDirScan) > 30 else { return }
        lastDirScan = Date()
        let fm = FileManager.default
        let home = KittenPaths.home
        var dirs: [URL] = []
        for name in (try? fm.contentsOfDirectory(atPath: home.path)) ?? [] where name.hasPrefix(".claude") {
            let dir = home.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent("sessions").path, isDirectory: &isDir), isDir.boolValue {
                dirs.append(dir)
            }
        }
        configDirs = dirs
    }

    private func loadRegistry() -> [RegEntry] {
        let fm = FileManager.default
        var out: [Int32: RegEntry] = [:]
        for dir in configDirs {
            let sdir = dir.appendingPathComponent("sessions")
            for name in (try? fm.contentsOfDirectory(atPath: sdir.path)) ?? [] where name.hasSuffix(".json") {
                guard let data = fm.contents(atPath: sdir.appendingPathComponent(name).path),
                      let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let pidNum = o["pid"] as? NSNumber,
                      let sid = o["sessionId"] as? String else { continue }
                let pid = pidNum.int32Value
                guard Proc.isAlive(pid), looksLikeClaude(pid) else { continue }
                func secs(_ k: String) -> Double? { (o[k] as? NSNumber).map { $0.doubleValue / 1000 } }
                let entry = RegEntry(pid: pid, sessionId: sid,
                                     cwd: o["cwd"] as? String ?? KittenPaths.home.path,
                                     name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                     status: o["status"] as? String,
                                     statusUpdatedAt: secs("statusUpdatedAt") ?? secs("updatedAt"),
                                     startedAt: secs("startedAt"),
                                     entrypoint: o["entrypoint"] as? String,
                                     configDir: dir.path)
                if let existing = out[pid], (existing.statusUpdatedAt ?? 0) > (entry.statusUpdatedAt ?? 0) { continue }
                out[pid] = entry
            }
        }
        return Array(out.values)
    }

    private func looksLikeClaude(_ pid: Int32) -> Bool {
        guard let name = Proc.name(pid)?.lowercased() else { return true }
        return name.contains("claude") || name.contains("node") || name.contains("bun")
    }

    private func loadHooks() -> [String: HookState] {
        let fm = FileManager.default
        var out: [String: HookState] = [:]
        let now = Date().timeIntervalSince1970
        for url in (try? fm.contentsOfDirectory(at: KittenPaths.sessions, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let h = try? JSONDecoder().decode(HookState.self, from: data) else { continue }
            let dead = h.pid.map { !Proc.isAlive($0) } ?? (now - h.updatedAt > 86_400)
            if dead {
                try? fm.removeItem(at: url)
                try? fm.removeItem(atPath: url.path + ".lock")
                continue
            }
            out[h.sessionId] = h
        }
        return out
    }
}

/// Finds the app (Terminal, iTerm, VS Code, …) a session runs in.
enum HostApp {
    static func find(for s: Session) -> NSRunningApplication? {
        var p = s.pid
        for _ in 0..<15 {
            guard let pid = p, pid > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
            p = Proc.parent(pid)
        }
        let bundle = s.hook?.bundleId ?? s.pid.flatMap(bundleIdFromEnv)
            ?? (s.entrypoint == "claude-desktop" ? "com.anthropic.claudefordesktop" : nil)
        if let b = bundle { return NSRunningApplication.runningApplications(withBundleIdentifier: b).first }
        return nil
    }

    @discardableResult
    static func activate(for s: Session) -> Bool {
        guard let app = find(for: s), let url = app.bundleURL else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        return true
    }

    static func isFrontmost(for s: Session) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, let app = find(for: s) else { return false }
        return front.processIdentifier == app.processIdentifier
    }

    /// Reads __CFBundleIdentifier from another of the user's processes (set by the terminal app).
    static func bundleIdFromEnv(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let key = Array("__CFBundleIdentifier=".utf8)
        var i = 0
        while i < size {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            if j - i > key.count, Array(buf[i..<(i + key.count)]) == key {
                return String(decoding: buf[(i + key.count)..<j], as: UTF8.self)
            }
            i = j + 1
        }
        return nil
    }
}
