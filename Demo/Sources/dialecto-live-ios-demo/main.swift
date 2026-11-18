// The live editing demo on iOS: a screen of strings and a debug session against a Dialecto server, run in
// the simulator. The README's "iOS host" section builds it into an app bundle and launches it:
//
//   xcrun simctl launch <device> eu.dialecto.live-demo editing <owner/name> [--server http://localhost:4500]
//
// Lines written to Documents/cmd in the app's data container run in order, and every line the app prints
// also goes to Documents/log.txt:
//   panel | close         the keys sheet
//   signin | signout      start the sign-in, or end the session
//   edit on|off           Edit text mode
//   tap <view>            the hit test at a view's center, as a tap in Edit text mode runs it
//   filter [text]         the keys panel's filter
//   appearance light|dark the app's appearance
//   shown                 print what each string shows
// Views: title, export, greeting, summary, library, plain (text that is not Dialecto's).

#if os(iOS)
    import DialectoLive
    import SwiftUI
    import UIKit

    #if DEBUG
        @_spi(Demo) import DialectoLiveEditing
    #endif

    struct FrameKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    extension View {
        func reported(_ id: String) -> some View {
            background(GeometryReader { Color.clear.preference(key: FrameKey.self, value: [id: $0.frame(in: .global)]) })
        }
    }

    @MainActor
    enum Host {
        static var frames: [String: CGRect] = [:]
        static var lastStatus = ""
        static var lastShown = ""

        static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

        static func say(_ line: String) {
            print(line)
            if let handle = try? FileHandle(forWritingTo: documents.appendingPathComponent("log.txt")) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            }
        }

        static func shown() -> [(String, String)] {
            [
                ("scenes.title", DialectoLive.string("scenes.title", default: "Scenes")),
                ("export.button", DialectoLive.string("export.button", default: "Export")),
                ("greeting.name", String(format: DialectoLive.string("greeting.name", default: "Hello, %@!"), "Mario")),
                (
                    "library.summary",
                    String(format: DialectoLive.string("library.summary", default: "%1$@ holds %2$lld scenes"), "Studio", 12)
                ),
                ("nav.library", NSLocalizedString("nav.library", value: "Library", comment: "")),
            ]
        }

        static func start() {
            let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
            FileManager.default.createFile(atPath: documents.appendingPathComponent("log.txt").path, contents: nil)
            FileManager.default.createFile(atPath: documents.appendingPathComponent("cmd").path, contents: nil)
            #if DEBUG
                guard arguments.first == "editing", arguments.count > 1 else {
                    say("usage: editing <owner/name> [--server URL]")
                    return
                }
                let project = arguments[1]
                var server = DialectoLiveEditing.defaultServer
                if let index = arguments.firstIndex(of: "--server"), arguments.indices.contains(index + 1),
                    let url = URL(string: arguments[index + 1])
                {
                    server = url
                }
                DialectoLiveEditing.openURL = { url in Host.say("OPEN \(url.absoluteString)") }
                // A file in the app's own container, never the Keychain.
                DialectoLiveEditing.start(
                    project: project, server: server, language: "de",
                    tokenStorage: .file(documents.appendingPathComponent("token.json")))
                say("READY \(project) \(server.absoluteString)")
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    MainActor.assumeIsolated { tick() }
                }
            #else
                say("A release build has no live editing.")
            #endif
        }

        #if DEBUG
            static func tick() {
                let status = DialectoLiveEditing.status
                if status != lastStatus {
                    lastStatus = status
                    say("STATUS \(status)")
                }
                let line = shown().map { "\($0.0)=\($0.1)" }.joined(separator: " | ")
                if line != lastShown {
                    lastShown = line
                    say("SHOWN \(line)")
                }
                let file = documents.appendingPathComponent("cmd")
                guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return }
                try? Data().write(to: file)
                for line in text.split(separator: "\n") { command(String(line).trimmingCharacters(in: .whitespaces)) }
            }

            static func command(_ line: String) {
                let parts = line.split(separator: " ").map(String.init)
                guard let name = parts.first else { return }
                say("CMD \(line)")
                switch name {
                case "panel": DialectoLiveEditing.showKeys()
                case "close":
                    keyWindow?.rootViewController?.presentedViewController?.dismiss(animated: true)
                case "signin": DialectoLiveEditing.signIn()
                case "signout": DialectoLiveEditing.signOut()
                case "edit": DialectoLiveEditing.isEditingText = parts.last == "on"
                case "editing": say("EDITING \(DialectoLiveEditing.isEditingText ? "on" : "off")")
                case "filter": DialectoLiveEditing.panelFilter = parts.dropFirst().joined(separator: " ")
                case "shown": say("SHOWN \(lastShown)")
                case "appearance":
                    let style: UIUserInterfaceStyle = parts.last == "dark" ? .dark : .light
                    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                        for window in scene.windows { window.overrideUserInterfaceStyle = style }
                    }
                case "tap":
                    guard let id = parts.dropFirst().first, let frame = frames[id] else { say("NO VIEW \(line)"); return }
                    DialectoLiveEditing.pickText(atScreenPoint: frame.midX, frame.midY)
                default: say("UNKNOWN \(line)")
                }
            }

            static var keyWindow: UIWindow? {
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                    .first { $0.isKeyWindow }
            }
        #endif
    }

    struct HostContent: View {
        var body: some View {
            // `Text(live:)` below reads the store's revision, which redraws this view when a draft lands.
            let shown = Host.shown()
            NavigationStack {
                VStack(alignment: .leading, spacing: 22) {
                    Text(live: "scenes.title", default: "Scenes").font(.largeTitle.bold()).reported("title")
                    Button {
                    } label: {
                        Text(live: "export.button", default: "Export")
                    }
                    .buttonStyle(.borderedProminent)
                    .reported("export")
                    Text(verbatim: shown[2].1).reported("greeting")
                    Text(verbatim: shown[3].1).reported("summary")
                    Text(verbatim: shown[4].1).reported("library")
                    Text(verbatim: "Build 42").font(.caption).foregroundStyle(.secondary).reported("plain")
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onPreferenceChange(FrameKey.self) { frames in
                    MainActor.assumeIsolated { Host.frames = frames }
                }
            }
        }
    }

    struct IOSDemoApp: App {
        init() { Host.start() }

        var body: some Scene {
            WindowGroup { HostContent() }
        }
    }

    IOSDemoApp.main()
#else
    print("The iOS host runs in the iOS simulator: see the README, \"iOS host\".")
#endif
