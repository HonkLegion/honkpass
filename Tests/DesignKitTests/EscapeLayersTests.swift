@testable import DesignKit
import Testing

/// Escape closes the layer that opened last, and each layer once.
@Suite(.serialized) @MainActor struct EscapeLayersTests {
    @Test func escapeClosesTheLayerOnTopAndThenTheOneUnderIt() {
        var closed: [String] = []
        let dialog = BWEscapeLayers.Layer(), list = BWEscapeLayers.Layer()
        dialog.close = {
            closed.append("dialog")
            BWEscapeLayers.remove(dialog)
        }
        list.close = {
            closed.append("list")
            BWEscapeLayers.remove(list)
        }
        #expect(!BWEscapeLayers.closeTop())
        BWEscapeLayers.add(dialog)
        BWEscapeLayers.add(list)
        // A layer that is drawn again stays where it is in the order.
        BWEscapeLayers.add(list)
        #expect(BWEscapeLayers.closeTop() && closed == ["list"])
        #expect(BWEscapeLayers.closeTop() && closed == ["list", "dialog"])
        #expect(!BWEscapeLayers.closeTop() && closed == ["list", "dialog"])
    }

    @Test func aLayerThatWentAwayIsNotClosed() {
        var closed = 0
        let dialog = BWEscapeLayers.Layer()
        dialog.close = { closed += 1 }
        BWEscapeLayers.add(dialog)
        BWEscapeLayers.remove(dialog)
        #expect(!BWEscapeLayers.closeTop() && closed == 0)
        // Nor one whose view is gone without a word.
        var gone: BWEscapeLayers.Layer? = BWEscapeLayers.Layer()
        gone?.close = { closed += 1 }
        if let gone { BWEscapeLayers.add(gone) }
        gone = nil
        #expect(!BWEscapeLayers.closeTop() && closed == 0)
    }
}
