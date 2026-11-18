// Notch and floating window views, plus the controller that keeps the floating widget on screen.

import AppKit
import SwiftUI
import Combine

enum Corner: String, CaseIterable { case topLeft = "Top left", topCenter = "Top centre", topRight = "Top right", center = "Centre of screen", bottomLeft = "Bottom left", bottomRight = "Bottom right" }
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
    static let wing: CGFloat = 62
    static let panelSize = CGSize(width: 460, height: 228)

    var body: some View {
        let open = m.expanded
        let icon = min(notchHeight - 8, 26)   // as large as fits, with room left for the glow
        let side = settings.notchSide
        let rings = settings.style == .rings
        let temp: CGFloat = 46, sp: CGFloat = 5
        // Each side is exactly as wide as what it holds; nothing is padded to match the other side.
        let leftItems: CGFloat = rings ? icon * 2 + sp : icon
        let rightItems: CGFloat = rings ? icon + sp + temp : temp
        let allW: CGFloat = leftItems + sp + rightItems
        let leftW: CGFloat = side == .right ? 0 : side == .left ? allW : leftItems
        let rightW: CGFloat = side == .left ? 0 : side == .right ? allW : rightItems
        let gap = notchWidth + 12   // keep 6 pt clear on each side of the physical notch
        let lp: CGFloat = leftW > 0 ? leftW + 12 : 8, rp: CGFloat = rightW > 0 ? rightW + 12 : 8   // + outer margin
        // Shift the strip so the reserved gap sits exactly over the notch even when the sides differ in width.
        let shift: CGFloat = open ? 0 : (rp - lp) / 2
        let w = open ? Self.panelSize.width : gap + lp + rp
        let h = open ? notchHeight + Self.panelSize.height : notchHeight
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: open ? 22 : 10).fill(.black)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        HStack(spacing: 5) {
                            if side == .both { leftHalf(icon) } else if side == .left { allItems(icon) }
                        }.frame(width: leftW, alignment: .trailing).padding(.leading, lp - leftW)
                        Spacer(minLength: gap)
                        HStack(spacing: 5) {
                            if side == .both { rightHalf(icon) } else if side == .right { allItems(icon) }
                        }.frame(width: rightW, alignment: .leading).padding(.trailing, rp - rightW)
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
            .offset(x: shift)
            .foregroundStyle(.white)
            .onHover { inside in
                if inside { set(true) } else if !m.pinned { set(false) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // Both-sides layout hugs the notch: left items align toward it, right items start right after it.
    @ViewBuilder func leftHalf(_ icon: CGFloat) -> some View {
        if settings.style == .orb { Orb(m: m, size: icon) } else {
            Ring(metric: .cpu, value: m.snap.cpu, size: icon)
            Ring(metric: .ram, value: m.snap.ramPct, size: icon)
        }
    }
    @ViewBuilder func rightHalf(_ icon: CGFloat) -> some View {
        if settings.style == .rings { Ring(metric: .gpu, value: m.snap.gpu, size: icon) }
        TempBadge(m: m, big: true)
    }
    @ViewBuilder func allItems(_ icon: CGFloat) -> some View {
        leftHalf(icon); rightHalf(icon)
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
        let centred = abs(f.midX - vis.midX) < 40
        let newX = centred ? f.midX - size.width / 2 : anchorRight ? f.maxX - size.width : f.minX
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
        switch c {
        case .topLeft, .bottomLeft: f.origin.x = v.minX + m
        case .topRight, .bottomRight: f.origin.x = v.maxX - f.width - m
        case .topCenter, .center: f.origin.x = v.midX - f.width / 2
        }
        switch c {
        case .topLeft, .topRight, .topCenter: f.origin.y = v.maxY - f.height - m
        case .bottomLeft, .bottomRight: f.origin.y = v.minY + m
        case .center: f.origin.y = v.midY - f.height / 2
        }
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
                CompactStrip(m: m, vertical: settings.orientation == .vertical, orb: settings.style == .orb)
                    .contentShape(Rectangle())
                    .onTapGesture { m.expanded = true }
            }
        }
        .background(RoundedRectangle(cornerRadius: m.expanded || settings.style == .rings ? 14 : 23).fill(Color.black.opacity(0.88))
            .overlay(RoundedRectangle(cornerRadius: m.expanded || settings.style == .rings ? 14 : 23).stroke(.white.opacity(0.12))))
        .foregroundStyle(.white)
        .fixedSize()
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

