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
