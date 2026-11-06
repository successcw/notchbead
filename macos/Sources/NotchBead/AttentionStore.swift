import AppKit
import Observation
import ServiceManagement

/// Polls the agent apps every few seconds, and again right away whenever you switch apps,
/// since switching to Orca, WorkBuddy or ChatGPT is usually what handles an item.
@MainActor
@Observable
final class AttentionStore {
    private(set) var items: [AttentionItem] = []
    /// Agents working right now, in Orca, WorkBuddy and ChatGPT.
    private(set) var working = 0
    @ObservationIgnored private var orca = OrcaAttention.Memory()
    @ObservationIgnored private var workBuddy = WorkBuddyAttention.Memory()
    @ObservationIgnored private var chatGPT = ChatGPTAttention.Memory()
    @ObservationIgnored private var chatGPTCache: ChatGPTAttention.Cache = [:]
    /// The last good read of each source, used when a read fails.
    @ObservationIgnored private var lastOrca = OrcaAttention.Status()
    @ObservationIgnored private var lastSessions: [WorkBuddyAttention.Session] = []
    @ObservationIgnored private var lastThreads: [ChatGPTAttention.Snapshot] = []
    @ObservationIgnored private var lastChats: [ChatGPTChats.Turn] = []
    @ObservationIgnored private var chats = ChatGPTChats.Memory()
    private(set) var lastChecked: Date?
    /// The newest arrival, for the notch to show briefly.
    private(set) var arrival: AttentionItem?
    /// Today's token use from tokenboard, shown under the notch with each arrival. nil when it isn't running.
    private(set) var tokens: TokenTotal?
    @ObservationIgnored private var tokensCheckedAt: Date?

    /// Items you waved away. Each id covers one occasion, so the next time that pane needs you it shows again.
    private var dismissed: Set<String>
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var ingestObserver: NSObjectProtocol?
    @ObservationIgnored private var seen: Set<String>?
    @ObservationIgnored private var arrivalTask: Task<Void, Never>?
    @ObservationIgnored private let demoStart: Date? = .now
    /// What clicking has already jumped to this round, so each click goes to the next one.
    @ObservationIgnored private var visited: [String] = []

    private static let interval: Duration = .seconds(3)
    /// How often today's total is re-read without a nudge: catches the service's own collection
    /// every 5 minutes and collections started from a browser. It's one local request.
    private static let tokenInterval: TimeInterval = 15
    private static let dismissedKey = "dismissed"
    private static let soundKey = "playsSound"

    /// A short chime when something new needs you. On unless turned off in the right-click menu.
    var playsSound: Bool = UserDefaults.standard.object(forKey: AttentionStore.soundKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(playsSound, forKey: Self.soundKey) }
    }

    init() {
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    var visible: [AttentionItem] {
        items.filter { !dismissed.contains($0.id) }
            .sorted { lhs, rhs in
                // Waiting on you first, then errors, then finished; newest first within each.
                if Self.rank(lhs) != Self.rank(rhs) { return Self.rank(lhs) < Self.rank(rhs) }
                return lhs.since > rhs.since
            }
    }

    /// Bead's mood: blue and running, onit's busy Bead, whenever something needs you or an agent
    /// is working; white and dozing when all is quiet.
    var mood: BeadMood {
        visible.isEmpty && working == 0 ? .dozing : .onIt
    }

    nonisolated static func rank(_ item: AttentionItem) -> Int {
        switch item.kind {
        case .waiting: 0
        case .failed: 1
        case .finished: 2
        }
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
        // The dashboard window's 采集 button just collected: show the new total now, not on the next check.
        ingestObserver = NotificationCenter.default.addObserver(
            forName: DashboardWindow.didIngest, object: nil, queue: .main
        ) { [weak self] _ in
            _ = MainActor.assumeIsolated { Task { await self?.refreshTokens() } }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            _ = MainActor.assumeIsolated { Task { await self?.refresh() } }
        }
    }

    func refresh() async {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let cache = chatGPTCache
        let orcaInFront = front == OrcaAttention.bundleID
        let focusedPane = orca.focusedPane
        let (orcaStatus, sessions, threads, chatTurns) = await Task.detached(priority: .utility) {
            (OrcaAttention.scan(orcaIsFrontmost: orcaInFront, focusedPane: focusedPane), WorkBuddyAttention.sessions(),
             ChatGPTAttention.scan(cache: cache), ChatGPTChats.activeTurns())
        }.value
        // A source that couldn't be read this time (nil) keeps what it had: reading nothing would look
        // like everything went away, and the next good read would then look like everything was new.
        if let orcaStatus {
            lastOrca = orcaStatus
            orca = OrcaAttention.step(orca, worktrees: orcaStatus.worktrees, orcaIsFrontmost: orcaInFront)
        }
        var orcaItems = lastOrca.items
        for item in orca.items.values where !orcaItems.contains(where: { $0.id == item.id }) { orcaItems.append(item) }
        if let sessions {
            lastSessions = sessions
            workBuddy = WorkBuddyAttention.step(workBuddy, sessions: sessions, workBuddyInFront: front == WorkBuddyAttention.bundleID)
        }
        if let threads {
            chatGPTCache = threads.cache
            lastThreads = threads.snapshots
            chatGPT = ChatGPTAttention.step(chatGPT, snapshots: threads.snapshots, appInFront: front == ChatGPTAttention.bundleID)
        }
        if let chatTurns {
            lastChats = chatTurns
            chats = ChatGPTChats.step(chats, active: chatTurns, appInFront: front == ChatGPTAttention.bundleID)
        }
        var found = orcaItems + Array(workBuddy.items.values) + Array(chatGPT.items.values) + Array(chats.items.values)
        let busy = lastOrca.working + WorkBuddyAttention.workingCount(lastSessions) + ChatGPTAttention.workingCount(lastThreads)
            + lastChats.count
        if busy != working { working = busy }
        // NOTCHBEAD_DEMO=1 adds a sample item a few seconds in, to see the notch without waiting on an agent.
        if ProcessInfo.processInfo.environment["NOTCHBEAD_DEMO"] == "1", let demoStart, Date.now.timeIntervalSince(demoStart) > 4 {
            found.append(AttentionItem(id: "demo", source: .orca, kind: .waiting, title: "π - teacher wants to run a command",
                                       project: "teacher", agent: "pi", since: demoStart, target: .app(bundleID: OrcaAttention.bundleID)))
            // A second app a few seconds later, so the icon beside Bead starts taking turns.
            if Date.now.timeIntervalSince(demoStart) > 9 {
                found.append(AttentionItem(id: "demo-chatgpt", source: .chatGPT, kind: .finished, title: "Make a study guide PDF",
                                           project: nil, agent: nil, since: demoStart.addingTimeInterval(9),
                                           target: .app(bundleID: ChatGPTAttention.bundleID)))
            }
        }
        if found != items { items = found }
        lastChecked = .now

        // Forget dismissals for things that have gone, so the list doesn't grow forever.
        let current = Set(found.map(\.id))
        let kept = dismissed.intersection(current)
        if kept != dismissed {
            dismissed = kept
            UserDefaults.standard.set(Array(kept), forKey: Self.dismissedKey)
        }
        visited.removeAll { !current.contains($0) }
        if noticeArrivals() || tokensCheckedAt.map({ Date.now.timeIntervalSince($0) > Self.tokenInterval }) ?? true {
            await refreshTokens()
        }
    }

    private func refreshTokens() async {
        tokensCheckedAt = .now
        let total = await TokenBoard.today()
        if total != tokens { tokens = total }
    }

    /// The item the next click goes to: the first in order not yet visited this round.
    var next: AttentionItem? {
        let items = visible
        return items.first { !visited.contains($0.id) } ?? items.first
    }

    /// Jumps to the next thing that needs you; once all have had a turn it starts over.
    func openNext() {
        let items = visible
        guard let item = next else { return }
        if !items.contains(where: { !visited.contains($0.id) }) { visited = [] }
        visited.append(item.id)
        open(item)
    }

    /// The first poll only learns what's already there; later ones announce what's new.
    /// Returns whether something new arrived.
    private func noticeArrivals() -> Bool {
        let ids = Set(visible.map(\.id))
        let known = self.seen
        // Forget items that have gone, so one that comes back (same id) chimes again.
        self.seen = (known ?? []).intersection(Set(items.map(\.id))).union(ids)
        guard let known, let newest = visible.first(where: { !known.contains($0.id) }) else { return false }
        arrival = newest
        if playsSound { ArrivalSound.play() }
        arrivalTask?.cancel()
        arrivalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.arrival = nil
        }
        return true
    }

    func clearArrival() {
        arrivalTask?.cancel()
        arrival = nil
    }

    /// Takes you to it. It clears by itself once its app says it's handled.
    func open(_ item: AttentionItem) {
        clearArrival()
        switch item.target {
        case .orcaPane(let paneKey):
            Task.detached(priority: .userInitiated) { OrcaAttention.open(paneKey: paneKey) }
            // Going there counts as seeing it; Orca's unread mark clears by itself, a watched finish doesn't.
            dismiss(item)
        case .app(let bundleID):
            activate(bundleID: bundleID)
            // WorkBuddy and ChatGPT can't tell NotchBead when you've looked, so going there counts as handling it.
            dismiss(item)
        }
    }

    func dismiss(_ item: AttentionItem) {
        if arrival?.id == item.id { clearArrival() }
        dismissed.insert(item.id)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
    }

    // MARK: - Open at login

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("NotchBead: could not change login item: \(error.localizedDescription)")
            }
        }
    }
}

/// Three soft rising pips (SupportFiles/Arrival.wav, made by generate-sound.py).
@MainActor
enum ArrivalSound {
    private static let sound: NSSound? = Bundle.main.url(forResource: "Arrival", withExtension: "wav")
        .flatMap { NSSound(contentsOf: $0, byReference: true) }

    static func play() {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }
}
