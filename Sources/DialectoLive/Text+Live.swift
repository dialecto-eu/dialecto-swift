#if canImport(SwiftUI)
    import Foundation
    import SwiftUI

    extension Text {
        /// Text that shows the live release's string for `key` and redraws when a release lands.
        ///
        /// `default` is what shows when the release has none; leave it out to use the app's own text
        /// for the key (the one `NSLocalizedString` finds), else the key itself.
        @MainActor
        public init(live key: String, default fallback: String? = nil, table: String? = nil) {
            // Reading the revision while the body builds is what subscribes the view to releases.
            _ = LiveStore.shared.revision
            let bundled = fallback ?? Bundle.bundledString(forKey: key, table: table) ?? key
            self.init(verbatim: DialectoLive.string(key, default: bundled, table: table))
        }
    }
#endif
