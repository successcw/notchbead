import Foundation
import Testing
@testable import Heed

struct OrcaAttentionTests {
    static func worktree(active: Bool, unread: Bool, agents: String) -> String {
        """
        {"worktreeId":"w\(UUID())","repo":"/Users/me/Dev/teacher","isArchived":false,"isActive":\(active),"unread":\(unread),"agents":[\(agents)]}
        """
    }
    static func agent(_ state: String, pane: String = "tab:leaf", name: String = "π - teacher", at: Int = 1000) -> String {
        #"{"paneKey":"\#(pane)","state":"\#(state)","agentType":"pi","conversationName":"\#(name)","stateStartedAt":\#(at),"toolInput":"secret stuff"}"#
    }
    static func response(_ worktrees: [String]) -> Data {
        Data(#"{"ok":true,"result":{"worktrees":[\#(worktrees.joined(separator: ","))]}}"#.utf8)
    }

    @Test func finishedOnlyWhenUnread() {
        let data = Self.response([
            Self.worktree(active: false, unread: true, agents: Self.agent("done", at: 1) + "," + Self.agent("done", pane: "t:l2", name: "later", at: 5)),
            Self.worktree(active: false, unread: false, agents: Self.agent("done")),
        ])
        let items = OrcaAttention.parse(data, orcaIsFrontmost: false)
        #expect(items.count == 1)
        #expect(items[0].kind == .finished)
        #expect(items[0].title == "later")
        #expect(items[0].project == "teacher")
        #expect(items[0].agent == "pi")
    }

    @Test func waitingAndErrorsShowWhenYouAreElsewhere() {
        let data = Self.response([Self.worktree(active: true, unread: false, agents: Self.agent("waiting") + "," + Self.agent("error", pane: "t:2"))])
        // Orca in front, on this very workspace: you can see it, so nothing to tell you.
        #expect(OrcaAttention.parse(data, orcaIsFrontmost: true).isEmpty)
        // Orca behind another app: both show.
        let items = OrcaAttention.parse(data, orcaIsFrontmost: false)
        #expect(items.map(\.kind) == [.waiting, .failed])
    }

    @Test func otherProjectsStillShowWhileOrcaIsInFront() {
        let data = Self.response([
            Self.worktree(active: true, unread: false, agents: Self.agent("working")),
            Self.worktree(active: false, unread: true, agents: Self.agent("done", pane: "x:y")),
        ])
        let items = OrcaAttention.parse(data, orcaIsFrontmost: true)
        #expect(items.count == 1)
        #expect(items[0].target == .orcaPane(paneKey: "x:y"))
    }

    @Test func aNewOccasionGetsANewID() {
        let first = OrcaAttention.parse(Self.response([Self.worktree(active: false, unread: false, agents: Self.agent("waiting", at: 1))]), orcaIsFrontmost: false)
        let second = OrcaAttention.parse(Self.response([Self.worktree(active: false, unread: false, agents: Self.agent("waiting", at: 2))]), orcaIsFrontmost: false)
        #expect(first[0].id != second[0].id)
    }

    @Test func findsTheTerminalForAPane() {
        let list = Data(#"{"result":{"terminals":[{"handle":"term_a","tabId":"t1","leafId":"l1"},{"handle":"term_b","tabId":"t1","leafId":"l2"}]}}"#.utf8)
        #expect(OrcaAttention.terminalHandle(in: list, tabID: "t1", leafID: "l2") == "term_b")
        #expect(OrcaAttention.terminalHandle(in: list, tabID: "t9", leafID: "l2") == nil)
    }

    @Test func badOutputMeansNothing() {
        #expect(OrcaAttention.parse(Data("not json".utf8), orcaIsFrontmost: false).isEmpty)
    }
}

struct WorkBuddyAttentionTests {
    typealias W = WorkBuddyAttention
    static func session(_ id: String, _ status: String, at: Double = 1000) -> W.Session {
        W.Session(id: id, title: "Summarise the quarterly report", status: status, updated_at: at, cwd: "/Users/me/WorkBuddy/reports")
    }

    @Test func firstPollShowsOnlyRecentInterruptions() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = Self.session("a", "error", at: (10_000 - 60) * 1000)
        let old = Self.session("b", "error", at: (10_000 - 7200) * 1000)
        let done = Self.session("c", "completed", at: (10_000 - 60) * 1000)
        let memory = W.step(W.Memory(), sessions: [recent, old, done], workBuddyInFront: false, now: now)
        #expect(Set(memory.items.keys) == ["a"])
        #expect(memory.statuses?["b"] == "error")
    }

    @Test func interruptionsShowEvenWithWorkBuddyInFront() {
        var memory = W.step(W.Memory(), sessions: [Self.session("a", "working")], workBuddyInFront: true)
        memory = W.step(memory, sessions: [Self.session("a", "error")], workBuddyInFront: true)
        #expect(memory.items["a"]?.kind == .failed)
        // Still there on the next poll in WorkBuddy; goes once the session runs again.
        memory = W.step(memory, sessions: [Self.session("a", "error")], workBuddyInFront: true)
        #expect(memory.items["a"] != nil)
        memory = W.step(memory, sessions: [Self.session("a", "working")], workBuddyInFront: true)
        #expect(memory.items["a"] == nil)
    }

    @Test func deletedSessionsGo() {
        var memory = W.step(W.Memory(), sessions: [Self.session("a", "working")], workBuddyInFront: false)
        memory = W.step(memory, sessions: [Self.session("a", "error")], workBuddyInFront: false)
        memory = W.step(memory, sessions: [], workBuddyInFront: false)
        #expect(memory.items.isEmpty)
    }

    @Test func finishingWhileYouAreElsewhere() {
        var memory = W.step(W.Memory(), sessions: [Self.session("a", "working"), Self.session("b", "working")], workBuddyInFront: false)
        memory = W.step(memory, sessions: [Self.session("a", "error", at: 2000), Self.session("b", "completed")], workBuddyInFront: false)
        #expect(memory.items["a"]?.kind == .failed)
        #expect(memory.items["a"]?.project == "reports")
        #expect(memory.items["b"]?.kind == .finished)
    }

    @Test func notWhenWorkBuddyIsInFront() {
        var memory = W.step(W.Memory(), sessions: [Self.session("a", "working")], workBuddyInFront: false)
        memory = W.step(memory, sessions: [Self.session("a", "completed")], workBuddyInFront: true)
        #expect(memory.items.isEmpty)
    }

    @Test func clearsWhenYouSwitchToWorkBuddyOrItResumes() {
        var memory = W.step(W.Memory(), sessions: [Self.session("a", "working"), Self.session("b", "working")], workBuddyInFront: false)
        memory = W.step(memory, sessions: [Self.session("a", "completed"), Self.session("b", "pending")], workBuddyInFront: false)
        #expect(memory.items["b"]?.kind == .waiting)
        memory = W.step(memory, sessions: [Self.session("a", "completed"), Self.session("b", "working")], workBuddyInFront: false)
        #expect(memory.items["b"] == nil)
        #expect(memory.items["a"] != nil)
        memory = W.step(memory, sessions: [Self.session("a", "completed"), Self.session("b", "working")], workBuddyInFront: true)
        #expect(memory.items.isEmpty)  // the finished one goes once you're in WorkBuddy
    }

    @Test func aQuickNewSessionCounts() {
        var memory = W.step(W.Memory(), sessions: [], workBuddyInFront: false)
        memory = W.step(memory, sessions: [Self.session("new", "completed")], workBuddyInFront: false)
        #expect(memory.items["new"]?.kind == .finished)
        #expect(W.workingCount([Self.session("x", "working"), Self.session("y", "completed")]) == 1)
    }
}

struct OrderingTests {
    @Test func waitingComesFirst() {
        func item(_ kind: AttentionItem.Kind) -> AttentionItem {
            AttentionItem(id: "\(kind)", source: .orca, kind: kind, title: "x", since: .now, target: .app(bundleID: "x"))
        }
        let sorted = [item(.finished), item(.waiting), item(.failed)].sorted { AttentionStore.rank($0) < AttentionStore.rank($1) }
        #expect(sorted.map(\.kind) == [.waiting, .failed, .finished])
    }

    @Test func timeText() {
        let now = Date()
        #expect(TimeText.ago(now, now: now) == "just now")
        #expect(TimeText.ago(now.addingTimeInterval(-300), now: now) == "5 min ago")
    }
}

struct ChatGPTAttentionTests {
    typealias C = ChatGPTAttention
    static func snap(_ id: String, _ turn: C.Turn, at: Double = 1000, live: Bool = true) -> C.Snapshot {
        C.Snapshot(thread: C.Thread(id: id, title: "Make a study guide PDF", cwd: "/Users/me/Documents/notes",
                                    updated_ms: at, rollout_path: "/tmp/x.jsonl"), turn: turn, live: live)
    }

    @Test func readsTheLastTurnEvent() {
        let log = """
        {"timestamp":"t","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}
        {"timestamp":"t","ordinal":2,"type":"response_item","payload":{"type":"message","content":"task_complete"}}
        {"timestamp":"t","ordinal":3,"type":"event_msg","payload":{"type":"token_count"}}
        """
        #expect(C.lastTurn(in: log[...], whole: true) == .running)
        let done = log + "\n" + #"{"timestamp":"t","ordinal":4,"type":"event_msg","payload":{"type":"task_complete","turn_id":"a"}}"#
        #expect(C.lastTurn(in: done[...], whole: true) == .done)
        let stopped = done + "\n" + #"{"timestamp":"t","ordinal":5,"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"# + "\n"
        #expect(C.lastTurn(in: stopped[...], whole: true) == .stopped)
        // The cut-off first line of a file's tail is ignored.
        let tail = #"ent_msg","payload":{"type":"task_complete"}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"token_count"}}"#
        #expect(C.lastTurn(in: tail[...], whole: false) == nil)
    }

    @Test func readsTheEndOfARealFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var text = #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n"
        text += String(repeating: #"{"type":"response_item","payload":{"type":"message","content":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}"# + "\n", count: 6000)
        try text.write(to: url, atomically: true, encoding: .utf8)
        // The turn event is further back than the first 256 KB window, so the bigger one finds it.
        #expect(C.lastTurn(path: url.path) == .done)
    }

    @Test func firstPollShowsNothing() {
        let memory = C.step(C.Memory(), snapshots: [Self.snap("a", .done)], appInFront: false)
        #expect(memory.items.isEmpty)
        #expect(memory.turns?["a"] == .done)
    }

    @Test func finishingWhileYouAreElsewhere() {
        var memory = C.step(C.Memory(), snapshots: [Self.snap("a", .running)], appInFront: false)
        memory = C.step(memory, snapshots: [Self.snap("a", .done, at: 2000)], appInFront: false)
        #expect(memory.items["a"]?.kind == .finished)
        #expect(memory.items["a"]?.source == .chatGPT)
        #expect(memory.items["a"]?.project == "notes")
        #expect(memory.items["a"]?.target == .app(bundleID: "com.openai.codex"))
        // Still there next poll; goes when you start another turn.
        memory = C.step(memory, snapshots: [Self.snap("a", .done, at: 2000)], appInFront: false)
        #expect(memory.items["a"] != nil)
        memory = C.step(memory, snapshots: [Self.snap("a", .running, at: 3000)], appInFront: false)
        #expect(memory.items.isEmpty)
    }

    @Test func notWhenTheAppIsInFrontAndClearsWhenYouSwitch() {
        var memory = C.step(C.Memory(), snapshots: [Self.snap("a", .running), Self.snap("b", .running)], appInFront: false)
        memory = C.step(memory, snapshots: [Self.snap("a", .done), Self.snap("b", .running)], appInFront: true)
        #expect(memory.items.isEmpty)
        memory = C.step(memory, snapshots: [Self.snap("a", .done), Self.snap("b", .done)], appInFront: false)
        #expect(Set(memory.items.keys) == ["b"])
        memory = C.step(memory, snapshots: [Self.snap("a", .done), Self.snap("b", .done)], appInFront: true)
        #expect(memory.items.isEmpty)
    }

    @Test func stoppingItYourselfNeverShows() {
        var memory = C.step(C.Memory(), snapshots: [Self.snap("a", .running)], appInFront: false)
        memory = C.step(memory, snapshots: [Self.snap("a", .stopped)], appInFront: false)
        #expect(memory.items.isEmpty)
    }

    @Test func newAndArchivedThreads() {
        var memory = C.step(C.Memory(), snapshots: [], appInFront: false)
        memory = C.step(memory, snapshots: [Self.snap("new", .done)], appInFront: false)
        #expect(memory.items["new"] != nil)
        memory = C.step(memory, snapshots: [], appInFront: false)
        #expect(memory.items.isEmpty)
        let hidden = C.Thread(id: "h", cwd: "/Users/me/.codex/.chatgpt-projects/g-p-0000", updated_ms: 1, rollout_path: "")
        #expect(hidden.projectName == nil)
        #expect(C.Thread(id: "p", cwd: hidden.cwd, updated_ms: 1, rollout_path: "", project: "Study").projectName == "Study")
        #expect(C.workingCount([Self.snap("x", .running), Self.snap("y", .running, live: false), Self.snap("z", .done)]) == 1)
    }
}
