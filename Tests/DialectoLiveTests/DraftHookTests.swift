import Foundation
import Testing
import os

@testable import DialectoLive

/// The draft layer's hook in the shared lookup. Part of the serialized `LiveClientTests` suite, because the
/// release in use and the hook are process-wide.
extension LiveClientTests {
    private func liveSnapshot(_ values: [String: String]) -> LiveSnapshot {
        LiveSnapshot(catalogs: ["localizable": ["de": values]], chain: ["de"])
    }

    private func install(
        drafts: [String: String], refused: OSAllocatedUnfairLock<[LookupRecord]>? = nil,
        records: OSAllocatedUnfairLock<[LookupRecord]>? = nil
    ) {
        LookupHooks.current = LookupHook(
            draft: { key, _, _ in drafts[key].map { LookupMatch(catalog: "localizable", locale: "de", text: $0) } },
            refused: { record in refused?.withLock { $0.append(record) } },
            record: { record in records?.withLock { $0.append(record) } })
    }

    @Test func aDraftBeatsTheLiveReleaseWhichBeatsTheBundle() {
        defer { LookupHooks.current = nil }
        LiveState.replace(liveSnapshot(["export.button": "Live"]))

        install(drafts: ["export.button": "Draft"])
        #expect(DialectoLive.string("export.button", default: "Bundle") == "Draft")

        install(drafts: [:])
        #expect(DialectoLive.string("export.button", default: "Bundle") == "Live")

        LiveState.replace(.empty)
        #expect(DialectoLive.string("export.button", default: "Bundle") == "Bundle")
    }

    @Test func theBundleHookTakesTheSameDraftsAsTheLookup() {
        defer { LookupHooks.current = nil }
        BundleHook.install()
        install(drafts: ["draft.only": "Entwurf"])
        #expect(NSLocalizedString("draft.only", value: "Bundled", comment: "") == "Entwurf")
        #expect(Bundle.main.localizedString(forKey: "draft.only", value: "Bundled", table: nil) == "Entwurf")

        LookupHooks.current = nil
        #expect(NSLocalizedString("draft.only", value: "Bundled", comment: "") == "Bundled")
    }

    @Test func aDraftThatChangesTheArgumentsNeverReachesStringFormat() {
        defer { LookupHooks.current = nil }
        BundleHook.install()
        let refused = OSAllocatedUnfairLock(initialState: [LookupRecord]())
        install(drafts: ["greeting": "%lld items"], refused: refused)

        // The app's text takes a string; the draft takes an integer. Formatting the draft with a string would crash.
        let viaString = DialectoLive.string("greeting", default: "%@ items")
        #expect(viaString == "%@ items")
        let viaBundle = NSLocalizedString("greeting", value: "%@ items", comment: "")
        #expect(viaBundle == "%@ items")
        #expect(String(format: viaBundle, "five") == "five items")
        #expect(refused.withLock { $0.count } == 2)
        #expect(refused.withLock { $0.first?.text } == "%lld items")
    }

    @Test func aDraftWithArgumentsAndNothingToCompareAgainstIsRefused() {
        defer { LookupHooks.current = nil }
        install(drafts: ["only.here": "%@ total", "plain": "Plain"])
        // `NSLocalizedString` with no value and no bundled text: only argument-free text is safe.
        #expect(NSLocalizedString("only.here", value: "", comment: "") == "only.here")
        #expect(NSLocalizedString("plain", value: "", comment: "") == "Plain")
    }

    @Test func everyLookupIsLoggedWithItsSource() {
        defer { LookupHooks.current = nil }
        BundleHook.install()
        let records = OSAllocatedUnfairLock(initialState: [LookupRecord]())
        LiveState.replace(liveSnapshot(["from.live": "Live text"]))
        install(drafts: ["from.draft": "Draft text"], records: records)

        _ = DialectoLive.string("from.draft", default: "x")
        _ = DialectoLive.string("from.live", default: "x")
        _ = DialectoLive.string("from.bundle", default: "Bundled text")
        _ = NSLocalizedString("also.bundle", value: "Other bundled", comment: "")

        let seen = records.withLock { $0 }
        #expect(seen.map(\.source) == [.draft, .live, .bundle, .bundle])
        #expect(seen.map(\.text) == ["Draft text", "Live text", "Bundled text", "Other bundled"])
        #expect(seen.map(\.key) == ["from.draft", "from.live", "from.bundle", "also.bundle"])
        #expect(seen[0].catalog == "localizable" && seen[0].locale == "de")
        #expect(seen[2].catalog == "localizable")
    }

    @Test func withNoHookNothingIsLoggedAndNothingChanges() {
        LookupHooks.current = nil
        LiveState.replace(liveSnapshot(["export.button": "Live"]))
        #expect(DialectoLive.string("export.button", default: "Bundle") == "Live")
        #expect(DialectoLive.string("other", default: "Bundle") == "Bundle")
    }
}
