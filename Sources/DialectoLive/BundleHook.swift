import Foundation
import ObjectiveC
import os

/// Makes `NSLocalizedString` and AppKit/UIKit lookups on the main bundle answer from the release first.
///
/// `Bundle.localizedString(forKey:value:table:)` and a method of ours trade implementations once,
/// guarded by a once-token (a second `start`, or a test calling it again, would swap them back). Only
/// `Bundle.main`, and only a table the release carries, is answered; everything else, and every
/// refusal, goes to the original implementation.
enum BundleHook {
    private static let installedFlag = OSAllocatedUnfairLock(initialState: false)

    /// Installs the hook once. Safe to call again.
    static func install() {
        _ = once
    }

    private static let once: Bool = {
        guard
            let original = class_getInstanceMethod(Bundle.self, #selector(Bundle.localizedString(forKey:value:table:))),
            let replacement = class_getInstanceMethod(Bundle.self, #selector(Bundle.dialecto_localizedString(forKey:value:table:)))
        else { return false }
        method_exchangeImplementations(original, replacement)
        installedFlag.withLock { $0 = true }
        return true
    }()

    static var isInstalled: Bool { installedFlag.withLock { $0 } }
    /// The live text to answer with, or nil to let the bundle answer. `original` asks the bundle
    /// itself, with `value` as the text it returns when it has none.
    static func answer(key: String, value: String?, table: String?, original: (String?) -> String) -> String? {
        Lookup.resolve(
            key: key, table: table, anyTable: false,
            reference: { reference(value: value, original: original) })
    }

    /// The text the app has for a key: the bundle's own, else the caller's `value`.
    static func reference(value: String?, original: (String?) -> String) -> String? {
        let absent = "\u{1}dialecto-live-absent\u{1}"
        let bundled = original(absent)
        return bundled != absent ? bundled : (value.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A live text whose printf tokens differ from the text the app has for the key is dropped.
    static func guarded(_ live: String, key: String, value: String?, original: (String?) -> String) -> String? {
        Lookup.accepts(live, reference: reference(value: value, original: original)) ? live : nil
    }
}

extension Bundle {
    /// After the exchange this is the bundle's own implementation, and `localizedString(forKey:value:table:)`
    /// runs this body.
    @objc dynamic func dialecto_localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if self === Bundle.main,
            let live = BundleHook.answer(
                key: key, value: value, table: tableName,
                original: { self.dialecto_localizedString(forKey: key, value: $0, table: tableName) })
        {
            return live
        }
        let text = dialecto_localizedString(forKey: key, value: value, table: tableName)
        if self === Bundle.main { Lookup.noteBundle(key: key, table: tableName, text: text) }
        return text
    }

    /// The main bundle's own text for `key`, never the release's, or nil when it has none.
    static func bundledString(forKey key: String, table: String?) -> String? {
        let absent = "\u{1}dialecto-live-absent\u{1}"
        let text =
            BundleHook.isInstalled
            ? main.dialecto_localizedString(forKey: key, value: absent, table: table)
            : main.localizedString(forKey: key, value: absent, table: table)
        return text == absent ? nil : text
    }
}
