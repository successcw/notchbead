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

/// NotchBead lives in the notch when there is one, and in the menu bar otherwise (an external display,
/// a Mac without a notch). It switches on its own as displays come and go.
@MainActor
@Observable
final class DisplayController {
    private(set) var notchAvailable = false
    var showsMenuBarIcon: Bool { !notchAvailable }

    @ObservationIgnored private let store: AttentionStore
    @ObservationIgnored private let jobs: JobStore
    @ObservationIgnored private var notch: NotchWindowController?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    init(store: AttentionStore, jobs: JobStore) {
        self.store = store
        self.jobs = jobs
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
            if notch == nil { notch = NotchWindowController(store: store, jobs: jobs) }
            notch?.show(on: geometry)
        } else {
            notch?.hide()
        }
    }
}

@MainActor
@Observable
final class NotchModel {
    /// The scheduled-tasks panel is open below the notch.
    var isExpanded = false {
        didSet { if oldValue != isExpanded { onExpandChange?(isExpanded) } }
    }
    @ObservationIgnored var onExpandChange: ((Bool) -> Void)?
    /// Set by the panel so Escape steps back from a task's detail before closing the panel.
    var showingDetail = false
    /// A "more" menu is open, so Bead in the panel header steps back with the rest of the panel.
    var menuOpen = false
    /// Clicks on Bead in the panel header; each one makes it hop.
    var beadPokes = 0
    var notchWidth: CGFloat = 180
    var notchHeight: CGFloat = 32
    var windowFrame: CGRect = .zero
    /// Pointer position in screen coordinates, so Bead can look at it.
    var mouse: CGPoint?

    static let wingWidth: CGFloat = 44
    static let wingBeadSize: CGFloat = 18
    static let headerBeadSize: CGFloat = 34
    static let panelWidth: CGFloat = 380
    static let space = "notch"
}

/// A borderless panel pinned over the notch. It is always the size of the open panel; everything
/// outside the black shape is transparent, so clicks there reach the apps below.
@MainActor
final class NotchWindowController {
    private let panel: NotchPanel
    private let model = NotchModel()
    private var mouseMonitors: [Any] = []
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?

    private static let windowSize = CGSize(width: NotchModel.panelWidth + 40, height: 640)

    init(store: AttentionStore, jobs: JobStore) {
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
        // A fullscreen app hides the notch area, so NotchBead steps aside too.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false

        let hosting = FirstClickHostingView(rootView: NotchView(store: store, jobs: jobs, model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting
        model.onExpandChange = { [weak self] expanded in self?.expandChanged(expanded) }
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
        // NOTCHBEAD_OPEN=1 opens the scheduled-tasks panel at launch, for screenshots.
        if ProcessInfo.processInfo.environment["NOTCHBEAD_OPEN"] == "1", !model.isExpanded {
            Task { @MainActor [model] in
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.notchOpen) { model.isExpanded = true }
            }
        }
    }

    func hide() {
        collapse()
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

extension NotchWindowController {
    func collapse() {
        guard model.isExpanded else { return }
        withAnimation(.notchClose) { model.isExpanded = false }
    }

    /// While the panel is open it takes keys (Escape) and closes on a click anywhere else.
    /// Closed, it never becomes key, so it can't take the text cursor from the app you're in.
    fileprivate func expandChanged(_ expanded: Bool) {
        panel.acceptsKey = expanded
        if expanded {
            panel.makeKey()
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.collapse() }
            }
            // Escape closes the panel unless a task's detail is open, where it first goes back to the list.
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, !self.model.showingDetail else { return false }
                    self.collapse()
                    return true
                }
                return handled ? nil : event
            }
        } else {
            for monitor in [outsideClickMonitor, escapeMonitor].compactMap({ $0 }) {
                NSEvent.removeMonitor(monitor)
            }
            outsideClickMonitor = nil
            escapeMonitor = nil
            panel.resignKey()
        }
    }
}

final class NotchPanel: NSPanel {
    /// Only while the scheduled-tasks panel is open.
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

extension EnvironmentValues {
    @Entry var panelWidth: CGFloat = Metrics.popoverWidth
    /// True inside the notch, where controls are flat fills on black instead of Liquid Glass.
    @Entry var notchStyle = false
    @Entry var notchModel: NotchModel?
}

/// The notch should react to the first click, even though NotchBead is never the active app.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension Animation {
    /// Opening has a little give; closing is quicker and settles flat.
    static let notchOpen = Animation.spring(duration: 0.45, bounce: 0.18)
    static let notchClose = Animation.spring(duration: 0.34, bounce: 0)
    static let settle = Animation.spring(duration: 0.4, bounce: 0.1)
}
