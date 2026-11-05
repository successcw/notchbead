import AppKit
import SwiftUI

/// The icon of the app that wants you, beside Bead. When several apps do, they take turns:
/// the current one drifts up and fades out as the next rises in.
struct SourceIcon: View {
    let sources: [AttentionItem.Source]
    var size: CGFloat = 12
    /// How long each app's icon stays before the next one's turn.
    var hold: Duration = .seconds(2.5)

    @State private var turn = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !sources.isEmpty {
                let source = sources[turn % sources.count]
                Image(nsImage: AppIcon.image(for: source.bundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .id(source)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: size * 0.5).combined(with: .opacity),
                        removal: .offset(y: -size * 0.5).combined(with: .opacity)))
                    .help(source.rawValue)
            }
        }
        .frame(width: size, height: size)
        .task(id: sources) {
            turn = 0
            guard sources.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: hold)
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.4)) { turn += 1 }
            }
        }
        .accessibilityLabel(sources.map(\.rawValue).joined(separator: ", "))
    }
}

/// App icons by bundle id, looked up once each.
@MainActor
enum AppIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            ?? NSImage()
        cache[bundleID] = image
        return image
    }
}
