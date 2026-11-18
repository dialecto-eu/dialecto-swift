import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// Dialecto live delivery for Apple apps: text merged in GitHub shows in the running app within
/// minutes, with no rebuild and no store review. A release that is tampered with, stale or broken
/// never changes a string; the app keeps what it has.
///
/// ```swift
/// DialectoLive.start(channel: "<public id>", publicKeys: ["ed25519:…"], builtAt: "2026-11-15T12:00:00Z")
/// DialectoLive.string("export.button", default: "Export")
/// Text(live: "export.button")
/// ```
public enum DialectoLive {
    /// Starts live delivery. Call it once at launch: it applies the cached release before returning,
    /// swaps in the `Bundle.main` hook, and checks in the background at start, on return to the
    /// foreground and every 15 minutes. It never throws; problems go to `onError`.
    ///
    /// - Parameters:
    ///   - channel: the channel's public id.
    ///   - publicKeys: the channel's `ed25519:` keys. One valid signature from any of them is enough.
    ///   - builtAt: the ISO 8601 committer time of the commit this build came from. A release committed
    ///     before it is skipped, so an old release never overrides a newer binary.
    ///   - baseURL: where releases are served; the default is Dialecto's delivery host.
    ///   - language: the language to show, for an app with its own language setting. Leave it out to
    ///     follow the main bundle's (the language the system resolved for the app).
    ///   - onError: called for any failure. The current strings stay.
    @MainActor
    public static func start(
        channel: String,
        publicKeys: [String],
        builtAt: String? = nil,
        baseURL: URL? = nil,
        language: String? = nil,
        onError: (@Sendable (DialectoLiveError) -> Void)? = nil
    ) {
        switch LiveConfiguration.make(
            channel: channel, publicKeys: publicKeys, builtAt: builtAt, baseURL: baseURL, onError: onError)
        {
        case .success(var configuration):
            if let language { configuration.language = { language } }
            _ = LiveRuntime.launch(configuration, watching: true)
        case .failure(let error):
            onError?(error)
        }
    }

    /// The live text for `key`, or `default` when the release has none (or its printf tokens differ
    /// from the text the app has for the key). `table` is the string table's name; nil looks in
    /// `Localizable` first, then in the release's other catalogs.
    public static func string(_ key: String, default fallback: String, table: String? = nil) -> String {
        if let text = Lookup.resolve(
            key: key, table: table, anyTable: true,
            reference: { Bundle.bundledString(forKey: key, table: table) ?? fallback })
        {
            return text
        }
        Lookup.noteBundle(key: key, table: table, text: fallback)
        return fallback
    }

    /// Goes up each time a release or a debug draft lands. A SwiftUI body that reads it is built again
    /// then, as `Text(live:)` is, so text the app looks up itself (`NSLocalizedString`, its own helper)
    /// redraws too.
    @MainActor public static var revision: Int { LiveStore.shared.revision }

    /// For the debug-only product, which needs the `Bundle.main` hook without a release channel.
    package static func installBundleHook() { BundleHook.install() }

    /// Checks for a release now, for example from a pull-to-refresh. Returns when the check is done.
    public static func refresh() async {
        guard let client = await LiveRuntime.current?.client else { return }
        await client.check()
    }
}

/// The running client, its watchers and its timer.
@MainActor
final class LiveRuntime {
    static var current: LiveRuntime?

    let client: LiveClient
    private var observers: [any NSObjectProtocol] = []
    private var loop: Task<Void, Never>?

    private init(client: LiveClient) { self.client = client }

    /// Applies the cached release, installs the hook and, when `watching`, starts the checks. A
    /// runtime already running is stopped first, so a second `start` replaces it and leaves the hook alone.
    static func launch(_ configuration: LiveConfiguration, watching: Bool) -> LiveRuntime {
        current?.stop()
        BundleHook.install()

        let held = LiveClient.loadCache(config: configuration)
        if let held { LiveState.replace(LiveClient.snapshot(of: held, config: configuration)) }
        else { LiveState.replace(.empty) }
        LiveStore.shared.bump()

        let runtime = LiveRuntime(client: LiveClient(config: configuration, held: held))
        current = runtime
        if watching { runtime.watch() }
        return runtime
    }

    private func watch() {
        let client = client
        let center = NotificationCenter.default
        for name in Self.foregroundNames {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    Task { await client.check() }
                })
        }
        loop = Task {
            await client.check()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                if Task.isCancelled { break }
                await client.check()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if LiveRuntime.current === self { LiveRuntime.current = nil }
    }

    /// Back to the foreground, and the system language changing, both re-resolve and re-check.
    private static var foregroundNames: [Notification.Name] {
        var names = [NSLocale.currentLocaleDidChangeNotification]
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            names.append(NSApplication.didBecomeActiveNotification)
        #elseif canImport(UIKit)
            names.append(UIApplication.didBecomeActiveNotification)
        #endif
        return names
    }
}
