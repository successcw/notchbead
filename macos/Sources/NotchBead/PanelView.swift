import SwiftUI

/// The open panel: what needs you, newest and most urgent first, and a small footer.
/// Used in the notch and in the menu bar window.
struct PanelView: View {
    let store: AttentionStore
    /// In the notch Bead already sits in the wing above the header.
    var showsHeaderBead = true
    var onOpen: (AttentionItem) -> Void

    private let maxRows = 8

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let items = store.visible
            VStack(alignment: .leading, spacing: 0) {
                header(count: items.count)
                if items.isEmpty {
                    empty
                } else {
                    VStack(spacing: 2) {
                        ForEach(items.prefix(maxRows)) { item in
                            ItemRow(item: item, now: context.date, onOpen: { onOpen(item) }, onDismiss: {
                                withAnimation(.settle) { store.dismiss(item) }
                            })
                        }
                    }
                    .padding(.horizontal, 4)
                    if items.count > maxRows {
                        Text("and \(items.count - maxRows) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                }
                footer
            }
            .animation(.settle, value: items.map(\.id))
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            if showsHeaderBead {
                BeadView(mood: store.mood, size: 24)
                    .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 0 ? "All clear" : count == 1 ? "1 thing needs you" : "\(count) things need you")
                    .font(.system(size: 14, weight: .semibold))
                Text(store.working > 0 ? (store.working == 1 ? "1 agent working" : "\(store.working) agents working") : "Orca, WorkBuddy and ChatGPT")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var empty: some View {
        Text("When an agent finishes somewhere you aren't looking, stops for your approval, or hits an error, it shows up here.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Toggle("Open at Login", isOn: Binding(get: { store.opensAtLogin }, set: { store.opensAtLogin = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Toggle("Sound", isOn: Binding(get: { store.playsSound }, set: { store.playsSound = $0; if $0 { ArrivalSound.play() } }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            Button("Dashboard") { DashboardWindow.shared.show() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Divider().opacity(0.4).padding(.horizontal, 8).padding(.top, 4) }
    }
}

struct ItemRow: View {
    let item: AttentionItem
    let now: Date
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    BeadGlyph(mood: KindSymbol.mood(item.kind), size: 16)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text(ItemText.detail(item, now: now))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.source == .orca ? "Go to this pane in Orca" : "Open \(item.source.rawValue)")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Hide until it needs you again")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hovering ? 0.08 : 0))
        )
        .onHover { hovering = $0 }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}

/// Each row carries a small Bead in the mood of what happened.
enum KindSymbol {
    static func mood(_ kind: AttentionItem.Kind) -> BeadMood {
        switch kind {
        case .waiting, .finished: .onIt
        case .failed: .failed
        }
    }
}

enum ItemText {
    /// "Waiting for you · Orca · teacher · pi · 3 min ago"
    static func detail(_ item: AttentionItem, now: Date) -> String {
        let what: String
        switch item.kind {
        case .waiting: what = "Waiting for you"
        case .finished: what = "Finished"
        case .failed: what = "Stopped with an error"
        }
        let parts = [what, item.source.rawValue, item.project, item.agent].compactMap { $0 }.filter { !$0.isEmpty }
        return (parts + [TimeText.ago(item.since, now: now)]).joined(separator: " · ")
    }
}
