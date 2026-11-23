// The live editing demo: a small window of strings, a debug session against a Dialecto server, and a
// command file so a headless run can drive it.
//
//   swift run dialecto-live-demo editing <owner/name> [--server http://localhost:4500] [--out <folder>]
//                                        [--token-store memory|file:<path>]   (memory by default; never the Keychain)
//
// With `--out`, every line the app prints also goes to <folder>/log.txt, links are written to
// <folder>/opened.txt instead of opening a browser, and lines written to <folder>/cmd run in order:
//   panel                 show the keys window
//   signin | signout      start the sign-in, or end the session
//   snapshot window|panel write <folder>/<name>.png
//   edit on|off           Edit text mode
//   click <view>          a real mouse-down on a view, through the app's event queue
//   hover <view>          a mouse-moved event over a view, through the app's event queue
//   pick <view>           the hit test at a view's center, without the event
//   esc                   an Esc key-down, through the app's event queue
//   editing               print whether Edit text is on
//   capture window|panel  write <folder>/<name>.png as the screen shows it, titlebar and Edit text frame included
//   filter [text]         the keys panel's filter (empty clears it)
//   appearance light|dark the app's appearance
//   frames                print the demo window's and the keys panel's frames, top-left origin, for screencapture -R
//   shown                 print what each string shows
//   ax <view>             print the accessibility chain at a view's center (role, label, value, help)
//   open sheet|popover|alert|panel   open one more window over the demo's (a sheet, a popover, an alert
//                         sheet, a floating panel), each with a string of its own; `close` closes them
//   quit
// Views: title, export, gear (a button with a tooltip and no text), greeting, summary, library, plain
// (text that is not Dialecto's). `click`, `hover`, `pick` and `capture` also take @sheet, @popover, @alert
// and @panel: the center of that window, or all of it.

import AppKit
import DialectoLive
import Foundation
import SwiftUI

#if DEBUG
    @_spi(Demo) import DialectoLiveEditing

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

    enum Shown {
        @MainActor static func summary() -> [(String, String)] {
            [
                ("scenes.title", DialectoLive.string("scenes.title", default: "Scenes")),
                ("export.button", DialectoLive.string("export.button", default: "Export")),
                ("greeting.name", String(format: DialectoLive.string("greeting.name", default: "Hello, %@!"), "Mario")),
                (
                    "library.summary",
                    String(
                        format: DialectoLive.string("library.summary", default: "%1$@ holds %2$lld scenes"), "Studio",
                        12)
                ),
                ("nav.library", NSLocalizedString("nav.library", value: "Library", comment: "")),
            ]
        }
    }

    struct DemoContent: View {
        var body: some View {
            // `Text(live:)` below reads the store's revision, which redraws this view when a draft lands.
            VStack(alignment: .leading, spacing: 18) {
                Text(live: "scenes.title", default: "Scenes").font(.title).reported("title")
                Button {
                } label: {
                    Text(live: "export.button", default: "Export")
                }
                .reported("export")
                // An icon with a tooltip and no text of its own: the tooltip is the string Edit text reaches.
                Button {
                } label: {
                    Image(systemName: "gearshape")
                }
                .help(DialectoLive.string("gear.help", default: "Open the settings"))
                .accessibilityLabel(Text(verbatim: ""))
                .reported("gear")
                Text(verbatim: Shown.summary()[2].1).reported("greeting")
                Text(verbatim: Shown.summary()[3].1).reported("summary")
                Text(verbatim: Shown.summary()[4].1).reported("library")
                // Text the app does not look up: a click on it finds no key.
                Text(verbatim: "Build 42").font(.caption).foregroundStyle(.secondary).reported("plain")
            }
            .padding(32)
            .frame(width: 420, height: 340, alignment: .topLeading)
            .onPreferenceChange(FrameKey.self) { EditingDemo.frames = $0 }
        }
    }

    @MainActor
    enum EditingDemo {
        static var frames: [String: CGRect] = [:]
        private static var window: NSWindow?
        private static var extras: [String: NSWindow] = [:]
        private static var popover: NSPopover?
        private static var out: URL?
        private static var lastShown = ""
        private static var lastStatus = ""

        static func say(_ line: String) {
            print(line)
            fflush(stdout)
            if let out, let handle = try? FileHandle(forWritingTo: out.appendingPathComponent("log.txt")) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            }
        }

        static func run(_ arguments: [String]) -> Never {
            guard let project = arguments.first, project.contains("/") else {
                print("usage: dialecto-live-demo editing <owner/name> [--server URL] [--out FOLDER]")
                exit(2)
            }
            var server = DialectoLiveEditing.defaultServer
            if let index = arguments.firstIndex(of: "--server"), arguments.indices.contains(index + 1),
                let url = URL(string: arguments[index + 1])
            {
                server = url
            }
            if let index = arguments.firstIndex(of: "--out"), arguments.indices.contains(index + 1) {
                let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: folder.appendingPathComponent("log.txt").path, contents: nil)
                FileManager.default.createFile(atPath: folder.appendingPathComponent("cmd").path, contents: nil)
                out = folder
                DialectoLiveEditing.openURL = { url in
                    EditingDemo.say("OPEN \(url.absoluteString)")
                }
            }

            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            // The main menu a SwiftUI app has by default: an app menu, so the Dialecto menu has a bar to join.
            let bar = NSMenu()
            let appItem = NSMenuItem()
            appItem.submenu = NSMenu(title: "Demo")
            appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            bar.addItem(appItem)
            app.mainMenu = bar

            // Never the Keychain: an unsigned demo binary prompts for it after every rebuild.
            var storage = DialectoLiveEditing.TokenStorage.memory
            if let index = arguments.firstIndex(of: "--token-store"), arguments.indices.contains(index + 1),
                arguments[index + 1].hasPrefix("file:")
            {
                storage = .file(URL(fileURLWithPath: String(arguments[index + 1].dropFirst(5))))
            }
            DialectoLiveEditing.start(project: project, server: server, language: "de", tokenStorage: storage)

            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = "Editing demo"
            created.contentView = NSHostingView(rootView: DemoContent())
            created.center()
            created.makeKeyAndOrderFront(nil)
            window = created
            app.activate(ignoringOtherApps: true)
            say("READY \(project) \(server.absoluteString)")

            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { tick() }
            }
            app.run()
            exit(0)
        }

        private static func tick() {
            let status = DialectoLiveEditing.status
            if status != lastStatus {
                lastStatus = status
                say("STATUS \(status)")
            }
            let shown = Shown.summary().map { "\($0.0)=\($0.1)" }.joined(separator: " | ")
            if shown != lastShown {
                lastShown = shown
                say("SHOWN \(shown)")
            }
            guard let out, let text = try? String(contentsOf: out.appendingPathComponent("cmd"), encoding: .utf8),
                !text.isEmpty
            else { return }
            try? Data().write(to: out.appendingPathComponent("cmd"))
            for line in text.split(separator: "\n") { command(String(line).trimmingCharacters(in: .whitespaces)) }
        }

        private static func command(_ line: String) {
            let parts = line.split(separator: " ").map(String.init)
            guard let name = parts.first else { return }
            say("CMD \(line)")
            switch name {
            case "panel": DialectoLiveEditing.showKeys()
            case "signin": DialectoLiveEditing.signIn()
            case "signout": DialectoLiveEditing.signOut()
            case "shown": say("SHOWN \(lastShown)")
            case "edit": DialectoLiveEditing.isEditingText = parts.last == "on"
            case "snapshot":
                guard let out, let target = parts.dropFirst().first else { return }
                let file = out.appendingPathComponent("\(target).png")
                if target == "panel" {
                    say(DialectoLiveEditing.writePanelImage(to: file) ? "WROTE \(file.path)" : "NO PANEL")
                } else if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                    say("WROTE \(file.path)")
                }
            case "esc":
                if let window, let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                    isARepeat: false, keyCode: 53)
                {
                    NSApp.postEvent(event, atStart: false)
                }
            case "editing":
                say("EDITING \(DialectoLiveEditing.isEditingText ? "on" : "off")")
            case "filter":
                DialectoLiveEditing.panelFilter = parts.dropFirst().joined(separator: " ")
            case "appearance":
                NSApp.appearance = NSAppearance(named: parts.last == "dark" ? .darkAqua : .aqua)
            case "capture":
                // The window as the screen shows it, titlebar and Edit text frame included, even when other
                // apps cover it: each window is captured on its own (screencapture -l) and the frame laid over.
                guard let out, let target = parts.dropFirst().first else { return }
                let shown =
                    target == "panel"
                    ? NSApp.windows.first { $0.isVisible && $0.title == "Dialecto Keys" }
                    : target.hasPrefix("@") ? extras[String(target.dropFirst())] : window
                guard let shown else { say("NO WINDOW \(line)"); return }
                let file = out.appendingPathComponent("\(target).png")
                say(capture(shown, to: file) ? "WROTE \(file.path)" : "NO CAPTURE \(line)")
            case "frames":
                let height = NSScreen.screens.first?.frame.height ?? 0
                for shown in NSApp.windows where shown.isVisible && (shown === window || shown.title == "Dialecto Keys") {
                    let frame = shown.frame
                    say(
                        "FRAME \(shown === window ? "window" : "panel") \(Int(frame.minX)),\(Int(height - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
                    )
                }
            case "click", "pick", "hover":
                guard let id = parts.dropFirst().first, let target = id.hasPrefix("@") ? extras[String(id.dropFirst())] : window,
                    let frame = id.hasPrefix("@") ? CGRect(x: 0, y: 0, width: target.frame.width, height: target.frame.height) : frames[id]
                else { say("NO VIEW \(line)"); return }
                let window = target
                // SwiftUI's global space starts at the top of the whole window, titlebar included.
                var inWindow = NSPoint(x: frame.midX, y: window.frame.height - frame.midY)
                // @windows: the middle of the content below the titlebar, where their one string is.
                if id.hasPrefix("@") { inWindow.y = window.contentLayoutRect.midY }
                if name == "pick" {
                    let screen = window.convertPoint(toScreen: inWindow)
                    DialectoLiveEditing.pickText(atScreenPoint: screen.x, screen.y)
                } else if let event = NSEvent.mouseEvent(
                    with: name == "hover" ? .mouseMoved : .leftMouseDown, location: inWindow, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: name == "hover" ? 0 : 1, pressure: name == "hover" ? 0 : 1)
                {
                    NSApp.postEvent(event, atStart: false)
                }
            case "ax":
                guard let id = parts.dropFirst().first, let frame = frames[id], let window else { return }
                let screen = window.convertPoint(toScreen: NSPoint(x: frame.midX, y: window.frame.height - frame.midY))
                var node = NSApp.accessibilityHitTest(screen) as AnyObject?
                var depth = 0
                while let current = node, depth < 8 {
                    let fields = ["accessibilityRole", "accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"]
                        .map { name -> String in
                            let value = current.responds(to: Selector(name)) ? current.perform(Selector(name))?.takeUnretainedValue() : nil
                            return "\(name.dropFirst(13))=\(value.map { "\($0)" } ?? "-")"
                        }
                    say("AX \(depth) \(fields.joined(separator: " "))")
                    node = current.responds(to: Selector("accessibilityParent")) ? current.perform(Selector("accessibilityParent"))?.takeUnretainedValue() : nil
                    depth += 1
                }
            case "open": openExtra(parts.dropFirst().first ?? "")
            case "close": closeExtras()
            case "quit": exit(0)
            default: say("UNKNOWN \(line)")
            }
        }

        private static func extraContent(_ text: String, _ key: String) -> NSView {
            let view = NSHostingView(
                rootView: Text(live: key, default: text).font(.title3).padding(24).fixedSize())
            view.frame.size = view.fittingSize
            return view
        }

        private static func openExtra(_ kind: String) {
            guard let window else { return }
            switch kind {
            case "sheet":
                let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
                sheet.contentView = extraContent("Rename this scene", "sheet.title")
                window.beginSheet(sheet)
                extras["sheet"] = sheet
            case "popover":
                let shown = NSPopover()
                shown.behavior = .applicationDefined
                let controller = NSViewController()
                controller.view = extraContent("Scenes in your library", "popover.title")
                shown.contentViewController = controller
                if let content = window.contentView {
                    shown.show(relativeTo: NSRect(x: content.bounds.midX, y: content.bounds.maxY - 40, width: 1, height: 1), of: content, preferredEdge: .minY)
                }
                popover = shown
                extras["popover"] = shown.contentViewController?.view.window
            case "alert":
                let alert = NSAlert()
                alert.messageText = DialectoLive.string("alert.title", default: "Delete this scene?")
                alert.informativeText = DialectoLive.string("alert.body", default: "This cannot be undone.")
                alert.addButton(withTitle: DialectoLive.string("alert.ok", default: "Delete"))
                alert.beginSheetModal(for: window)
                extras["alert"] = window.attachedSheet
            case "panel":
                let panel = NSPanel(
                    contentRect: .zero, styleMask: [.titled, .utilityWindow, .closable], backing: .buffered, defer: false)
                panel.title = "Inspector"
                panel.isFloatingPanel = true
                panel.contentView = extraContent("Scene details", "panel.title")
                panel.setFrameTopLeftPoint(NSPoint(x: window.frame.maxX + 20, y: window.frame.maxY))
                panel.orderFront(nil)
                extras["panel"] = panel
            default: say("UNKNOWN open \(kind)")
            }
        }

        private static func closeExtras() {
            for (_, extra) in extras {
                if let sheet = window?.attachedSheet, sheet === extra { window?.endSheet(sheet) } else { extra.close() }
            }
            popover?.close()
            popover = nil
            extras = [:]
        }

        private static func windowImage(_ number: Int) -> NSImage? {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dialecto-demo-\(number)-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(number), file.path]
            guard (try? shot.run()) != nil else { return nil }
            shot.waitUntilExit()
            return NSImage(contentsOf: file)
        }

        private static func capture(_ shown: NSWindow, to file: URL) -> Bool {
            guard let base = windowImage(shown.windowNumber), let rep = base.representations.first else { return false }
            let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            guard
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                    bitsPerPixel: 0)
            else { return false }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            base.draw(in: NSRect(origin: .zero, size: size))
            for child in shown.childWindows ?? [] where child.isVisible {
                guard let layer = windowImage(child.windowNumber) else { continue }
                let scale = size.width / shown.frame.width
                let rect = NSRect(
                    x: (child.frame.minX - shown.frame.minX) * scale, y: (child.frame.minY - shown.frame.minY) * scale,
                    width: child.frame.width * scale, height: child.frame.height * scale)
                layer.draw(in: rect)
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: file)) != nil
        }
    }
#else
    @MainActor
    enum EditingDemo {
        static func run(_ arguments: [String]) -> Never {
            print("A release build has no live editing.")
            exit(0)
        }
    }
#endif
