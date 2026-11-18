// Thermo — live CPU / RAM / GPU / temperature for macOS.
// Three display modes: around the notch, a floating movable widget, or the menu bar.

import AppKit
import SwiftUI
import Combine

enum Corner: String, CaseIterable { case topLeft = "Top left", topRight = "Top right", bottomLeft = "Bottom left", bottomRight = "Bottom right" }
extension Notification.Name { static let moveToCorner = Notification.Name("moveToCorner")
    static let detachFromNotch = Notification.Name("detachFromNotch")
    static let dockToNotch = Notification.Name("dockToNotch") }

// MARK: - Notch mode

struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat { get { radius } set { radius = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        let top: CGFloat = 6
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + radius, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - radius), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRoot: View {
    @ObservedObject var m: Monitor
    @ObservedObject var settings: Settings
    let notchWidth: CGFloat, notchHeight: CGFloat
    static let wing: CGFloat = 58
    static let panelSize = CGSize(width: 460, height: 228)

    var body: some View {
        let s = m.snap
        let open = m.expanded
        let w = open ? Self.panelSize.width : notchWidth + Self.wing * 2
        let h = open ? notchHeight + Self.panelSize.height : notchHeight
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: open ? 22 : 10).fill(.black)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        HStack(spacing: 5) {
                            Ring(metric: .cpu, value: s.cpu)
                            Ring(metric: .ram, value: s.ramPct)
                        }.frame(width: Self.wing, alignment: .leading).padding(.leading, 10)
                        Spacer(minLength: notchWidth)
                        HStack(spacing: 5) {
                            Ring(metric: .gpu, value: s.gpu)
                            TempBadge(m: m)
                        }.frame(width: Self.wing, alignment: .trailing).padding(.trailing, 10)
                    }
                    .frame(height: notchHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle() }
                    .gesture(DragGesture(minimumDistance: 10).onEnded { g in
                        // Pull the notch down to detach it into a floating widget.
                        if g.translation.height > 40 { NotificationCenter.default.post(name: .detachFromNotch, object: nil) }
                    })

                    if open {
                        ExpandedPanel(m: m, settings: settings, showPin: true,
                                      onCollapse: { m.pinned = false; set(false) })
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .frame(width: w, height: h)
            .foregroundStyle(.white)
            .onHover { inside in
                if inside { set(true) } else if !m.pinned { set(false) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func set(_ v: Bool) {
        guard m.expanded != v else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { m.expanded = v }
    }
    func toggle() {
        m.pinned.toggle()
        set(m.pinned || !m.expanded)
    }
}

// MARK: - Floating mode

struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

final class FloatController {
    weak var panel: NSPanel?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func resize(to size: CGSize) {
        guard let panel, size.width > 0, let screen = panel.screen ?? NSScreen.main else { return }
        var f = panel.frame
        let vis = screen.visibleFrame
        // Grow toward the screen centre so the panel never runs off-screen.
        let anchorRight = f.midX > vis.midX
        let anchorTop = f.midY > vis.midY
        let newX = anchorRight ? f.maxX - size.width : f.minX
        let newY = anchorTop ? f.maxY - size.height : f.minY
        f = NSRect(x: newX, y: newY, width: size.width, height: size.height)
        panel.setFrame(clamp(f, vis), display: true)
    }

    func drag(changed: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if changed {
            if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
            let s = dragStart!
            panel.setFrameOrigin(NSPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
        } else {
            dragStart = nil
            snap()
        }
    }

    /// Magnetic edges: within 30 pt of a screen edge, stick to it.
    func snap() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame, m: CGFloat = 12, reach: CGFloat = 30
        var f = panel.frame
        if f.minX - v.minX < reach { f.origin.x = v.minX + m }
        if v.maxX - f.maxX < reach { f.origin.x = v.maxX - f.width - m }
        if f.minY - v.minY < reach { f.origin.y = v.minY + m }
        if v.maxY - f.maxY < reach { f.origin.y = v.maxY - f.height - m }
        if screen.safeAreaInsets.top > 0, f.maxY > v.maxY - 40, abs(f.midX - screen.frame.midX) < 160 {
            NotificationCenter.default.post(name: .dockToNotch, object: nil)
            return
        }
        f = clamp(f, v)
        panel.setFrame(f, display: true, animate: true)
        UserDefaults.standard.set(NSStringFromPoint(f.origin), forKey: "floatOrigin")
    }

    func move(to c: Corner) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame, m: CGFloat = 12
        var f = panel.frame
        f.origin.x = (c == .topLeft || c == .bottomLeft) ? v.minX + m : v.maxX - f.width - m
        f.origin.y = (c == .topLeft || c == .topRight) ? v.maxY - f.height - m : v.minY + m
        panel.setFrame(f, display: true, animate: true)
        UserDefaults.standard.set(NSStringFromPoint(f.origin), forKey: "floatOrigin")
    }

    private func clamp(_ f: NSRect, _ v: NSRect) -> NSRect {
        var r = f
        r.origin.x = min(max(r.minX, v.minX), v.maxX - r.width)
        r.origin.y = min(max(r.minY, v.minY), v.maxY - r.height)
        return r
    }
}

struct FloatingRoot: View {
    @ObservedObject var m: Monitor
    @ObservedObject var settings: Settings
    let ctl: FloatController

    var body: some View {
        Group {
            if m.expanded {
                VStack(spacing: 0) {
                    Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 4).padding(.top, 6)  // drag handle
                    ExpandedPanel(m: m, settings: settings, onCollapse: { m.expanded = false })
                }
            } else {
                CompactStrip(m: m, vertical: settings.orientation == .vertical)
                    .contentShape(Rectangle())
                    .onTapGesture { m.expanded = true }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.88))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12))))
        .foregroundStyle(.white)
        .fixedSize()
        .background(GeometryReader { g in Color.clear.preference(key: SizeKey.self, value: g.size) })
        .onPreferenceChange(SizeKey.self) { ctl.resize(to: $0) }
        .simultaneousGesture(DragGesture(minimumDistance: 4)
            .onChanged { _ in ctl.drag(changed: true) }
            .onEnded { _ in ctl.drag(changed: false) })
        .contextMenu {
            Picker("Layout", selection: $settings.orientation) {
                ForEach(Orientation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

// MARK: - App

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
        apply(force: true)
        settings.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.apply() } }
            .store(in: &bag)
        monitor.$snap.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusTitle() } }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.apply(force: true) }
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
        let winW = max(NotchRoot.panelSize.width, notchW + NotchRoot.wing * 2 + 28) + 40
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
        p.contentView = NSHostingView(rootView: FloatingRoot(m: monitor, settings: settings, ctl: floatCtl))
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
        if let t = s.hottest { parts.append((monitor.advice.level >= .hot ? "⚠︎ " : "") + "\(Int(t))°") }
        b.attributedTitle = NSAttributedString(string: parts.joined(separator: "  "),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
