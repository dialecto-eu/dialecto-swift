// A live release landing in a running app, with nothing rebuilt.
//
//   swift run dialecto-live-demo            serves the contract release from a temp folder, then a second one
//   swift run dialecto-live-demo <folder>   <folder>/<channel>/manifest.json is served as file://
//   swift run dialecto-live-demo <https URL> a delivery host (the channel is "production")
//
// It prints what each way of asking for a string answers: before a release, after the first and after
// a second one that is swapped in while the app runs. The key is the test-only one: it signs nothing real.

import AppKit
import CryptoKit
import DialectoLive
import DialectoLiveFixtures
import Foundation
import SwiftUI

// `editing <owner/name>` runs the live editing demo instead (EditingDemo.swift).
if CommandLine.arguments.dropFirst().first == "editing" {
    EditingDemo.run(Array(CommandLine.arguments.dropFirst(2)))
}

let keys = try ContractFixture.testKey()
let channel = "production"

// Where releases come from.
var baseURL: URL
var writableChannelDirectory: URL?
if let argument = CommandLine.arguments.dropFirst().first, argument.hasPrefix("http") {
    baseURL = URL(string: argument)!
} else {
    let root = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("dialecto-live-demo-\(UUID().uuidString)")
    baseURL = root
    let directory = root.appendingPathComponent(channel, isDirectory: true)
    writableChannelDirectory = directory
    if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
        for (path, data) in try ContractFixture.served() {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }
}

// Pixels of a view, to tell which text SwiftUI drew without reading private storage.
@MainActor func pixels(_ view: some View) -> Data? {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
    renderer.scale = 1
    return renderer.cgImage?.dataProvider?.data as Data?
}

@MainActor func drew(_ view: some View, _ candidates: [String]) -> String {
    guard let drawn = pixels(view) else { return "(could not render)" }
    for text in candidates where pixels(Text(verbatim: text)) == drawn { return text }
    return "(none of the candidates)"
}

/// Text(live:) keeps its string in a `verbatim` storage; read it back.
@MainActor func verbatim(_ text: Text) -> String {
    let mirror = Mirror(reflecting: text)
    guard let storage = mirror.descendant("storage", "verbatim") as? String else { return "(unreadable)" }
    return storage
}

struct Probe {
    let key: String
    let bundled: String
}

let probes = [
    Probe(key: "export.button", bundled: "Export"),
    Probe(key: "greeting.name", bundled: "Hello, %@! 100%% ready."),
    Probe(key: "library.summary", bundled: "%1$@ holds %2$lld scenes"),
]

@MainActor func report(_ title: String) {
    print("\n== \(title)")
    for probe in probes {
        let live = DialectoLive.string(probe.key, default: probe.bundled)
        let candidates = [probe.key, probe.bundled, live]
        print("  \(probe.key)")
        print("    DialectoLive.string                     \(live)")
        print("    NSLocalizedString                       \(NSLocalizedString(probe.key, value: probe.bundled, comment: ""))")
        print("    Bundle.main.localizedString             \(Bundle.main.localizedString(forKey: probe.key, value: probe.bundled, table: nil))")
        print("    String(localized:)                      \(String(localized: String.LocalizationValue(probe.key)))")
        print("    String(localized:) bundle .main         \(String(localized: String.LocalizationValue(probe.key), bundle: .main))")
        print("    Text(live:) string                      \(verbatim(Text(live: probe.key, default: probe.bundled)))")
        print("    Text(live:) rendered by ImageRenderer   \(drew(Text(live: probe.key, default: probe.bundled), candidates))")
        print("    Text(\"key\") rendered by ImageRenderer   \(drew(Text(LocalizedStringKey(probe.key)), candidates))")
    }
}

report("Before any release")

DialectoLive.start(
    channel: channel, publicKeys: [keys.publicText], builtAt: "2026-10-01T00:00:00Z", baseURL: baseURL,
    language: "de",
    onError: { print("  onError:", $0) })

await DialectoLive.refresh()
report("After the first release (sequence 7, German)")

// A second release lands while the app runs: the export button is renamed.
if let directory = writableChannelDirectory {
    let second = FixtureRelease(
        sequence: 8, release: "rel_demo_second",
        files: [
            .init(locale: "de", values: [
                "export.button": "Szenen exportieren",
                "greeting.name": "Hallo, %@! Alles bereit.",
                "library.summary": "%2$lld Szenen in %1$@, neu sortiert",
            ]),
        ])
    try second.write(to: directory, signedBy: [keys.privateKey])
    print("\n-- wrote release sequence 8 to \(directory.path)")
}

await DialectoLive.refresh()
report("After the second release (sequence 8)")
