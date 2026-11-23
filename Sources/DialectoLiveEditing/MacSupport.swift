#if DEBUG && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
    import Observation
    import SwiftUI

    /// Text under a point, read from the app's own accessibility tree (no Accessibility permission, no
    /// other process: `NSApp.accessibilityHitTest` answers for this app's windows). The hit is a private
    /// SwiftUI node that is not declared as `NSAccessibilityProtocol`, so its strings are read by selector.
    /// `point` is in Cocoa screen coordinates, origin bottom left, and so is the frame it returns.
    enum MacHitTest {
        struct Hit {
            var text: String
            var frame: NSRect?
            /// The view's tooltip (its accessibility help), when it has one. With no visible text, the
            /// tooltip is the text.
            var tooltip: String?
        }

        @MainActor
        static func text(at point: NSPoint, in windows: [NSWindow]) -> String? { hit(at: point, in: windows)?.text }

        /// `windows` are the ones Edit text covers, so the hit test and the frames agree.
        @MainActor
        static func hit(at point: NSPoint, in windows: [NSWindow]) -> Hit? {
            if let hit = read(at: point) { return hit }
            // The hit can land on the hosting view itself: look through the window's nodes for the smallest
            // one with text whose frame holds the point.
            var best: (area: Double, hit: Hit)?
            for window in windows where window.frame.contains(point) {
                search(window as AnyObject, point: point, depth: 0, best: &best)
            }
            return best?.hit
        }

        private static func search(_ node: AnyObject, point: NSPoint, depth: Int, best: inout (area: Double, hit: Hit)?) {
            guard depth < 12 else { return }
            if depth > 0, let rect = frame(of: node), rect.contains(point),
                string(node, "accessibilityRole") != "AXWindow"
            {
                let tooltip = string(node, "accessibilityHelp").flatMap { $0.isEmpty ? nil : $0 }
                let visible = ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"].lazy
                    .compactMap({ string(node, $0) }).first(where: { !$0.isEmpty })
                // A view with only a tooltip (an icon button) is its tooltip.
                if let text = visible ?? tooltip {
                    let area = Double(rect.width * rect.height)
                    if best == nil || area < best!.area { best = (area, Hit(text: text, frame: rect, tooltip: tooltip)) }
                }
            }
            for child in (object(node, "accessibilityChildren") as? [AnyObject]) ?? [] {
                search(child, point: point, depth: depth + 1, best: &best)
            }
        }

        private static func frame(of node: AnyObject) -> NSRect? {
            guard node.responds(to: Selector("accessibilityFrame")) else { return nil }
            return ((node as? NSObject)?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
        }

        @MainActor
        private static func read(at point: NSPoint) -> Hit? {
            var node = NSApp.accessibilityHitTest(point) as AnyObject?
            var up = 0
            var tooltip: (text: String, frame: NSRect?)?
            while let current = node, up < 6 {
                if let role = string(current, "accessibilityRole"), role == "AXWindow" || role == "AXApplication" {
                    break
                }
                if tooltip == nil, let help = string(current, "accessibilityHelp"), !help.isEmpty {
                    tooltip = (help, frame(of: current))
                }
                for selector in ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"] {
                    if let text = string(current, selector), !text.isEmpty {
                        return Hit(text: text, frame: frame(of: current), tooltip: tooltip?.text)
                    }
                }
                node = object(current, "accessibilityParent")
                up += 1
            }
            return tooltip.map { Hit(text: $0.text, frame: $0.frame, tooltip: $0.text) }
        }

        private static func object(_ node: AnyObject, _ name: String) -> AnyObject? {
            let selector = Selector(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }

        private static func string(_ node: AnyObject, _ name: String) -> String? {
            object(node, name) as? String
        }
    }

    /// What one app window's Edit text frame draws: the outline under the pointer, if any.
    @MainActor
    @Observable
    final class EditFrameState {
        struct Outline: Equatable {
            /// In the window's own space, origin top left.
            var rect: CGRect
            var label: String
        }

        var outline: Outline?
        /// No badge: the window is small.
        var compact = false

        init(compact: Bool = false) { self.compact = compact }
    }

    /// A click-through window over an app window while Edit text is on: a sea frame, a badge and the hover
    /// outline. It is a child window, so it moves with its parent.
    final class EditFrameWindow: NSWindow {
        let state: EditFrameState

        /// A window too small for the badge (a popover, an alert) gets the frame alone.
        static func isCompact(_ parent: NSWindow) -> Bool { parent.frame.width < 300 || parent.frame.height < 160 }

        @MainActor
        init(over parent: NSWindow) {
            state = EditFrameState(compact: Self.isCompact(parent))
            super.init(contentRect: parent.frame, styleMask: .borderless, backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            ignoresMouseEvents = true
            isReleasedWhenClosed = false
            collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            contentView = NSHostingView(rootView: EditFrameView(state: state))
            if let panel = parent as? NSPanel, panel.isFloatingPanel { level = parent.level }
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// The frame's drawing. The corner follows a titled macOS window's.
    struct EditFrameView: View {
        var state: EditFrameState

        var body: some View {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Coastal.sea, lineWidth: 3)
                if let outline = state.outline { outlineView(outline) }
                if !state.compact {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            badge
                            Spacer()
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .ignoresSafeArea()
        }

        private var badge: some View {
            HStack(spacing: 6) {
                Image(systemName: EditTextToggle.symbol)
                Text("Editing text")
                Text("esc")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.22)))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(Coastal.buttonSea))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }

        private func outlineView(_ outline: EditFrameState.Outline) -> some View {
            let box = outline.rect.insetBy(dx: -4, dy: -3)
            let tabAbove = box.minY > 22
            return ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Coastal.sea.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Coastal.sea, lineWidth: 2))
                    .background(RoundedRectangle(cornerRadius: 7.5).stroke(.white.opacity(0.85), lineWidth: 1.5).padding(-1.5))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                HStack(spacing: 4) {
                    Image(systemName: "pencil").font(.system(size: 10, weight: .bold))
                    Text(outline.label).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 19)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: tabAbove ? 5 : 0, bottomLeadingRadius: tabAbove ? 0 : 5,
                        bottomTrailingRadius: tabAbove ? 0 : 5, topTrailingRadius: tabAbove ? 5 : 0
                    )
                    .fill(Coastal.buttonSea))
                .fixedSize()
                .offset(x: box.minX, y: tabAbove ? box.minY - 19 : box.maxY)
            }
            .allowsHitTesting(false)
        }
    }

    /// The Mac side: a Dialecto menu, the keys panel and Edit text mode (frame, hover outline, pointer,
    /// the click that picks text, Esc).
    @MainActor
    final class MacSupport: NSObject, NSMenuItemValidation, NSWindowDelegate {
        private unowned let runtime: EditingRuntime
        private(set) var window: NSPanel?
        private var monitors: [Any] = []
        private var frames: [ObjectIdentifier: (parent: NSWindow, overlay: EditFrameWindow, movedEvents: Bool)] = [:]
        private var observers: [NSObjectProtocol] = []
        private var hovering = false
        private let item = NSMenuItem(title: "Dialecto", action: nil, keyEquivalent: "")
        private let signInItem = NSMenuItem(title: "Sign in to Dialecto", action: #selector(signInOrOut), keyEquivalent: "")
        private let editItem = NSMenuItem(title: "Edit text", action: #selector(toggleEdit), keyEquivalent: "e")
        private let keysItem = NSMenuItem(title: "Keys\u{2026}", action: #selector(showKeys), keyEquivalent: "")

        init(runtime: EditingRuntime) {
            self.runtime = runtime
            super.init()
            let menu = NSMenu(title: "Dialecto")
            editItem.keyEquivalentModifierMask = [.command, .option, .control]
            for entry in [signInItem, editItem, keysItem] {
                entry.target = self
                menu.addItem(entry)
            }
            item.submenu = menu
        }

        // MARK: Menu

        /// SwiftUI builds the main menu after launch and may rebuild it, so the item is put back whenever the
        /// app becomes active.
        func installMenu() {
            ensureMenu()
            let center = NotificationCenter.default
            for name in [NSApplication.didFinishLaunchingNotification, NSApplication.didBecomeActiveNotification] {
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.ensureMenu() }
                }
            }
            Task { @MainActor in
                for _ in 0..<20 where NSApp.mainMenu == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                ensureMenu()
            }
        }

        private func ensureMenu() {
            guard let main = NSApp.mainMenu, item.menu !== main else { return }
            main.addItem(item)
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            switch menuItem {
            case signInItem:
                switch runtime.session.state {
                case .signedIn: menuItem.title = "Sign out of Dialecto"
                case .waiting: menuItem.title = "Show the sign-in code"
                default: menuItem.title = "Sign in to Dialecto"
                }
            case editItem:
                menuItem.state = runtime.editState.isOn ? .on : .off
            default:
                break
            }
            return true
        }

        @objc private func signInOrOut() {
            switch runtime.session.state {
            case .signedIn: runtime.session.signOut()
            case .waiting: showWindow()
            default:
                runtime.session.signIn()
                showWindow()
            }
        }

        @objc private func toggleEdit() { runtime.editState.isOn.toggle() }

        @objc private func showKeys() { showWindow() }

        // MARK: Keys panel

        /// A floating utility panel, so it stays above the app's windows while text in them is clicked.
        func showWindow() {
            if window == nil {
                let panel = KeysPanel(
                    model: runtime.model, session: runtime.session, editMode: runtime.editState,
                    open: { [weak runtime] row in runtime?.openEditor(key: row.key) },
                    openProject: { [weak runtime] in runtime?.openProject() },
                    close: nil)
                let created = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                    styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
                created.title = "Dialecto Keys"
                created.isFloatingPanel = true
                created.hidesOnDeactivate = false
                created.becomesKeyOnlyIfNeeded = true
                created.contentView = NSHostingView(rootView: panel)
                created.isReleasedWhenClosed = false
                // Top right of the screen, so it does not sit over the app's text a click would pick.
                if let visible = NSScreen.main?.visibleFrame {
                    created.setFrameTopLeftPoint(NSPoint(x: visible.maxX - 440 - 16, y: visible.maxY - 16))
                } else {
                    created.center()
                }
                window = created
            }
            runtime.model.refresh()
            window?.orderFrontRegardless()
        }

        /// The window's pixels, for a check that does not need screen recording.
        func snapshot(to url: URL) -> Bool {
            guard let view = window?.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return false }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? data.write(to: url)) != nil
        }

        // MARK: Edit text

        /// Classes of the windows the system draws for itself: menus, tooltips, the status bar, text input.
        private static let systemWindowNames = ["Menu", "ToolTip", "Tooltip", "StatusBar", "TUINSWindow", "TextInput", "Dock", "NSCursor"]

        /// Every visible window the app shows, but Dialecto's own panel and frames: the main windows, and
        /// the sheets, alerts, popovers and panels the app opens. The click, the hover and the frames all
        /// go by this one list.
        func appWindows() -> [NSWindow] {
            NSApp.windows.filter { isAppWindow($0) }
        }

        private func isAppWindow(_ candidate: NSWindow) -> Bool {
            guard candidate.isVisible, candidate !== window, !(candidate is EditFrameWindow),
                candidate.frame.width > 20, candidate.frame.height > 20
            else { return false }
            let name = NSStringFromClass(type(of: candidate))
            return !Self.systemWindowNames.contains { name.contains($0) }
        }

        private func detach(_ id: ObjectIdentifier) {
            guard let held = frames.removeValue(forKey: id) else { return }
            held.parent.removeChildWindow(held.overlay)
            held.overlay.orderOut(nil)
            held.parent.acceptsMouseMovedEvents = held.movedEvents
        }

        /// Frames follow the windows: one on each that opened since, none on those that closed.
        private func rescan() {
            guard runtime.editState.isOn else { return }
            for (id, held) in frames where !held.parent.isVisible { detach(id) }
            for candidate in appWindows() where frames[ObjectIdentifier(candidate)] == nil { attachFrame(to: candidate) }
        }

        func setMonitoring(_ on: Bool) {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors = []
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            for id in Array(frames.keys) { detach(id) }
            if hovering {
                NSCursor.arrow.set()
                hovering = false
            }
            guard on else { return }

            for parent in appWindows() { attachFrame(to: parent) }
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didExposeNotification] {
                observers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                        nonisolated(unsafe) let note = note
                        MainActor.assumeIsolated { self?.windowChanged(note.object as? NSWindow) }
                    })
            }
            // A sheet, an alert or a popover opens, and closes, without the notices above: look again after
            // every event the app handles.
            for name in [NSApplication.didUpdateNotification, NSWindow.willCloseNotification] {
                observers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.rescan() }
                    })
            }

            if let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let target = event.window, self.isAppWindow(target) else { return false }
                    // Cocoa screen space already (origin bottom left): do not flip it.
                    let hit = MacHitTest.hit(at: target.convertPoint(toScreen: event.locationInWindow), in: self.appWindows())
                    self.runtime.pick(
                        text: hit?.text, tooltip: hit?.tooltip, preferTooltip: event.modifierFlags.contains(.option))
                    return true
                }
                return consumed ? nil : event
            }) {
                monitors.append(click)
            }
            if let move = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited], handler: { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.hover(event) }
                return event
            }) {
                monitors.append(move)
            }
            if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, event.keyCode == 53, self.runtime.editState.isOn else { return false }
                    self.runtime.editState.isOn = false
                    return true
                }
                return consumed ? nil : event
            }) {
                monitors.append(escape)
            }
        }

        private func attachFrame(to parent: NSWindow) {
            guard frames[ObjectIdentifier(parent)] == nil else { return }
            let overlay = EditFrameWindow(over: parent)
            overlay.setFrame(parent.frame, display: false)
            parent.addChildWindow(overlay, ordered: .above)
            frames[ObjectIdentifier(parent)] = (parent, overlay, parent.acceptsMouseMovedEvents)
            parent.acceptsMouseMovedEvents = true
        }

        private func windowChanged(_ changed: NSWindow?) {
            guard runtime.editState.isOn, let changed, !(changed is EditFrameWindow) else { return }
            if let held = frames[ObjectIdentifier(changed)] {
                held.overlay.setFrame(changed.frame, display: true)
            } else if isAppWindow(changed) {
                attachFrame(to: changed)
            }
        }

        /// Outlines the text under the pointer when it is a key Dialecto knows, and shows the pointing hand.
        private func hover(_ event: NSEvent) {
            let target = event.window.flatMap { frames[ObjectIdentifier($0)] }
            var shown: (overlay: EditFrameWindow, outline: EditFrameState.Outline)?
            if event.type == .mouseMoved, let target, let parent = event.window {
                let point = parent.convertPoint(toScreen: event.locationInWindow)
                if let hit = MacHitTest.hit(at: point, in: appWindows()), let rect = hit.frame {
                    // The same choice a click makes: the text, else the tooltip; Option puts the tooltip first.
                    let ordered = event.modifierFlags.contains(.option) ? [hit.tooltip, hit.text] : [hit.text, hit.tooltip]
                    let chosen = ordered.first { !runtime.keys(for: $0).isEmpty } ?? nil
                    let names = Array(Set(runtime.keys(for: chosen).map(\.key))).sorted()
                    if let first = names.first {
                        let frame = parent.frame
                        let local = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
                        let prefix = chosen != nil && chosen == hit.tooltip ? "Tooltip: " : ""
                        shown = (target.overlay, .init(rect: local, label: prefix + (names.count == 1 ? first : "\(names.count) keys")))
                    }
                }
            }
            for (_, held) in frames where held.overlay !== shown?.overlay {
                if held.overlay.state.outline != nil { held.overlay.state.outline = nil }
            }
            if let shown {
                if shown.overlay.state.outline != shown.outline { shown.overlay.state.outline = shown.outline }
                hovering = true
                NSCursor.pointingHand.set()
                // The app's own cursor rects run after this monitor; set it again once they have.
                DispatchQueue.main.async { if self.hovering { NSCursor.pointingHand.set() } }
            } else if hovering {
                hovering = false
                NSCursor.arrow.set()
            }
        }
    }

    extension EditingRuntime {
        static func openInBrowser(_ url: URL) { NSWorkspace.shared.open(url) }

        func installPlatform() {
            let support = MacSupport(runtime: self)
            platform = support
            support.installMenu()
        }

        func showPanel() { (platform as? MacSupport)?.showWindow() }

        func editModeChanged(_ on: Bool) { (platform as? MacSupport)?.setMonitoring(on) }

        func pickText(atScreenPoint x: Double, _ y: Double) {
            let hit = (platform as? MacSupport).flatMap { MacHitTest.hit(at: NSPoint(x: x, y: y), in: $0.appWindows()) }
            pick(text: hit?.text, tooltip: hit?.tooltip)
        }

        func snapshotPanel(to url: URL) -> Bool { (platform as? MacSupport)?.snapshot(to: url) ?? false }
    }
#endif
