import Foundation
import Testing
@testable import NotchBead

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
    // MARK: watching agents finish

    typealias O = OrcaAttention
    static func claude(_ state: String, pane: String, main: String? = nil, mainAt: Int = 1, parent: String? = nil, at: Int = 1000) -> String {
        let mainJSON = main.map { #","mainAgent":{"state":"\#($0)","stateStartedAt":\#(mainAt)}"# } ?? ""
        let parentJSON = parent.map { #","parentPaneKey":"\#($0)""# } ?? ""
        return #"{"paneKey":"\#(pane)","state":"\#(state)","agentType":"claude","conversationName":"Fix the login form","stateStartedAt":\#(at)\#(mainJSON)\#(parentJSON)}"#
    }
    static func trees(_ agents: String..., active: Bool = true) -> [O.Worktree] {
        O.decode(Self.response([Self.worktree(active: active, unread: false, agents: agents.joined(separator: ","))]))
    }

    @Test func firstPollOnlyLearns() {
        let memory = O.step(O.Memory(), worktrees: Self.trees(Self.claude("done", pane: "a:1")), orcaIsFrontmost: false)
        #expect(memory.items.isEmpty)
        #expect(memory.states?["a:1|claude"] == "done")
    }

    @Test func aReplyWhileYouAreInAnotherAppShows() {
        var m = O.step(O.Memory(), worktrees: Self.trees(Self.claude("working", pane: "a:1")), orcaIsFrontmost: false)
        m = O.step(m, worktrees: Self.trees(Self.claude("done", pane: "a:1", at: 2000)), orcaIsFrontmost: false)
        #expect(m.items["a:1|claude"]?.kind == .finished)
        #expect(m.items["a:1|claude"]?.target == .orcaPane(paneKey: "a:1"))
        // You reply: it's handled.
        m = O.step(m, worktrees: Self.trees(Self.claude("working", pane: "a:1")), orcaIsFrontmost: false)
        #expect(m.items.isEmpty)
    }

    /// Seen for real: Claude's top-level state stuck on working with the same start time, so every
    /// finish had one id and only the first chimed.
    @Test func eachFinishInAPaneGetsItsOwnId() {
        var m = O.step(O.Memory(), worktrees: Self.trees(Self.claude("working", pane: "b:1", main: "working", mainAt: 10)), orcaIsFrontmost: false)
        m = O.step(m, worktrees: Self.trees(Self.claude("working", pane: "b:1", main: "done", mainAt: 20)), orcaIsFrontmost: false)
        let first = m.items["b:1|claude"]?.id
        m = O.step(m, worktrees: Self.trees(Self.claude("working", pane: "b:1", main: "working", mainAt: 30)), orcaIsFrontmost: false)
        m = O.step(m, worktrees: Self.trees(Self.claude("working", pane: "b:1", main: "done", mainAt: 40)), orcaIsFrontmost: false)
        let second = m.items["b:1|claude"]?.id
        #expect(first != nil && second != nil && first != second)
    }

    @Test func aReplyInAnotherOrcaPaneShowsEvenWithOrcaInFront() {
        // Asked in one project (d:1), then sent something here (t:1): t:1 is where you are now.
        let t0 = Date(timeIntervalSince1970: 100)
        var m = O.step(O.Memory(), worktrees: Self.trees(Self.claude("done", pane: "d:1"), Self.claude("done", pane: "t:1")), orcaIsFrontmost: true, now: t0)
        m = O.step(m, worktrees: Self.trees(Self.claude("working", pane: "d:1"), Self.claude("done", pane: "t:1")), orcaIsFrontmost: true, now: t0 + 1)
        m = O.step(m, worktrees: Self.trees(Self.claude("working", pane: "d:1"), Self.claude("working", pane: "t:1")), orcaIsFrontmost: true, now: t0 + 2)
        #expect(m.focusedPane == "t:1")
        // That project answers while you're here, in the same Orca: it shows.
        m = O.step(m, worktrees: Self.trees(Self.claude("done", pane: "d:1"), Self.claude("working", pane: "t:1")), orcaIsFrontmost: true, now: t0 + 3)
        #expect(m.items["d:1|claude"] != nil)
        // The agent you're talking to answers: you're looking at it, so nothing.
        m = O.step(m, worktrees: Self.trees(Self.claude("done", pane: "d:1"), Self.claude("done", pane: "t:1")), orcaIsFrontmost: true, now: t0 + 4)
        #expect(m.items["t:1|claude"] == nil)
        // ...but with Orca behind another app, it would.
        m = O.step(m, worktrees: Self.trees(Self.claude("done", pane: "d:1"), Self.claude("working", pane: "t:1")), orcaIsFrontmost: false, now: t0 + 5)
        m = O.step(m, worktrees: Self.trees(Self.claude("done", pane: "d:1"), Self.claude("done", pane: "t:1")), orcaIsFrontmost: false, now: t0 + 6)
        #expect(m.items["t:1|claude"] != nil)
    }

    @Test func workersAndStaleStatesDoNotCount() {
        // A worker started by another agent, and a pane whose top-level state is stuck on "working"
        // while its main conversation is done.
        var m = O.step(O.Memory(), worktrees: Self.trees(Self.claude("working", pane: "w:1", parent: "c:1"), Self.claude("working", pane: "s:1", main: "done")), orcaIsFrontmost: false)
        m = O.step(m, worktrees: Self.trees(Self.claude("done", pane: "w:1", parent: "c:1"), Self.claude("working", pane: "s:1", main: "done")), orcaIsFrontmost: false)
        #expect(m.items.isEmpty)
        #expect(O.workingCount(Self.response([Self.worktree(active: true, unread: false, agents: Self.claude("working", pane: "s:1", main: "done"))])) == 0)
        // The main conversation's own state is what's watched.
        m = O.step(m, worktrees: Self.trees(Self.claude("working", pane: "s:1", main: "working")), orcaIsFrontmost: false)
        m = O.step(m, worktrees: Self.trees(Self.claude("working", pane: "s:1", main: "done")), orcaIsFrontmost: false)
        #expect(m.items["s:1|claude"] != nil)
    }

    @Test func closedPanesGo() {
        var m = O.step(O.Memory(), worktrees: Self.trees(Self.claude("working", pane: "a:1")), orcaIsFrontmost: false)
        m = O.step(m, worktrees: Self.trees(Self.claude("done", pane: "a:1")), orcaIsFrontmost: false)
        m = O.step(m, worktrees: [], orcaIsFrontmost: false)
        #expect(m.items.isEmpty)
        #expect(m.focusedPane == nil)
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
        // updated_at is in ms; "now" is 1 min after the session changed.
        let now = Date(timeIntervalSince1970: 61)
        var memory = W.step(W.Memory(), sessions: [], workBuddyInFront: false, now: now)
        memory = W.step(memory, sessions: [Self.session("new", "completed")], workBuddyInFront: false, now: now)
        #expect(memory.items["new"]?.kind == .finished)
        #expect(W.workingCount([Self.session("x", "working"), Self.session("y", "completed")]) == 1)
    }

    @Test func anOldSessionComingBackIntoTheListDoesNot() {
        // Finished an hour before it showed up, e.g. after a read that failed.
        let now = Date(timeIntervalSince1970: 3601)
        var memory = W.step(W.Memory(), sessions: [], workBuddyInFront: false, now: now)
        memory = W.step(memory, sessions: [Self.session("old", "completed")], workBuddyInFront: false, now: now)
        #expect(memory.items.isEmpty)
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

    @Test func eachAppOnceInOrder() {
        func item(_ id: String, _ source: AttentionItem.Source) -> AttentionItem {
            AttentionItem(id: id, source: source, kind: .finished, title: id, since: .now, target: .app(bundleID: source.bundleID))
        }
        let items = [item("a", .chatGPT), item("b", .orca), item("c", .chatGPT), item("d", .workBuddy)]
        #expect(AttentionItem.Source.distinct(in: items) == [.chatGPT, .orca, .workBuddy])
        #expect(AttentionItem.Source.distinct(in: []).isEmpty)
    }

    @Test func timeText() {
        let now = Date()
        #expect(TimeText.ago(now, now: now) == "just now")
        #expect(TimeText.ago(now.addingTimeInterval(-300), now: now) == "5m ago")
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchbead-\(UUID().uuidString).jsonl")
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

    /// The false alarm seen for real: one unreadable poll dropped every thread, and the next poll
    /// saw yesterday's finished threads as new.
    @Test func threadsFinishedLongAgoComingBackDoNotShow() {
        let now = Date(timeIntervalSince1970: 86_400)
        let old = [Self.snap("a", .done), Self.snap("b", .done), Self.snap("c", .done)]
        var memory = C.step(C.Memory(), snapshots: old, appInFront: false, now: now)
        memory = C.step(memory, snapshots: [], appInFront: false, now: now)
        memory = C.step(memory, snapshots: old, appInFront: false, now: now)
        #expect(memory.items.isEmpty)
    }

    @Test func newAndArchivedThreads() {
        let now = Date(timeIntervalSince1970: 61)
        var memory = C.step(C.Memory(), snapshots: [], appInFront: false, now: now)
        memory = C.step(memory, snapshots: [Self.snap("new", .done)], appInFront: false, now: now)
        #expect(memory.items["new"] != nil)
        memory = C.step(memory, snapshots: [], appInFront: false)
        #expect(memory.items.isEmpty)
        let hidden = C.Thread(id: "h", cwd: "/Users/me/.codex/.chatgpt-projects/g-p-0000", updated_ms: 1, rollout_path: "")
        #expect(hidden.projectName == nil)
        #expect(C.Thread(id: "p", cwd: hidden.cwd, updated_ms: 1, rollout_path: "", project: "Study").projectName == "Study")
        #expect(C.workingCount([Self.snap("x", .running), Self.snap("y", .running, live: false), Self.snap("z", .done)]) == 1)
    }
}

@Suite struct ChatGPTChatTests {
    typealias C = ChatGPTChats
    static let turn = C.Turn(thread_id: "t", title: "Plan a weekend trip")

    @Test func aReplyFinishingWhileYouAreElsewhereShows() {
        var memory = C.step(C.Memory(), active: [], appInFront: true)
        memory = C.step(memory, active: [Self.turn], appInFront: true)   // you send it in ChatGPT
        memory = C.step(memory, active: [Self.turn], appInFront: false)  // then go elsewhere
        #expect(memory.items.isEmpty)
        memory = C.step(memory, active: [], appInFront: false)           // the reply is done
        #expect(memory.items["t"]?.title == "Plan a weekend trip")
        memory = C.step(memory, active: [], appInFront: true)            // you look
        #expect(memory.items.isEmpty)
    }

    @Test func notWhenYouWatchItFinish() {
        var memory = C.step(C.Memory(), active: [Self.turn], appInFront: true)
        memory = C.step(memory, active: [], appInFront: true)
        #expect(memory.items.isEmpty)
    }

    @Test func firstPollOnlyLearnsAndANewTurnClears() {
        var memory = C.step(C.Memory(), active: [], appInFront: false)
        #expect(memory.items.isEmpty)
        memory = C.step(memory, active: [Self.turn], appInFront: false)
        memory = C.step(memory, active: [], appInFront: false)
        #expect(memory.items.count == 1)
        memory = C.step(memory, active: [Self.turn], appInFront: false)
        #expect(memory.items.isEmpty)
    }
}
