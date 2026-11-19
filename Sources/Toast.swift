// Small notification cards that slide in at the top-right of the screen:
// welcome (with "Open at login"), update available, and "what's new" after an update.
// Drawn by Thermo itself, so no notification permission is needed.

import AppKit
import SwiftUI
import ServiceManagement

struct ToastAction { let title: String; let primary: Bool; let run: () -> Void }

struct ToastContent {
    var icon: String
    var tint: Color
    var title: String
    var subtitle: String
    var bullets: [String] = []
    var actions: [ToastAction] = []
    var autoHide: Double? = nil
    var keepInInbox = true
}

final class ToastModel: ObservableObject {
    @Published var content: ToastContent?
    @Published var shown = false
}

struct ToastView: View {
    @ObservedObject var model: ToastModel
    var close: () -> Void
    var body: some View {
        if let c = model.content {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: c.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(c.tint)
                        .frame(width: 30, height: 30).background(Circle().fill(c.tint.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.system(size: 13, weight: .bold))
                        Text(c.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 18, height: 18).background(Circle().fill(.white.opacity(0.08)))
                    }.buttonStyle(.plain)
                }
                if !c.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(c.bullets.prefix(4), id: \.self) { b in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(c.tint)
                                Text(b).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.leading, 40)
                }
                if !c.actions.isEmpty {
                    HStack(spacing: 8) {
                        Spacer()
                        ForEach(Array(c.actions.enumerated()), id: \.offset) { _, a in
                            Button { a.run(); close() } label: {
                                Text(a.title).font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(Capsule().fill(a.primary ? c.tint : .white.opacity(0.1)))
                                    .foregroundStyle(a.primary ? .black : .white)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 330)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.09).opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .foregroundStyle(.white)
            .offset(x: model.shown ? 0 : 380)
            .opacity(model.shown ? 1 : 0)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}

final class Toasts {
    static let shared = Toasts()
    private let model = ToastModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ c: ToastContent) {
        let size = CGSize(width: 370, height: 260)
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.isReleasedWhenClosed = false
            p.level = .statusBar + 2
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let host = NSHostingView(rootView: ToastView(model: model, close: { [weak self] in self?.hide() }))
            host.sizingOptions = []
            p.contentView = host
            panel = p
        }
        guard let p = panel, let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        p.setFrame(NSRect(x: v.maxX - size.width, y: v.maxY - size.height, width: size.width, height: size.height), display: false)
        if c.keepInInbox { Inbox.shared.add(c) }
        model.content = c
        model.shown = false
        p.orderFrontRegardless()
        DispatchQueue.main.async { withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { self.model.shown = true } }
        hideWork?.cancel()
        if let t = c.autoHide {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
        }
    }

    func hide() {
        withAnimation(.easeIn(duration: 0.2)) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            if self?.model.shown == false { self?.panel?.orderOut(nil) }
        }
    }

    // MARK: Specific toasts

    func welcome() {
        let loginOn = SMAppService.mainApp.status == .enabled
        show(ToastContent(
            icon: "hand.wave.fill", tint: .orange,
            title: "Thermo is running 🎉",
            subtitle: "Find it beside your notch or in the menu bar. Hover or click it for details.",
            bullets: loginOn ? [] : ["Want Thermo to start automatically every time you log in?"],
            actions: loginOn ? [ToastAction(title: "Got it", primary: true, run: {})] : [
                ToastAction(title: "Not now", primary: false, run: {}),
                ToastAction(title: "Open at login", primary: true, run: { setOpenAtLogin(true) }),
            ],
            autoHide: 25, keepInInbox: false))
    }

    /// One-time tip in notch mode: other apps' menu-bar icons can't be detected without extra permissions,
    /// so explain the layout and offer to move Thermo to one side.
    func notchTip(settings: Settings) {
        show(ToastContent(
            icon: "rectangle.topthird.inset.filled", tint: .cyan,
            title: "Thermo sits around your notch",
            subtitle: "It stays centred so it's always easy to glance at. If it covers any of your menu-bar icons, move it to one side. You can change this anytime in ⚙ → Notch side.",
            actions: [
                ToastAction(title: "Keep centred", primary: false, run: {}),
                ToastAction(title: "Right", primary: false, run: { settings.notchSide = .right }),
                ToastAction(title: "Move left", primary: true, run: { settings.notchSide = .left }),   // left is usually free
            ]))
    }

    func updateAvailable(_ r: Release) {
        show(ToastContent(
            icon: "arrow.down.circle.fill", tint: .orange,
            title: "Thermo \(r.version) is available",
            subtitle: "You have \(Updater.shared.current). Here's what's new:",
            bullets: releaseBullets(r.notes),
            actions: [
                ToastAction(title: "Later", primary: false, run: {}),
                ToastAction(title: "Update now", primary: true, run: { Updater.shared.promptInstall() }),
            ]))
    }

    func whatsNew(version: String, notes: String) {
        show(ToastContent(
            icon: "sparkles", tint: .mint,
            title: "Updated to Thermo \(version)",
            subtitle: "Here's what changed:",
            bullets: releaseBullets(notes),
            actions: [ToastAction(title: "Nice!", primary: true, run: {})],
            autoHide: 20))
    }
}

/// "- item" lines from release notes, with markdown emphasis removed.
func releaseBullets(_ notes: String) -> [String] {
    notes.split(separator: "\n").compactMap { line in
        let l = line.trimmingCharacters(in: .whitespaces)
        guard l.hasPrefix("- ") || l.hasPrefix("* ") else { return nil }
        return String(l.dropFirst(2)).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}

func setOpenAtLogin(_ on: Bool) {
    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
    catch { NSSound.beep(); NSLog("Thermo login item: \(error)") }
}

// MARK: - Inbox: the last 20 notifications, kept in memory only

struct InboxItem: Identifiable { let id = UUID(); let date = Date(); let content: ToastContent }

final class Inbox: ObservableObject {
    static let shared = Inbox()
    @Published var items: [InboxItem] = []
    @Published var unread = 0
    @Published var openID: UUID?
    func add(_ c: ToastContent) {
        items.insert(InboxItem(content: c), at: 0)
        if items.count > 20 { items.removeLast(items.count - 20) }
        unread += 1
    }
}

struct InboxButton: View {
    @ObservedObject var m: Monitor
    @ObservedObject var inbox = Inbox.shared
    var body: some View {
        Button { m.tab = m.tab == .inbox ? .overview : .inbox; inbox.unread = 0 } label: {
            Image(systemName: inbox.unread > 0 ? "bell.badge.fill" : "bell.fill")
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(inbox.unread > 0 ? .multicolor : .monochrome)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(m.tab == .inbox ? 0.25 : 0.1)))
        }.buttonStyle(.plain).help(inbox.unread > 0 ? "\(inbox.unread) new alert\(inbox.unread == 1 ? "" : "s")" : "Alerts")
    }
}

struct InboxTab: View {
    @ObservedObject var m: Monitor
    @ObservedObject var inbox = Inbox.shared
    var body: some View {
        if inbox.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "bell.slash").font(.system(size: 22)).foregroundStyle(.secondary)
                Text("No alerts yet").font(.system(size: 12, weight: .semibold))
                Text("Updates and warnings will be listed here.").font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MaybeScroll {
                VStack(spacing: 4) {
                    ForEach(inbox.items) { item in InboxRow(item: item, open: inbox.openID == item.id) {
                        withAnimation(.easeOut(duration: 0.2)) { inbox.openID = inbox.openID == item.id ? nil : item.id }
                    } }
                }
            }
        }
    }
}

struct InboxRow: View {
    let item: InboxItem
    let open: Bool
    let toggle: () -> Void
    var body: some View {
        let c = item.content
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: c.icon).foregroundStyle(c.tint).frame(width: 18)
                Text(c.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(item.date, style: .relative).font(.system(size: 9)).foregroundStyle(.secondary)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if open {
                Text(c.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(c.bullets.prefix(4), id: \.self) { b in
                    HStack(alignment: .top, spacing: 6) { Text("•").foregroundStyle(c.tint); Text(b).font(.system(size: 11)) }
                }
                HStack(spacing: 6) {
                    Spacer()
                    ForEach(Array(c.actions.enumerated()), id: \.offset) { _, a in
                        Button(action: a.run) {
                            Text(a.title).font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(a.primary ? c.tint : .white.opacity(0.1)))
                                .foregroundStyle(a.primary ? .black : .white)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(open ? 0.1 : 0.05)))
    }
}
