#if DEBUG && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
    import SwiftUI

    /// The floating editor's window: borderless and non-activating, a child of the window whose text was
    /// clicked, so it moves with it and a sheet under it stays a sheet. It takes keys only to be typed in.
    final class EditorPanel: NSPanel {
        @MainActor
        init() {
            super.init(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            isReleasedWhenClosed = false
            becomesKeyOnlyIfNeeded = false
            hidesOnDeactivate = false
            animationBehavior = .none
            collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        }

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// Where the card goes beside the text: on the side with room, flipped to stay on screen. Cocoa screen
    /// space (origin bottom left).
    enum EditorPlacement {
        struct Result: Equatable {
            var card: CGRect
            /// The card's edge the arrow sits on.
            var side: EditorChrome.Side
            /// Along that edge, from its top or leading end.
            var offset: CGFloat
        }

        static let gap: CGFloat = 12
        static let inset: CGFloat = 6

        /// The first placement: left or right of the text, whichever has more room, then below and above
        /// (a tooltip's control tries below first). The arrow points at the text's middle, a third of the
        /// way down the card.
        static func place(card size: CGSize, anchor: CGRect, in visible: CGRect, prefersBelow: Bool) -> Result {
            let roomLeft = anchor.minX - visible.minX
            let roomRight = visible.maxX - anchor.maxX
            let horizontal: [EditorChrome.Side] = roomLeft >= roomRight ? [.right, .left] : [.left, .right]
            let vertical: [EditorChrome.Side] = [.top, .bottom]
            let order = prefersBelow ? vertical + horizontal : horizontal + vertical
            for side in order {
                let card = rect(side, size: size, anchor: anchor, visible: visible)
                if fits(card, side: side, in: visible) { return result(card, side: side, anchor: anchor) }
            }
            let side = order[0]
            return result(clamp(rect(side, size: size, anchor: anchor, visible: visible), in: visible), side: side, anchor: anchor)
        }

        /// A later size (a language opened, an error shown): the top stays put, the card stays on screen.
        static func resize(_ previous: Result, to size: CGSize, anchor: CGRect, in visible: CGRect) -> Result {
            var card = CGRect(x: previous.card.minX, y: previous.card.maxY - size.height, width: size.width, height: size.height)
            card = clamp(card, in: visible)
            return result(card, side: previous.side, anchor: anchor)
        }

        private static func rect(_ side: EditorChrome.Side, size: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
            switch side {
            case .right, .left:
                // The card is left of the text when its arrow is on its right.
                let x = side == .right ? anchor.minX - gap - size.width : anchor.maxX + gap
                let top = anchor.midY + min(size.height * 0.35, 110)
                return clampVertically(CGRect(x: x, y: top - size.height, width: size.width, height: size.height), in: visible)
            case .top, .bottom:
                // The card is below the text when its arrow is on its top.
                let y = side == .top ? anchor.minY - gap - size.height : anchor.maxY + gap
                let x = min(max(anchor.midX - size.width / 2, visible.minX + inset), visible.maxX - inset - size.width)
                return CGRect(x: x, y: y, width: size.width, height: size.height)
            }
        }

        private static func fits(_ card: CGRect, side: EditorChrome.Side, in visible: CGRect) -> Bool {
            visible.insetBy(dx: inset, dy: inset).contains(card)
        }

        private static func clampVertically(_ card: CGRect, in visible: CGRect) -> CGRect {
            var card = card
            if card.maxY > visible.maxY - inset { card.origin.y = visible.maxY - inset - card.height }
            if card.minY < visible.minY + inset { card.origin.y = visible.minY + inset }
            return card
        }

        private static func clamp(_ card: CGRect, in visible: CGRect) -> CGRect {
            var card = clampVertically(card, in: visible)
            if card.maxX > visible.maxX - inset { card.origin.x = visible.maxX - inset - card.width }
            if card.minX < visible.minX + inset { card.origin.x = visible.minX + inset }
            return card
        }

        private static func result(_ card: CGRect, side: EditorChrome.Side, anchor: CGRect) -> Result {
            let offset: CGFloat
            switch side {
            case .left, .right: offset = min(max(card.maxY - anchor.midY, 18), card.height - 18)
            case .top, .bottom: offset = min(max(anchor.midX - card.minX, 18), card.width - 18)
            }
            return Result(card: card, side: side, offset: offset)
        }
    }

    /// One open floating editor: its window, its model and where it points.
    @MainActor
    final class EditorController {
        let model: EditorModel
        let panel = EditorPanel()
        private let chrome = EditorChrome()
        private let hosting: NSHostingView<FloatingEditorView>
        private weak var parent: NSWindow?
        private let anchor: CGRect
        private let prefersBelow: Bool
        private var placement: EditorPlacement.Result?

        init(
            model: EditorModel, session: DraftSession, anchor: CGRect, prefersBelow: Bool, parent: NSWindow,
            openInDialecto: @escaping (String) -> Void
        ) {
            self.model = model
            self.anchor = anchor
            self.prefersBelow = prefersBelow
            self.parent = parent
            hosting = NSHostingView(
                rootView: FloatingEditorView(model: model, session: session, chrome: chrome, openInDialecto: openInDialecto))
            hosting.sizingOptions = []
            panel.contentView = hosting
            chrome.onSize = { [weak self] size in self?.layout(size) }
        }

        /// Opens at its final size: the cached entries are in place before the first frame is drawn.
        func show() {
            model.start()
            let fitting = hosting.fittingSize
            let margin = FloatingEditorView.margin
            layout(CGSize(width: fitting.width - margin * 2, height: fitting.height - margin * 2))
            parent?.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            panel.displayIfNeeded()
            DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
        }

        private func layout(_ card: CGSize) {
            guard card.width > 0, card.height > 0 else { return }
            if let placement, placement.card.size == card { return }
            let visible = (parent?.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
            let next =
                placement.map { EditorPlacement.resize($0, to: card, anchor: anchor, in: visible) }
                ?? EditorPlacement.place(card: card, anchor: anchor, in: visible, prefersBelow: prefersBelow)
            placement = next
            if chrome.side != next.side { chrome.side = next.side }
            if chrome.offset != next.offset { chrome.offset = next.offset }
            let margin = FloatingEditorView.margin
            panel.setFrame(next.card.insetBy(dx: -margin, dy: -margin), display: true)
            panel.invalidateShadow()
        }

        func dismiss() {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            // The window the text was in takes the keys back, a sheet included.
            if let parent, parent.isVisible, parent.canBecomeKey { parent.makeKey() }
        }
    }

    extension View {
        /// Reports the view's frame in the Edit text frame's space, where the click monitor reads it.
        func reportFrame(_ report: @escaping (CGRect) -> Void) -> some View {
            background(
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(EditFrameView.space))
                    Color.clear
                        .onAppear { report(frame) }
                        .onChange(of: frame) { _, next in report(next) }
                })
        }
    }
#endif
