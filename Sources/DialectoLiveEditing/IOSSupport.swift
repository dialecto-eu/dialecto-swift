#if DEBUG && canImport(UIKit) && !canImport(AppKit)
    import SwiftUI
    import UIKit

    /// Text under a tap, read from the app's accessibility elements. iOS builds that tree only when
    /// accessibility is on, so this finds nothing in a simulator or device with it off (the README gives
    /// the `simctl` command that turns it on for a simulator); the keys panel always works.
    @MainActor
    enum IOSHitTest {
        struct Found { var text: String; var frame: CGRect }

        /// `point` is in screen coordinates, as an element's `accessibilityFrame` is.
        static func text(at point: CGPoint, in root: UIWindow) -> String? {
            var found: [Found] = []
            collect(root, into: &found, depth: 0)
            return found.filter { $0.frame.contains(point) }
                .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.text
        }

        private static func collect(_ node: NSObject, into found: inout [Found], depth: Int) {
            guard depth < 24 else { return }
            if node.isAccessibilityElement {
                let text = [node.accessibilityValue, node.accessibilityLabel].compactMap { $0 }.first { !$0.isEmpty }
                if let text { found.append(Found(text: text, frame: node.accessibilityFrame)) }
                return
            }
            if let elements = node.accessibilityElements {
                for case let element as NSObject in elements { collect(element, into: &found, depth: depth + 1) }
                return
            }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = node.accessibilityElement(at: index) as? NSObject {
                        collect(element, into: &found, depth: depth + 1)
                    }
                }
                return
            }
            if let view = node as? UIView { for subview in view.subviews { collect(subview, into: &found, depth: depth + 1) } }
        }
    }

    /// A window above the app that lets every touch through except on its own controls and, in Edit text
    /// mode, a full-screen tap.
    final class DebugWindow: UIWindow {
        var capturing = false

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            if hit === rootViewController?.view { return capturing ? hit : nil }
            return hit
        }
    }

    /// The floating Dialecto button and, while Edit text is on, a sea frame round the screen.
    @MainActor
    final class IOSSupport: NSObject {
        private unowned let runtime: EditingRuntime
        private var window: DebugWindow?
        private let button = UIButton(type: .system)
        private let frameView = UIView()
        private weak var sheet: UIViewController?

        init(runtime: EditingRuntime) {
            self.runtime = runtime
            super.init()
        }

        func install() {
            attach()
            for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.attach() }
                }
            }
        }

        private var scene: UIWindowScene? {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
        }

        private func attach() {
            guard window == nil, let scene else { return }
            let overlay = DebugWindow(windowScene: scene)
            overlay.windowLevel = .alert + 1
            let controller = UIViewController()
            controller.view.backgroundColor = .clear
            overlay.rootViewController = controller

            frameView.isUserInteractionEnabled = false
            frameView.layer.borderWidth = 4
            frameView.layer.borderColor = Coastal.native(0x1C5C86).cgColor
            frameView.isHidden = true
            frameView.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(frameView)
            NSLayoutConstraint.activate([
                frameView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
                frameView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
                frameView.topAnchor.constraint(equalTo: controller.view.topAnchor),
                frameView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            ])

            styleButton(editing: false)
            button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
                button.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            ])
            controller.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))

            overlay.isHidden = false
            window = overlay
        }

        private static let flor: UIImage? = {
            let renderer = ImageRenderer(content: FlorMark(size: 20))
            renderer.scale = 3
            return renderer.uiImage?.withRenderingMode(.alwaysOriginal)
        }()

        /// Off: a paper capsule with the Flor and "Dialecto". On: a sea capsule, "Editing text" and a close mark.
        private func styleButton(editing: Bool) {
            var configuration = UIButton.Configuration.filled()
            configuration.cornerStyle = .capsule
            configuration.imagePadding = 6
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 14)
            var title = AttributedString(editing ? "Editing text" : "Dialecto")
            title.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            configuration.attributedTitle = title
            if editing {
                configuration.image = UIImage(systemName: "xmark.circle.fill")
                configuration.baseBackgroundColor = Coastal.native(0x1C5C86)
                configuration.baseForegroundColor = .white
                configuration.background.strokeWidth = 0
            } else {
                configuration.image = Self.flor
                configuration.baseBackgroundColor = UIColor { $0.userInterfaceStyle == .dark ? Coastal.native(0x271F17) : .white }
                configuration.baseForegroundColor = UIColor { $0.userInterfaceStyle == .dark ? Coastal.native(0xF3ECDB) : Coastal.native(0x33291F) }
                configuration.background.strokeColor = UIColor { $0.userInterfaceStyle == .dark ? Coastal.native(0x463B28) : Coastal.native(0xE4D4B8) }
                configuration.background.strokeWidth = 1
            }
            button.configuration = configuration
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.16
            button.layer.shadowRadius = 8
            button.layer.shadowOffset = CGSize(width: 0, height: 3)
            button.accessibilityLabel = editing ? "Stop editing text" : "Dialecto keys"
        }

        @objc private func buttonTapped() {
            if runtime.editState.isOn {
                runtime.editState.isOn = false
            } else {
                present()
            }
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard runtime.editState.isOn, let overlay = window, let screen = overlay.windowScene?.screen else { return }
            let point = overlay.convert(recognizer.location(in: overlay), to: screen.coordinateSpace)
            runtime.pick(text: text(atScreenPoint: point))
        }

        func text(atScreenPoint point: CGPoint) -> String? {
            guard let scene = window?.windowScene,
                let app = scene.windows.first(where: { $0 !== window && $0.isKeyWindow })
                    ?? scene.windows.first(where: { $0 !== window })
            else { return nil }
            return IOSHitTest.text(at: point, in: app)
        }

        func setCapturing(_ on: Bool) {
            window?.capturing = on
            frameView.isHidden = !on
            styleButton(editing: on)
            // The sheet would cover the text to tap.
            if on, let sheet { sheet.dismiss(animated: true) }
        }

        func present() {
            guard sheet == nil, let scene = window?.windowScene ?? self.scene,
                let app = scene.windows.first(where: { $0 !== window && $0.isKeyWindow })
                    ?? scene.windows.first(where: { $0 !== window })
            else { return }
            var top = app.rootViewController
            while let next = top?.presentedViewController { top = next }
            let panel = KeysPanel(
                model: runtime.model, session: runtime.session, editMode: runtime.editState,
                open: { [weak runtime] row in runtime?.openEditor(key: row.key) },
                openProject: { [weak runtime] in runtime?.openProject() },
                close: { [weak top] in top?.dismiss(animated: true) })
            runtime.model.refresh()
            let host = PanelHostController(rootView: panel)
            // The button sits in a window above the sheet; it comes back when the sheet goes.
            button.isHidden = true
            host.onGone = { [weak self] in self?.button.isHidden = false }
            host.modalPresentationStyle = .pageSheet
            if let controller = host.sheetPresentationController {
                controller.detents = [.medium(), .large()]
                controller.prefersGrabberVisible = true
            }
            sheet = host
            top?.present(host, animated: true)
        }
    }

    final class PanelHostController: UIHostingController<KeysPanel> {
        var onGone: (() -> Void)?

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            onGone?()
        }
    }

    extension EditingRuntime {
        static func openInBrowser(_ url: URL) { UIApplication.shared.open(url) }

        func installPlatform() {
            let support = IOSSupport(runtime: self)
            platform = support
            support.install()
        }

        func showPanel() { (platform as? IOSSupport)?.present() }

        func editModeChanged(_ on: Bool) { (platform as? IOSSupport)?.setCapturing(on) }

        func pickText(atScreenPoint x: Double, _ y: Double) {
            pick(text: (platform as? IOSSupport)?.text(atScreenPoint: CGPoint(x: x, y: y)))
        }

        func snapshotPanel(to url: URL) -> Bool { false }
    }
#endif
