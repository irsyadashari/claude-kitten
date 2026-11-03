import Foundation
import Darwin

/// Where the hook helper writes session state and the app reads it.
enum KittenPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/ClaudeKitten", isDirectory: true)
    static let sessions = support.appendingPathComponent("sessions", isDirectory: true)
    static let events = support.appendingPathComponent("events", isDirectory: true)

    static func ensure() {
        for dir in [sessions, events] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func sessionFile(_ sessionId: String) -> URL {
        let safe = sessionId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return sessions.appendingPathComponent("\(safe).json")
    }
}

/// What the hooks know about one Claude Code session.
struct HookState: Codable, Equatable {
    var sessionId: String
    var pid: Int32?
    var cwd: String?
    var configDir: String?
    var bundleId: String?
    /// working | needs_you | done | idle | error
    var status: String = "idle"
    var activity: String?
    var lastPrompt: String?
    var lastMessage: String?
    var needsMessage: String?
    var turnStartedAt: Double?
    var lastTurnSeconds: Double?
    var lastEvent: String = ""
    var updatedAt: Double = 0
    /// Set whenever something nudge-worthy happens.
    var nudgeAt: Double?
    /// done | needs_you | error
    var nudgeKind: String?
}

/// A one-off message from the `meow` command.
struct MeowEvent: Codable {
    var message: String
    var at: Double
    var cwd: String?
    var ok: Bool?
}

enum Proc {
    static func info(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func parent(_ pid: pid_t) -> pid_t? {
        guard let i = info(pid) else { return nil }
        let p = i.kp_eproc.e_ppid
        return p > 0 ? p : nil
    }

    static func name(_ pid: pid_t) -> String? {
        guard var i = info(pid) else { return nil }
        return withUnsafePointer(to: &i.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}

/// Collapse whitespace, drop common markdown noise, and cap the length.
func oneLine(_ s: String?, max: Int) -> String? {
    guard let s else { return nil }
    var text = s.replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "`", with: "")
    text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    while text.hasPrefix("#") { text.removeFirst() }
    text = text.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return nil }
    return text.count > max ? String(text.prefix(max - 1)) + "…" : text
}
