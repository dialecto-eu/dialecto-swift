import Observation

/// What SwiftUI watches. A release landing bumps `revision`; a view that read it while building its
/// body (`Text(live:)` does) is built again. A debug session's drafts bump it the same way.
@MainActor
@Observable
package final class LiveStore {
    package static let shared = LiveStore()

    package private(set) var revision = 0

    package func bump() { revision += 1 }
}
