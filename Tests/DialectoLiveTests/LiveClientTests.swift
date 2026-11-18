import CryptoKit
import DialectoLiveFixtures
import Foundation
import Observation
import Testing
import os

@testable import DialectoLive

#if canImport(AppKit)
    import AppKit
#endif

/// The client end to end against a stubbed network. One serialized suite: the release in use, and the
/// `Bundle.main` hook, are process-wide.
@MainActor
@Suite(.serialized)
struct LiveClientTests {
    let publicText: String
    let key: Curve25519.Signing.PrivateKey

    init() throws {
        (key, publicText) = try ContractFixture.testKey()
        LiveRuntime.current?.stop()
        LiveState.replace(.empty)
    }

    private func text(_ key: String, _ fallback: String) -> String { DialectoLive.string(key, default: fallback) }

    private func contract() throws -> [String: Data] { try ContractFixture.served() }

    private func release(_ sequence: Int, de: [String: String]) -> FixtureRelease {
        FixtureRelease(
            sequence: sequence, release: "rel_test\(sequence)",
            files: [.init(locale: "de", values: de), .init(locale: "en", values: ["export.button": "Export"])])
    }

    // MARK: A good release

    @Test func goodReleaseApplies() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText])

        #expect(text("export.button", "Export") == "Export")
        let before = DialectoLive.revision
        #expect(await runtime.client.check() == .applied)
        #expect(DialectoLive.revision > before)
        #expect(text("export.button", "Export") == "Exportieren")
        #expect(text("library.summary", "%1$@ holds %2$lld scenes") == "%2$lld Szenen in %1$@")
        // Plural, device and not-to-translate keys are not in the release: the app's text stays.
        #expect(text("scenes.count", "%lld scenes") == "%lld scenes")
        #expect(text("app.identifier", "vibe") == "vibe")
        #expect(harness.reported.isEmpty)
    }

    @Test func downloadsOnlyTheCurrentLocale() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText], language: "zh-Hans-DE")
        _ = await runtime.client.check()

        #expect(text("export.button", "Export") == "导出")
        #expect(harness.requests.filter { $0.hasSuffix(".json") && $0 != "manifest.json" } == ["r/rel_swiftfixture0001/localizable/zh-Hans.json"])
    }

    @Test func aLanguageTheReleaseLacksKeepsTheAppsText() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText], language: "fr-FR")
        #expect(await runtime.client.check() == .applied)
        #expect(text("export.button", "Export") == "Export")
        #expect(harness.requests.allSatisfy { !$0.hasPrefix("r/") })
    }

    @Test func anUnchangedManifestIsNotFetchedAgain() async throws {
        let harness = Harness(served: try contract(), etag: "\"v1\"")
        let runtime = harness.launch(publicKeys: [publicText])
        #expect(await runtime.client.check() == .applied)
        harness.clearRequests()

        #expect(await runtime.client.check() == .unchanged)
        #expect(harness.requests == ["manifest.json"])
    }

    @Test func aNewerReleaseReplacesTheOldAndDownloadsOnlyWhatChanged() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText])
        _ = await runtime.client.check()

        harness.serve(release(8, de: ["export.button": "Raus"]).served(signedBy: [key]))
        #expect(await runtime.client.check() == .applied)
        #expect(text("export.button", "Export") == "Raus")
        #expect(text("library.summary", "fallback") == "fallback")
    }

    // MARK: Releases that must change nothing

    @Test func aBadSignatureIsRefusedAndKeepsTheCurrentStrings() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText])
        _ = await runtime.client.check()

        var served = try contract()
        served["manifest.json"] = try altering(served["manifest.json"]!) { envelope in
            var sigs = envelope["sigs"] as! [[String: String]]
            sigs[0]["sig"] = "A" + sigs[0]["sig"]!.dropFirst()
            envelope["sigs"] = sigs
        }
        harness.serve(served)

        #expect(await runtime.client.check() == .failed)
        #expect(harness.reported.contains(.badSignature))
        #expect(text("export.button", "Export") == "Exportieren")
    }

    @Test func aPayloadChangedAfterSigningIsRefused() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText])

        var served = try contract()
        served["manifest.json"] = try altering(served["manifest.json"]!) { envelope in
            let payload = Base64URL.decode(envelope["payload"] as! String)!
            let changed = String(data: payload, encoding: .utf8)!.replacingOccurrences(of: "\"sequence\":7", with: "\"sequence\":9")
            envelope["payload"] = FixtureRelease.base64url(Data(changed.utf8))
        }
        harness.serve(served)

        #expect(await runtime.client.check() == .failed)
        #expect(harness.reported == [.badSignature])
        #expect(text("export.button", "Export") == "Export")
    }

    @Test func aManifestSignedByAnotherKeyIsRefused() async throws {
        let stranger = Curve25519.Signing.PrivateKey()
        let harness = Harness(served: release(8, de: ["export.button": "Raus"]).served(signedBy: [stranger]))
        let runtime = harness.launch(publicKeys: [publicText])

        #expect(await runtime.client.check() == .failed)
        #expect(harness.reported == [.unknownKey])
        #expect(text("export.button", "Export") == "Export")
    }

    @Test func aReleaseSignedForAnotherChannelIsRefusedFromTheNetworkAndTheCache() async throws {
        var other = release(8, de: ["export.button": "Raus"])
        other.channel = "staging"
        let harness = Harness(served: other.served(signedBy: [key]))
        let runtime = harness.launch(publicKeys: [publicText])

        #expect(await runtime.client.check() == .failed)
        #expect(harness.reported == [.badManifest])
        #expect(text("export.button", "Export") == "Export")

        // The same bytes planted in the cache are dropped at start.
        let cache = LiveCache(root: harness.cacheRoot, channel: "production")
        try cache.write(manifest: other.served(signedBy: [key])["manifest.json"]!, etag: nil, payloads: [:])
        runtime.stop()
        let restarted = harness.launch(publicKeys: [publicText])
        _ = restarted
        #expect(text("export.button", "Export") == "Export")
        #expect(harness.reported.last == .badManifest)
    }

    @Test func aBadPayloadHashIsRefused() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText])

        var served = try contract()
        served["r/rel_swiftfixture0001/localizable/de.json"] = FixtureRelease.payloadData(["export.button": "Gehackt"])
        harness.serve(served)

        #expect(await runtime.client.check() == .failed)
        #expect(harness.reported == [.badHash])
        #expect(text("export.button", "Export") == "Export")
    }

    @Test func aLowerSequenceIsRefused() async throws {
        let harness = Harness(served: release(9, de: ["export.button": "Neun"]).served(signedBy: [key]))
        let runtime = harness.launch(publicKeys: [publicText])
        #expect(await runtime.client.check() == .applied)

        harness.serve(try contract())  // sequence 7
        #expect(await runtime.client.check() == .stale)
        #expect(text("export.button", "Export") == "Neun")

        harness.serve(release(9, de: ["export.button": "Anders"]).with(release: "rel_other").served(signedBy: [key]))
        #expect(await runtime.client.check() == .stale)  // the same sequence under another release id
        #expect(text("export.button", "Export") == "Neun")
    }

    @Test func aReleaseCommittedBeforeTheBuildIsSkipped() async throws {
        let harness = Harness(served: try contract())  // committed 2026-10-09
        let runtime = harness.launch(publicKeys: [publicText], builtAt: "2026-10-10T00:00:00Z")

        #expect(await runtime.client.check() == .olderThanBuild)
        #expect(text("export.button", "Export") == "Export")
        #expect(harness.requests == ["manifest.json"])
    }

    @Test func aValueWhoseTokensChangedKeepsTheAppsText() async throws {
        let values = ["greeting.name": "Hallo, %d!", "export.button": "Raus", "library.summary": "%2$lld in %1$@"]
        let harness = Harness(served: release(8, de: values).served(signedBy: [key]))
        let runtime = harness.launch(publicKeys: [publicText])
        #expect(await runtime.client.check() == .applied)

        #expect(text("greeting.name", "Hello, %@!") == "Hello, %@!")
        #expect(NSLocalizedString("greeting.name", value: "Hello, %@!", comment: "") == "Hello, %@!")
        // The rest of the release still applies, and a reordered positional string is the same tokens.
        #expect(text("export.button", "Export") == "Raus")
        #expect(text("library.summary", "%1$@ has %2$lld") == "%2$lld in %1$@")
    }

    // MARK: Offline and restart

    @Test func theCacheServesAfterARestartWithTheNetworkDown() async throws {
        let first = Harness(served: try contract())
        let runtime = first.launch(publicKeys: [publicText])
        #expect(await runtime.client.check() == .applied)

        // The app quits: nothing is in memory, and the network is gone.
        runtime.stop()
        LiveState.replace(.empty)
        #expect(text("export.button", "Export") == "Export")

        let second = Harness(cacheRoot: first.cacheRoot)
        second.setOffline(true)
        let restarted = second.launch(publicKeys: [publicText])
        #expect(text("export.button", "Export") == "Exportieren")  // before any check
        #expect(await restarted.client.check() == .failed)
        #expect(second.reported == [.network])
        #expect(text("export.button", "Export") == "Exportieren")
        withExtendedLifetime(first) {}
    }

    @Test func aCacheTheKeysNoLongerTrustIsDropped() async throws {
        let first = Harness(served: try contract())
        let runtime = first.launch(publicKeys: [publicText])
        _ = await runtime.client.check()
        runtime.stop()
        LiveState.replace(.empty)

        let other = ManifestVerifier.keyScheme + FixtureRelease.base64url(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let second = Harness(cacheRoot: first.cacheRoot)
        second.setOffline(true)
        _ = second.launch(publicKeys: [other])
        #expect(text("export.button", "Export") == "Export")
        withExtendedLifetime(first) {}
    }

    // MARK: The hook

    @Test func theHookAnswersNSLocalizedString() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText])
        #expect(NSLocalizedString("export.button", comment: "") == "export.button")  // before a release
        _ = await runtime.client.check()

        #expect(NSLocalizedString("export.button", comment: "") == "Exportieren")
        #expect(NSLocalizedString("export.button", tableName: "Localizable", bundle: .main, value: "Export", comment: "") == "Exportieren")
        #expect(Bundle.main.localizedString(forKey: "export.button", value: nil, table: nil) == "Exportieren")
        // A table the release does not carry, a key it lacks, and another bundle: the bundle answers.
        #expect(NSLocalizedString("export.button", tableName: "Menus", bundle: .main, value: "Export", comment: "") == "Export")
        #expect(NSLocalizedString("scenes.count", value: "%lld scenes", comment: "") == "%lld scenes")
        // Live text that takes arguments, with no text of the app's to compare it with, is not shown.
        #expect(NSLocalizedString("greeting.name", comment: "") == "greeting.name")
        #expect(NSLocalizedString("greeting.name", value: "", comment: "") == "greeting.name")
        #expect(NSLocalizedString("greeting.name", value: "Hello, %@! 100%% ready.", comment: "") == "Hallo, %@! 100%% bereit.")
        #expect(Bundle(for: Harness.self).localizedString(forKey: "export.button", value: "Export", table: nil) == "Export")
    }

    @Test func aSecondStartDoesNotUndoTheHook() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText])
        _ = await runtime.client.check()

        BundleHook.install()
        BundleHook.install()
        let again = harness.launch(publicKeys: [publicText])  // start called again
        #expect(again !== runtime)
        _ = await again.client.check()

        #expect(NSLocalizedString("export.button", comment: "") == "Exportieren")
        #expect(text("export.button", "Export") == "Exportieren")
    }

    @Test func swiftUIObserversAreToldWhenAReleaseLands() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText])
        let before = LiveStore.shared.revision

        let fired = Flag()
        withObservationTracking({ _ = LiveStore.shared.revision }, onChange: { fired.set() })
        _ = await runtime.client.check()

        #expect(fired.value)
        #expect(LiveStore.shared.revision > before)
    }

    // MARK: When it checks

    @Test func startingChecksInTheBackgroundAndComingBackToTheForegroundChecksAgain() async throws {
        let harness = Harness(served: try contract())
        let runtime = harness.launch(publicKeys: [publicText], watching: true)
        defer { runtime.stop() }

        try await waitFor { harness.requests.contains("manifest.json") && text("export.button", "Export") == "Exportieren" }
        let first = harness.requests.count

        #if canImport(AppKit)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #endif
        try await waitFor { harness.requests.count > first }
    }

    // MARK: Helpers

    private func altering(_ manifest: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var envelope = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
        change(&envelope)
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("timed out waiting")
    }
}

extension FixtureRelease {
    fileprivate func with(release: String) -> FixtureRelease {
        var copy = self
        copy.release = release
        return copy
    }
}

private struct Flag: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func set() { lock.withLock { $0 = true } }
    var value: Bool { lock.withLock { $0 } }
}
