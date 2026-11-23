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

        /// A tooltip being edited: Dialecto draws it under its control, with the typed text.
        struct Tip {
            /// The control, in the window's own space.
            var control: CGRect
            var model: EditorModel
        }

        var outline: Outline?
        /// The text whose editor is open, outlined while it is.
        var pinned: Outline?
        var tip: Tip?
        /// No badge: the window is small.
        var compact = false
        /// The dock's parts as drawn, in the window's own space: a click there is the dock's, not the app's.
        @ObservationIgnored var badgeRect: CGRect?
        @ObservationIgnored var goRect: CGRect?

        init(compact: Bool = false) { self.compact = compact }

        /// A screen rect (Cocoa, origin bottom left) in a window's own space (origin top left).
        static func local(_ rect: CGRect, in window: NSWindow) -> CGRect {
            let frame = window.frame
            return CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }

        /// The other way: a rect in a window's own space on the screen.
        static func screen(_ rect: CGRect, in window: NSWindow) -> CGRect {
            let frame = window.frame
            return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    /// A click-through window over an app window while Edit text is on: a sea frame, a badge and the hover
    /// outline. It is a child window, so it moves with its parent.
    final class EditFrameWindow: NSWindow {
        let state: EditFrameState

        /// A window too small for the badge (a popover, an alert) gets the frame alone.
        static func isCompact(_ parent: NSWindow) -> Bool { parent.frame.width < 300 || parent.frame.height < 160 }

        @MainActor
        init(over parent: NSWindow, session: DraftSession, panel: PanelModel) {
            state = EditFrameState(compact: Self.isCompact(parent))
            super.init(contentRect: parent.frame, styleMask: .borderless, backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            ignoresMouseEvents = true
            isReleasedWhenClosed = false
            collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            contentView = NSHostingView(rootView: EditFrameView(state: state, session: session, panel: panel))
            if let panel = parent as? NSPanel, panel.isFloatingPanel { level = parent.level }
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// The frame's drawing. The corner follows a titled macOS window's.
    struct EditFrameView: View {
        var state: EditFrameState
        var session: DraftSession
        var panel: PanelModel

        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Coastal.sea, lineWidth: 3)
                    if let pinned = state.pinned { outlineView(pinned, picked: true) }
                    if let outline = state.outline, outline.rect != state.pinned?.rect { outlineView(outline, picked: false) }
                    if let tip = state.tip { tipPreview(tip, width: proxy.size.width) }
                    if !state.compact {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                dock
                                Spacer()
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .coordinateSpace(name: Self.space)
            .ignoresSafeArea()
        }

        static let space = "dialecto-frame"

        /// The Editing text badge, which grows into the drafts count and Preview pull request.
        private var dock: some View {
            let count = session.isSignedIn ? session.draftCount : 0
            return HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: EditTextToggle.symbol)
                    Text("Editing text")
                    Text("esc")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.22)))
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .reportFrame { state.badgeRect = $0 }
                if count > 0 {
                    Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 16)
                    HStack(spacing: 6) {
                        Circle().fill(Coastal.gold).frame(width: 7, height: 7)
                        Text(count == 1 ? "1 draft" : "\(count) drafts").monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    if panel.step != .pullRequest {
                        Text("Preview pull request")
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(Capsule().fill(Coastal.buttonTerra))
                            .padding(3)
                            .reportFrame { state.goRect = $0 }
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(height: 30)
            .background(Capsule().fill(Coastal.buttonSea))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .onChange(of: count) { _, next in if next == 0 { state.goRect = nil } }
            .onChange(of: panel.step) { _, step in if step == .pullRequest { state.goRect = nil } }
        }

        /// The tooltip as it will read, under its control, while its editor is open.
        private func tipPreview(_ tip: EditFrameState.Tip, width: CGFloat) -> some View {
            let text = tip.model.liveText
            let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5)])
            let w = ceil(size.width) + 14
            let x = min(max(tip.control.midX - w / 2, 8), width - w - 8)
            return Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Coastal.tipInk)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Coastal.tipBackground))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Coastal.sea, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .offset(x: x, y: EditFrameView.tipTop(below: tip.control))
                .allowsHitTesting(false)
        }

        /// Under the control and its key's tab.
        static func tipTop(below control: CGRect) -> CGFloat { control.maxY + 3 + 19 + 9 }

        private func outlineView(_ outline: EditFrameState.Outline, picked: Bool) -> some View {
            let box = outline.rect.insetBy(dx: -4, dy: -3)
            let tabAbove = box.minY > 22
            return ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Coastal.sea.opacity(picked ? 0 : 0.10))
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
        private var keyMonitor: Any?
        /// The floating editor, while it is open.
        private(set) var editor: EditorController?
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

        /// SwiftUI builds the main menu after launch and rebuilds it whenever the app's commands change, either
        /// as a new menu or by clearing the old one, so the item is put back each time.
        func installMenu() {
            installKeys()
            ensureMenu()
            let center = NotificationCenter.default
            for name in [
                NSApplication.didFinishLaunchingNotification, NSApplication.didBecomeActiveNotification,
                NSApplication.didUpdateNotification,
            ] {
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

        /// An item can sit in one menu only, and adding it to a second one raises, so it leaves a replaced
        /// main menu before it joins the new one.
        private func ensureMenu() {
            guard let main = NSApp.mainMenu, item.menu !== main else { return }
            item.menu?.removeItem(item)
            main.addItem(item)
        }

        /// ⌃⌥⌘E, matched here as well as on the menu item, so Edit text works while the menu is being rebuilt.
        static func isEditShortcut(_ event: NSEvent) -> Bool {
            event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option, .control]
                && event.charactersIgnoringModifiers?.lowercased() == "e"
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
                    open: { [weak self] row, frame in self?.openRow(row, frame: frame) },
                    openInBrowser: { [weak runtime] row in runtime?.openEditor(key: row.key) },
                    openProject: { [weak runtime] in runtime?.openProject() },
                    showPullRequest: { [weak runtime] in runtime?.showPullRequest() },
                    openPreview: { [weak runtime] in runtime?.openPreview() },
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
            guard candidate.isVisible, candidate !== window, !(candidate is EditFrameWindow), !(candidate is EditorPanel),
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
                    if self.clickedDock(event, in: target) { return true }
                    // Cocoa screen space already (origin bottom left): do not flip it.
                    let point = target.convertPoint(toScreen: event.locationInWindow)
                    let hit = MacHitTest.hit(at: point, in: self.appWindows())
                    self.pick(hit, at: point, in: target, preferTooltip: event.modifierFlags.contains(.option))
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
        }

        /// Esc, ⌘S and ⌘↵ for the editor while it is open, and Esc to end Edit text. Installed once: the
        /// editor also opens from the Keys panel, with Edit text off.
        private func installKeys() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { () -> Bool in self?.key(event) ?? false }
                return consumed ? nil : event
            }
        }

        private func key(_ event: NSEvent) -> Bool {
            if Self.isEditShortcut(event) {
                toggleEdit()
                return true
            }
            let escape = event.keyCode == 53
            if let editor {
                guard event.window === editor.panel || runtime.editState.isOn else { return false }
                let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                if escape {
                    editor.model.escape()
                    return true
                }
                if case .choosing(let choices) = editor.model.phase, event.keyCode == 36 || event.keyCode == 76,
                    let first = choices.first
                {
                    let model = editor.model
                    Task { await model.choose(first) }
                    return true
                }
                if command, event.charactersIgnoringModifiers == "s" || event.keyCode == 36 || event.keyCode == 76 {
                    let model = editor.model
                    Task { await model.save() }
                    return true
                }
                return false
            }
            guard escape, runtime.editState.isOn else { return false }
            runtime.editState.isOn = false
            return true
        }

        // MARK: The floating editor

        /// A click on text in Edit text mode: the editor on its key, a choice of keys, or a note that the
        /// text has none. A click on nothing of Dialecto's closes an open editor, asking first.
        func pick(_ hit: MacHitTest.Hit?, at point: NSPoint, in window: NSWindow, preferTooltip: Bool = false) {
            let ordered = preferTooltip ? [hit?.tooltip, hit?.text] : [hit?.text, hit?.tooltip]
            guard let chosen = ordered.compactMap({ $0 }).first(where: { !runtime.keys(for: $0).isEmpty }) else {
                if let editor {
                    editor.model.requestClose()
                } else {
                    runtime.model.noKey(for: hit?.text)
                }
                return
            }
            runtime.model.clearNote()
            let found = runtime.keys(for: chosen)
            // A view with no visible text answers its tooltip as its text too: that is still the tooltip.
            let isTooltip = chosen == hit?.tooltip
            let anchor = hit?.frame ?? NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
            let open: () -> Void = { [weak self] in
                self?.presentEditor(
                    choices: EditingRuntime.choices(found), text: chosen, isTooltip: isTooltip, anchor: anchor,
                    parent: window, clickPoint: point)
            }
            if let editor {
                editor.model.requestClose(then: open)
            } else {
                open()
            }
        }

        /// A row picked in the Keys panel: the same editor, beside the row.
        func openRow(_ row: PanelRow, frame: CGRect) {
            guard let window, let content = window.contentView else { return }
            var local = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            if !content.isFlipped { local.origin.y = content.bounds.height - frame.maxY }
            let anchor = window.convertToScreen(content.convert(local, to: nil))
            let choice = EditorModel.KeyChoice(key: row.key, catalog: row.catalog, text: row.text)
            let open: () -> Void = { [weak self] in
                self?.presentEditor(
                    choices: [choice], text: row.text, isTooltip: false, anchor: anchor, parent: window, clickPoint: nil)
                self?.runtime.model.editingRowID = row.id
            }
            if let editor {
                editor.model.requestClose(then: open)
            } else {
                open()
            }
        }

        private func presentEditor(
            choices: [EditorModel.KeyChoice], text: String, isTooltip: Bool, anchor: NSRect, parent: NSWindow,
            clickPoint: NSPoint?
        ) {
            let started = CACurrentMediaTime()
            let model = EditorModel(
                choices: choices, shownText: text, isTooltip: isTooltip, session: runtime.session, layer: runtime.layer)
            let overlay = frames[ObjectIdentifier(parent)]?.overlay
            var anchor = anchor
            if let overlay, let key = choices.first?.key {
                let local = EditFrameState.local(anchor, in: parent)
                let label = Set(choices.map(\.key)).count > 1 ? "\(Set(choices.map(\.key)).count) keys" : key
                overlay.state.pinned = .init(rect: local, label: (isTooltip ? "Tooltip: " : "") + label)
                overlay.state.outline = nil
                if isTooltip {
                    overlay.state.tip = .init(control: local, model: model)
                    // The panel goes under the tooltip Dialecto draws.
                    let top = EditFrameView.tipTop(below: local)
                    let tip = CGRect(x: local.minX, y: top, width: local.width, height: 21)
                    anchor = anchor.union(EditFrameState.screen(tip, in: parent))
                }
            }
            let controller = EditorController(
                model: model, session: runtime.session, anchor: anchor, prefersBelow: isTooltip, parent: parent,
                openInDialecto: { [weak runtime] key in runtime?.openEditor(key: key) })
            model.onClose = { [weak self, weak controller] in
                guard let self, let controller, self.editor === controller else { return }
                self.closeEditor()
            }
            model.onTyped = { [weak self] in self?.followText(clickPoint: clickPoint, in: parent) }
            editor = controller
            controller.show()
            EditingRuntime.onEditorShown?((CACurrentMediaTime() - started) * 1000)
            Task { await model.load() }
        }

        func closeEditor() {
            guard let controller = editor else { return }
            editor = nil
            controller.dismiss()
            for (_, held) in frames {
                held.overlay.state.pinned = nil
                held.overlay.state.tip = nil
            }
            runtime.model.editingRowID = nil
        }

        /// The typed text redraws the app's text: the outline follows its new frame.
        private func followText(clickPoint: NSPoint?, in parent: NSWindow) {
            guard let clickPoint, let overlay = frames[ObjectIdentifier(parent)]?.overlay, overlay.state.pinned != nil
            else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let pinned = overlay.state.pinned, overlay.state.tip == nil,
                    let frame = MacHitTest.hit(at: clickPoint, in: self.appWindows())?.frame
                else { return }
                let local = EditFrameState.local(frame, in: parent)
                if local != pinned.rect { overlay.state.pinned?.rect = local }
            }
        }

        func dockButtonScreenRect() -> CGRect? {
            for (_, held) in frames {
                if let go = held.overlay.state.goRect { return EditFrameState.screen(go, in: held.parent) }
            }
            return nil
        }

        /// A click on the dock: Preview pull request, or the badge, which ends Edit text.
        private func clickedDock(_ event: NSEvent, in target: NSWindow) -> Bool {
            guard let state = frames[ObjectIdentifier(target)]?.overlay.state else { return false }
            let point = CGPoint(x: event.locationInWindow.x, y: target.frame.height - event.locationInWindow.y)
            if let go = state.goRect, go.contains(point) {
                runtime.showPullRequest()
                return true
            }
            if let badge = state.badgeRect, badge.contains(point) {
                runtime.editState.isOn = false
                return true
            }
            return false
        }

        private func attachFrame(to parent: NSWindow) {
            guard frames[ObjectIdentifier(parent)] == nil else { return }
            let overlay = EditFrameWindow(over: parent, session: runtime.session, panel: runtime.model)
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
            var overDock = false
            if event.type == .mouseMoved, let target, let parent = event.window {
                let local = CGPoint(x: event.locationInWindow.x, y: parent.frame.height - event.locationInWindow.y)
                overDock = [target.overlay.state.goRect, target.overlay.state.badgeRect].contains { $0?.contains(local) ?? false }
            }
            if event.type == .mouseMoved, !overDock, let target, let parent = event.window {
                let point = parent.convertPoint(toScreen: event.locationInWindow)
                if let hit = MacHitTest.hit(at: point, in: appWindows()), let rect = hit.frame {
                    // The same choice a click makes: the text, else the tooltip; Option puts the tooltip first.
                    let ordered = event.modifierFlags.contains(.option) ? [hit.tooltip, hit.text] : [hit.text, hit.tooltip]
                    let chosen = ordered.first { !runtime.keys(for: $0).isEmpty } ?? nil
                    let names = Array(Set(runtime.keys(for: chosen).map(\.key))).sorted()
                    if let first = names.first {
                        let local = EditFrameState.local(rect, in: parent)
                        let prefix = chosen != nil && chosen == hit.tooltip ? "Tooltip: " : ""
                        shown = (target.overlay, .init(rect: local, label: prefix + (names.count == 1 ? first : "\(names.count) keys")))
                        // Read the key's languages now, so a click opens the editor at once.
                        for name in names { runtime.session.prefetch(name) }
                    }
                }
            }
            for (_, held) in frames where held.overlay !== shown?.overlay {
                if held.overlay.state.outline != nil { held.overlay.state.outline = nil }
            }
            if overDock {
                hovering = true
                NSCursor.pointingHand.set()
                DispatchQueue.main.async { if self.hovering { NSCursor.pointingHand.set() } }
            } else if let shown {
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
            guard let support = platform as? MacSupport else { return }
            let point = NSPoint(x: x, y: y)
            let windows = support.appWindows()
            // The frontmost window under the point: a sheet before the window it sits on.
            guard
                let window = windows.filter({ $0.frame.contains(point) }).min(by: { $0.orderedIndex < $1.orderedIndex })
                    ?? windows.first
            else { return }
            support.pick(MacHitTest.hit(at: point, in: windows), at: point, in: window)
        }

        /// The floating editor's model while it is open, for a demo that drives it headless.
        var editorModel: EditorModel? { (platform as? MacSupport)?.editor?.model }

        var editorWindowNumber: Int? { (platform as? MacSupport)?.editor?.panel.windowNumber }

        func closeEditor() { (platform as? MacSupport)?.closeEditor() }

        /// Preview pull request's place on screen (Cocoa), when the dock shows it.
        func dockButtonScreenRect() -> CGRect? {
            guard let support = platform as? MacSupport else { return nil }
            return support.dockButtonScreenRect()
        }

        func snapshotPanel(to url: URL) -> Bool { (platform as? MacSupport)?.snapshot(to: url) ?? false }
    }
#endif
