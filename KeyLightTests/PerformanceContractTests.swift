import XCTest

#if canImport(KeyLight)
@testable import KeyLight
#endif

final class PerformanceContractTests: XCTestCase {
    func testOneHundredThousandSyntheticTransitionsKeepRuntimeStateBounded() {
        var state = GlowInteractionState()
        state.setPreview(
            .preview(.settings, horizontalPosition: 0.5, keyWidth: 1),
            for: .settings
        )

        for index in 0..<100_000 {
            let keyCode = UInt16(index % 128)
            let target = GlowTarget.physicalKey(
                keyCode,
                horizontalPosition: Double(index % 100) / 100,
                keyWidth: 1
            )
            state.handle(
                .keyDown(
                    keyCode,
                    source: .eventTap,
                    timestamp: TimeInterval(index)
                ),
                target: target
            )
            state.handle(
                .keyUp(
                    keyCode,
                    source: .eventTap,
                    timestamp: TimeInterval(index) + 0.5
                )
            )
        }

        XCTAssertTrue(state.heldPhysicalKeyCodes.isEmpty)
        XCTAssertEqual(state.activePreviewSourcesInPriorityOrder, [.settings])
        XCTAssertEqual(state.resolvedTarget?.id, .preview(.settings))
    }

    func testNormalizedKeyboardEventHasNoCharacterOrTextSurface() {
        let event = KeyboardEvent.keyDown(
            42,
            source: .eventTap,
            timestamp: 1
        )
        let storedLabels = Set(Mirror(reflecting: event).children.compactMap(\.label))

        XCTAssertEqual(
            storedLabels,
            ["action", "canonicalKeyCode", "isRepeat", "sequence", "source", "timestamp"]
        )
        XCTAssertFalse(storedLabels.contains("character"))
        XCTAssertFalse(storedLabels.contains("text"))
    }
}
