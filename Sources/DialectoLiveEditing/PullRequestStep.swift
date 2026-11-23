#if DEBUG && canImport(SwiftUI)
    import Foundation
    import Observation
    import SwiftUI

    /// The person's drafts, before and after, for the Keys panel's pull request step. The after is the
    /// draft; the before is the repository's text, read from the key's entries.
    @MainActor
    @Observable
    final class PullRequestModel {
        struct Change: Equatable, Identifiable {
            var key: String
            var before: String?
            var after: String
            var id: String { key }
        }

        /// One catalog in one language.
        struct Group: Equatable, Identifiable {
            var catalog: String
            var locale: String
            var changes: [Change]
            var id: String { "\(catalog)\u{0}\(locale)" }
        }

        private(set) var groups: [Group] = []
        private(set) var loading = false

        var draftCount: Int { groups.reduce(0) { $0 + $1.changes.count } }
        var fileCount: Int { Set(groups.map(\.catalog)).count }

        /// Reads the drafts from the layer, then the texts they replace. A key read for the editor is not
        /// read again.
        func load(session: DraftSession, layer: DraftLayer) async {
            let drafts = layer.drafts
            groups = Self.group(drafts) { key in session.cachedEntries(key) }
            let missing = Array(Set(drafts.map(\.key).filter { session.cachedEntries($0) == nil })).sorted()
            guard !missing.isEmpty else { return }
            loading = true
            defer { loading = false }
            // Capped, so a long list of drafts made in the browser does not spend the read limit.
            for key in missing.prefix(40) { _ = await session.fetchEntries(key) }
            groups = Self.group(layer.drafts) { key in session.cachedEntries(key) }
        }

        static func group(_ drafts: [DraftRow], entries: (String) -> Entries?) -> [Group] {
            var groups: [Group] = []
            for row in drafts {
                guard let text = row.text else { continue }
                let before = entries(row.key)?.catalog(matching: row.catalog)?.language(row.locale)?.text
                let change = Change(key: row.key, before: before, after: text)
                if let at = groups.firstIndex(where: { $0.catalog == row.catalog && $0.locale == row.locale }) {
                    groups[at].changes.append(change)
                } else {
                    groups.append(Group(catalog: row.catalog, locale: row.locale, changes: [change]))
                }
            }
            return groups
        }
    }

    /// The pull request step inside the Keys panel, as the site sidebar's: each draft before and after,
    /// Open full diff, and Open pull request. Both open Dialecto's pull request page in the browser.
    struct PullRequestStep: View {
        var model: PullRequestModel
        var back: () -> Void
        var openPreview: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Button(action: back) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.left").font(.system(size: 11, weight: .medium))
                                Text("Keys")
                            }
                            .font(.system(size: 12.5))
                            .foregroundStyle(Coastal.ink2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Text("New pull request")
                            .font(.system(size: 21, weight: .bold, design: .serif))
                            .tracking(-0.2)
                            .foregroundStyle(Coastal.ink)
                            .padding(.top, 10)
                        Text(meta)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Coastal.mut)
                            .padding(.top, 2)
                        HStack {
                            Text("Drafts \u{00B7} \(model.draftCount)".uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.2)
                                .foregroundStyle(Coastal.mut)
                            Spacer()
                            Button(action: openPreview) {
                                HStack(spacing: 4) {
                                    Text("Open full diff")
                                    Image(systemName: "arrow.up.forward.square").font(.system(size: 10))
                                }
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Coastal.sea)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 18)
                        .padding(.bottom, 6)
                        VStack(spacing: 10) {
                            ForEach(model.groups) { group in CatalogBox(group: group) }
                        }
                        if model.loading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Loading").font(.system(size: 12)).foregroundStyle(Coastal.mut)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel", action: back).buttonStyle(OutlineButtonStyle())
                    Button(action: openPreview) {
                        HStack(spacing: 6) {
                            Text("Open pull request")
                            KeyHint("\u{2318}\u{21A9}", solid: true)
                        }
                    }
                    .buttonStyle(SolidButtonStyle(fill: Coastal.buttonTerra))
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Coastal.paper)
                .overlay(alignment: .top) { Rectangle().fill(Coastal.edge).frame(height: 1) }
            }
        }

        private var meta: String {
            let drafts = model.draftCount == 1 ? "1 draft" : "\(model.draftCount) drafts"
            let files = model.fileCount == 1 ? "1 catalog" : "\(model.fileCount) catalogs"
            return "\(drafts) \u{00B7} \(files)"
        }

        struct CatalogBox: View {
            var group: PullRequestModel.Group

            var body: some View {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(group.catalog).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        Spacer()
                        Text(EditorWords.name(group.locale)).font(.system(size: 11.5)).foregroundStyle(Coastal.mut)
                    }
                    .foregroundStyle(Coastal.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Coastal.cream2)
                    ForEach(Array(group.changes.enumerated()), id: \.element.id) { index, change in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(change.key)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Coastal.mut)
                                .padding(.bottom, 1)
                            if let before = change.before, !before.isEmpty {
                                line("\u{2212}", before, removed: true)
                            }
                            line("+", change.after, removed: false)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .overlay(alignment: .top) {
                            if index > 0 { Rectangle().fill(Coastal.edgeSoft).frame(height: 1) }
                        }
                    }
                }
                .background(Coastal.paper)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Coastal.edge))
            }

            private func line(_ sign: String, _ text: String, removed: Bool) -> some View {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(sign).fontWeight(.semibold)
                    Text(text)
                        .strikethrough(removed)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
                .foregroundStyle(removed ? Coastal.terraText : Coastal.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(removed ? Coastal.gapBackground : Coastal.okBackground))
            }
        }
    }
#endif
