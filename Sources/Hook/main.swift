import Foundation
import Darwin

// kitten-hook: called by Claude Code hooks (JSON on stdin), or as `meow` from any shell.
// It must never print anything or fail loudly: Claude Code reads hook stdout.

let now = Date().timeIntervalSince1970
let argv0 = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) ?? ""
let args = Array(CommandLine.arguments.dropFirst())

// MARK: - meow (manual nudges from any terminal)

func writeMeow(_ message: String, ok: Bool?) {
    KittenPaths.ensure()
    let ev = MeowEvent(message: message, at: Date().timeIntervalSince1970,
                       cwd: FileManager.default.currentDirectoryPath, ok: ok)
    guard let data = try? JSONEncoder().encode(ev) else { return }
    let url = KittenPaths.events.appendingPathComponent("\(Int(ev.at * 1000))-\(getpid()).json")
    try? data.write(to: url, options: .atomic)
}

func formatDuration(_ secs: Double) -> String {
    let s = Int(secs.rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

func runMeow(_ rest: [String]) -> Never {
    if rest.first == "-h" || rest.first == "--help" {
        print("""
        meow — make the Claude Kitten nudge you 🐾
          meow                    nudge with "Your shell is done!"
          meow "message"          nudge with a message
          meow run <cmd> [args]   run a command, then nudge with how it went
        Tip: long-command; meow
        """)
        exit(0)
    }
    if rest.first == "run" || rest.first == "--" {
        let cmd = Array(rest.dropFirst())
        guard !cmd.isEmpty else { exit(0) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = cmd
        signal(SIGINT, SIG_IGN) // let the child handle Ctrl-C
        let start = Date()
        do { try p.run() } catch {
            writeMeow("Couldn't start \(cmd[0]) 🙀", ok: false)
            exit(127)
        }
        p.waitUntilExit()
        let took = formatDuration(Date().timeIntervalSince(start))
        let name = oneLine(cmd.joined(separator: " "), max: 40) ?? cmd[0]
        let code = p.terminationStatus
        if code == 0 {
            writeMeow("\(name) finished ✅ (\(took))", ok: true)
        } else {
            writeMeow("\(name) failed with exit \(code) 🙀 (\(took))", ok: false)
        }
        exit(code)
    }
    let text = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    writeMeow(text.isEmpty ? "Your shell is done!" : text, ok: nil)
    exit(0)
}

if argv0 == "meow" { runMeow(args) }
if args.first == "meow" || args.first == "say" { runMeow(Array(args.dropFirst())) }

// MARK: - Hook mode

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let sessionId = obj["session_id"] as? String, !sessionId.isEmpty else { exit(0) }
let event = (obj["hook_event_name"] as? String) ?? args.first ?? ""
let env = ProcessInfo.processInfo.environment

/// The Claude Code process that ran this hook (skipping any shell in between).
func claudePID() -> Int32? {
    let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "login"]
    var pid = getppid()
    var firstNonShell: Int32?
    for _ in 0..<6 {
        guard pid > 1 else { break }
        let name = (Proc.name(pid) ?? "").lowercased()
        if name.contains("claude") { return pid }
        if firstNonShell == nil && !shells.contains(name) { firstNonShell = pid }
        guard let parent = Proc.parent(pid) else { break }
        pid = parent
    }
    return firstNonShell ?? getppid()
}

func describeTool(_ name: String, _ input: [String: Any]) -> String {
    func file(_ key: String) -> String {
        (input[key] as? String).map { ($0 as NSString).lastPathComponent } ?? "a file"
    }
    func text(_ key: String, _ max: Int) -> String? { oneLine(input[key] as? String, max: max) }
    switch name {
    case "Bash":
        let what = text("description", 70) ?? text("command", 70) ?? "a command"
        let bg = (input["run_in_background"] as? Bool) == true
        return (bg ? "Started in background: " : "Running: ") + what
    case "Read": return "Reading \(file("file_path"))"
    case "Edit", "MultiEdit": return "Editing \(file("file_path"))"
    case "Write": return "Writing \(file("file_path"))"
    case "NotebookEdit": return "Editing \(file("notebook_path"))"
    case "Grep": return "Searching for “\(text("pattern", 40) ?? "…")”"
    case "Glob": return "Looking for \(text("pattern", 40) ?? "files")"
    case "WebFetch": return "Reading \(URL(string: input["url"] as? String ?? "")?.host ?? "a web page")"
    case "WebSearch": return "Searching the web: \(text("query", 50) ?? "")"
    case "Agent", "Task": return "Delegating: \(text("description", 60) ?? "a subagent")"
    case "TodoWrite", "TaskCreate", "TaskUpdate": return "Updating the to-do list"
    case "Skill": return "Using skill \(input["skill"] as? String ?? "")"
    case "AskUserQuestion": return "Asking you a question"
    case "ExitPlanMode": return "Has a plan ready for you"
    case "Monitor": return "Watching a background task"
    default:
        if name.hasPrefix("mcp__") {
            let parts = name.components(separatedBy: "__").dropFirst()
            return "Using \(parts.joined(separator: " → "))"
        }
        return "Using \(name)"
    }
}

KittenPaths.ensure()
let url = KittenPaths.sessionFile(sessionId)
let lockPath = url.path + ".lock"

if event == "SessionEnd" {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(atPath: lockPath)
    exit(0)
}

let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
if fd >= 0 { flock(fd, LOCK_EX) }
defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }

var st = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(HookState.self, from: $0) }
    ?? HookState(sessionId: sessionId)

st.cwd = (obj["cwd"] as? String) ?? st.cwd
st.pid = claudePID() ?? st.pid
st.configDir = env["CLAUDE_CONFIG_DIR"] ?? st.configDir ?? KittenPaths.home.appendingPathComponent(".claude").path
st.bundleId = env["__CFBundleIdentifier"] ?? st.bundleId

func nudge(_ kind: String) {
    st.nudgeAt = now
    st.nudgeKind = kind
}

let isStale = now < st.updatedAt // an async hook that arrived late
let toolName = obj["tool_name"] as? String ?? ""
let toolInput = obj["tool_input"] as? [String: Any] ?? [:]
let inSubagent = obj["agent_id"] != nil

if !isStale {
    var applied = true
    switch event {
    case "SessionStart":
        st.status = "idle"
        st.activity = nil
        st.needsMessage = nil
    case "UserPromptSubmit":
        st.status = "working"
        st.activity = "Thinking…"
        st.lastPrompt = oneLine(obj["prompt"] as? String, max: 160) ?? st.lastPrompt
        st.turnStartedAt = now
        st.needsMessage = nil
    case "PreToolUse":
        let what = describeTool(toolName, toolInput)
        if !inSubagent && (toolName == "AskUserQuestion" || toolName == "ExitPlanMode") {
            st.status = "needs_you"
            st.needsMessage = toolName == "AskUserQuestion" ? "Claude has a question for you" : "Claude has a plan for you to review"
            nudge("needs_you")
        } else {
            st.status = "working"
            st.needsMessage = nil
        }
        st.activity = inSubagent ? "Subagent · \(what)" : what
    case "PostToolUse", "PostToolUseFailure":
        if st.status == "working" || st.status == "needs_you" {
            st.status = "working"
            st.needsMessage = nil
            st.activity = "Thinking…"
        } else { applied = false }
    case "PermissionRequest":
        st.status = "needs_you"
        st.needsMessage = "Wants permission · \(describeTool(toolName, toolInput))"
        nudge("needs_you")
    case "Notification":
        let type = obj["notification_type"] as? String ?? ""
        let message = oneLine(obj["message"] as? String, max: 140)
        switch type {
        case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            st.status = "needs_you"
            st.needsMessage = message ?? st.needsMessage ?? "Claude needs you"
            nudge("needs_you")
        case "agent_completed":
            if st.status != "working" {
                st.status = "done"
                st.lastMessage = message ?? st.lastMessage
                nudge("done")
            }
        case "":
            // Older versions don't send a type; only permission prompts matter here.
            if let m = message, m.lowercased().contains("permission") {
                st.status = "needs_you"
                st.needsMessage = m
                nudge("needs_you")
            } else { applied = false }
        default:
            applied = false
        }
    case "Stop":
        st.status = "done"
        st.activity = nil
        st.needsMessage = nil
        st.lastMessage = oneLine(obj["last_assistant_message"] as? String, max: 280) ?? st.lastMessage
        if let start = st.turnStartedAt { st.lastTurnSeconds = now - start }
        nudge("done")
    case "StopFailure":
        st.status = "error"
        st.activity = nil
        let err = (obj["error"] as? String) ?? (obj["error_message"] as? String) ?? (obj["message"] as? String)
        st.lastMessage = oneLine(err, max: 200) ?? "Stopped because of an API error"
        nudge("error")
    default:
        applied = false
    }
    if applied {
        st.updatedAt = now
        st.lastEvent = event
    }
}

if let data = try? JSONEncoder().encode(st) {
    try? data.write(to: url, options: .atomic)
}
exit(0)
