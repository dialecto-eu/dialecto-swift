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
        }

        @MainActor
        static func text(at point: NSPoint) -> String? { hit(at: point)?.text }

        @MainActor
        static func hit(at point: NSPoint) -> Hit? {
            if let hit = read(at: point) { return hit }
            // The hit can land on the hosting view itself: look through the window's nodes for the smallest
            // one with text whose frame holds the point.
            var best: (area: Double, hit: Hit)?
            for window in NSApp.windows where window.isVisible && window.frame.contains(point) && !(window is EditFrameWindow) {
                search(window as AnyObject, point: point, depth: 0, best: &best)
            }
            return best?.hit
        }

        private static func search(_ node: AnyObject, point: NSPoint, depth: Int, best: inout (area: Double, hit: Hit)?) {
            guard depth < 12 else { return }
            if depth > 0, let rect = frame(of: node), rect.contains(point),
                let text = ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"].lazy
                    .compactMap({ string(node, $0) }).first(where: { !$0.isEmpty }),
                string(node, "accessibilityRole") != "AXWindow"
            {
                let area = Double(rect.width * rect.height)
                if best == nil || area < best!.area { best = (area, Hit(text: text, frame: rect)) }
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
            while let current = node, up < 6 {
                if let role = string(current, "accessibilityRole"), role == "AXWindow" || role == "AXApplication" {
                    return nil
                }
                for selector in ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"] {
                    if let text = string(current, selector), !text.isEmpty { return Hit(text: text, frame: frame(of: current)) }
                }
                node = object(current, "accessibilityParent")
                up += 1
            }
            return nil
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
    }

    /// A click-through window over an app window while Edit text is on: a sea frame, a badge and the hover
    /// outline. It is a child window, so it moves with its parent.
    final class EditFrameWindow: NSWindow {
        let state: EditFrameState

        @MainActor
        init(over parent: NSWindow) {
            state = EditFrameState()
            super.init(contentRect: parent.frame, styleMask: .borderless, backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            ignoresMouseEvents = true
            isReleasedWhenClosed = false
            collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            contentView = NSHostingView(rootView: EditFrameView(state: state))
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

        private func appWindows() -> [NSWindow] {
            NSApp.windows.filter { candidate in
                candidate.isVisible && candidate !== window && !(candidate is EditFrameWindow) && !(candidate is NSPanel)
                    && candidate.canBecomeMain && candidate.frame.width > 60
            }
        }

        func setMonitoring(_ on: Bool) {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors = []
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            for (_, held) in frames {
                held.parent.removeChildWindow(held.overlay)
                held.overlay.orderOut(nil)
                held.parent.acceptsMouseMovedEvents = held.movedEvents
            }
            frames = [:]
            if hovering {
                NSCursor.arrow.set()
                hovering = false
            }
            guard on else { return }

            for parent in appWindows() { attachFrame(to: parent) }
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                        nonisolated(unsafe) let note = note
                        MainActor.assumeIsolated { self?.windowChanged(note.object as? NSWindow) }
                    })
            }

            if let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let target = event.window, self.isAppWindow(target) else { return false }
                    // Cocoa screen space already (origin bottom left): do not flip it.
                    self.runtime.pick(text: MacHitTest.text(at: target.convertPoint(toScreen: event.locationInWindow)))
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

        private func isAppWindow(_ candidate: NSWindow) -> Bool {
            frames[ObjectIdentifier(candidate)] != nil || appWindows().contains { $0 === candidate }
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
            } else if appWindows().contains(where: { $0 === changed }) {
                attachFrame(to: changed)
            }
        }

        /// Outlines the text under the pointer when it is a key Dialecto knows, and shows the pointing hand.
        private func hover(_ event: NSEvent) {
            let target = event.window.flatMap { frames[ObjectIdentifier($0)] }
            var shown: (overlay: EditFrameWindow, outline: EditFrameState.Outline)?
            if event.type == .mouseMoved, let target, let parent = event.window {
                let point = parent.convertPoint(toScreen: event.locationInWindow)
                if let hit = MacHitTest.hit(at: point), let rect = hit.frame {
                    let keys = runtime.keys(for: hit.text)
                    let names = Array(Set(keys.map(\.key))).sorted()
                    if let first = names.first {
                        let frame = parent.frame
                        let local = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
                        shown = (target.overlay, .init(rect: local, label: names.count == 1 ? first : "\(names.count) keys"))
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
            pick(text: MacHitTest.text(at: NSPoint(x: x, y: y)))
        }

        func snapshotPanel(to url: URL) -> Bool { (platform as? MacSupport)?.snapshot(to: url) ?? false }
    }
#endif
