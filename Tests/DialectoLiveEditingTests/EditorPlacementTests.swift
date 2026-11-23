#if DEBUG && canImport(AppKit)
    import Foundation
    import Testing

    @testable import DialectoLiveEditing

    /// Where the floating editor goes beside the text: the side with room, flipped to stay on screen.
    struct EditorPlacementTests {
        private let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
        private let card = CGSize(width: 340, height: 260)

        @Test func goesLeftOfTextOnTheRightWithItsArrowOnItsRightEdge() {
            let anchor = CGRect(x: 600, y: 400, width: 400, height: 32)
            let placed = EditorPlacement.place(card: card, anchor: anchor, in: screen, prefersBelow: false)
            #expect(placed.side == .right)
            #expect(placed.card.maxX == anchor.minX - EditorPlacement.gap)
            // The arrow points at the text's middle.
            #expect(abs((placed.card.maxY - placed.offset) - anchor.midY) < 0.5)
        }

        @Test func goesRightOfTextOnTheLeft() {
            let anchor = CGRect(x: 80, y: 400, width: 200, height: 20)
            let placed = EditorPlacement.place(card: card, anchor: anchor, in: screen, prefersBelow: false)
            #expect(placed.side == .left)
            #expect(placed.card.minX == anchor.maxX + EditorPlacement.gap)
        }

        @Test func flipsBelowWhenNeitherSideHasRoom() {
            let anchor = CGRect(x: 100, y: 500, width: 1080, height: 20)
            let placed = EditorPlacement.place(card: card, anchor: anchor, in: screen, prefersBelow: false)
            #expect(placed.side == .top)
            #expect(placed.card.maxY == anchor.minY - EditorPlacement.gap)
        }

        @Test func aTooltipGoesBelowItsControl() {
            let anchor = CGRect(x: 830, y: 700, width: 26, height: 26)
            let placed = EditorPlacement.place(card: card, anchor: anchor, in: screen, prefersBelow: true)
            #expect(placed.side == .top)
            #expect(abs((placed.card.minX + placed.offset) - anchor.midX) < 0.5)
        }

        @Test func flipsAboveAtTheBottomOfTheScreen() {
            let anchor = CGRect(x: 100, y: 40, width: 1080, height: 20)
            let placed = EditorPlacement.place(card: card, anchor: anchor, in: screen, prefersBelow: true)
            #expect(placed.side == .bottom)
            #expect(placed.card.minY == anchor.maxY + EditorPlacement.gap)
        }

        @Test func staysOnScreenNearTheTop() {
            let anchor = CGRect(x: 700, y: 770, width: 200, height: 20)
            let placed = EditorPlacement.place(card: card, anchor: anchor, in: screen, prefersBelow: false)
            #expect(placed.card.maxY <= screen.maxY - EditorPlacement.inset)
        }

        @Test func aTallerCardKeepsItsTopAndStaysOnScreen() {
            let anchor = CGRect(x: 600, y: 300, width: 400, height: 32)
            let first = EditorPlacement.place(card: card, anchor: anchor, in: screen, prefersBelow: false)
            let taller = EditorPlacement.resize(first, to: CGSize(width: 340, height: 320), anchor: anchor, in: screen)
            #expect(taller.card.maxY == first.card.maxY)
            #expect(taller.side == first.side)
            let tallest = EditorPlacement.resize(first, to: CGSize(width: 340, height: 700), anchor: anchor, in: screen)
            #expect(tallest.card.minY >= screen.minY + EditorPlacement.inset)
        }
    }
#endif
