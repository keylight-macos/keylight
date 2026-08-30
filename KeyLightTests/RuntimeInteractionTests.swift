import XCTest

#if canImport(KeyLight)
@testable import KeyLight
#endif

final class RuntimeInteractionTests: XCTestCase {
    private func target(
        _ keyCode: UInt16,
        position: Double? = nil
    ) -> GlowTarget {
        .physicalKey(
            keyCode,
            horizontalPosition: position ?? Double(keyCode) / 100,
            keyWidth: 1
        )
    }

    private func down(
        _ keyCode: UInt16,
        repeat isRepeat: Bool = false,
        timestamp: TimeInterval = 1
    ) -> KeyboardEvent {
        .keyDown(
            keyCode,
            isRepeat: isRepeat,
            source: .eventTap,
            timestamp: timestamp
        )
    }

    private func up(_ keyCode: UInt16) -> KeyboardEvent {
        .keyUp(keyCode, source: .eventTap, timestamp: 2)
    }

    func testNewestPhysicalKeyWinsAndReleaseRestoresMostRecentRemainingKey() {
        var state = GlowInteractionState()
        let first = target(10)
        let second = target(20)
        let third = target(30)

        state.handle(down(10), target: first)
        state.handle(down(20), target: second)
        let transition = state.handle(down(30), target: third)

        XCTAssertEqual(state.heldPhysicalKeyCodes, [10, 20, 30])
        XCTAssertEqual(
            state.activePhysicalTargetsInPressOrder,
            [first, second, third]
        )
        XCTAssertEqual(transition.previous, second)
        XCTAssertEqual(transition.current, third)

        let firstRelease = state.handle(up(30))
        XCTAssertEqual(firstRelease.previous, third)
        XCTAssertEqual(firstRelease.current, second)
        XCTAssertEqual(
            state.activePhysicalTargetsInPressOrder,
            [first, second]
        )

        let secondRelease = state.handle(up(20))
        XCTAssertEqual(secondRelease.current, first)

        let finalRelease = state.handle(up(10))
        XCTAssertNil(finalRelease.current)
        XCTAssertTrue(state.heldPhysicalKeyCodes.isEmpty)
    }

    func testDuplicateAndRepeatKeyDownAreIdempotentAndDoNotReorderHeldKeys() {
        var state = GlowInteractionState()
        let first = target(10)
        let second = target(20)

        state.handle(down(10), target: first)
        state.handle(down(20), target: second)

        let duplicate = state.handle(down(10), target: first)
        let repeated = state.handle(down(10, repeat: true), target: first)

        XCTAssertTrue(duplicate.isNoOp)
        XCTAssertTrue(repeated.isNoOp)
        XCTAssertEqual(state.heldPhysicalKeyCodes, [10, 20])
        XCTAssertEqual(state.resolvedTarget, second)
    }

    func testDuplicateDownCanRefreshStoredGeometryWithoutStealingPriority() {
        var state = GlowInteractionState()
        let updatedFirst = target(10, position: 0.75)

        state.handle(down(10), target: target(10, position: 0.1))
        state.handle(down(20), target: target(20))
        let suppressedUpdate = state.handle(down(10, repeat: true), target: updatedFirst)

        XCTAssertTrue(suppressedUpdate.isNoOp)
        XCTAssertEqual(state.heldPhysicalKeyCodes, [10, 20])

        state.handle(up(20))
        XCTAssertEqual(state.resolvedTarget, updatedFirst)
    }

    func testReleasingNonDominantOrUnknownKeyDoesNotChangeResolution() {
        var state = GlowInteractionState()
        state.handle(down(10), target: target(10))
        state.handle(down(20), target: target(20))

        XCTAssertTrue(state.handle(up(10)).isNoOp)
        XCTAssertTrue(state.handle(up(99)).isNoOp)
        XCTAssertEqual(state.heldPhysicalKeyCodes, [20])
        XCTAssertEqual(state.resolvedTarget, target(20))
    }

    func testPhysicalKeyBeatsEditorAndSettingsPreviews() {
        var state = GlowInteractionState()
        let settings = GlowTarget.preview(
            .settings,
            horizontalPosition: 0.5,
            keyWidth: 1
        )
        let editor = GlowTarget.preview(
            .keyEditor,
            colorReferenceKeyCode: 42,
            horizontalPosition: 0.25,
            keyWidth: 1.5
        )

        state.setPreview(settings, for: .settings)
        state.setPreview(editor, for: .keyEditor)

        XCTAssertEqual(state.activePreviewSourcesInPriorityOrder, [.keyEditor, .settings])
        XCTAssertEqual(state.resolvedTarget, editor)

        let physical = target(18)
        state.handle(down(18), target: physical)
        XCTAssertEqual(state.resolvedTarget, physical)
    }

    func testChordPreviewIsGroupedEphemeralAndBelowPhysicalInput() {
        var state = GlowInteractionState()
        let settings = GlowTarget.preview(.settings, horizontalPosition: 0.5, keyWidth: 1)
        let chordTargets = PreviewSource.chordTestSources.enumerated().map { index, source in
            GlowTarget.preview(
                source,
                colorReferenceKeyCode: UInt16(index),
                horizontalPosition: 0.3 + Double(index) * 0.1,
                keyWidth: 1
            )
        }
        state.setPreview(settings, for: .settings)

        state.replaceChordTestTargets(chordTargets)
        XCTAssertEqual(state.activeChordTestTargetsInSourceOrder, chordTargets)
        XCTAssertEqual(state.resolvedTarget, chordTargets.first)

        state.handle(down(18), target: target(18))
        XCTAssertEqual(state.resolvedTarget, target(18))
        state.handle(up(18))
        XCTAssertEqual(state.resolvedTarget, chordTargets.first)

        let transition = state.clearChordTestTargets()
        XCTAssertEqual(transition.current, settings)
        XCTAssertTrue(state.activeChordTestTargetsInSourceOrder.isEmpty)
    }

    func testEditorPreviewBeatsSettingsAndClearingItFallsBackToSettings() {
        var state = GlowInteractionState()
        let settings = GlowTarget.preview(
            .settings,
            horizontalPosition: 0.5,
            keyWidth: 1
        )
        let editor = GlowTarget.preview(
            .keyEditor,
            horizontalPosition: 0.2,
            keyWidth: 1
        )

        state.setPreview(settings, for: .settings)
        state.setPreview(editor, for: .keyEditor)
        let transition = state.clearPreview(.keyEditor)

        XCTAssertEqual(transition.previous, editor)
        XCTAssertEqual(transition.current, settings)
        XCTAssertEqual(state.resolvedTarget, settings)
    }

    func testPhysicalReleaseResumesStillActivePreview() {
        var state = GlowInteractionState()
        let settings = GlowTarget.preview(
            .settings,
            horizontalPosition: 0.5,
            keyWidth: 1
        )
        let physical = target(18)

        state.setPreview(settings, for: .settings)
        state.handle(down(18), target: physical)
        let transition = state.handle(up(18))

        XCTAssertEqual(transition.previous, physical)
        XCTAssertEqual(transition.current, settings)
    }

    func testStreamResetClearsPhysicalStateAndResumesPreview() {
        var state = GlowInteractionState()
        let editor = GlowTarget.preview(
            .keyEditor,
            horizontalPosition: 0.4,
            keyWidth: 1
        )

        state.setPreview(editor, for: .keyEditor)
        state.handle(down(10), target: target(10))
        state.handle(down(20), target: target(20))

        let transition = state.handle(.streamReset(source: .eventTap, timestamp: 3))

        XCTAssertEqual(transition.previous, target(20))
        XCTAssertEqual(transition.current, editor)
        XCTAssertTrue(state.heldPhysicalKeyCodes.isEmpty)
        XCTAssertEqual(state.activePreviewSourcesInPriorityOrder, [.keyEditor])
    }

    func testClearAllRemovesPhysicalAndPreviewState() {
        var state = GlowInteractionState()
        state.setPreview(
            .preview(.settings, horizontalPosition: 0.5, keyWidth: 1),
            for: .settings
        )
        state.handle(down(10), target: target(10))

        let transition = state.clearAll()

        XCTAssertEqual(transition.previous, target(10))
        XCTAssertNil(transition.current)
        XCTAssertTrue(state.heldPhysicalKeyCodes.isEmpty)
        XCTAssertTrue(state.activePreviewSourcesInPriorityOrder.isEmpty)
    }

    func testMismatchedPhysicalOrPreviewTargetIsIgnored() {
        var state = GlowInteractionState()

        XCTAssertTrue(state.handle(down(10), target: target(20)).isNoOp)
        XCTAssertTrue(
            state.setPreview(
                .preview(.settings, horizontalPosition: 0.5, keyWidth: 1),
                for: .keyEditor
            ).isNoOp
        )
        XCTAssertNil(state.resolvedTarget)
    }

    func testGlowTargetSanitizesGeometryAndCarriesOnlyColorReferenceCode() {
        let physical = GlowTarget.physicalKey(
            42,
            horizontalPosition: .nan,
            keyWidth: .infinity
        )
        let bounded = GlowTarget.preview(
            .keyEditor,
            colorReferenceKeyCode: 7,
            horizontalPosition: -3,
            keyWidth: 100
        )

        XCTAssertEqual(physical.id, .physicalKey(42))
        XCTAssertEqual(physical.colorReferenceKeyCode, 42)
        XCTAssertEqual(physical.horizontalPosition, 0.5)
        XCTAssertEqual(physical.keyWidth, 1)
        XCTAssertEqual(bounded.id, .preview(.keyEditor))
        XCTAssertEqual(bounded.colorReferenceKeyCode, 7)
        XCTAssertEqual(bounded.horizontalPosition, 0)
        XCTAssertEqual(bounded.keyWidth, 5)
    }

    func testKeyboardEventMetadataIsCanonicalAndSanitizesTimestamp() {
        let down = KeyboardEvent.keyDown(
            42,
            isRepeat: true,
            source: .consumerHID,
            timestamp: .nan
        )
        let reset = KeyboardEvent.streamReset(timestamp: -1)

        XCTAssertEqual(down.action, .down)
        XCTAssertEqual(down.canonicalKeyCode, 42)
        XCTAssertTrue(down.isRepeat)
        XCTAssertEqual(down.source, .consumerHID)
        XCTAssertEqual(down.timestamp, 0)

        XCTAssertEqual(reset.action, .streamReset)
        XCTAssertNil(reset.canonicalKeyCode)
        XCTAssertFalse(reset.isRepeat)
        XCTAssertEqual(reset.source, .lifecycle)
        XCTAssertEqual(reset.timestamp, 0)
    }
}
