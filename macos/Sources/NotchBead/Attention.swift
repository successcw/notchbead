import AppKit

/// Something an agent app is waiting on you for: a reply or approval, a finished run you haven't
/// looked at, or an error. Items are worked out fresh on every poll, so one disappears by itself
/// as soon as its app no longer reports it.
struct AttentionItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Stopped to ask you something: approval, a choice, a reply.
        case waiting
        case finished
        case failed
    }

    enum Source: String, Sendable {
        case orca = "Orca"
        case workBuddy = "WorkBuddy"
        case chatGPT = "ChatGPT"

        /// The app whose icon stands for this source beside Bead.
        var bundleID: String {
            switch self {
            case .orca: OrcaAttention.bundleID
            case .workBuddy: WorkBuddyAttention.bundleID
            case .chatGPT: ChatGPTAttention.bundleID
            }
        }

        /// Each source once, in the order its first item appears.
        static func distinct(in items: [AttentionItem]) -> [Source] {
            var seen = Set<Source>()
            return items.map(\.source).filter { seen.insert($0).inserted }
        }
    }

    /// Changes when the same pane or session needs you again, so a dismissal covers one occasion only.
    var id: String
    var source: Source
    var kind: Kind
    /// The conversation or session name.
    var title: String
    /// The project it belongs to.
    var project: String?
    /// Which agent, such as "claude" or "pi".
    var agent: String?
    var since: Date
    /// How to bring you to it.
    var target: Target

    enum Target: Equatable, Sendable {
        case orcaPane(paneKey: String)
        case app(bundleID: String)
    }
}

// MARK: - Orca

/// Reads Orca's own view of its agents with its bundled CLI (`orca worktree ps --json`).
/// Two signals for "finished and you haven't seen it": Orca's own unread mark on a workspace, and
/// NotchBead watching each agent go from working to done. The second is needed because Orca counts
/// a workspace open in any of its windows as seen, so a reply in another Orca window never goes unread.
enum OrcaAttention {
    static let bundleID = "com.stablyai.orca"
    static let cli = "/Applications/Orca.app/Contents/Resources/bin/orca"

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: cli) }

    struct Status: Sendable {
        var items: [AttentionItem] = []
        /// Agents busy right now, anywhere in Orca: Bead runs while there are any.
        var working = 0
        var worktrees: [Worktree] = []
    }

    static func scan(orcaIsFrontmost: Bool, focusedPane: String?) -> Status {
        guard isInstalled, isRunning else { return Status() }
        let result = Shell.run(cli, ["worktree", "ps", "--json"])
        guard result.status == 0 else { return Status() }
        let data = Data(result.output.utf8)
        return Status(items: parse(data, orcaIsFrontmost: orcaIsFrontmost, focusedPane: focusedPane),
                      working: workingCount(data), worktrees: decode(data))
    }

    static func decode(_ data: Data) -> [Worktree] {
        ((try? JSONDecoder().decode(Response.self, from: data))?.result.worktrees ?? []).filter { $0.isArchived != true }
    }

    static func workingCount(_ data: Data) -> Int {
        decode(data).flatMap { $0.agents ?? [] }.filter { $0.isYours && $0.current == "working" }.count
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    struct Response: Decodable {
        struct Result: Decodable { var worktrees: [Worktree] }
        var result: Result
    }

    struct Worktree: Decodable, Sendable {
        var worktreeId: String
        var repo: String?
        var path: String?
        var displayName: String?
        var isArchived: Bool?
        var isActive: Bool?
        var unread: Bool?
        var agents: [Agent]?
    }

    /// Only names and states are decoded; prompts, tool input and replies are left alone.
    struct Agent: Decodable, Sendable {
        var paneKey: String
        var state: String?
        /// For Claude: the main conversation's own state. The top-level state can stay "working"
        /// for hours because of background subagents, so this one is trusted first.
        var mainAgent: MainState?
        /// Set on workers started by another agent (orchestration); they report to that agent, not to you.
        var parentPaneKey: String?
        var agentType: String?
        var conversationName: String?
        var displayName: String?
        var taskTitle: String?
        var stateStartedAt: Double?
        var interrupted: Bool?

        struct MainState: Decodable, Sendable { var state: String? }

        var current: String { (mainAgent?.state ?? state ?? "").lowercased() }
        var isYours: Bool { parentPaneKey?.isEmpty ?? true }
        var key: String { "\(paneKey)|\(agentType ?? "")" }
    }

    /// Waiting and error states, plus Orca's own unread mark. `focusedPane` is the pane you last
    /// sent something in (see `Memory`); when known, it decides what you're looking at while Orca is
    /// in front, since Orca can't say which window or pane has your attention.
    static func parse(_ data: Data, orcaIsFrontmost: Bool, focusedPane: String? = nil) -> [AttentionItem] {
        guard (try? JSONDecoder().decode(Response.self, from: data)) != nil else { return [] }
        var items: [AttentionItem] = []
        for worktree in decode(data) {
            let workspaceOnScreen = orcaIsFrontmost && worktree.isActive == true
            let project = projectName(worktree)
            let agents = (worktree.agents ?? []).filter(\.isYours)
            var flagged = false
            for agent in agents {
                let looking = orcaIsFrontmost && (focusedPane.map { $0 == agent.paneKey } ?? workspaceOnScreen)
                guard !looking else { continue }
                let kind: AttentionItem.Kind
                switch agent.current {
                case "waiting", "blocked", "needs-input", "needs_input", "permission": kind = .waiting
                case "error", "failed": kind = .failed
                default: continue
                }
                flagged = true
                items.append(item(for: agent, kind: kind, project: project))
            }
            // Unread is per workspace; name it after the agent that finished last.
            if worktree.unread == true, !flagged, !workspaceOnScreen,
               let latest = agents.filter({ $0.current == "done" }).max(by: { ($0.stateStartedAt ?? 0) < ($1.stateStartedAt ?? 0) }) {
                items.append(item(for: latest, kind: .finished, project: project))
            }
        }
        return items
    }

    /// What NotchBead remembers between polls.
    struct Memory: Equatable, Sendable {
        /// Each agent's state at the last poll; nil before the first poll.
        var states: [String: String]?
        /// When each pane last started working: the newest is where you last sent something.
        var started: [String: Date] = [:]
        /// Finished items found by watching states, by agent.
        var items: [String: AttentionItem] = [:]

        var focusedPane: String? { started.max { $0.value < $1.value }?.key }
    }

    /// An agent of yours going from working to done is a finished item, unless Orca is in front and it's
    /// the pane you last sent something in. It goes when the agent works again, when you click it,
    /// or when the pane closes.
    static func step(_ memory: Memory, worktrees: [Worktree], orcaIsFrontmost: Bool, now: Date = .now) -> Memory {
        var next = memory
        var states: [String: String] = [:]
        for worktree in worktrees {
            for agent in (worktree.agents ?? []) where agent.isYours {
                let state = agent.current
                states[agent.key] = state
                guard let known = memory.states else { continue }
                let before = known[agent.key]
                if state == "working" {
                    if before != "working" { next.started[agent.paneKey] = now }
                    next.items[agent.key] = nil
                } else if state == "done", before == "working" {
                    let looking = orcaIsFrontmost && next.focusedPane == agent.paneKey
                    if !looking { next.items[agent.key] = item(for: agent, kind: .finished, project: projectName(worktree)) }
                }
            }
        }
        next.items = next.items.filter { states[$0.key] != nil }
        let panes = Set(states.keys.map { String($0.split(separator: "|", maxSplits: 1).first ?? "") })
        next.started = next.started.filter { panes.contains($0.key) }
        next.states = states
        return next
    }

    private static func item(for agent: Agent, kind: AttentionItem.Kind, project: String?) -> AttentionItem {
        let started = agent.stateStartedAt ?? 0
        let title = [agent.taskTitle, agent.displayName, agent.conversationName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? agent.agentType?.capitalized ?? "Agent"
        return AttentionItem(
            id: "orca:\(agent.paneKey):\(kind):\(Int(started))",
            source: .orca,
            kind: kind,
            title: title,
            project: project,
            agent: agent.agentType,
            since: Date(timeIntervalSince1970: started / 1000),
            target: .orcaPane(paneKey: agent.paneKey)
        )
    }

    /// The repository's name; the worktree folder when there isn't one.
    private static func projectName(_ worktree: Worktree) -> String? {
        if let repo = worktree.repo, !repo.isEmpty { return URL(fileURLWithPath: repo).lastPathComponent }
        return worktree.path.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Switches Orca to the pane, then brings Orca forward. paneKey is "<tab id>:<pane id>".
    static func open(paneKey: String) {
        let parts = paneKey.split(separator: ":", maxSplits: 1).map(String.init)
        let list = Shell.run(cli, ["terminal", "list", "--json"])
        if parts.count == 2, let handle = terminalHandle(in: Data(list.output.utf8), tabID: parts[0], leafID: parts[1]) {
            _ = Shell.run(cli, ["terminal", "switch", "--terminal", handle])
        }
        Task { @MainActor in activate(bundleID: bundleID) }
    }

    static func terminalHandle(in data: Data, tabID: String, leafID: String) -> String? {
        struct List: Decodable {
            struct Result: Decodable { var terminals: [Terminal] }
            struct Terminal: Decodable { var handle: String; var tabId: String?; var leafId: String? }
            var result: Result
        }
        let list = try? JSONDecoder().decode(List.self, from: data)
        return list?.result.terminals.first { $0.tabId == tabID && $0.leafId == leafID }?.handle
    }
}

// MARK: - WorkBuddy

/// Reads WorkBuddy's local database, read-only. WorkBuddy doesn't record which sessions you've
/// looked at, so NotchBead watches status changes instead: a session that stops working while
/// WorkBuddy isn't in front is one you didn't see finish.
enum WorkBuddyAttention {
    static let bundleID = "com.tencent.workbuddy.mac"

    static var database: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy/workbuddy.db").path
    }

    static func query(_ sql: String) -> Data? {
        guard FileManager.default.fileExists(atPath: database) else { return nil }
        // mode=ro: never writes, never takes a write lock on the app's database.
        let result = Shell.run("/usr/bin/sqlite3", ["-readonly", "-json", "file:\(database)?mode=ro", sql])
        guard result.status == 0 else { return nil }
        return Data(result.output.utf8)
    }

    struct Session: Decodable, Equatable, Sendable {
        var id: String
        var title: String?
        var status: String?
        var updated_at: Double?
        var cwd: String?
    }

    /// Sessions active in the last day; only titles and states, never the conversation.
    static func sessions() -> [Session] {
        guard let data = query("""
            SELECT id, COALESCE(NULLIF(custom_title, ''), title) AS title, status, updated_at, cwd
            FROM sessions
            WHERE (deleted_at IS NULL OR deleted_at = -1)
              AND updated_at > (strftime('%s', 'now') - 86400) * 1000
            ORDER BY updated_at DESC LIMIT 100
            """), !data.isEmpty
        else { return [] }
        return (try? JSONDecoder().decode([Session].self, from: data)) ?? []
    }

    /// What NotchBead remembers between polls.
    struct Memory: Equatable, Sendable {
        /// Each session's status at the last poll; nil before the first poll.
        var statuses: [String: String]?
        /// Open items, by session id.
        var items: [String: AttentionItem] = [:]
    }

    static func kind(for status: String?) -> AttentionItem.Kind? {
        switch status?.lowercased() {
        case "completed", "done": .finished
        case "error", "failed", "terminated": .failed
        default: nil
        }
    }

    static func isBusy(_ status: String?) -> Bool {
        ["working", "running", "in_progress"].contains(status?.lowercased() ?? "")
    }

    /// How far back the first poll looks for interruptions, so ones from just before NotchBead started show.
    static let recentWindow: TimeInterval = 30 * 60

    /// One poll's worth of change.
    /// - An interruption (error) or a stop to ask you something always shows, even with WorkBuddy
    ///   in front, since NotchBead can't tell which session you're looking at. It goes when the session
    ///   runs again or disappears, or when you click or dismiss it.
    /// - A normal finish shows only if WorkBuddy wasn't in front, and goes when you switch to it.
    static func step(_ memory: Memory, sessions: [Session], workBuddyInFront: Bool, now: Date = .now) -> Memory {
        var next = memory
        let known = memory.statuses
        var statuses: [String: String] = [:]
        for session in sessions {
            let status = session.status?.lowercased() ?? ""
            statuses[session.id] = status
            let before = known?[session.id]

            if known == nil {
                // First poll: only recent interruptions; everything else is where things stand.
                let updated = Date(timeIntervalSince1970: (session.updated_at ?? 0) / 1000)
                if kind(for: status) == .failed, now.timeIntervalSince(updated) < recentWindow {
                    next.items[session.id] = item(session, kind: .failed)
                }
                continue
            }
            guard before != status else { continue }

            if isBusy(status) {
                // It picked up again, so whatever it was waiting on is handled.
                next.items[session.id] = nil
                continue
            }
            // A brand-new session that's already done ran between two polls, so it counts too.
            guard before == nil || isBusy(before) else { continue }
            switch kind(for: status) {
            case .failed?:
                next.items[session.id] = item(session, kind: .failed)
            case .finished?:
                if !workBuddyInFront { next.items[session.id] = item(session, kind: .finished) }
            default:
                // Went from working back to pending: it stopped to ask you something.
                if status == "pending", before != nil { next.items[session.id] = item(session, kind: .waiting) }
            }
        }
        // Sessions that were deleted, or fell out of the last day.
        next.items = next.items.filter { statuses[$0.key] != nil }
        // In WorkBuddy now: finished ones are there to see. Interruptions stay until handled.
        if workBuddyInFront { next.items = next.items.filter { $0.value.kind != .finished } }
        next.statuses = statuses
        return next
    }

    private static func item(_ session: Session, kind: AttentionItem.Kind) -> AttentionItem {
        let updated = session.updated_at ?? 0
        return AttentionItem(
            id: "workbuddy:\(session.id):\(kind):\(Int(updated))",
            source: .workBuddy,
            kind: kind,
            title: session.title?.isEmpty == false ? session.title! : "WorkBuddy session",
            project: session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            agent: nil,
            since: Date(timeIntervalSince1970: updated / 1000),
            target: .app(bundleID: bundleID)
        )
    }

    /// Sessions working right now, so Bead runs for WorkBuddy too.
    static func workingCount(_ sessions: [Session]) -> Int {
        sessions.filter { isBusy($0.status) }.count
    }
}

// MARK: - ChatGPT

/// Tasks in the ChatGPT desktop app, which is OpenAI's Codex app (bundle id com.openai.codex).
/// Reads Codex's own thread list (`~/.codex/state_5.sqlite`, read-only) and the end of each
/// thread's log, where every turn ends with `task_complete` (or `turn_aborted` when you stop it).
/// Like WorkBuddy, nothing records what you've seen, so NotchBead watches turns end while the app
/// isn't in front. The Codex CLI and background review threads are left out: CLI runs live in
/// Orca, which already reports them.
enum ChatGPTAttention {
    static let bundleID = "com.openai.codex"

    static var database: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite").path
    }

    struct Thread: Decodable, Equatable, Sendable {
        var id: String
        var title: String?
        var cwd: String?
        var updated_ms: Double
        var rollout_path: String
        /// The ChatGPT project's name, when the thread is in one.
        var project: String?

        /// The project's name, or the working folder's; nil for ChatGPT's own hidden folders.
        var projectName: String? {
            if let project, !project.isEmpty { return project }
            guard let cwd, !cwd.contains("/.codex/") else { return nil }
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
    }

    /// Desktop-app threads active in the last day; only names and paths, never the conversation.
    static func threads() -> [Thread] {
        guard FileManager.default.fileExists(atPath: database) else { return [] }
        let sql = """
            SELECT id, COALESCE(NULLIF(name, ''), title) AS title, cwd,
                   COALESCE(updated_at_ms, updated_at * 1000) AS updated_ms, rollout_path,
                   (SELECT name FROM projects WHERE projects.id = threads.project_id) AS project
            FROM threads
            WHERE originator = 'codex_work_desktop' AND archived = 0
              AND source NOT LIKE '{%' AND updated_at > strftime('%s', 'now') - 86400
            ORDER BY updated_at DESC LIMIT 50
            """
        let result = Shell.run("/usr/bin/sqlite3", ["-readonly", "-json", "file:\(database)?mode=ro", sql])
        guard result.status == 0, !result.output.isEmpty else { return [] }
        return (try? JSONDecoder().decode([Thread].self, from: Data(result.output.utf8))) ?? []
    }

    /// Where a thread's latest turn stands.
    enum Turn: String, Equatable, Sendable {
        case running, done, stopped
    }

    /// The latest turn event in a piece of log: the last of task_started / task_complete / turn_aborted.
    /// The first line may be cut off when `text` is the end of a file; it's skipped unless `whole`.
    static func lastTurn(in text: Substring, whole: Bool) -> Turn? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if !whole, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            // Turn events are short and say what they are near the start; skip everything else unread.
            let head = line.prefix(200)
            guard head.contains("\"type\":\"event_msg\"") else { continue }
            if head.contains("\"payload\":{\"type\":\"task_complete\"") { return .done }
            if head.contains("\"payload\":{\"type\":\"task_started\"") { return .running }
            if head.contains("\"payload\":{\"type\":\"turn_aborted\"") { return .stopped }
        }
        return nil
    }

    /// Reads only the end of the log (they reach 100 MB+), a bit more if the last turn event is further back.
    static func lastTurn(path: String) -> Turn? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        for window in [UInt64(256 << 10), 4 << 20] {
            let start = size > window ? size - window : 0
            try? file.seek(toOffset: start)
            guard let data = try? file.readToEnd() else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            if let turn = lastTurn(in: text[...], whole: start == 0) { return turn }
            if start == 0 { return nil }
        }
        return nil
    }

    struct Snapshot: Equatable, Sendable {
        var thread: Thread
        var turn: Turn
        /// The log was written recently, so a running turn is really running and not left over.
        var live: Bool
    }

    /// Each thread's turn, remembered by last update so unchanged logs aren't read again.
    typealias Cache = [String: (updated: Double, turn: Turn)]

    static func scan(cache: Cache) -> (snapshots: [Snapshot], cache: Cache) {
        var next: Cache = [:]
        var snapshots: [Snapshot] = []
        for thread in threads() {
            let turn: Turn?
            if let known = cache[thread.id], known.updated == thread.updated_ms {
                turn = known.turn
            } else {
                turn = lastTurn(path: thread.rollout_path) ?? cache[thread.id]?.turn
            }
            guard let turn else { continue }
            next[thread.id] = (thread.updated_ms, turn)
            var live = false
            if turn == .running,
               let modified = (try? FileManager.default.attributesOfItem(atPath: thread.rollout_path))?[.modificationDate] as? Date {
                live = Date.now.timeIntervalSince(modified) < 15 * 60
            }
            snapshots.append(Snapshot(thread: thread, turn: turn, live: live))
        }
        return (snapshots, next)
    }

    struct Memory: Equatable, Sendable {
        /// Each thread's turn at the last poll; nil before the first poll.
        var turns: [String: Turn]?
        var items: [String: AttentionItem] = [:]
    }

    /// One poll's worth of change. A turn that finishes while the app isn't in front shows as
    /// finished; it goes when you switch to the app, start another turn, or archive the thread.
    /// Stopping a turn is something you did, so it never shows.
    static func step(_ memory: Memory, snapshots: [Snapshot], appInFront: Bool) -> Memory {
        var next = memory
        var turns: [String: Turn] = [:]
        for snapshot in snapshots {
            let id = snapshot.thread.id
            turns[id] = snapshot.turn
            // First poll: just where things stand.
            guard let known = memory.turns else { continue }
            let before = known[id]
            guard before != snapshot.turn else { continue }
            switch snapshot.turn {
            case .running, .stopped:
                next.items[id] = nil
            case .done:
                // A thread new to the list was just updated, so its finished turn is new too.
                if (before == nil || before == .running), !appInFront {
                    next.items[id] = item(snapshot.thread)
                }
            }
        }
        next.items = next.items.filter { turns[$0.key] != nil }
        if appInFront { next.items = [:] }
        next.turns = turns
        return next
    }

    private static func item(_ thread: Thread) -> AttentionItem {
        AttentionItem(
            id: "chatgpt:\(thread.id):finished:\(Int(thread.updated_ms))",
            source: .chatGPT,
            kind: .finished,
            title: thread.title?.isEmpty == false ? thread.title! : "ChatGPT task",
            project: thread.projectName,
            agent: nil,
            since: Date(timeIntervalSince1970: thread.updated_ms / 1000),
            target: .app(bundleID: bundleID)
        )
    }

    static func workingCount(_ snapshots: [Snapshot]) -> Int {
        snapshots.filter { $0.turn == .running && $0.live }.count
    }
}

/// Brings an app to the front. NotchBead is never the active app, and since macOS 14 a plain
/// `NSRunningApplication.activate()` from a background app is quietly ignored, so this goes through
/// Launch Services instead, like the Dock or `open -a`, which works from the background.
@MainActor
func activate(bundleID: String) {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        if let error { NSLog("NotchBead: could not bring \(bundleID) forward: \(error.localizedDescription)") }
    }
}
