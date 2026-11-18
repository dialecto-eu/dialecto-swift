#if DEBUG && canImport(SwiftUI)
    import SwiftUI
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        import AppKit
    #else
        import UIKit
    #endif

    /// Dialecto's Coastal colours for the debug panel, light and dusk (the web app's tokens, the same hex
    /// values), and the brand pieces drawn natively: the Flor mark, the wordmark and the four-colour seam.
    enum Coastal {
        static let sea = pair(0x1C5C86, 0x4F93C2)
        static let brandDia = pair(0x184D70, 0xF3ECDB)
        static let terra = pair(0xC75D43, 0xDB6F54)
        static let terraText = pair(0xA44A35, 0xD3735A)
        static let gold = pair(0xE9A43C, 0xEDAB48)
        static let olive = pair(0x6E7F4E, 0x94A96B)
        static let oliveText = pair(0x5A6940, 0x87A15F)
        static let sky = pair(0x3E9AD1, 0x6CB8EA)

        static let cream = pair(0xFBF4E9, 0x1B1610)
        static let cream2 = pair(0xF3E7D2, 0x241D15)
        static let paper = pair(0xFFFFFF, 0x271F17)
        static let edge = pair(0xE4D4B8, 0x463B28)
        static let edgeSoft = pair(0xEFE3CC, 0x352B1D)

        static let ink = pair(0x33291F, 0xF3ECDB)
        static let ink2 = pair(0x6A5E4B, 0xCABB9F)
        static let mut = pair(0x7A6745, 0xAB9B78)

        /// Solid fills that carry white text (AA in both themes).
        static let buttonTerra = pair(0xBA563E, 0xB3523C)
        static let buttonSea = pair(0x1C5C86, 0x3A78A3)

        static let warnBackground = pair(0xFBF0D8, 0x342910)
        static let warnText = pair(0x855C11, 0xF0C87A)
        static let gapBackground = pair(0xF7E6DF, 0x341F17)
        static let infoBackground = pair(0xE7F1F8, 0x102733)
        static let okBackground = pair(0xEEF2DF, 0x242B18)

        private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
                Color(
                    nsColor: NSColor(name: nil) { appearance in
                        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? native(dark) : native(light)
                    })
            #else
                Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? native(dark) : native(light) })
            #endif
        }

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            static func native(_ hex: UInt32) -> NSColor {
                NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
        #else
            static func native(_ hex: UInt32) -> UIColor {
                UIColor(
                    red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
        #endif
    }

    /// The Flor, Dialecto's dahlia mark: ten terra petals, five coral ones and a gold heart, in the brand
    /// SVG's proportions (a 24-point box). The same colours in light and dark, as on the web.
    struct FlorMark: View {
        var size: CGFloat = 20

        var body: some View {
            Canvas { context, canvas in
                let scale = canvas.width / 24
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                func petals(count: Int, length: CGFloat, width: CGFloat, offset: Double, color: Color) {
                    for index in 0..<count {
                        let angle = Angle.degrees(offset + Double(index) * 360 / Double(count))
                        var petal = context
                        petal.translateBy(x: center.x, y: center.y)
                        petal.rotate(by: angle)
                        let rect = CGRect(x: -width * scale / 2, y: -length * scale, width: width * scale, height: length * scale)
                        petal.fill(Path(roundedRect: rect, cornerRadius: width * scale / 2), with: .color(color))
                    }
                }
                petals(count: 10, length: 11, width: 3.6, offset: 0, color: Color(red: 0.78, green: 0.365, blue: 0.263))
                let disc = CGRect(x: center.x - 6.5 * scale, y: center.y - 6.5 * scale, width: 13 * scale, height: 13 * scale)
                context.fill(Path(ellipseIn: disc), with: .color(Color(red: 0.78, green: 0.365, blue: 0.263)))
                petals(count: 5, length: 7.4, width: 3.8, offset: 0, color: Color(red: 0.91, green: 0.545, blue: 0.424))
                let heart = CGRect(x: center.x - 2.7 * scale, y: center.y - 2.7 * scale, width: 5.4 * scale, height: 5.4 * scale)
                context.fill(Path(ellipseIn: heart), with: .color(Color(red: 0.914, green: 0.643, blue: 0.235)))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }

    /// "dia" in the lockup's deep sea (cream at dusk) and "lecto" in terra, in a bold serif.
    struct Wordmark: View {
        var size: CGFloat = 17

        var body: some View {
            (Text(verbatim: "dia").foregroundStyle(Coastal.brandDia) + Text(verbatim: "lecto").foregroundStyle(Coastal.terra))
                .font(.system(size: size, weight: .bold, design: .serif))
                .tracking(-0.3)
                .accessibilityLabel(Text(verbatim: "Dialecto"))
        }
    }

    /// A solid Coastal button (the one terra call to action, or sea for a mode that is on). It keeps its
    /// colour when the panel is not the key window, where a tinted system button turns grey and the
    /// sign-in would no longer stand out.
    struct SolidButtonStyle: ButtonStyle {
        var fill: Color
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                #if os(macOS)
                    .frame(height: 26)
                #else
                    .frame(height: 34)
                #endif
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.black.opacity(configuration.isPressed ? 0.14 : 0)))
                )
                .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
        }
    }

    /// The quiet companion of `SolidButtonStyle`: paper, an edge line and ink text, at the same height.
    struct OutlineButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Coastal.ink)
                .padding(.horizontal, 10)
                #if os(macOS)
                    .frame(height: 26)
                #else
                    .frame(height: 34)
                #endif
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isPressed ? Coastal.cream2 : Coastal.paper))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Coastal.edge))
                .contentShape(Rectangle())
        }
    }

    /// The four-colour seam under a header: sea, terra, gold, olive, repeating.
    struct SeamLine: View {
        var height: CGFloat = 3

        var body: some View {
            Canvas { context, canvas in
                let colors = [Coastal.sea, Coastal.terra, Coastal.gold, Coastal.olive]
                var x: CGFloat = 0
                var index = 0
                while x < canvas.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 22, height: canvas.height)), with: .color(colors[index % 4]))
                    x += 22
                    index += 1
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
        }
    }
#endif
