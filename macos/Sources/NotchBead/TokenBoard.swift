import AppKit
import Foundation
import WebKit

/// Today's token use, read from the tokenboard service on this Mac (see the repository's README).
/// The service collects every 5 minutes, so the figure can trail live use by a few minutes.
struct TokenTotal: Equatable, Sendable {
    /// input + output + cache read + cache write, all sources.
    var tokens: Int
    /// Cost of the events with a known price, in USD.
    var cost: Double
    /// Some events have no known price, so `cost` covers only part of the day.
    var costPartial: Bool
}

enum TokenBoard {
    /// The service's address. `defaults write io.github.successcw.notchbead tokenboardURL http://127.0.0.1:8798` points elsewhere.
    static var baseURL: URL {
        let custom = UserDefaults.standard.string(forKey: "tokenboardURL").flatMap(URL.init(string:))
        return custom ?? URL(string: "http://127.0.0.1:8787")!
    }

    /// nil when the service isn't running or answers with something unexpected.
    static func today(now: Date = .now) async -> TokenTotal? {
        let day = dayString(now)
        var parts = URLComponents(url: baseURL.appending(path: "api/breakdown"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "start", value: day), .init(name: "end", value: day),
            .init(name: "metric", value: "total"), .init(name: "by", value: "source"),
        ]
        var request = URLRequest(url: parts.url!, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> TokenTotal? {
        struct Breakdown: Decodable {
            struct Row: Decodable {
                var value: Double
                var cost: Double?
                var cost_partial: Bool?
            }
            var rows: [Row]
        }
        guard let breakdown = try? JSONDecoder().decode(Breakdown.self, from: data) else { return nil }
        return TokenTotal(
            tokens: Int(breakdown.rows.reduce(0) { $0 + $1.value }),
            cost: breakdown.rows.reduce(0) { $0 + ($1.cost ?? 0) },
            costPartial: breakdown.rows.contains { $0.cost_partial ?? false }
        )
    }

    // MARK: - The token panel

    /// One row of a breakdown: an agent or a model.
    struct Share: Equatable, Sendable, Identifiable {
        var key: String
        var tokens: Int
        var cost: Double
        var costPartial: Bool
        var id: String { key }
    }

    /// One day's tokens per agent.
    struct Day: Equatable, Sendable, Identifiable {
        var day: String
        var bySource: [String: Int]
        var id: String { day }
        var total: Int { bySource.values.reduce(0, +) }
    }

    /// What the token panel shows: today by agent and by model, and the last seven days.
    struct Stats: Equatable, Sendable {
        var agents: [Share]
        var models: [Share]
        var week: [Day]
        var total: Int { agents.reduce(0) { $0 + $1.tokens } }
        var cost: Double { agents.reduce(0) { $0 + $1.cost } }
        var costPartial: Bool { agents.contains(where: \.costPartial) }
    }

    /// nil when the service isn't running or answers with something unexpected.
    static func stats(now: Date = .now) async -> Stats? {
        let today = dayString(now)
        let weekStart = dayString(Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now)
        async let agents = get("api/breakdown", ["start": today, "end": today, "metric": "total", "by": "source"])
        async let models = get("api/breakdown", ["start": today, "end": today, "metric": "total", "by": "model"])
        async let daily = get("api/daily", ["start": weekStart, "end": today, "metric": "total"])
        guard let agentData = await agents, let modelData = await models, let dailyData = await daily,
              let agentRows = shares(agentData), let modelRows = shares(modelData), let week = days(dailyData)
        else { return nil }
        return Stats(agents: agentRows, models: modelRows, week: week)
    }

    static func shares(_ data: Data) -> [Share]? {
        struct Breakdown: Decodable {
            struct Row: Decodable { var key: String; var value: Double; var cost: Double?; var cost_partial: Bool? }
            var rows: [Row]
        }
        guard let breakdown = try? JSONDecoder().decode(Breakdown.self, from: data) else { return nil }
        return breakdown.rows.map { Share(key: $0.key, tokens: Int($0.value), cost: $0.cost ?? 0, costPartial: $0.cost_partial ?? false) }
    }

    static func days(_ data: Data) -> [Day]? {
        struct Daily: Decodable { var days: [String]; var series: [String: [Double]] }
        guard let daily = try? JSONDecoder().decode(Daily.self, from: data) else { return nil }
        return daily.days.enumerated().map { index, day in
            Day(day: day, bySource: daily.series.compactMapValues { index < $0.count ? Int($0[index]) : nil })
        }
    }

    /// Asks the service to collect now (the dashboard's 采集); true once it has finished.
    static func collect() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "api/ingest"), timeoutInterval: 120)
        request.httpMethod = "POST"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func get(_ path: String, _ query: [String: String]) async -> Data? {
        var parts = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: parts.url!, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum TokenText {
    /// Always in 亿 (10^8) with two decimals: 201_000_000 → "2.01亿", 1_903_000_000 → "19.03亿".
    static func yi(_ value: Int) -> String {
        String(format: "%.2f亿", Double(value) / 1e8)
    }

    /// For smaller amounts: 亿 from 0.1亿 up, 万 below that: "1.95亿", "222万", "<1万".
    static func compact(_ value: Int) -> String {
        if value >= 10_000_000 { return yi(value) }
        if value >= 10_000 { return "\(value / 10_000)万" }
        return value > 0 ? "<1万" : "0"
    }

    /// "$91.22", with a "+" when some of it has no known price.
    static func cost(_ value: Double, partial: Bool) -> String {
        String(format: "$%.2f", value) + (partial ? "+" : "")
    }
}

/// tokenboard's web page in a window of its own, so it lives in the Dock and in Cmd-Tab
/// while it's open instead of in a browser tab. Closing it puts NotchBead back in the notch only.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = DashboardWindow()
    /// Posted when the page's 采集 (collect now) button has finished, so the notch number updates at once.
    static let didIngest = Notification.Name("TokenBoardDidIngest")

    /// Tells NotchBead when the page's own POST /api/ingest comes back.
    private static let ingestWatcher = """
    (() => {
      const original = window.fetch;
      window.fetch = function (input, init) {
        const url = typeof input === "string" ? input : (input && input.url) || "";
        const method = ((init && init.method) || (input && input.method) || "GET").toUpperCase();
        const result = original.apply(this, arguments);
        if (method === "POST" && url.indexOf("/api/ingest") !== -1) {
          result.then(() => window.webkit.messageHandlers.tokenboard.postMessage("ingested"), () => {});
        }
        return result;
      };
    })();
    """
    private var window: NSWindow?
    private var webView: WKWebView?

    func show() {
        if window == nil {
            build()
        } else if window?.isVisible == false {
            load()  // fresh numbers, and a second try if the service was down last time
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func build() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.ingestWatcher, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(self, name: "tokenboard")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.underPageBackgroundColor = .windowBackgroundColor
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "tokenboard"
        window.appearance = NSAppearance(named: .darkAqua)  // the page is always dark
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TokenboardDashboard")
        self.window = window
        self.webView = web
        load()
    }

    private func load() {
        webView?.load(URLRequest(url: TokenBoard.baseURL))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "tokenboard", message.body as? String == "ingested" else { return }
        NotificationCenter.default.post(name: Self.didIngest, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Only the dashboard opens inside the window; any other link goes to your browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.host == TokenBoard.baseURL.host, url.port == TokenBoard.baseURL.port { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let html = """
        <body style="font: 14px -apple-system; color: #999; background: #1e1e1e; display: grid; place-items: center; height: 90vh">
        <div style="text-align: center">tokenboard isn't running at \(TokenBoard.baseURL.absoluteString).<br>
        Start it with <code>scripts/install.sh</code> in the tokenboard repository, then reopen this window.</div></body>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
