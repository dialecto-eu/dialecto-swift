#if DEBUG && canImport(SwiftUI)
    #if canImport(AppKit)
        import AppKit
    #endif
    import Observation
    import SwiftUI

    /// Where the panel's arrow points from: the panel's edge that faces the text, and how far along it.
    @MainActor
    @Observable
    final class EditorChrome {
        enum Side { case left, right, top, bottom }
        var side: Side?
        /// From the leading or top end of that edge, in points.
        var offset: CGFloat = 0
        /// The card's size as SwiftUI laid it out, for the window that holds it.
        @ObservationIgnored var onSize: ((CGSize) -> Void)?
    }

    /// The floating editor: a 340-point Coastal card beside the clicked text. The key and its links, the
    /// source and the shown language in fields, the rest folded, then Cancel and Save draft.
    struct FloatingEditorView: View {
        var model: EditorModel
        var session: DraftSession
        var chrome: EditorChrome
        var openInDialecto: (String) -> Void
        @State private var hoveredChoice: String?

        static let margin: CGFloat = 9

        var body: some View {
            card
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { chrome.onSize?(proxy.size) }
                            .onChange(of: proxy.size) { _, size in chrome.onSize?(size) }
                    }
                )
                .overlay(alignment: .topLeading) { arrow }
                .padding(Self.margin)
                .tint(Coastal.sea)
                .onChange(of: session.isSignedIn) { _, signedIn in
                    if signedIn { Task { await model.load() } }
                }
        }

        private var width: CGFloat {
            if case .choosing = model.phase { return 300 }
            return 340
        }

        private var card: some View {
            VStack(spacing: 0) {
                head
                SeamLine()
                content
            }
            .background(Coastal.cream)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Coastal.edge))
        }

        // MARK: Arrow

        @ViewBuilder private var arrow: some View {
            if let side = chrome.side {
                GeometryReader { proxy in
                    let size: CGFloat = 13
                    let fill = side == .top ? Coastal.paper : side == .bottom ? Coastal.cream2 : Coastal.cream
                    Rectangle()
                        .fill(fill)
                        .overlay(ArrowTip(side: side).stroke(Coastal.edge, lineWidth: 1))
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(45))
                        .position(arrowCenter(side, in: proxy.size, inset: size / 2 - 0.5))
                }
                .allowsHitTesting(false)
            }
        }

        private func arrowCenter(_ side: EditorChrome.Side, in size: CGSize, inset: CGFloat) -> CGPoint {
            switch side {
            case .right: CGPoint(x: size.width - 0.5, y: chrome.offset)
            case .left: CGPoint(x: 0.5, y: chrome.offset)
            case .top: CGPoint(x: chrome.offset, y: 0.5)
            case .bottom: CGPoint(x: chrome.offset, y: size.height - 0.5)
            }
        }

        // MARK: Head

        private var head: some View {
            HStack(spacing: 7) {
                FlorMark(size: 16)
                if case .choosing(let choices) = model.phase {
                    Text("\(choices.count) keys").font(.system(size: 13, weight: .semibold)).foregroundStyle(Coastal.ink)
                } else {
                    Text(model.key)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Coastal.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if model.isTooltip {
                        TagView(text: "Tooltip", foreground: Coastal.sea, background: Coastal.infoBackground)
                    }
                }
                Spacer(minLength: 6)
                if !isChoosing {
                    IconButton(symbol: "arrow.up.forward.square", label: "Open in Dialecto") { openInDialecto(model.key) }
                }
                IconButton(symbol: "xmark", label: "Close") { model.requestClose() }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 38)
            .background(Coastal.paper)
        }

        private var isChoosing: Bool {
            if case .choosing = model.phase { return true }
            return false
        }

        // MARK: Content

        @ViewBuilder private var content: some View {
            switch model.phase {
            case .choosing(let choices):
                VStack(spacing: 6) {
                    // The row under the pointer is lit; with none, the first, which Return picks.
                    ForEach(choices) { choice in
                        ChoiceRow(
                            choice: choice, lit: (hoveredChoice ?? choices.first?.id) == choice.id,
                            hover: { hoveredChoice = $0 ? choice.id : (hoveredChoice == choice.id ? nil : hoveredChoice) }
                        ) { Task { await model.choose(choice) } }
                    }
                }
                .padding(12)
            case .signedOut:
                signedOut
            case .loading:
                VStack(alignment: .leading, spacing: 10) {
                    quote
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading").font(.system(size: 12.5)).foregroundStyle(Coastal.mut)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .missing:
                note(icon: "questionmark.circle", "No key \u{201C}\(model.key)\u{201D} in the catalog")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    quote
                    lineBanner(icon: "wifi.exclamationmark", message, action: "Retry") { Task { await model.retry() } }
                }
                .padding(12)
            case .editing:
                editing
            }
        }

        private var quote: some View {
            Text(model.shownText)
                .font(.system(size: 13))
                .foregroundStyle(Coastal.ink2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func note(icon: String, _ text: String) -> some View {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Coastal.mut)
                Text(text).font(.system(size: 12.5)).foregroundStyle(Coastal.ink2)
                Spacer(minLength: 0)
            }
            .padding(12)
        }

        @ViewBuilder private var signedOut: some View {
            VStack(alignment: .leading, spacing: 10) {
                quote
                switch session.state {
                case .signedOut, .signedIn:
                    HStack(spacing: 10) {
                        Text("Sign in to Dialecto to edit this text here.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Coastal.ink)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Sign in") { session.signIn() }
                            .buttonStyle(SolidButtonStyle(fill: Coastal.buttonTerra))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Coastal.infoBackground))
                default:
                    SignInCard(session: session)
                }
            }
            .padding(12)
        }

        // MARK: Editing

        private var editing: some View {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.primary.enumerated()), id: \.element.id) { index, field in
                        // The language the app shows takes the caret: the source when it shows that.
                        FieldEditor(model: model, field: field, focusFirst: index == model.primary.count - 1)
                            .padding(.top, index == 0 ? 0 : 12)
                    }
                    if !model.others.isEmpty { others }
                    if let banner = model.banner { bannerView(banner).padding(.top, 10) }
                }
                .padding(12)
                foot
            }
        }

        private var others: some View {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Coastal.edgeSoft).frame(height: 1).padding(.top, 12)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.othersOpen.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: model.othersOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Coastal.mut)
                            .frame(width: 10)
                        Text("Other languages").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Coastal.ink)
                        Text("\(model.others.count)").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Coastal.mut)
                        Spacer(minLength: 6)
                        if model.outdatesOthers {
                            TagView(text: "Outdated after save", foreground: Coastal.warnText, background: Coastal.warnBackground)
                        }
                    }
                    .padding(.top, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if model.othersOpen {
                    VStack(spacing: 0) {
                        ForEach(Array(model.others.enumerated()), id: \.element.id) { index, field in
                            OtherLanguageRow(field: field, last: index == model.others.count - 1) {
                                model.open(field.locale)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }

        @ViewBuilder private func bannerView(_ banner: EditorModel.Banner) -> some View {
            switch banner {
            case .needsEditScope:
                lineBanner(icon: "person.crop.circle.badge.exclamationmark", "Sign in again to save here", action: "Sign in") {
                    model.signInAgain()
                }
            case .pendingByOther:
                lineBanner(icon: "person.2", "Someone else has a draft here", action: "Open") { openInDialecto(model.key) }
            case .rateLimited:
                lineBanner(icon: "hourglass", "Wait a moment, then save again", action: nil) {}
            case .offline:
                lineBanner(icon: "wifi.exclamationmark", "Dialecto unreachable", action: "Retry") {
                    Task { await model.retrySave() }
                }
            }
        }

        private func lineBanner(icon: String, _ text: String, action: String?, run: @escaping () -> Void) -> some View {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Coastal.terraText)
                Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Coastal.ink).lineLimit(1)
                Spacer(minLength: 6)
                if let action {
                    Button(action, action: run).buttonStyle(OutlineButtonStyle())
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Coastal.gapBackground))
        }

        @ViewBuilder private var foot: some View {
            HStack(spacing: 8) {
                if model.confirmingDiscard {
                    Text("Unsaved text").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Coastal.ink)
                    Spacer(minLength: 6)
                    Button {
                        model.keepEditing()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Keep editing")
                            KeyHint("esc")
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button("Discard") { model.discard() }
                        .buttonStyle(SolidButtonStyle(fill: Coastal.buttonTerra))
                } else {
                    Spacer(minLength: 6)
                    Button {
                        model.requestClose()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Cancel")
                            KeyHint("esc")
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button {
                        Task { await model.save() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.saving { ProgressView().controlSize(.mini).tint(.white) }
                            Text("Save draft")
                            KeyHint("\u{2318}\u{21A9}", solid: true)
                        }
                    }
                    .buttonStyle(SolidButtonStyle(fill: Coastal.buttonTerra))
                    .disabled(model.readOnly || model.saving)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Coastal.cream2)
            .overlay(alignment: .top) { Rectangle().fill(Coastal.edge).frame(height: 1) }
        }
    }

    /// One language open for typing: its name, code and tags, the field, and what Dialecto said.
    struct FieldEditor: View {
        var model: EditorModel
        var field: EditorModel.Field
        var focusFirst: Bool
        @FocusState private var focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(EditorWords.name(field.locale)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Coastal.ink2)
                    Text(field.locale).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Coastal.mut)
                    if field.isSource {
                        TagView(text: "Source", foreground: Coastal.sea, background: Coastal.infoBackground)
                    } else if field.outdated {
                        TagView(text: "Outdated", foreground: Coastal.warnText, background: Coastal.warnBackground)
                    }
                    if field.hasDraft && !field.isDirty {
                        TagView(text: "Draft", foreground: Coastal.warnText, background: Coastal.warnBackground)
                    }
                    Spacer(minLength: 0)
                }
                if field.editable {
                    input
                } else {
                    Text(field.text.isEmpty ? "\u{2014}" : field.text)
                        .font(.system(size: 13))
                        .foregroundStyle(Coastal.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Coastal.cream2))
                    Text(notEditable).font(.system(size: 11.5)).foregroundStyle(Coastal.mut)
                }
                if let error = field.error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Coastal.terraText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let current = field.conflict { conflict(current) }
            }
        }

        private var notEditable: String {
            switch field.reason {
            case "plural": "Plural text is edited in Dialecto"
            case "variation": "Device variations are edited in Dialecto"
            case "not_translatable": "Not translatable"
            case "no_permission": "No edit access to this language"
            default: "Read-only here"
            }
        }

        private var input: some View {
            TextField(
                "", text: Binding(get: { field.text }, set: { model.type($0, in: field.locale) }), axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Coastal.ink)
            .lineSpacing(3)
            .lineLimit(3...10)
            .focused($focused)
            .disabled(model.readOnly)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(minHeight: 64, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Coastal.paper))
            .overlay(
                RoundedRectangle(cornerRadius: 7).strokeBorder(
                    field.error != nil ? Coastal.terra : focused ? Coastal.sky : Coastal.edge, lineWidth: 1)
            )
            .background(
                RoundedRectangle(cornerRadius: 9.5)
                    .stroke(Coastal.sky.opacity(focused ? 0.28 : 0), lineWidth: 3)
                    .padding(-1.5)
            )
            .onAppear {
                if focusFirst { focused = true }
            }
            .onChange(of: focused) { _, now in
                #if canImport(AppKit) && !targetEnvironment(macCatalyst)
                    // A field that takes focus selects all of its text; the caret goes to the end, so typing adds.
                    guard now else { return }
                    DispatchQueue.main.async {
                        let panel = NSApp.windows.first { $0 is EditorPanel && $0.isVisible }
                        guard let editor = panel?.firstResponder as? NSTextView else { return }
                        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    }
                #endif
            }
        }

        private func conflict(_ current: String) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Changed in Dialecto").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Coastal.warnText)
                Text(current.isEmpty ? "\u{2014}" : current)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Coastal.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Use theirs") { model.useTheirs(field.locale) }.buttonStyle(OutlineButtonStyle())
                    Button("Keep mine") { Task { await model.keepMine(field.locale) } }
                        .buttonStyle(SolidButtonStyle(fill: Coastal.buttonSea))
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Coastal.warnBackground))
        }
    }

    /// A folded language: its code and its text on two lines at most. A click opens it for typing.
    struct OtherLanguageRow: View {
        var field: EditorModel.Field
        var last: Bool
        var open: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(field.locale)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Coastal.mut)
                        .frame(width: 26, alignment: .leading)
                    Text(field.text.isEmpty ? "\u{2014}" : field.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(hovering ? Coastal.ink : Coastal.ink2)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(Coastal.edgeSoft).frame(height: 1) }
            }
            .help("Edit \(EditorWords.name(field.locale))")
        }
    }

    /// One key of a text that has several.
    struct ChoiceRow: View {
        var choice: EditorModel.KeyChoice
        var lit: Bool
        var hover: (Bool) -> Void
        var pick: () -> Void
        private var hovering: Bool { lit }

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.key)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Coastal.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(choice.text).font(.system(size: 12)).foregroundStyle(Coastal.ink2).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Coastal.mut)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Coastal.infoBackground : Coastal.paper))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovering ? Coastal.sea : Coastal.edge))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover(perform: hover)
        }
    }

    /// A small square icon button in the panel's head.
    struct IconButton: View {
        var symbol: String
        var label: String
        var run: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: run) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Coastal.mut)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Coastal.cream2 : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(label)
            .accessibilityLabel(Text(label))
        }
    }

    /// A key's shortcut beside a button's title.
    struct KeyHint: View {
        var text: String
        var solid = false

        init(_ text: String, solid: Bool = false) {
            self.text = text
            self.solid = solid
        }

        var body: some View {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(solid ? Color.white : Coastal.mut)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(solid ? Color.white.opacity(0.2) : Coastal.cream2))
        }
    }

    /// A quiet button: ink2 text on nothing, at the solid button's height.
    struct GhostButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Coastal.ink2)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isPressed ? Coastal.edgeSoft : .clear))
                .contentShape(Rectangle())
        }
    }

    /// Half of a square, so a rotated square reads as an arrow with only its outer edges stroked.
    struct ArrowTip: Shape {
        var side: EditorChrome.Side

        func path(in rect: CGRect) -> Path {
            // Rotated 45°, the square's top and right edges face up-right. Pick the two edges that end up
            // outside the card for each side.
            var path = Path()
            let tl = CGPoint(x: rect.minX, y: rect.minY)
            let tr = CGPoint(x: rect.maxX, y: rect.minY)
            let br = CGPoint(x: rect.maxX, y: rect.maxY)
            let bl = CGPoint(x: rect.minX, y: rect.maxY)
            let points: [CGPoint] =
                switch side {
                case .right: [tl, tr, br]
                case .left: [br, bl, tl]
                case .top: [bl, tl, tr]
                case .bottom: [tr, br, bl]
                }
            path.move(to: points[0])
            path.addLine(to: points[1])
            path.addLine(to: points[2])
            return path
        }
    }
#endif
