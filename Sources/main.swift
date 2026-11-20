// Thermo — live CPU / RAM / GPU / temperature for macOS.
// Three display modes: around the notch, a floating movable widget, or the menu bar.

import AppKit
import SwiftUI
import Combine
import ServiceManagement

// MARK: - App

final class DropdownState: ObservableObject {
    @Published var shown = false
    var anchorX: CGFloat = 0.5
    var generation = 0
}

/// The menu-bar dropdown: pops out of the menu-bar item with a springy, Dock-like scale and fade.
struct MenuDropdown: View {
    static let pad: CGFloat = 24
    @ObservedObject var state: DropdownState
    @ObservedObject var m: Monitor
    @ObservedObject var settings: Settings
    var body: some View {
        ExpandedPanel(m: m, settings: settings)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            .scaleEffect(state.shown ? 1 : 0.25, anchor: UnitPoint(x: state.anchorX, y: 0))
            .opacity(state.shown ? 1 : 0)
            .padding(.horizontal, Self.pad)
            .padding(.bottom, Self.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

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
    var menuPanel: OverlayPanel?   // dropdown under the menu-bar item
    let dropdown = DropdownState()
    let monitor = Monitor()
    lazy var settings = Settings(hasNotch: NSScreen.screens.contains { $0.safeAreaInsets.top > 0 })
    let floatCtl = FloatController()
    var bag = Set<AnyCancellable>()
    var lastMode: DisplayMode?
    var lastOrientation: Orientation?

    func applicationWillTerminate(_ n: Notification) { History.shared.save() }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = Updater.shared   // starts the daily update check
        #if !NO_CONNECT
        LocalAPI.shared.monitor = monitor
        if LocalAPI.shared.enabled { LocalAPI.shared.start() }
        #endif
        if CommandLine.arguments.contains("--version") {
            print("Thermo \(Updater.shared.current)"); exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--set-login"), i + 1 < CommandLine.arguments.count {
            setOpenAtLogin(CommandLine.arguments[i + 1] == "on")   // `Thermo --set-login on|off`
            print("Open at login:", SMAppService.mainApp.status == .enabled ? "on" : "off (\(SMAppService.mainApp.status.rawValue))")
            exit(0)
        }
        let busy = Updater.shared.announceLaunch()
        if settings.mode == .notch && !UserDefaults.standard.bool(forKey: "notchTipShown") {
            DispatchQueue.main.asyncAfter(deadline: .now() + (busy ? 30 : 4)) {
                guard self.settings.mode == .notch else { return }
                UserDefaults.standard.set(true, forKey: "notchTipShown")
                Toasts.shared.notchTip(settings: self.settings)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--test-toast"), i + 1 < CommandLine.arguments.count {
            let notes = "- Smoother menu-bar dropdown\n- Gauges fit the notch\n- **Update notifications**"
            DispatchQueue.main.asyncAfter(deadline: .now() + 16) { NSApp.terminate(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                switch CommandLine.arguments[i + 1] {
                case "welcome": Toasts.shared.welcome()
                case "notch": Toasts.shared.notchTip(settings: self.settings)
                case "update": Toasts.shared.updateAvailable(Release(version: "9.9.9", notes: notes, zipURL: URL(string: "https://github.com")!, shaURL: URL(string: "https://github.com")!, pageURL: URL(string: "https://github.com")!))
                default: Toasts.shared.whatsNew(version: Updater.shared.current, notes: notes)
                }
            }
        }
        if CommandLine.arguments.contains("--update-now") { Updater.shared.updateNow() }
        if CommandLine.arguments.contains("--open-menu") {   // used to test the menu-bar dropdown
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.togglePopover() }
        }
        apply(force: true)
        settings.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.apply() } }
            .store(in: &bag)
        monitor.$snap.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusTitle() } }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.apply(force: true) }
        // A click anywhere outside Thermo collapses the expanded panel.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Clicks on our own menu-bar item are handled by togglePopover, not treated as "outside".
            if let self, !self.clickIsOnStatusItem() { self.hideMenu() }
            guard let m = self?.monitor, m.expanded else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { m.pinned = false; m.expanded = false }
        }
        // "Details" on an alert card opens the panel wherever Thermo lives.
        NotificationCenter.default.addObserver(forName: .showPanel, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            switch self.settings.mode {
            case .menuBar: if !self.dropdown.shown { self.togglePopover() }
            default: withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { self.monitor.pinned = true; self.monitor.expanded = true }
            }
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
        if !showStatus, let s = statusItem { NSStatusBar.system.removeStatusItem(s); statusItem = nil; menuPanel?.orderOut(nil); menuPanel = nil }

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
        // A fixed-size panel of our own instead of NSPopover: the popover re-measured its SwiftUI content on every
        // data refresh and kept jumping between the menu bar and lower down the screen.
        let size = CGSize(width: 510 + MenuDropdown.pad * 2, height: 210 + MenuDropdown.pad)   // room for the shadow
        let host = NSHostingView(rootView: MenuDropdown(state: dropdown, m: monitor, settings: settings))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let p = basePanel(NSRect(origin: .zero, size: size))
        p.level = .popUpMenu
        p.contentView = host
        menuPanel = p
        updateStatusTitle()
    }

    private func clickIsOnStatusItem() -> Bool {
        guard let b = statusItem?.button, let bw = b.window else { return false }
        return bw.convertToScreen(b.convert(b.bounds, to: nil)).insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    @objc func togglePopover() {
        guard let p = menuPanel, let b = statusItem?.button, let bw = b.window else { return }
        if dropdown.shown { hideMenu(); return }
        let item = bw.convertToScreen(b.convert(b.bounds, to: nil))
        let v = (bw.screen ?? NSScreen.main!).visibleFrame
        let pad = MenuDropdown.pad
        var x = item.midX - p.frame.width / 2
        x = min(max(x, v.minX + 8 - pad), v.maxX - p.frame.width - 8 + pad)
        p.setFrameOrigin(NSPoint(x: x, y: item.minY - 6 - p.frame.height))
        dropdown.anchorX = (item.midX - x) / p.frame.width   // grow out of the menu-bar item
        dropdown.generation += 1
        p.orderFrontRegardless()
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.66)) { self.dropdown.shown = true }
        }
    }

    /// Shrinks back into the menu-bar item, then removes the window.
    func hideMenu() {
        guard dropdown.shown, let p = menuPanel else { return }
        let gen = dropdown.generation
        withAnimation(.easeIn(duration: 0.16)) { dropdown.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if gen == self.dropdown.generation && !self.dropdown.shown { p.orderOut(nil) }
        }
    }

    func updateStatusTitle() {
        guard let b = statusItem?.button else { return }
        let s = monitor.snap
        var parts = ["CPU \(Int(s.cpu))%", "RAM \(Int(s.ramPct))%"]
        if let g = s.gpu { parts.append("GPU \(Int(g))%") }
        if let t = s.hottest { parts.append((monitor.advice.level >= .hot ? "⚠︎ " : "") + "\(Int(t))°") }
        b.toolTip = healthSummary(monitor).text
        b.attributedTitle = NSAttributedString(string: parts.joined(separator: "  "),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
    }
}

// Command-line and MCP modes run without any UI and exit.
#if !NO_CONNECT
if let code = CLI.run(CommandLine.arguments) { exit(code) }
#else
if CommandLine.arguments.contains("--cli") || CommandLine.arguments.contains("--mcp") {
    FileHandle.standardError.write(Data("This Thermo build has no CLI/MCP support (built with --no-connect).\n".utf8)); exit(1)
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
