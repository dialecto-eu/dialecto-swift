#if DEBUG
    import Foundation
    import Testing

    /// A release build must carry none of live editing. This builds the demo app (Demo/), which links
    /// `DialectoLiveEditing`, with `-c release` and searches the binary for the server path, the Keychain
    /// service, the panel's words and the session's type names. The same search finds every one of them in
    /// this debug test binary, which links the same code, so an empty result means something.
    struct ReleaseBinaryTests {
        /// Long literals (a Swift string of 15 bytes or fewer is stored inside the code, not as bytes) and type names.
        static let forbidden = [
            "api/live/native/device", "api/live/native/token", "api/live/native/drafts",
            "eu.dialecto.live-editing",
            "Sign in to Dialecto", "Waiting for approval", "Sign out of Dialecto",
            "EditingRuntime", "DraftSession", "DraftLayer", "LookupLog", "KeysPanel",
        ]

        private static var packageRoot: URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
        }

        private static func contained(in binary: URL) throws -> [String] {
            let data = try Data(contentsOf: binary, options: .mappedIfSafe)
            return forbidden.filter { data.range(of: Data($0.utf8)) != nil }
        }

        @Test func theDebugTestBinaryHasEverythingTheReleaseMustNot() throws {
            // The test bundle is a loaded image whose path runs through `.xctest/`.
            let image = (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map(String.init(cString:)) }
                .first { $0.contains(".xctest/") }
            let binary = URL(fileURLWithPath: try #require(image))
            #expect(Set(try Self.contained(in: binary)) == Set(Self.forbidden))
        }

        @Test(.timeLimit(.minutes(10))) func aReleaseBuildHoldsNoneOfIt() throws {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("dialecto-release-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }

            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            build.arguments = [
                "swift", "build", "-c", "release", "--product", "dialecto-live-demo",
                "--package-path", Self.packageRoot.appendingPathComponent("Demo").path, "--scratch-path", scratch.path,
            ]
            let output = Pipe()
            build.standardOutput = output
            build.standardError = output
            try build.run()
            let log = output.fileHandleForReading.readDataToEndOfFile()
            build.waitUntilExit()
            #expect(
                build.terminationStatus == 0,
                "release build failed: \(String(decoding: log.suffix(2000), as: UTF8.self))")

            let binary = scratch.appendingPathComponent("release/dialecto-live-demo")
            #expect(FileManager.default.fileExists(atPath: binary.path))
            #expect(try Self.contained(in: binary) == [])
        }
    }
#endif
