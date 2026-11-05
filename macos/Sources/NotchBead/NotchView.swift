import SwiftUI

// Adapted from onit's notch (MIT, Copyright (c) 2026 Neethan Wu).

/// One black shape: the notch plus a wing on each side, always out, so the shape never changes size.
/// The right wing shows today's tokens from tokenboard, dimmed ("2.01亿"). When something needs you,
/// the icon of the app that wants you (taking turns when there are several) and Bead with a small
/// count on its corner rise into the left wing. Clicking takes you straight
/// to the next thing, in order; right-click has the dashboard and settings.
struct NotchView: View {
    let store: AttentionStore
    @Bindable var model: NotchModel
    /// Bumped on each new arrival, so Bead hops.
    @State private var pokes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var wing: CGFloat { NotchModel.wingWidth }
    /// Bead comes out only while something needs you.
    private var present: Bool { !store.visible.isEmpty }
    /// Today's tokens, once tokenboard has answered.
    private var tokenLabel: String? { store.tokens.map { TokenText.yi($0.tokens) } }
    private var collapsedWidth: CGFloat { model.notchWidth + 2 * wing }
    /// Where the right wing starts, just past the camera.
    private var rightEdge: CGFloat { (model.windowFrame.width + model.notchWidth) / 2 }
    /// Where the left wing starts, at its outer end.
    private var leftEdge: CGFloat { (model.windowFrame.width - model.notchWidth) / 2 - wing }
    /// How far the icon and Bead drift as they come and go.
    private var drift: CGFloat { reduceMotion ? 0 : 7 }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .frame(width: collapsedWidth, height: model.notchHeight)
            tapTarget
        }
        .frame(width: model.windowFrame.width, height: model.windowFrame.height, alignment: .top)
        .overlay(alignment: .topLeading) { sourceIcon }
        .overlay(alignment: .topLeading) { bead }
        .overlay(alignment: .topLeading) { tokenText }
        .environment(\.colorScheme, .dark)
        .onChange(of: store.arrival?.id) { _, id in if id != nil { pokes += 1 } }
    }

    // MARK: - Click

    /// Today's tokens in the right wing, always shown and dimmed. Clicking it opens the dashboard.
    private var tokenText: some View {
        let shown = tokenLabel != nil
        return Text(tokenLabel ?? " ")
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.45))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: wing - 4, height: model.notchHeight)
            .contentShape(Rectangle())
            .onTapGesture { DashboardWindow.shared.show() }
            .help("Today's tokens. Click to open the tokenboard dashboard")
            .offset(x: rightEdge, y: shown ? 0 : drift)
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 3)
            .animation(shown ? .notchOpen.delay(0.12) : .easeIn(duration: 0.2), value: shown)
            .allowsHitTesting(shown)
    }

    private var tapTarget: some View {
        Color.clear
            .frame(width: collapsedWidth, height: model.notchHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                store.clearArrival()
                pokes += 1
                store.openNext()
            }
            .contextMenu {
                Button("Open Dashboard") { DashboardWindow.shared.show() }
                Divider()
                Toggle("Play Sound", isOn: Binding(get: { store.playsSound }, set: { store.playsSound = $0; if $0 { ArrivalSound.play() } }))
                Toggle("Open at Login", isOn: Binding(get: { store.opensAtLogin }, set: { store.opensAtLogin = $0 }))
                Divider()
                Button("Quit NotchBead") { NSApp.terminate(nil) }
            }
            .help(store.next.map { "Go to: \($0.title)" } ?? "NotchBead: nothing needs you")
    }

    // MARK: - Bead

    /// The left wing, outside in: 3pt, the app icon (12pt), 4pt, Bead (18pt), then room for its count.
    private static let iconSize: CGFloat = 12

    /// Which app wants you, beside Bead; it comes and goes with Bead.
    private var sourceIcon: some View {
        let size = Self.iconSize
        return SourceIcon(sources: AttentionItem.Source.distinct(in: store.visible), size: size)
            .scaleEffect(present ? 1 : 0.8)
            .opacity(present ? 0.95 : 0)
            .blur(radius: present || reduceMotion ? 0 : 3)
            .offset(x: leftEdge + 3, y: (model.notchHeight - size) / 2 + (present ? 0 : drift))
            .animation(present ? .notchOpen.delay(0.12) : .easeIn(duration: 0.15), value: present)
            .allowsHitTesting(false)
    }

    /// Bead sits in the left wing while something needs you; the wing stays out, empty, otherwise.
    private var bead: some View {
        let size = NotchModel.wingBeadSize
        let center = CGPoint(x: leftEdge + 3 + Self.iconSize + 4 + size / 2, y: model.notchHeight / 2)
        return BeadView(
            mood: store.mood, size: size, runRange: 2, gaze: gaze(from: center), pokes: pokes,
            badge: max(store.visible.count, 1)
        )
            .scaleEffect(present ? 1 : 0.8)
            .opacity(present ? 1 : 0)
            .blur(radius: present || reduceMotion ? 0 : 3)
            .offset(x: center.x - size / 2, y: center.y - size / 2 + (present ? 0 : drift))
            .animation(present ? .notchOpen.delay(0.08) : .easeIn(duration: 0.15), value: present)
            .allowsHitTesting(false)
    }

    /// Points Bead's eyes at the pointer when it's within reach, scaled by how close it is.
    private func gaze(from center: CGPoint) -> CGVector? {
        guard let mouse = model.mouse, model.windowFrame != .zero else { return nil }
        let screenCenter = CGPoint(x: model.windowFrame.minX + center.x, y: model.windowFrame.maxY - center.y)
        let dx = mouse.x - screenCenter.x
        let dy = screenCenter.y - mouse.y
        let distance = hypot(dx, dy)
        guard distance < 420, distance > 1 else { return nil }
        let strength = min(1, distance / 60)
        return CGVector(dx: dx / distance * strength, dy: dy / distance * strength)
    }
}

/// How many things need you; drawn on Bead's corner.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 8, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.black)
            .padding(.horizontal, 3)
            .frame(minWidth: 11, minHeight: 11)
            .background(Capsule().fill(BeadMood.onIt.body))
            .contentTransition(.numericText())
            .animation(.settle, value: count)
    }
}
