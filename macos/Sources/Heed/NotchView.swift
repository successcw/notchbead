import SwiftUI

// Adapted from onit's notch (MIT, Copyright (c) 2026 Neethan Wu).

/// One black shape that grows out of the notch. The right wing is always out with today's tokens
/// from tokenboard, dimmed ("2.01亿"). When something needs you, the left wing grows out too, with
/// Bead and a small count on its top-right corner (it moves with Bead). Clicking takes you straight
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
    private var leftWing: CGFloat { present ? wing : 0 }
    private var rightWing: CGFloat { present || tokenLabel != nil ? wing : 0 }
    private var collapsedWidth: CGFloat { model.notchWidth + leftWing + rightWing }
    /// The shape stays centred on the camera when only one wing is out.
    private var shift: CGFloat { (rightWing - leftWing) / 2 }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .frame(width: collapsedWidth, height: model.notchHeight)
                .offset(x: shift)
                .animation(.notchOpen, value: present)
                .animation(.notchOpen, value: tokenLabel == nil)
            tapTarget
        }
        .frame(width: model.windowFrame.width, height: model.windowFrame.height, alignment: .top)
        .overlay(alignment: .topLeading) { bead }
        .overlay(alignment: .topLeading) { tokenText }
        .environment(\.colorScheme, .dark)
        .onChange(of: store.arrival?.id) { _, id in if id != nil { pokes += 1 } }
    }

    // MARK: - Click

    /// Today's tokens in the right wing, always shown and dimmed. Clicking it opens the dashboard.
    private var tokenText: some View {
        let shown = tokenLabel != nil
        let rightEdge = (model.windowFrame.width + model.notchWidth) / 2
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
            .offset(x: rightEdge + (shown ? 0 : -wing * 0.6), y: 0)
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 3)
            .animation(shown ? .notchOpen.delay(0.12) : .easeIn(duration: 0.12), value: shown)
            .allowsHitTesting(shown)
    }

    private var tapTarget: some View {
        Color.clear
            .frame(width: collapsedWidth, height: model.notchHeight)
            .offset(x: shift)
            .contentShape(Rectangle())
            .onTapGesture {
                store.clearArrival()
                pokes += 1
                store.openNext()
            }
            .contextMenu {
                Button("Open Dashboard") { DashboardWindow.shared.show() }
                Divider()
                Toggle("Open at Login", isOn: Binding(get: { store.opensAtLogin }, set: { store.opensAtLogin = $0 }))
                Divider()
                Button("Quit Heed") { NSApp.terminate(nil) }
            }
            .help(store.next.map { "Go to: \($0.title)" } ?? "Heed: nothing needs you")
    }

    // MARK: - Bead

    /// Bead sits in the left wing while something needs you, and tucks away behind the notch otherwise.
    private var bead: some View {
        let size = NotchModel.wingBeadSize
        let leftEdge = (model.windowFrame.width - model.notchWidth) / 2 - wing
        let center = CGPoint(x: leftEdge + wing / 2, y: model.notchHeight / 2)
        return BeadView(
            mood: store.mood, size: size, runRange: 8, gaze: gaze(from: center), pokes: pokes,
            badge: max(store.visible.count, 1)
        )
            .scaleEffect(present ? 1 : 0.3)
            .opacity(present ? 1 : 0)
            .blur(radius: present || reduceMotion ? 0 : 3)
            .offset(x: center.x - size / 2 + (present ? 0 : wing * 0.6), y: center.y - size / 2)
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
