import AppKit
import Observation
import SwiftUI

// The notch window technique is adapted from onit (MIT, Copyright (c) 2026 Neethan Wu).

/// Where the notch is on the built-in display, if there is one.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var notchMidX: CGFloat

    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            let frame = screen.frame
            let width = frame.width - left.width - right.width
            return NotchGeometry(
                screenFrame: frame,
                notchWidth: width,
                notchHeight: screen.safeAreaInsets.top,
                notchMidX: frame.minX + left.width + width / 2
            )
        }
        return nil
    }
}

/// Heed lives in the notch when there is one, and in the menu bar otherwise (an external display,
/// a Mac without a notch). It switches on its own as displays come and go.
@MainActor
@Observable
final class DisplayController {
    private(set) var notchAvailable = false
    var showsMenuBarIcon: Bool { !notchAvailable }

    @ObservationIgnored private let store: AttentionStore
    @ObservationIgnored private var notch: NotchWindowController?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    init(store: AttentionStore) {
        self.store = store
    }

    func start() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    func update() {
        let geometry = NotchGeometry.current()
        notchAvailable = geometry != nil
        if let geometry {
            if notch == nil { notch = NotchWindowController(store: store) }
            notch?.show(on: geometry)
        } else {
            notch?.hide()
        }
    }
}

@MainActor
@Observable
final class NotchModel {
    var notchWidth: CGFloat = 180
    var notchHeight: CGFloat = 32
    var windowFrame: CGRect = .zero
    /// Pointer position in screen coordinates, so Bead can look at it.
    var mouse: CGPoint?

    static let wingWidth: CGFloat = 44
    static let wingBeadSize: CGFloat = 18
}

/// A borderless panel pinned over the notch. Everything outside the black shape is transparent,
/// so clicks there reach the apps below.
@MainActor
final class NotchWindowController {
    private let panel: NotchPanel
    private let model = NotchModel()
    private var mouseMonitors: [Any] = []

    private static let windowSize = CGSize(width: 400, height: 80)

    init(store: AttentionStore) {
        panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // A fullscreen app hides the notch area, so Heed steps aside too.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false

        let hosting = FirstClickHostingView(rootView: NotchView(store: store, model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    func show(on geometry: NotchGeometry) {
        model.notchWidth = geometry.notchWidth
        model.notchHeight = geometry.notchHeight
        let origin = CGPoint(
            x: geometry.notchMidX - Self.windowSize.width / 2,
            y: geometry.screenFrame.maxY - Self.windowSize.height
        )
        let frame = CGRect(origin: origin, size: Self.windowSize)
        panel.setFrame(frame, display: true)
        model.windowFrame = frame
        panel.orderFrontRegardless()
        trackPointer()
    }

    func hide() {
        panel.orderOut(nil)
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
    }

    /// Mouse moves anywhere on screen, so Bead can look at the pointer as it approaches.
    private func trackPointer() {
        guard mouseMonitors.isEmpty else { return }
        let update: () -> Void = { [weak self] in
            guard let self else { return }
            let location = NSEvent.mouseLocation
            if let last = model.mouse, hypot(last.x - location.x, last.y - location.y) < 2 { return }
            model.mouse = location
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { _ in
            MainActor.assumeIsolated { update() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            MainActor.assumeIsolated { update() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The notch should react to the first click, even though Heed is never the active app.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension Animation {
    /// Opening has a little give; closing is quicker and settles flat.
    static let notchOpen = Animation.spring(duration: 0.45, bounce: 0.18)
    static let notchClose = Animation.spring(duration: 0.34, bounce: 0)
    static let settle = Animation.spring(duration: 0.4, bounce: 0.1)
}
