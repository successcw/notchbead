import SwiftUI

// Adapted from onit's notch (MIT, Copyright (c) 2026 Neethan Wu).

/// Where the task list's header keeps a place for Bead, in the notch's coordinate space.
struct BeadSlotKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// One black shape around the notch. Closed, it is the notch plus a wing on each side, always the
/// same size: the right wing shows today's tokens from tokenboard, dimmed ("2.01亿"); the left wing
/// holds Bead. While something needs you, Bead is blue with a count on its corner and the icon of
/// the app that wants you beside it, and clicking takes you straight to the next thing. Otherwise
/// Bead shows how your scheduled tasks are doing (dozing when all is well, running, amber or red),
/// and clicking opens the panel of your own scheduled tasks, as in onit. Right-click has the rest.
struct NotchView: View {
    let store: AttentionStore
    let jobs: JobStore
    @Bindable var model: NotchModel
    /// Bumped on each new arrival, so Bead hops.
    @State private var pokes = 0
    @State private var contentHeight: CGFloat = 320
    @State private var headerSlot = CGRect.zero
    @State private var resetToken = 0
    @State private var tokenOpens = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var open: Bool { model.isExpanded }
    private var wing: CGFloat { NotchModel.wingWidth }
    /// Something needs you: Bead turns blue and clicks go to it.
    private var present: Bool { !store.visible.isEmpty }
    /// Today's tokens, once tokenboard has answered.
    private var tokenLabel: String? { store.tokens.map { TokenText.yi($0.tokens) } }
    private var collapsedWidth: CGFloat { model.notchWidth + 2 * wing }
    /// Where the right wing starts, just past the camera.
    private var rightEdge: CGFloat { (model.windowFrame.width + model.notchWidth) / 2 }
    /// Where the left wing starts, at its outer end.
    private var leftEdge: CGFloat { (model.windowFrame.width - model.notchWidth) / 2 - wing }
    /// How far the icon drifts as it comes and goes.
    private var drift: CGFloat { reduceMotion ? 0 : 7 }

    private var shapeSize: CGSize {
        open
            ? CGSize(width: NotchModel.panelWidth, height: model.notchHeight + contentHeight)
            : CGSize(width: collapsedWidth, height: model.notchHeight)
    }

    private var shape: UnevenRoundedRectangle {
        let radius: CGFloat = open ? 30 : 12
        return UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .frame(width: shapeSize.width, height: shapeSize.height)
                // Moving between the list and a task's detail changes the height; the black follows it.
                .animation(.panelSpring, value: contentHeight)
            panel
            tapTarget
        }
        .frame(width: model.windowFrame.width, height: model.windowFrame.height, alignment: .top)
        .overlay(alignment: .topLeading) { sourceIcon }
        .overlay(alignment: .topLeading) { bead }
        .overlay(alignment: .topLeading) { tokenText }
        .coordinateSpace(.named(NotchModel.space))
        .onPreferenceChange(BeadSlotKey.self) { headerSlot = $0 }
        .environment(\.colorScheme, .dark)
        .onChange(of: store.arrival?.id) { _, id in if id != nil { pokes += 1 } }
        .onChange(of: open) { _, isOpen in
            guard !isOpen else { return }
            // Back to the list once the panel has folded away, so it always reopens there.
            Task {
                try? await Task.sleep(for: .seconds(0.4))
                if !model.isExpanded { resetToken += 1 }
            }
        }
    }

    // MARK: - Panel

    private var panel: some View {
        let top = model.notchHeight
        return VStack(spacing: 0) {
            Color.clear.frame(height: model.notchHeight)
            Group {
                switch model.content {
                case .tasks:
                    PopoverView(store: jobs, onDetailChange: { model.showingDetail = $0 }, resetToken: resetToken)
                case .tokens:
                    TokenPanel(openToken: tokenOpens)
                }
            }
                .environment(\.notchModel, model)
                .environment(\.notchStyle, true)
                .environment(\.panelWidth, NotchModel.panelWidth - 16)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .frame(width: NotchModel.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height - top } action: { contentHeight = $0 }
        // The content arrives just after the shape starts to grow and leaves before it shrinks.
        .opacity(open ? 1 : 0)
        .blur(radius: open || reduceMotion ? 0 : 8)
        .animation(open ? .easeOut(duration: 0.24).delay(0.1) : .easeOut(duration: 0.12), value: open)
        .mask(alignment: .top) {
            shape.frame(width: shapeSize.width, height: shapeSize.height)
                .animation(.panelSpring, value: contentHeight)
        }
        .allowsHitTesting(open)
    }

    private func openPanel(_ content: NotchModel.PanelContent = .tasks) {
        store.clearArrival()
        if content == .tokens { tokenOpens += 1 }
        model.content = content
        model.showingDetail = false
        withAnimation(.notchOpen) { model.isExpanded = true }
    }

    // MARK: - Click

    /// Today's tokens in the right wing, always shown and dimmed. Clicking it opens the token panel.
    private var tokenText: some View {
        let shown = tokenLabel != nil && !open
        return Text(tokenLabel ?? " ")
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.45))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: wing - 4, height: model.notchHeight)
            .contentShape(Rectangle())
            .onTapGesture { openPanel(.tokens) }
            .help("Today's tokens. Click for today by agent and model, and the last seven days")
            .offset(x: rightEdge, y: tokenLabel != nil ? 0 : drift)
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 3)
            .animation(shown ? .notchOpen.delay(0.12) : .easeIn(duration: 0.15), value: shown)
            .allowsHitTesting(shown)
    }

    /// Something needs you: go to it. Otherwise: open your scheduled tasks.
    private var tapTarget: some View {
        Color.clear
            .frame(width: collapsedWidth, height: model.notchHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                if present {
                    store.clearArrival()
                    pokes += 1
                    store.openNext()
                } else {
                    openPanel()
                }
            }
            .contextMenu {
                Button("Scheduled Tasks") { openPanel() }
                Button("Today's Tokens") { openPanel(.tokens) }
                Button("Open Dashboard") { DashboardWindow.shared.show() }
                Divider()
                Toggle("Play Sound", isOn: Binding(get: { store.playsSound }, set: { store.playsSound = $0; if $0 { ArrivalSound.play() } }))
                Toggle("Open at Login", isOn: Binding(get: { store.opensAtLogin }, set: { store.opensAtLogin = $0 }))
                Divider()
                Button("Quit NotchBead") { NSApp.terminate(nil) }
            }
            .help(store.next.map { "Go to: \($0.title)" } ?? "Your scheduled tasks")
            .allowsHitTesting(!open)
    }

    // MARK: - Bead

    /// The left wing while something needs you, outside in: 3pt, the app icon (12pt), 4pt,
    /// Bead (18pt), then room for its count. Otherwise Bead sits in the middle of the wing.
    private static let iconSize: CGFloat = 12

    /// Which app wants you, beside Bead.
    private var sourceIcon: some View {
        let size = Self.iconSize
        let shown = present && !open
        return SourceIcon(sources: AttentionItem.Source.distinct(in: store.visible), size: size)
            .scaleEffect(shown ? 1 : 0.8)
            .opacity(shown ? 0.95 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 3)
            .offset(x: leftEdge + 3, y: (model.notchHeight - size) / 2 + (shown ? 0 : drift))
            .animation(shown ? .notchOpen.delay(0.12) : .easeIn(duration: 0.15), value: shown)
            .allowsHitTesting(false)
    }

    /// Bead is in the wing while closed, and in the list's header while the panel shows the list.
    /// On a task's detail it goes back up to the wing.
    private var inWing: Bool { !open || model.showingDetail || headerSlot == .zero }
    /// Blue for what needs you while closed; in the panel, how your scheduled tasks are.
    private var showsAttention: Bool { present && !open }

    private var beadCenter: CGPoint {
        if !inWing { return CGPoint(x: headerSlot.midX, y: headerSlot.midY) }
        let x = showsAttention ? leftEdge + 3 + Self.iconSize + 4 + NotchModel.wingBeadSize / 2 : leftEdge + wing / 2
        return CGPoint(x: x, y: model.notchHeight / 2)
    }

    private var bead: some View {
        let size = inWing ? NotchModel.wingBeadSize : NotchModel.headerBeadSize
        let center = beadCenter
        return BeadView(
            mood: showsAttention ? store.mood : BeadMood(jobs.overallState),
            size: size,
            runRange: inWing ? (showsAttention ? 2 : 8) : 3,
            gaze: gaze(from: center),
            pokes: pokes + model.beadPokes,
            badge: showsAttention ? max(store.visible.count, 1) : nil
        )
        // Grey while it just dozes in the wing, so it stays quiet next to the notch.
        .opacity(model.menuOpen && !inWing ? 0.35 : (inWing && !showsAttention && jobs.overallState == .ok || jobs.overallState == .empty) && inWing ? 0.55 : 1)
        .animation(.easeOut(duration: 0.18), value: model.menuOpen)
        .offset(x: center.x - size / 2, y: center.y - size / 2)
        .animation(.notchOpen, value: inWing)
        .animation(.notchOpen, value: showsAttention)
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

extension BeadMood {
    /// How your scheduled tasks are: dozing when all is well, running while one runs,
    /// amber when one needs a look, red when one failed.
    init(_ state: OverallState) {
        switch state {
        case .empty, .ok: self = .dozing
        case .running: self = .onIt
        case .headsUp: self = .headsUp
        case .failed: self = .failed
        }
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
