// Thermo — live CPU / RAM / GPU / temperature for macOS.
// Three display modes: around the notch, a floating movable widget, or the menu bar.

import AppKit
import SwiftUI
import Combine

// MARK: - App

/// Reports its SwiftUI content size so the floating window can be resized (and kept on screen) by us.
final class FitHostingView<V: View>: NSHostingView<V> {
    var onFit: ((CGSize) -> Void)?
    private var pending = false
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            let s = self.intrinsicContentSize
            if s.width > 0, s.height > 0 { self.onFit?(s) }
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); invalidateIntrinsicContentSize() }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // lets menus and buttons work
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: OverlayPanel?
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let monitor = Monitor()
    lazy var settings = Settings(hasNotch: NSScreen.screens.contains { $0.safeAreaInsets.top > 0 })
    let floatCtl = FloatController()
    var bag = Set<AnyCancellable>()
    var lastMode: DisplayMode?
    var lastOrientation: Orientation?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = Updater.shared   // starts the daily update check
        if CommandLine.arguments.contains("--update-now") { Updater.shared.updateNow() }
        apply(force: true)
        settings.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.apply() } }
            .store(in: &bag)
        monitor.$snap.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusTitle() } }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.apply(force: true) }
        // A click anywhere outside Thermo collapses the expanded panel.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let m = self?.monitor, m.expanded else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { m.pinned = false; m.expanded = false }
        }
        NotificationCenter.default.addObserver(forName: .detachFromNotch, object: nil, queue: .main) { [weak self] _ in
            let p = NSEvent.mouseLocation
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: p.x - 80, y: p.y - 30)), forKey: "floatOrigin")
            self?.settings.mode = .floating
        }
        NotificationCenter.default.addObserver(forName: .dockToNotch, object: nil, queue: .main) { [weak self] _ in
            self?.settings.mode = .notch
        }
        NotificationCenter.default.addObserver(forName: .moveToCorner, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? Corner { self?.floatCtl.move(to: c) }
        }
    }

    func apply(force: Bool = false) {
        let showStatus = settings.mode == .menuBar || settings.menuBarItem
        if showStatus && statusItem == nil { makeStatusItem() }
        if !showStatus, let s = statusItem { NSStatusBar.system.removeStatusItem(s); statusItem = nil }

        guard force || settings.mode != lastMode || (settings.mode == .floating && settings.orientation != lastOrientation) else { return }
        lastMode = settings.mode
        lastOrientation = settings.orientation
        monitor.expanded = false
        monitor.pinned = false
        panel?.close()
        panel = nil
        switch settings.mode {
        case .notch: makeNotchPanel()
        case .floating: makeFloatingPanel()
        case .menuBar: break
        }
    }

    private func basePanel(_ frame: NSRect) -> OverlayPanel {
        let p = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return p
    }

    private func makeNotchPanel() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        var notchW: CGFloat = 190
        var notchH: CGFloat = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notchW = screen.frame.width - l.width - r.width
            notchH = screen.safeAreaInsets.top
        }
        let winW = max(NotchRoot.panelSize.width, notchW + NotchRoot.wing * 4 + 40) + 40
        let winH = notchH + NotchRoot.panelSize.height + 20
        let p = basePanel(NSRect(x: screen.frame.midX - winW / 2, y: screen.frame.maxY - winH, width: winW, height: winH))
        p.level = .statusBar + 1
        p.contentView = NSHostingView(rootView: NotchRoot(m: monitor, settings: settings, notchWidth: notchW, notchHeight: notchH))
        p.orderFrontRegardless()
        panel = p
    }

    private func makeFloatingPanel() {
        let screen = NSScreen.main!
        var origin = NSPoint(x: screen.visibleFrame.maxX - 330, y: screen.visibleFrame.maxY - 50)
        if let s = UserDefaults.standard.string(forKey: "floatOrigin") {
            let o = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -10, dy: -10).contains(o) }) { origin = o }
        }
        let p = basePanel(NSRect(origin: origin, size: CGSize(width: 300, height: 34)))
        p.level = .floating
        floatCtl.panel = p
        let host = FitHostingView(rootView: FloatingRoot(m: monitor, settings: settings, ctl: floatCtl))
        host.sizingOptions = [.intrinsicContentSize]   // no auto window resizing; FloatController keeps it on screen
        host.onFit = { [weak self] size in self?.floatCtl.resize(to: size) }
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView:
            ExpandedPanel(m: monitor, settings: settings).background(Color.black.opacity(0.92)))
        popover = pop
        updateStatusTitle()
    }

    @objc func togglePopover() {
        guard let pop = popover, let b = statusItem?.button else { return }
        if pop.isShown { pop.performClose(nil) } else {
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }

    func updateStatusTitle() {
        guard let b = statusItem?.button else { return }
        let s = monitor.snap
        var parts = ["CPU \(Int(s.cpu))%", "RAM \(Int(s.ramPct))%"]
        if let g = s.gpu { parts.append("GPU \(Int(g))%") }
        if let t = s.hottest { parts.append((monitor.advice.level >= .hot ? "⚠︎ " : "") + "\(Int(t))°") }
        b.attributedTitle = NSAttributedString(string: parts.joined(separator: "  "),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
