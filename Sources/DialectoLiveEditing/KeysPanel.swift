#if DEBUG && canImport(SwiftUI)
    import DialectoLive
    import Foundation
    import Observation
    import SwiftUI
    import os

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// One line of the panel: a key the app showed, or a draft that is not on screen.
    struct PanelRow: Identifiable, Equatable {
        var id: String
        var key: String
        var text: String
        var catalog: String
        var locale: String
        var source: LookupSource?
        /// Why a typed draft is not shown, in words; nil for a row that is.
        var notShown: String?
    }

    /// The words for a reason the server or the app's guard gave.
    func notShownReason(_ code: String) -> String {
        switch code {
        case "plural": "plural"
        case "variation": "device variation"
        case "not_translatable": "not translatable"
        case "empty": "empty"
        case "placeholders": "placeholders differ"
        case "check": "check failed"
        default: code.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Whether two catalog names are one catalog. The release names a catalog in a folder by its path
    /// (`App/Localizable.xcstrings` is `app-localizable`), while a bundle lookup knows only its table
    /// (`localizable`), so a name matches another that ends in `-` and it, as `LiveSnapshot.lookup` does.
    func sameCatalog(_ a: String, _ b: String) -> Bool {
        a == b || a.hasSuffix("-" + b) || b.hasSuffix("-" + a)
    }

    /// What the panel lists and filters. The log is written from any thread, so rows are rebuilt on the
    /// main actor, a moment after the last lookup.
    @MainActor
    @Observable
    final class PanelModel {
        private(set) var rows: [PanelRow] = []
        /// More than one catalog among the rows: each row then names its own.
        private(set) var severalCatalogs = false
        var filter = ""
        /// Row ids a click on text matched, when the panel was opened by one.
        private(set) var matched: Set<String>?
        private(set) var matchedText: String?
        /// The text of the last click that found no key.
        private(set) var noKeyText: String?
        /// A line the panel shows until it is dismissed: a key the catalog lacks, a sign-in needed.
        private(set) var notice: String?

        private let log: LookupLog
        private let layer: DraftLayer
        @ObservationIgnored private let dirty = OSAllocatedUnfairLock(initialState: false)

        init(log: LookupLog, layer: DraftLayer) {
            self.log = log
            self.layer = layer
        }

        /// Called from any thread after a lookup or a draft change; one rebuild follows a burst of them.
        nonisolated func changed() {
            let first = dirty.withLock { dirty -> Bool in
                defer { dirty = true }
                return !dirty
            }
            guard first else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                self.refresh()
            }
        }

        /// One row per key and catalog: the app shows one text per key at a time, so the newest lookup
        /// stands for it, whichever layer answered and in whichever language. A draft or skip the app
        /// cannot show joins the row of its key when it is in the app's language, and has its own row
        /// otherwise.
        func refresh() {
            dirty.withLock { $0 = false }
            var rows: [PanelRow] = []
            var index: [String: [Int]] = [:]
            for entry in log.entries() {
                if let at = index[entry.key, default: []].first(where: { sameCatalog(rows[$0].catalog, entry.catalog) }) {
                    // Keep the newest text; name the catalog as the release does (the longer, path name).
                    if entry.catalog.count > rows[at].catalog.count { rows[at].catalog = entry.catalog }
                    continue
                }
                index[entry.key, default: []].append(rows.count)
                rows.append(
                    PanelRow(
                        id: "\(entry.key)\u{0}\(entry.catalog)", key: entry.key, text: entry.text,
                        catalog: entry.catalog, locale: entry.locale, source: entry.source, notShown: nil))
            }
            let language = layer.currentLanguage
            var extra: [PanelRow] = []
            for item in layer.notShown {
                let inAppLanguage = language.map { LocaleMatching.chain(for: $0, available: [item.locale]).contains(item.locale) } ?? false
                let at = index[item.key, default: []].first { at in
                    sameCatalog(rows[at].catalog, item.catalog) && (rows[at].locale == item.locale || inAppLanguage)
                }
                if let at {
                    if rows[at].notShown == nil { rows[at].notShown = notShownReason(item.reason) }
                    continue
                }
                let id = "\(item.key)\u{0}\(item.catalog)\u{0}\(item.locale)"
                if extra.contains(where: { $0.id == id }) { continue }
                extra.append(
                    PanelRow(
                        id: id, key: item.key, text: "", catalog: item.catalog, locale: item.locale, source: nil,
                        notShown: notShownReason(item.reason)))
            }
            rows.insert(contentsOf: extra, at: 0)
            var families: [String] = []
            for row in rows where !families.contains(where: { sameCatalog($0, row.catalog) }) { families.append(row.catalog) }
            let several = families.count > 1
            if several != severalCatalogs { severalCatalogs = several }
            if rows != self.rows { self.rows = rows }
        }

        /// Opens the list on what a click on `text` matched.
        func show(matches: [LookupEntry], for text: String) {
            refresh()
            let keys = Set(matches.map(\.key))
            matched = Set(rows.filter { row in keys.contains(row.key) && matches.contains { sameCatalog($0.catalog, row.catalog) } }.map(\.id))
            matchedText = text
            noKeyText = nil
            filter = ""
        }

        /// A click on text that is not Dialecto's: a short note, nothing else.
        func noKey(for text: String?) {
            let text = text.map(ReverseLookup.normalize) ?? ""
            noKeyText = text.count > 40 ? String(text.prefix(39)) + "\u{2026}" : text
            notice = nil
        }

        func clearMatches() {
            matched = nil
            matchedText = nil
        }

        func notify(_ text: String) { notice = text }

        func clearNote() {
            noKeyText = nil
            notice = nil
        }

        var visible: [PanelRow] {
            var rows = rows
            if let matched { rows = rows.filter { matched.contains($0.id) } }
            let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
            if !needle.isEmpty {
                rows = rows.filter {
                    $0.key.lowercased().contains(needle) || $0.text.lowercased().contains(needle)
                }
            }
            return rows
        }
    }

    /// Whether the next click or tap picks text for the editor.
    @MainActor
    @Observable
    final class EditModeState {
        var isOn = false {
            didSet { if oldValue != isOn { onChange?(isOn) } }
        }
        @ObservationIgnored var onChange: ((Bool) -> Void)?
    }

    /// The window (Mac) or sheet (iOS) of keys: Dialecto's header, the sign-in when signed out, Edit text
    /// and the filter, then one row per key the app showed.
    struct KeysPanel: View {
        var model: PanelModel
        var session: DraftSession
        var editMode: EditModeState
        var open: (PanelRow) -> Void
        var openProject: () -> Void
        var close: (() -> Void)?

        var body: some View {
            VStack(spacing: 0) {
                header
                SeamLine()
                VStack(alignment: .leading, spacing: 10) {
                    if !session.isSignedIn { SignInCard(session: session) }
                    toolbar
                    if let text = model.matchedText { matchesBanner(text) }
                    if let text = model.noKeyText { noteRow(text.isEmpty ? "No text there" : "No key for \u{201C}\(text)\u{201D}") }
                    if let text = model.notice { noteRow(text) }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
                Rectangle().fill(Coastal.edge).frame(height: 1)
                list
            }
            .background(Coastal.cream)
            .tint(Coastal.sea)
            .animation(.easeOut(duration: 0.15), value: session.state)
            #if os(macOS)
                .frame(minWidth: 380, minHeight: 420)
            #endif
        }

        // MARK: Header

        private var header: some View {
            HStack(spacing: 8) {
                FlorMark(size: 22)
                #if os(macOS)
                    Wordmark(size: 18)
                    project.padding(.leading, 4)
                #else
                    // A phone is too narrow for one line: the project sits under the wordmark.
                    VStack(alignment: .leading, spacing: 1) {
                        Wordmark(size: 17)
                        project
                    }
                #endif
                Spacer(minLength: 8)
                if session.isSignedIn {
                    statusChip
                    Menu {
                        Button("Open in Dialecto", action: openProject)
                        Divider()
                        Button("Sign out") { session.signOut() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(Coastal.sea)
                            .accessibilityLabel(Text(verbatim: "Account"))
                    }
                    .menuIndicatorHiddenIfAvailable()
                    .fixedSize()
                }
                if let close {
                    Button("Done", action: close).fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 14)
            #if os(macOS)
                .frame(height: 46)
            #else
                .padding(.top, 14)
                .frame(height: 64)
            #endif
            .background(Coastal.paper)
        }

        private var project: some View {
            Text(session.project)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Coastal.mut)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }

        private var statusChip: some View {
            let offline = session.offline
            let count = session.draftCount
            return HStack(spacing: 5) {
                // Drafts are gold, as each row's Draft tag is; offline is terra, a gap.
                Circle().fill(offline ? Coastal.terra : Coastal.gold).frame(width: 6, height: 6)
                Text(offline ? "Offline" : count == 1 ? "1 draft" : "\(count) drafts")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(offline ? Coastal.terraText : Coastal.warnText)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(offline ? Coastal.gapBackground : Coastal.warnBackground))
        }

        // MARK: Edit text and filter

        private var toolbar: some View {
            HStack(spacing: 8) {
                EditTextToggle(editMode: editMode)
                FilterField(text: Bindable(model).filter)
            }
        }

        private func matchesBanner(_ text: String) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(Coastal.sea)
                Text("Matches for \u{201C}\(text)\u{201D}").lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Show all") { model.clearMatches() }.buttonStyle(.borderless)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Coastal.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Coastal.infoBackground))
        }

        private func noteRow(_ text: String) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(Coastal.mut)
                Text(text).lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    model.clearNote()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .accessibilityLabel(Text(verbatim: "Dismiss"))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Coastal.mut)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Coastal.ink2)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Coastal.cream2))
            .accessibilityElement(children: .combine)
        }

        // MARK: Keys

        private var list: some View {
            let rows = model.visible
            return List {
                ForEach(rows) { row in
                    KeyRowView(row: row, showCatalog: model.severalCatalogs) { open(row) }
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .overlay {
                if rows.isEmpty { emptyState }
            }
        }

        @ViewBuilder private var emptyState: some View {
            if model.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble").font(.system(size: 24, weight: .light)).foregroundStyle(Coastal.mut)
                    Text("No strings yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(Coastal.ink2)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .light)).foregroundStyle(Coastal.mut)
                    Text("No matches").font(.system(size: 14, weight: .semibold)).foregroundStyle(Coastal.ink2)
                    Button("Clear filter") {
                        model.filter = ""
                        model.clearMatches()
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
        }
    }

    /// The sign-in, while signed out: the button, the code to type, the wait and the errors.
    struct SignInCard: View {
        var session: DraftSession
        @State private var copied = false

        var body: some View {
            Group {
                switch session.state {
                case .signedOut, .signedIn:
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signed out").font(.system(size: 13, weight: .semibold)).foregroundStyle(Coastal.ink)
                            Text(session.note ?? "Drafts off").font(.system(size: 12)).foregroundStyle(Coastal.mut)
                        }
                        Spacer(minLength: 8)
                        signInButton("Sign in")
                    }
                case .requesting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Connecting").font(.system(size: 13)).foregroundStyle(Coastal.ink2)
                        Spacer()
                    }
                    .frame(minHeight: 30)
                case .waiting(let code, let link):
                    waiting(code: code, link: link)
                case .failed(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Coastal.terraText)
                        Text(message).font(.system(size: 13, weight: .semibold)).foregroundStyle(Coastal.terraText)
                        Spacer(minLength: 8)
                        signInButton("Sign in again")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Coastal.paper))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Coastal.edge))
        }

        private func signInButton(_ title: String) -> some View {
            Button(title) { session.signIn() }
                .buttonStyle(SolidButtonStyle(fill: Coastal.buttonTerra))
        }

        private func waiting(code: String, link: URL) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SIGN-IN CODE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Coastal.mut)
                    Spacer()
                    Button("Cancel") { session.signOut() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .foregroundStyle(Coastal.ink2)
                }
                Text(code)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Coastal.ink)
                    .textSelection(.enabled)
                    .accessibilityLabel(Text(code.map(String.init).joined(separator: " ")))
                HStack(spacing: 8) {
                    Button {
                        copyToPasteboard(code)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button {
                        EditingRuntime.open(link)
                    } label: {
                        Label("Open browser", systemImage: "arrow.up.forward.square")
                    }
                    Spacer()
                }
                .buttonStyle(OutlineButtonStyle())
                .labelStyle(SeaIconLabelStyle())
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for approval").font(.system(size: 12)).foregroundStyle(Coastal.mut)
                }
            }
        }
    }

    /// Edit text, on and off: a bordered button off, a filled sea one with its Esc key while on. Both are
    /// one width, so the filter beside it holds still when the mode changes.
    struct EditTextToggle: View {
        var editMode: EditModeState

        /// The pointing hand the Mac pointer turns into over text while the mode is on.
        static let symbol = "hand.point.up.left"
        #if os(macOS)
            private static let width: CGFloat = 132
        #else
            private static let width: CGFloat = 118
        #endif

        var body: some View {
            if editMode.isOn {
                Button {
                    editMode.isOn = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Self.symbol)
                        Text("Editing text")
                        #if os(macOS)
                            Text("esc")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.22)))
                        #endif
                    }
                    .frame(minWidth: Self.width)
                }
                .buttonStyle(SolidButtonStyle(fill: Coastal.buttonSea))
                .help("Stop editing text, Esc")
            } else {
                Button {
                    editMode.isOn = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Self.symbol).foregroundStyle(Coastal.sea)
                        Text("Edit text")
                    }
                    // The outline style pads 2pt less on each side than the solid one.
                    .frame(minWidth: Self.width + 4)
                }
                .buttonStyle(OutlineButtonStyle())
                .help("Edit text \u{2303}\u{2325}\u{2318}E")
            }
        }
    }

    /// The filter: a magnifier, the field and a clear button.
    struct FilterField: View {
        @Binding var text: String

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Coastal.mut)
                TextField("Filter", text: $text, prompt: Text("Filter"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .autocorrectionDisabledIfAvailable()
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Coastal.mut)
                            .accessibilityLabel(Text(verbatim: "Clear filter"))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            #if os(macOS)
                .frame(height: 26)
            #else
                .frame(height: 34)
            #endif
            .background(RoundedRectangle(cornerRadius: 7).fill(Coastal.paper))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Coastal.edge))
        }
    }

    /// A key: its name and tag, then the text shown now and its language.
    struct KeyRowView: View {
        var row: PanelRow
        var showCatalog: Bool
        var open: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.key)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Coastal.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        tag
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.text.isEmpty ? "\u{2014}" : row.text)
                            .font(.system(size: 13))
                            .foregroundStyle(row.text.isEmpty ? Coastal.mut : Coastal.ink2)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(showCatalog ? "\(row.catalog) \u{00B7} \(row.locale)" : row.locale)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Coastal.mut)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Coastal.cream2 : Color.clear))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Coastal.edgeSoft).frame(height: 1).padding(.horizontal, 8).offset(y: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Open in Dialecto")
        }

        @ViewBuilder private var tag: some View {
            if let reason = row.notShown {
                TagView(text: "Not shown \u{00B7} \(reason)", foreground: Coastal.terraText, background: Coastal.gapBackground)
            } else if row.source == .draft {
                TagView(text: "Draft", foreground: Coastal.warnText, background: Coastal.warnBackground)
            }
        }
    }

    struct SeaIconLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.foregroundStyle(Coastal.sea)
                configuration.title
            }
        }
    }

    struct TagView: View {
        var text: String
        var foreground: Color
        var background: Color

        var body: some View {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(background))
        }
    }

    @MainActor
    func copyToPasteboard(_ text: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }

    extension View {
        fileprivate func autocorrectionDisabledIfAvailable() -> some View {
            #if os(iOS)
                self.autocorrectionDisabled().textInputAutocapitalization(.never)
            #else
                self.autocorrectionDisabled()
            #endif
        }

        fileprivate func menuIndicatorHiddenIfAvailable() -> some View {
            #if os(macOS)
                self.menuStyle(.borderlessButton).menuIndicator(.hidden)
            #else
                self.menuIndicator(.hidden)
            #endif
        }
    }
#endif
