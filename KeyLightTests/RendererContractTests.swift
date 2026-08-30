import XCTest
import CoreGraphics
import AppKit
import MetalKit
import SwiftUI
@testable import KeyLight

final class LiquidGlassTransitionMathTests: XCTestCase {
    func testMotionProfileScalesEveryInteractivePhaseWithFadeDuration() {
        let fast = LiquidGlassMotionProfile(fadeDuration: 0.12)
        let standard = LiquidGlassMotionProfile(fadeDuration: 1)
        let slow = LiquidGlassMotionProfile(fadeDuration: 2)

        XCTAssertEqual(fast.fadeOutDuration, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(standard.fadeOutDuration, 1, accuracy: 0.000_001)
        XCTAssertEqual(slow.fadeOutDuration, 2, accuracy: 0.000_001)

        XCTAssertLessThan(fast.revealDuration, standard.revealDuration)
        XCTAssertLessThan(standard.revealDuration, slow.revealDuration)
        XCTAssertLessThan(fast.nearbyMorphDuration, standard.nearbyMorphDuration)
        XCTAssertLessThan(standard.nearbyMorphDuration, slow.nearbyMorphDuration)
        XCTAssertLessThan(
            fast.travelDuration(normalizedDistance: 1),
            standard.travelDuration(normalizedDistance: 1)
        )
        XCTAssertLessThan(
            standard.travelDuration(normalizedDistance: 1),
            slow.travelDuration(normalizedDistance: 1)
        )
    }

    func testDistantTravelIsSlowerThanAdjacentMorphButRemainsBounded() {
        let profile = LiquidGlassMotionProfile(fadeDuration: 1)

        XCTAssertGreaterThan(
            profile.travelDuration(normalizedDistance: 1),
            profile.nearbyMorphDuration
        )
        XCTAssertGreaterThan(
            profile.travelDuration(normalizedDistance: 1),
            profile.travelDuration(normalizedDistance: 0)
        )
        XCTAssertLessThanOrEqual(profile.travelDuration(normalizedDistance: 100), 0.64)
        XCTAssertGreaterThanOrEqual(profile.travelDuration(normalizedDistance: -.infinity), 0.06)
    }

    func testFlowExpansionVelocityIsFiniteDistanceSensitiveAndBounded() {
        let short = LiquidGlassTransitionMath.flowExpansionVelocity(
            distance: 40,
            duration: 0.2,
            containerWidth: 1_000
        )
        let long = LiquidGlassTransitionMath.flowExpansionVelocity(
            distance: 800,
            duration: 0.2,
            containerWidth: 1_000
        )

        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short)
        XCTAssertLessThanOrEqual(long, 15_000)
        XCTAssertEqual(
            LiquidGlassTransitionMath.flowExpansionVelocity(
                distance: .nan,
                duration: 0.2,
                containerWidth: 1_000
            ),
            0
        )
    }

    func testMergeDecisionIsLeftRightSymmetric() {
        let left = CGRect(x: 120, y: -8, width: 70, height: 30)
        let closeRight = CGRect(x: 205, y: -8, width: 90, height: 30)
        let farRight = CGRect(x: 260, y: -8, width: 90, height: 30)
        let spacing: CGFloat = 18

        XCTAssertTrue(LiquidGlassTransitionMath.shouldMerge(left, with: closeRight, spacing: spacing))
        XCTAssertTrue(LiquidGlassTransitionMath.shouldMerge(closeRight, with: left, spacing: spacing))
        XCTAssertFalse(LiquidGlassTransitionMath.shouldMerge(left, with: farRight, spacing: spacing))
        XCTAssertFalse(LiquidGlassTransitionMath.shouldMerge(farRight, with: left, spacing: spacing))
    }

    func testConnectedFrameGroupsMergeAdjacentAndKeepDistantKeysSeparate() {
        let frames = [
            CGRect(x: 100, y: -8, width: 90, height: 30),
            CGRect(x: 180, y: -8, width: 90, height: 30),
            CGRect(x: 500, y: -8, width: 90, height: 30)
        ]

        XCTAssertEqual(
            LiquidGlassTransitionMath.connectedFrameGroups(
                frames,
                spacing: 18
            ),
            [[0, 1], [2]]
        )
    }

    func testConnectedFrameGroupsAreTransitiveAndOrderedLeftToRight() {
        let frames = [
            CGRect(x: 250, y: -8, width: 80, height: 30),
            CGRect(x: 90, y: -8, width: 80, height: 30),
            CGRect(x: 170, y: -8, width: 80, height: 30)
        ]

        XCTAssertEqual(
            LiquidGlassTransitionMath.connectedFrameGroups(
                frames,
                spacing: 0
            ),
            [[1, 2, 0]]
        )
    }

    func testConnectedFrameGroupsDoNotMergeInvalidGeometry() {
        let frames = [
            CGRect(x: 0, y: 0, width: 80, height: 30),
            CGRect(x: CGFloat.nan, y: 0, width: 80, height: 30)
        ]

        XCTAssertEqual(
            LiquidGlassTransitionMath.connectedFrameGroups(
                frames,
                spacing: 18
            ).map(Set.init),
            [Set([0]), Set([1])]
        )
    }

    func testBezelGeometryIsShallowWideAndConnectedToTheBottomEdge() {
        let expanded = LiquidGlassTransitionMath.bezelFrame(
            in: CGRect(x: 0, y: 0, width: 1_000, height: 120),
            position: 0.5,
            baseKeyWidth: 60,
            keyWidth: 1,
            widthMultiplier: 1,
            glowHeight: 80
        )
        XCTAssertEqual(expanded.midX, 500, accuracy: 0.000_001)
        XCTAssertEqual(expanded.height, 23, accuracy: 0.000_001)
        XCTAssertGreaterThan(expanded.width / expanded.height, 6)
        XCTAssertLessThan(expanded.width / expanded.height, 9)
        XCTAssertLessThan(expanded.minY, 0)
        XCTAssertEqual(expanded.maxY, expanded.height * 0.72, accuracy: 0.000_001)
    }

    func testSmoothnessAggressivelyControlsTheWaveFootprint() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 120)
        let compact = LiquidGlassTransitionMath.bezelFrame(
            in: bounds,
            position: 0.5,
            baseKeyWidth: 60,
            keyWidth: 1,
            widthMultiplier: 1,
            glowHeight: 80,
            smoothness: 0
        )
        let middle = LiquidGlassTransitionMath.bezelFrame(
            in: bounds,
            position: 0.5,
            baseKeyWidth: 60,
            keyWidth: 1,
            widthMultiplier: 1,
            glowHeight: 80,
            smoothness: 0.5
        )
        let broad = LiquidGlassTransitionMath.bezelFrame(
            in: bounds,
            position: 0.5,
            baseKeyWidth: 60,
            keyWidth: 1,
            widthMultiplier: 1,
            glowHeight: 80,
            smoothness: 1
        )

        XCTAssertEqual(
            LiquidGlassTransitionMath.smoothnessWidthScale(0),
            0.36,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LiquidGlassTransitionMath.smoothnessWidthScale(1),
            1,
            accuracy: 0.000_001
        )
        XCTAssertLessThan(compact.width, middle.width)
        XCTAssertLessThan(middle.width, broad.width)
        XCTAssertLessThanOrEqual(compact.width / broad.width, 0.37)
        XCTAssertLessThanOrEqual(middle.width / broad.width, 0.52)
    }

    func testBezelHeightSupportsTinyBumpsAndCapsTheLargestSavedValue() {
        XCTAssertEqual(
            LiquidGlassTransitionMath.bezelHeight(glowHeight: 4, containerHeight: 120),
            4,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LiquidGlassTransitionMath.bezelHeight(glowHeight: 80, containerHeight: 120),
            23,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LiquidGlassTransitionMath.bezelHeight(glowHeight: 200, containerHeight: 120),
            53,
            accuracy: 0.000_001
        )
    }

    func testTransitionPlannerSanitizesInvalidNumericInputs() {
        XCTAssertFalse(
            LiquidGlassTransitionMath.shouldMerge(
                CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                with: CGRect(x: 0, y: 0, width: 10, height: 10),
                spacing: 18
            )
        )
    }
}

final class SurfaceMotionEngineTests: XCTestCase {
    func testInjectedClockAndTrackIdentityAreDeterministic() {
        let clock = ClosureSurfaceMotionClock { 42.25 }
        var engine = SurfaceMotionEngine(clock: clock)
        let first = SurfaceMotionTrack(id: .physicalKey(7))
        var duplicate = SurfaceMotionTrack(id: .physicalKey(7))
        duplicate.state.frame = CGRect(x: 900, y: 0, width: 10, height: 10)

        engine.setTracks([first, duplicate])

        XCTAssertEqual(engine.currentTime, 42.25, accuracy: 0.000_001)
        XCTAssertEqual(engine.tracks.count, 1)
        XCTAssertEqual(engine.tracks[0].state.frame, .zero)
    }

    func testHermiteRetargetStartsWithoutAPositionOrVelocityDiscontinuity() {
        let id = GlowID.physicalKey(8)
        let start = SurfaceMotionState(
            id: id,
            frame: CGRect(x: 100, y: 0, width: 80, height: 30),
            visibility: 1,
            emergence: 1,
            smoothness: 0.7,
            isVisible: true
        )
        var destination = start
        destination.frame.origin.x = 420
        let first = SurfaceMotionTransition(
            start: start,
            destination: destination,
            initialVelocity: .zero,
            startTime: 10,
            duration: 1
        )
        let retargetTime = 10.4
        let handoff = first.sample(at: retargetTime)
        var secondDestination = handoff.state
        secondDestination.frame.origin.x = 680
        let second = SurfaceMotionTransition(
            start: handoff.state,
            destination: secondDestination,
            initialVelocity: handoff.velocity,
            startTime: retargetTime,
            duration: 0.5
        )

        let firstSecondSample = second.sample(at: retargetTime)
        XCTAssertEqual(firstSecondSample.state.frame, handoff.state.frame)
        XCTAssertEqual(
            firstSecondSample.velocity.frame.origin.x,
            handoff.velocity.frame.origin.x,
            accuracy: 0.000_001
        )
    }
}

final class LiquidGlassMaterialMathTests: XCTestCase {
    func testNormalDisplayOpacityMatchesTheSavedSliderExactly() {
        for percentage in stride(from: 5, through: 100, by: 5) {
            let userOpacity = Float(percentage) / 100
            XCTAssertEqual(
                LiquidGlassMaterialMath.displayOpacity(
                    userOpacity: userOpacity,
                    reduceTransparency: false,
                    increaseContrast: false
                ),
                userOpacity,
                accuracy: 0.000_001
            )
        }
    }

    func testAccessibilityOpacityFloorsAreExactAndReduceTransparencyWins() {
        XCTAssertEqual(
            LiquidGlassMaterialMath.displayOpacity(
                userOpacity: 0,
                reduceTransparency: false,
                increaseContrast: false
            ),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LiquidGlassMaterialMath.displayOpacity(
                userOpacity: 0,
                reduceTransparency: false,
                increaseContrast: true
            ),
            0.30,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LiquidGlassMaterialMath.displayOpacity(
                userOpacity: 0,
                reduceTransparency: true,
                increaseContrast: true
            ),
            0.45,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LiquidGlassMaterialMath.displayOpacity(
                userOpacity: 0.8,
                reduceTransparency: true,
                increaseContrast: true
            ),
            0.8,
            accuracy: 0.000_001
        )
    }

    func testDisplayOpacityBoundsInvalidInputs() {
        let displayOpacity = LiquidGlassMaterialMath.displayOpacity(
            userOpacity: .nan,
            reduceTransparency: false,
            increaseContrast: false
        )

        XCTAssertTrue(displayOpacity.isFinite)
        XCTAssertTrue((0...1).contains(displayOpacity))
    }

    func testLowBodyOpacityStrengthensPrismaticEdgesIndependently() {
        let clearLensEdge = LiquidGlassMaterialMath.prismaticEdgeOpacity(
            userOpacity: 0.05,
            reduceTransparency: false,
            increaseContrast: false
        )
        let frostedEdge = LiquidGlassMaterialMath.prismaticEdgeOpacity(
            userOpacity: 1,
            reduceTransparency: false,
            increaseContrast: false
        )

        XCTAssertGreaterThan(clearLensEdge, 0.9)
        XCTAssertLessThan(frostedEdge, 0.3)
        XCTAssertGreaterThan(clearLensEdge, frostedEdge)
        XCTAssertEqual(
            LiquidGlassMaterialMath.displayOpacity(
                userOpacity: 0.05,
                reduceTransparency: false,
                increaseContrast: false
            ),
            0.05,
            accuracy: 0.000_001
        )
    }

    func testLowBodyOpacityPreservesClearLensingAndUsesEdgeDisplacement() {
        let clearLens = LiquidGlassMaterialMath.clearLensOpacity(
            userOpacity: 0.05,
            reduceTransparency: false,
            increaseContrast: false
        )
        let frostedLens = LiquidGlassMaterialMath.clearLensOpacity(
            userOpacity: 1,
            reduceTransparency: false,
            increaseContrast: false
        )
        let clearDimming = LiquidGlassMaterialMath.localizedDimmingOpacity(
            userOpacity: 0.05,
            reduceTransparency: false,
            increaseContrast: false
        )
        let frostedDimming = LiquidGlassMaterialMath.localizedDimmingOpacity(
            userOpacity: 1,
            reduceTransparency: false,
            increaseContrast: false
        )
        let clearEdge = LiquidGlassMaterialMath.prismaticEdgeOpacity(
            userOpacity: 0.05,
            reduceTransparency: false,
            increaseContrast: false
        )
        let frostedEdge = LiquidGlassMaterialMath.prismaticEdgeOpacity(
            userOpacity: 1,
            reduceTransparency: false,
            increaseContrast: false
        )

        XCTAssertGreaterThan(clearLens, 0.95)
        XCTAssertLessThan(frostedLens, 0.7)
        XCTAssertGreaterThan(clearLens, frostedLens)
        XCTAssertLessThan(clearDimming, 0.03)
        XCTAssertGreaterThan(frostedDimming, 0.18)
        XCTAssertGreaterThan(
            LiquidGlassMaterialMath.chromaticDisplacement(edgeOpacity: clearEdge),
            1.8
        )
        XCTAssertLessThan(
            LiquidGlassMaterialMath.chromaticDisplacement(edgeOpacity: frostedEdge),
            1
        )
    }

    func testClearLensAccessibilityTreatmentRemainsBounded() {
        let lens = LiquidGlassMaterialMath.clearLensOpacity(
            userOpacity: 0,
            reduceTransparency: true,
            increaseContrast: true
        )
        let dimming = LiquidGlassMaterialMath.localizedDimmingOpacity(
            userOpacity: 0,
            reduceTransparency: true,
            increaseContrast: true
        )
        let displacement = LiquidGlassMaterialMath.chromaticDisplacement(
            edgeOpacity: .nan
        )

        XCTAssertEqual(lens, 0.72, accuracy: 0.000_001)
        XCTAssertEqual(dimming, 0.28, accuracy: 0.000_001)
        XCTAssertTrue(displacement.isFinite)
        XCTAssertTrue((0...2.35).contains(displacement))
    }

    func testPrismaticEdgeAccessibilityAdjustmentsRemainBounded() {
        let edge = LiquidGlassMaterialMath.prismaticEdgeOpacity(
            userOpacity: 0.95,
            reduceTransparency: true,
            increaseContrast: true
        )

        XCTAssertEqual(edge, 0.48, accuracy: 0.000_001)
        XCTAssertTrue((0...1).contains(edge))
        XCTAssertTrue(
            LiquidGlassMaterialMath.prismaticEdgeOpacity(
                userOpacity: .nan,
                reduceTransparency: false,
                increaseContrast: false
            ).isFinite
        )
    }
}

final class GlowInteractionCompatibilityTests: XCTestCase {
    private let settingsTarget = GlowTarget.preview(
        .settings,
        horizontalPosition: 0.5,
        keyWidth: 1
    )
    private let editorTarget = GlowTarget.preview(
        .keyEditor,
        colorReferenceKeyCode: 42,
        horizontalPosition: 0.25,
        keyWidth: 1.5
    )

    func testKeyEditorWinsWhileBothPreviewSourcesAreActive() {
        var state = GlowInteractionState()
        state.setPreview(settingsTarget, for: .settings)
        state.setPreview(editorTarget, for: .keyEditor)

        XCTAssertEqual(state.resolvedTarget, editorTarget)
    }

    func testPhysicalKeySuppressesPreviewAndReleaseResumesHighestPrioritySource() {
        var state = GlowInteractionState()
        state.setPreview(settingsTarget, for: .settings)
        state.setPreview(editorTarget, for: .keyEditor)
        let physicalTarget = GlowTarget.physicalKey(
            18,
            horizontalPosition: 0.75,
            keyWidth: 1
        )

        state.handle(
            .keyDown(18, source: .eventTap, timestamp: 1),
            target: physicalTarget
        )
        XCTAssertEqual(state.resolvedTarget, physicalTarget)

        state.handle(.keyUp(18, source: .eventTap, timestamp: 2))
        XCTAssertEqual(state.resolvedTarget, editorTarget)
    }

    func testClosingEditorFallsBackToStillActiveSettingsPreview() {
        var state = GlowInteractionState()
        state.setPreview(settingsTarget, for: .settings)
        state.setPreview(editorTarget, for: .keyEditor)

        state.clearPreview(.keyEditor)
        XCTAssertEqual(state.resolvedTarget, settingsTarget)

        state.clearPreview(.settings)
        XCTAssertNil(state.resolvedTarget)
    }

    func testRandomColorReferenceFollowsResolvedPhysicalOrPreviewTarget() {
        var state = GlowInteractionState()
        state.setPreview(editorTarget, for: .keyEditor)
        XCTAssertEqual(state.resolvedTarget?.colorReferenceKeyCode, 42)

        let physicalTarget = GlowTarget.physicalKey(
            77,
            horizontalPosition: 0.75,
            keyWidth: 1
        )
        state.handle(
            .keyDown(77, source: .eventTap, timestamp: 1),
            target: physicalTarget
        )
        XCTAssertEqual(state.resolvedTarget?.colorReferenceKeyCode, 77)

        state.handle(.keyUp(77, source: .eventTap, timestamp: 2))
        XCTAssertEqual(state.resolvedTarget?.colorReferenceKeyCode, 42)
    }
}

final class KeyEditorGlowPreviewSessionTests: XCTestCase {
    @MainActor
    func testNewPreviewCancelsAStaleScheduledHide() {
        var shownKeyCodes: [UInt16] = []
        var hideCount = 0
        let session = KeyEditorGlowPreviewSession(
            show: { keyCode, _, _ in shownKeyCodes.append(keyCode) },
            hide: { hideCount += 1 }
        )

        session.show(keyCode: 1, position: 0.2, keyWidth: 1)
        session.scheduleHide(after: 0.03)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        session.show(keyCode: 2, position: 0.8, keyWidth: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))

        XCTAssertEqual(shownKeyCodes, [1, 2])
        XCTAssertEqual(hideCount, 0)

        session.scheduleHide(after: 0.01)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(hideCount, 1)
    }

    @MainActor
    func testStoppingSessionCancelsPendingWorkAndHidesImmediately() {
        var hideCount = 0
        let session = KeyEditorGlowPreviewSession(
            show: { _, _, _ in },
            hide: { hideCount += 1 }
        )

        session.show(keyCode: 3, position: 0.5, keyWidth: 1)
        session.scheduleHide(after: 0.03)
        session.stop()
        XCTAssertEqual(hideCount, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(hideCount, 1)
    }
}

final class SettingsGlowPreviewSessionTests: XCTestCase {
    @MainActor
    func testRepeatedChangesCancelTheStaleHide() {
        var showCount = 0
        var hideCount = 0
        let session = SettingsGlowPreviewSession(
            hideDelay: 0.03,
            show: { showCount += 1 },
            hide: { hideCount += 1 }
        )

        session.configurationChanged(isEnabled: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        session.configurationChanged(isEnabled: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertEqual(showCount, 2)
        XCTAssertEqual(hideCount, 0)

        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(hideCount, 1)
    }

    @MainActor
    func testSliderEditingKeepsPreviewAliveUntilInteractionEnds() {
        var showCount = 0
        var hideCount = 0
        let session = SettingsGlowPreviewSession(
            hideDelay: 0.01,
            show: { showCount += 1 },
            hide: { hideCount += 1 }
        )

        session.editingChanged(true, isEnabled: true)
        session.configurationChanged(isEnabled: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        XCTAssertEqual(showCount, 2)
        XCTAssertEqual(hideCount, 0)

        session.editingChanged(false, isEnabled: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(showCount, 3)
        XCTAssertEqual(hideCount, 1)
    }

    @MainActor
    func testDisableAndStopHideImmediatelyWithoutStaleCallbacks() {
        var hideCount = 0
        let session = SettingsGlowPreviewSession(
            hideDelay: 0.02,
            show: {},
            hide: { hideCount += 1 }
        )

        session.configurationChanged(isEnabled: true)
        session.configurationChanged(isEnabled: false)
        XCTAssertEqual(hideCount, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(hideCount, 1)

        session.configurationChanged(isEnabled: true)
        session.stop()
        XCTAssertEqual(hideCount, 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(hideCount, 2)
    }
}

final class OverlayRendererStaleStateTests: XCTestCase {
    @MainActor
    func testClassicRendererKeepsEveryHeldKeyAndReleasesOnlyItsOwnSurface() throws {
        let window = GlowOverlayWindow(contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120))
        defer { window.close() }
        let renderer = try XCTUnwrap(window.glowRenderer as? GlowView)

        renderer.show(.physicalKey(40, horizontalPosition: 0.25, keyWidth: 1))
        renderer.show(.physicalKey(41, horizontalPosition: 0.75, keyWidth: 1))
        let glowLayers = try XCTUnwrap(renderer.view.layer?.sublayers)
        XCTAssertTrue(renderer.supportsConcurrentPhysicalTargets)
        XCTAssertEqual(glowLayers.count, 2)
        XCTAssertTrue(renderer.refresh(.physicalKey(40)))
        XCTAssertTrue(renderer.refresh(.physicalKey(41)))

        renderer.hide(.physicalKey(40))
        XCTAssertFalse(renderer.refresh(.physicalKey(40)))
        XCTAssertTrue(renderer.refresh(.physicalKey(41)))
        XCTAssertNotNil(glowLayers[0].animation(forKey: "fadeOut"))
        XCTAssertNil(glowLayers[1].animation(forKey: "fadeOut"))

        renderer.hide(.physicalKey(41))
        XCTAssertNotNil(glowLayers[1].animation(forKey: "fadeOut"))

        renderer.clear()
        for glowLayer in glowLayers {
            XCTAssertEqual(glowLayer.opacity, 0)
            XCTAssertNil(glowLayer.animation(forKey: "fadeOut"))
        }
        XCTAssertTrue(renderer.view.layer?.sublayers?.isEmpty ?? true)
    }

    @MainActor
    func testClassicRendererKeepsThreeKeyChordAliveConcurrently() throws {
        let window = GlowOverlayWindow(contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120))
        defer { window.close() }
        let renderer = try XCTUnwrap(window.glowRenderer as? GlowView)
        let ids = [GlowID.physicalKey(40), .physicalKey(41), .physicalKey(42)]

        renderer.show(.physicalKey(40, horizontalPosition: 0.2, keyWidth: 1))
        renderer.show(.physicalKey(41, horizontalPosition: 0.5, keyWidth: 1))
        renderer.show(.physicalKey(42, horizontalPosition: 0.8, keyWidth: 1))

        XCTAssertEqual(renderer.view.layer?.sublayers?.count, 3)
        XCTAssertTrue(ids.allSatisfy(renderer.refresh))

        renderer.hide(.physicalKey(41))

        XCTAssertTrue(renderer.refresh(.physicalKey(40)))
        XCTAssertFalse(renderer.refresh(.physicalKey(41)))
        XCTAssertTrue(renderer.refresh(.physicalKey(42)))
    }

    @MainActor
    func testClassicRendererReusesTheRetreatingSurfaceForSequentialTyping() throws {
        let window = GlowOverlayWindow(contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120))
        defer { window.close() }
        let renderer = try XCTUnwrap(window.glowRenderer as? GlowView)

        renderer.show(.physicalKey(40, horizontalPosition: 0.25, keyWidth: 1))
        let originalLayer = try XCTUnwrap(renderer.view.layer?.sublayers?.first)
        renderer.hide(.physicalKey(40))
        XCTAssertNotNil(originalLayer.animation(forKey: "fadeOut"))

        renderer.show(.physicalKey(41, horizontalPosition: 0.75, keyWidth: 1))

        let activeLayers = try XCTUnwrap(renderer.view.layer?.sublayers)
        XCTAssertEqual(activeLayers.count, 1)
        XCTAssertTrue(activeLayers[0] === originalLayer)
        XCTAssertNotNil(originalLayer.animation(forKey: "slidePosition"))
        XCTAssertNil(originalLayer.animation(forKey: "fadeOut"))
        XCTAssertFalse(renderer.refresh(.physicalKey(40)))
        XCTAssertTrue(renderer.refresh(.physicalKey(41)))
    }

    @MainActor
    func testClassicRendererAppliesConfigurationAtomically() throws {
        let window = GlowOverlayWindow(contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120))
        defer { window.close() }
        let renderer = try XCTUnwrap(window.glowRenderer)

        renderer.show(.preview(.settings, horizontalPosition: 0.5, keyWidth: 1))
        renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                glowHeight: 80,
                widthMultiplier: 1.5,
                maximumOpacity: 0.45,
                fadeDuration: 0.8,
                roundness: 0.6,
                fullness: 0.4
            )
        )
        let glowLayer = try XCTUnwrap(renderer.view.layer?.sublayers?.first)
        XCTAssertEqual(glowLayer.opacity, 0.45, accuracy: 0.000_001)
        XCTAssertTrue(glowLayer.frame.width.isFinite)
    }

    @MainActor
    func testClassicRendererAppliesConfigurationToEveryHeldKey() throws {
        let window = GlowOverlayWindow(contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120))
        defer { window.close() }
        let renderer = try XCTUnwrap(window.glowRenderer as? GlowView)

        renderer.show(.physicalKey(40, horizontalPosition: 0.25, keyWidth: 1))
        renderer.show(.physicalKey(41, horizontalPosition: 0.75, keyWidth: 1))
        renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                glowHeight: 80,
                widthMultiplier: 1.5,
                maximumOpacity: 0.45,
                fadeDuration: 0.8,
                roundness: 0.6,
                fullness: 0.4
            )
        )

        let glowLayers = try XCTUnwrap(renderer.view.layer?.sublayers)
        XCTAssertEqual(glowLayers.count, 2)
        XCTAssertEqual(glowLayers[0].opacity, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(glowLayers[1].opacity, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(glowLayers[0].frame.midX, 250, accuracy: 0.000_001)
        XCTAssertEqual(glowLayers[1].frame.midX, 750, accuracy: 0.000_001)
        XCTAssertEqual(glowLayers[0].frame.width, 225, accuracy: 0.000_001)
        XCTAssertEqual(glowLayers[1].frame.width, 225, accuracy: 0.000_001)
    }

    @MainActor
    func testClassicRendererRefreshesVisiblePhysicalTargetOnAtomicApply() throws {
        let window = GlowOverlayWindow(contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120))
        defer { window.close() }
        let renderer = try XCTUnwrap(window.glowRenderer)
        let keyID = GlowID.physicalKey(44)

        renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemRed),
                glowHeight: 40,
                widthMultiplier: 0.75,
                maximumOpacity: 0.8
            )
        )
        renderer.show(.physicalKey(44, horizontalPosition: 0.37, keyWidth: 1.5))
        let glowLayer = try XCTUnwrap(renderer.view.layer?.sublayers?.first)
        let originalFrame = glowLayer.frame

        renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                glowHeight: 100,
                widthMultiplier: 2,
                maximumOpacity: 0.32,
                fadeDuration: 0.65,
                roundness: 0.2,
                fullness: 0.9
            )
        )

        XCTAssertEqual(glowLayer.opacity, 0.32, accuracy: 0.000_001)
        XCTAssertEqual(glowLayer.frame.midX, 370, accuracy: 0.000_001)
        XCTAssertEqual(glowLayer.frame.width, 450, accuracy: 0.000_001)
        XCTAssertNotEqual(glowLayer.frame, originalFrame)
        XCTAssertTrue(renderer.refresh(keyID), "Atomic apply must retain the active physical key identity")

        let gradient = try XCTUnwrap(glowLayer.sublayers?.first as? CAGradientLayer)
        let firstColor = try XCTUnwrap((gradient.colors as? [CGColor])?.first)
        let renderedColor = try XCTUnwrap(NSColor(cgColor: firstColor)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(renderedColor.blueComponent, renderedColor.redComponent)

        renderer.hide(keyID)
        let fade = try XCTUnwrap(glowLayer.animation(forKey: "fadeOut"))
        XCTAssertEqual(fade.duration, 0.65, accuracy: 0.000_001)
    }

    @MainActor
    func testClassicReduceMotionNeverAddsGeometryAnimations() throws {
        let window = GlowOverlayWindow(contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120))
        defer { window.close() }
        let renderer = try XCTUnwrap(window.glowRenderer)
        renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                reduceMotion: true
            )
        )

        renderer.show(.physicalKey(1, horizontalPosition: 0.25, keyWidth: 1))
        let firstGlowLayer = try XCTUnwrap(renderer.view.layer?.sublayers?.first)
        XCTAssertNil(firstGlowLayer.animation(forKey: "popPosition"))
        XCTAssertNil(firstGlowLayer.animation(forKey: "popBounds"))

        renderer.show(.physicalKey(2, horizontalPosition: 0.75, keyWidth: 1))
        let glowLayers = try XCTUnwrap(renderer.view.layer?.sublayers)
        XCTAssertEqual(glowLayers.count, 2)
        let secondGlowLayer = glowLayers[1]
        XCTAssertNil(secondGlowLayer.animation(forKey: "popPosition"))
        XCTAssertNil(secondGlowLayer.animation(forKey: "popBounds"))
        XCTAssertNil(secondGlowLayer.animation(forKey: "slidePosition"))
        XCTAssertNil(secondGlowLayer.animation(forKey: "slideBounds"))
    }

    @MainActor
    func testClassicChordIntensityAppliesOnlyWithMultipleActiveMembers() throws {
        let window = GlowOverlayWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120)
        )
        defer { window.close() }
        let renderer = try XCTUnwrap(window.glowRenderer as? GlowView)
        renderer.apply(RendererConfiguration(
            colorMode: .solid(.systemBlue),
            maximumOpacity: 0.8,
            chordAppearance: ChordAppearance(
                style: .naturalMerge,
                intensityMultiplier: 0.5
            )
        ))

        renderer.show(.physicalKey(1, horizontalPosition: 0.3, keyWidth: 1))
        let first = try XCTUnwrap(renderer.view.layer?.sublayers?.first)
        XCTAssertEqual(first.opacity, 0.8, accuracy: 0.000_001)

        renderer.show(.physicalKey(2, horizontalPosition: 0.6, keyWidth: 1))
        let layers = try XCTUnwrap(renderer.view.layer?.sublayers)
        XCTAssertEqual(layers.count, 2)
        XCTAssertTrue(layers.allSatisfy { abs($0.opacity - 0.4) < 0.000_001 })

        renderer.hide(.physicalKey(2))
        XCTAssertEqual(first.opacity, 0.8, accuracy: 0.000_001)
        XCTAssertTrue(renderer.refresh(.physicalKey(1)))
        XCTAssertFalse(renderer.refresh(.physicalKey(2)))
    }

    @MainActor
    func testClassicChordIntensitySupportsHundredAndHundredFiftyPercent() throws {
        let window = GlowOverlayWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120)
        )
        defer { window.close() }
        let renderer = try XCTUnwrap(window.glowRenderer as? GlowView)
        renderer.show(.physicalKey(1, horizontalPosition: 0.3, keyWidth: 1))
        renderer.show(.physicalKey(2, horizontalPosition: 0.6, keyWidth: 1))

        renderer.apply(RendererConfiguration(
            colorMode: .solid(.systemBlue),
            maximumOpacity: 0.6,
            chordAppearance: ChordAppearance(intensityMultiplier: 1)
        ))
        XCTAssertTrue(try XCTUnwrap(renderer.view.layer?.sublayers).allSatisfy {
            abs($0.opacity - 0.6) < 0.000_001
        })

        renderer.apply(RendererConfiguration(
            colorMode: .solid(.systemBlue),
            maximumOpacity: 0.6,
            chordAppearance: ChordAppearance(intensityMultiplier: 1.5)
        ))
        XCTAssertTrue(try XCTUnwrap(renderer.view.layer?.sublayers).allSatisfy {
            abs($0.opacity - 0.9) < 0.000_001
        })
    }
}

final class RendererMotionPolicyTests: XCTestCase {
    func testReduceMotionSuppressesEveryGeometryDuration() {
        XCTAssertFalse(RendererMotionPolicy.allowsGeometryAnimation(reduceMotion: true))
        XCTAssertEqual(
            RendererMotionPolicy.geometryDuration(0.38, reduceMotion: true),
            0
        )
        XCTAssertEqual(
            RendererMotionPolicy.geometryDuration(0.13, reduceMotion: false),
            0.13
        )
        XCTAssertEqual(
            RendererMotionPolicy.geometryDuration(.nan, reduceMotion: false),
            0
        )
    }

    func testRefractionStrengthIsFiniteAndBoundedAtRendererBoundary() {
        XCTAssertEqual(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                refractionStrength: .nan
            ).refractionStrength,
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                refractionStrength: 0
            ).refractionStrength,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                refractionStrength: 9
            ).refractionStrength,
            2.5,
            accuracy: 0.000_001
        )
    }

    func testChordAppearanceNormalizesAtTheRendererBoundary() {
        let low = RendererConfiguration(
            colorMode: .solid(.systemBlue),
            chordAppearance: ChordAppearance(
                style: .independent,
                intensityMultiplier: -.infinity
            )
        )
        XCTAssertEqual(low.chordAppearance.style, .independent)
        XCTAssertEqual(low.chordAppearance.intensityMultiplier, 1)

        XCTAssertEqual(
            ChordAppearance(intensityMultiplier: -1).intensityMultiplier,
            0.5
        )
        XCTAssertEqual(
            ChordAppearance(intensityMultiplier: 5).intensityMultiplier,
            1.5
        )
    }

    func testAutomaticPowerSavingPolicyCoversLowPowerAndThermalStates() {
        for thermal in PowerThermalState.allCases {
            let environment = PowerEnvironmentState(
                isLowPowerModeEnabled: false,
                thermalState: thermal
            )
            XCTAssertEqual(
                environment.requiresFallback,
                thermal == .serious || thermal == .critical
            )
        }

        let lowPower = PowerEnvironmentState(
            isLowPowerModeEnabled: true,
            thermalState: .nominal
        )
        XCTAssertTrue(lowPower.requiresFallback)
        XCTAssertEqual(lowPower.fallbackReason, "Low Power Mode")

        let automatic = RendererConfiguration(
            colorMode: .solid(.systemBlue),
            powerSavingMode: .automatic,
            powerEnvironmentState: lowPower
        )
        XCTAssertTrue(automatic.automaticPowerSavingIsActive)
        XCTAssertNotEqual(
            automatic.resolvedEffectStyle(for: .physicalRefraction),
            .physicalRefraction
        )

        let off = RendererConfiguration(
            colorMode: .solid(.systemBlue),
            powerSavingMode: .off,
            powerEnvironmentState: lowPower
        )
        XCTAssertFalse(off.automaticPowerSavingIsActive)
        XCTAssertEqual(
            off.resolvedEffectStyle(for: .physicalRefraction),
            EffectStyle.physicalRefraction.resolvedForCurrentSystem
        )
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
@MainActor
private func makeLiquidGlassHarness() throws -> (
    window: GlowOverlayWindow,
    renderer: LiquidGlassGlowView
) {
    let window = GlowOverlayWindow(contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120))
    window.setEffectStyle(.systemGlass)
    let renderer = try XCTUnwrap(window.glowRenderer as? LiquidGlassGlowView)
    return (window, renderer)
}

@available(macOS 26.0, *)
@MainActor
private func runLiquidGlassAnimation(for duration: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
}

final class LiquidGlassBellShapeTests: XCTestCase {
    func testEveryProfileHasAClosedFillAndAnOpenOpticalContour() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let rect = CGRect(x: 0, y: 0, width: 300, height: 30)
        for profile in SurfaceShapeProfile.allCases {
            let fill = LiquidGlassBellShape(
                emergence: 1,
                profile: profile
            ).path(in: rect)
            let edge = LiquidGlassBellShape.edgePath(
                in: rect,
                emergence: 1,
                smoothness: 0.7069,
                flow: 0,
                profile: profile
            )

            XCTAssertTrue(
                containsCloseSubpath(fill.cgPath),
                "\(profile) fill must remain closed"
            )
            XCTAssertFalse(
                containsCloseSubpath(edge.cgPath),
                "\(profile) optical contour must not stroke the bezel baseline"
            )
            XCTAssertEqual(
                edge.boundingRect.maxY,
                rect.height * 0.72,
                accuracy: 0.000_001
            )
        }
    }

    func testExpandedShapeHasLongFlatTopAndCurvedShouldersInsteadOfRectangleCorners() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let rect = CGRect(x: 0, y: 0, width: 300, height: 30)
        let path = LiquidGlassBellShape(emergence: 1).path(in: rect)
        let bounds = path.boundingRect

        XCTAssertEqual(bounds.minX, rect.minX, accuracy: 0.000_001)
        XCTAssertEqual(bounds.maxX, rect.maxX, accuracy: 0.000_001)
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.000_001)
        XCTAssertEqual(bounds.maxY, rect.height * 0.72, accuracy: 0.000_001)
        XCTAssertGreaterThan(bounds.width / bounds.height, 12)

        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX - 55, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX + 55, y: 1)))
        XCTAssertFalse(path.contains(CGPoint(x: 5, y: 1)))
        XCTAssertFalse(path.contains(CGPoint(x: 295, y: 1)))
    }

    func testCollapsedShapeStartsAtScreenEdgeAndExpandsHorizontallyWithEmergence() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let rect = CGRect(x: 0, y: 0, width: 300, height: 30)
        let collapsed = LiquidGlassBellShape(emergence: 0).path(in: rect).boundingRect
        let solidBlackCollapsed = LiquidGlassBellShape(
            emergence: 0,
            minimumRise: 0
        ).path(in: rect).boundingRect
        let expanded = LiquidGlassBellShape(emergence: 1).path(in: rect).boundingRect

        XCTAssertEqual(collapsed.maxY, rect.height * 0.72, accuracy: 0.000_001)
        XCTAssertEqual(collapsed.height, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(collapsed.width, rect.width * 0.28, accuracy: 0.000_001)
        XCTAssertEqual(solidBlackCollapsed.height, 0, accuracy: 0.000_001)
        XCTAssertEqual(expanded.minY, 0, accuracy: 0.000_001)
        XCTAssertEqual(expanded.width, rect.width, accuracy: 0.000_001)
    }

    func testSmoothnessBroadensShouldersWhileRetainingAFlatTop() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        XCTAssertEqual(
            LiquidGlassBellShape.shoulderShare(for: 0),
            0.12,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LiquidGlassBellShape.shoulderShare(for: 1),
            0.42,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(
            LiquidGlassBellShape.shoulderShare(for: 0.7069),
            LiquidGlassBellShape.shoulderShare(for: 0)
        )

        let rect = CGRect(x: 0, y: 0, width: 300, height: 30)
        let softPath = LiquidGlassBellShape(emergence: 1, smoothness: 1).path(in: rect)
        XCTAssertTrue(softPath.contains(CGPoint(x: rect.midX - 25, y: 0.25)))
        XCTAssertTrue(softPath.contains(CGPoint(x: rect.midX + 25, y: 0.25)))
    }

    func testShapeSanitizesInvalidAndOutOfRangeEmergence() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let rect = CGRect(x: 0, y: 0, width: 300, height: 30)
        let collapsed = LiquidGlassBellShape(emergence: 0).path(in: rect).boundingRect
        let expanded = LiquidGlassBellShape(emergence: 1).path(in: rect).boundingRect

        XCTAssertEqual(
            LiquidGlassBellShape(emergence: .nan).path(in: rect).boundingRect,
            collapsed
        )
        XCTAssertEqual(
            LiquidGlassBellShape(emergence: -20).path(in: rect).boundingRect,
            collapsed
        )
        XCTAssertEqual(
            LiquidGlassBellShape(emergence: 20).path(in: rect).boundingRect,
            expanded
        )
        XCTAssertEqual(
            LiquidGlassBellShape(emergence: 1, smoothness: .nan).path(in: rect).boundingRect,
            LiquidGlassBellShape(emergence: 1, smoothness: 0.7069).path(in: rect).boundingRect
        )
    }

    func testCohesiveBridgeCreatesAShallowSmoothSaddle() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let compactSag = LiquidGlassCohesiveBridge.sag(
            averageHeight: 23,
            smoothness: 0
        )
        let smoothSag = LiquidGlassCohesiveBridge.sag(
            averageHeight: 23,
            smoothness: 1
        )
        XCTAssertGreaterThan(compactSag, smoothSag)
        XCTAssertLessThanOrEqual(compactSag, 3.2)

        let bridge = LiquidGlassCohesiveBridge.path(
            start: CGPoint(x: 420, y: 97),
            end: CGPoint(x: 480, y: 97),
            baselineY: 120,
            averageHeight: 23,
            smoothness: 0
        )
        XCTAssertTrue(bridge.contains(CGPoint(x: 450, y: 100)))
        XCTAssertFalse(bridge.contains(CGPoint(x: 450, y: 96)))
    }

    func testInteriorBridgePreservesBothExteriorEdges() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let localRect = CGRect(x: 0, y: 0, width: 160, height: 30)
        let left = LiquidGlassBellShape(emergence: 1)
            .path(in: localRect)
            .applying(CGAffineTransform(
                translationX: 350,
                y: 98.4
            ))
        let right = LiquidGlassBellShape(emergence: 1)
            .path(in: localRect)
            .applying(CGAffineTransform(
                translationX: 410,
                y: 98.4
            ))
        let individualUnion = left.union(right)
        let bridge = LiquidGlassCohesiveBridge.path(
            start: CGPoint(x: 430, y: 98.4),
            end: CGPoint(x: 490, y: 98.4),
            baselineY: 120,
            averageHeight: 21.6,
            smoothness: 0.7
        )
        let blended = individualUnion.union(bridge)
        XCTAssertEqual(
            blended.boundingRect.minX,
            individualUnion.boundingRect.minX,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            blended.boundingRect.maxX,
            individualUnion.boundingRect.maxX,
            accuracy: 0.000_001
        )
    }

    private func containsCloseSubpath(_ path: CGPath) -> Bool {
        var containsClose = false
        path.applyWithBlock { element in
            if element.pointee.type == .closeSubpath {
                containsClose = true
            }
        }
        return containsClose
    }
}

final class LiquidGlassRendererSmokeTests: XCTestCase {
    func testSystemGlassPolicyUsesOnlySystemOptics() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("System Glass requires macOS 26")
        }

        XCTAssertTrue(
            LiquidGlassPresentationMode.systemGlass
                .extendsGlassBelowVisibleBaseline
        )
        XCTAssertFalse(
            LiquidGlassPresentationMode.solidBlack
                .extendsGlassBelowVisibleBaseline
        )
    }

    @MainActor
    func testSystemGlassIsASeparateCaptureFreeRendererRoute() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("System Glass requires macOS 26")
        }

        let window = GlowOverlayWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120)
        )
        defer { window.close() }

        window.setEffectStyle(.systemGlass)
        let renderer = try XCTUnwrap(
            window.glowRenderer as? LiquidGlassGlowView
        )

        XCTAssertEqual(renderer.testPresentationMode, .systemGlass)
        XCTAssertTrue(renderer.testExtendsGlassBelowVisibleBaseline)
        XCTAssertTrue(renderer.supportsConcurrentPhysicalTargets)
        XCTAssertEqual(renderer.testHostingViewCount, 1)

        window.setEffectStyle(.liquidGlass)
        XCTAssertEqual(renderer.testPresentationMode, .systemGlass)
        XCTAssertTrue(
            try XCTUnwrap(window.glowRenderer as? LiquidGlassGlowView)
                === renderer
        )
    }

    @MainActor
    func testPhysicalPermissionFallbackUsesSystemGlassAndNeverPrompts() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let fallbackWindow = GlowOverlayWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120),
            screenCaptureAccessProvider: { false }
        )
        defer { fallbackWindow.close() }

        fallbackWindow.setEffectStyle(.physicalRefraction)
        let fallback = try XCTUnwrap(
            fallbackWindow.glowRenderer as? LiquidGlassGlowView
        )
        XCTAssertEqual(fallback.testPresentationMode, .systemGlass)

        let allowedWindow = GlowOverlayWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120),
            screenCaptureAccessProvider: { true }
        )
        defer { allowedWindow.close() }
        allowedWindow.setEffectStyle(.physicalRefraction)
        let physical = try XCTUnwrap(
            allowedWindow.glowRenderer as? LiquidGlassGlowView
        )
        XCTAssertEqual(physical.testPresentationMode, .physicalRefraction)
    }

    @MainActor
    func testAutomaticPowerFallbackStopsCaptureAndReplaysEveryHeldIdentity() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Physical Refraction requires macOS 26")
        }

        let panel = GlowOverlayWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120),
            screenCaptureAccessProvider: { true }
        )
        defer { panel.close() }
        let controller = OverlayController(
            displayProvider: {
                [OverlayDisplayCandidate(
                    id: 1,
                    isBuiltIn: true,
                    isMain: true,
                    frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
                )]
            },
            windowFactory: { _ in panel }
        )
        var statuses: [EffectRuntimeStatus] = []
        controller.setRuntimeStatusHandler { statuses.append($0) }
        controller.start()
        controller.apply(
            effectStyle: .physicalRefraction,
            configuration: RendererConfiguration(
                colorMode: .solid(.systemBlue),
                powerSavingMode: .automatic,
                powerEnvironmentState: .normal
            )
        )
        let physical = try XCTUnwrap(
            panel.glowRenderer as? LiquidGlassGlowView
        )
        XCTAssertEqual(physical.testPresentationMode, .physicalRefraction)

        let left = GlowTarget.physicalKey(30, horizontalPosition: 0.35, keyWidth: 1)
        let right = GlowTarget.physicalKey(31, horizontalPosition: 0.65, keyWidth: 1)
        controller.handle(
            .keyDown(30, source: .eventTap, timestamp: 1),
            target: left
        )
        controller.handle(
            .keyDown(31, source: .eventTap, timestamp: 2),
            target: right
        )
        XCTAssertEqual(physical.testActiveTargetIDs, [left.id, right.id])

        let constrained = PowerEnvironmentState(
            isLowPowerModeEnabled: true,
            thermalState: .serious
        )
        controller.apply(
            effectStyle: .physicalRefraction,
            configuration: RendererConfiguration(
                colorMode: .solid(.systemBlue),
                powerSavingMode: .automatic,
                powerEnvironmentState: constrained
            )
        )
        let fallback = try XCTUnwrap(
            panel.glowRenderer as? LiquidGlassGlowView
        )
        XCTAssertEqual(fallback.testPresentationMode, .systemGlass)
        XCTAssertTrue(physical.testActiveTargetIDs.isEmpty)
        XCTAssertFalse(physical.testPhysicalCaptureIsReady)
        XCTAssertEqual(fallback.testActiveTargetIDs, [left.id, right.id])
        XCTAssertEqual(statuses.last?.selectedEffect, .physicalRefraction)
        XCTAssertEqual(statuses.last?.resolvedEffect, .systemGlass)
        XCTAssertEqual(statuses.last?.automaticPowerSavingIsActive, true)
        XCTAssertEqual(statuses.last?.powerEnvironmentState, constrained)
        XCTAssertTrue(statuses.last?.fallbackReason?.contains("Low Power Mode") == true)

        controller.apply(
            effectStyle: .physicalRefraction,
            configuration: RendererConfiguration(
                colorMode: .solid(.systemBlue),
                powerSavingMode: .automatic,
                powerEnvironmentState: .normal
            )
        )
        let restored = try XCTUnwrap(
            panel.glowRenderer as? LiquidGlassGlowView
        )
        XCTAssertTrue(restored === physical)
        XCTAssertEqual(restored.testPresentationMode, .physicalRefraction)
        XCTAssertEqual(restored.testActiveTargetIDs, [left.id, right.id])
    }

    func testPhysicalRefractionStrengthPreservesBaselineAndExpandsSamplingBound() {
        XCTAssertEqual(
            PhysicalRefractionOptics.sanitizedStrength(.nan),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PhysicalRefractionOptics.sanitizedStrength(0),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PhysicalRefractionOptics.sanitizedStrength(4),
            2.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PhysicalRefractionOptics.transmissionLimit(for: 1),
            26,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PhysicalRefractionOptics.transmissionLimit(for: 2.5),
            65,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PhysicalRefractionOptics.opticalMargin(for: 1),
            28,
            accuracy: 0.000_001
        )
    }

    func testPhysicalRefractionUsesTheDisplayBackingScale() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Physical Refraction requires macOS 26")
        }

        XCTAssertEqual(
            PhysicalRefractionMetalView.renderScale(for: 1),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PhysicalRefractionMetalView.renderScale(for: 2),
            2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PhysicalRefractionMetalView.renderScale(for: .nan),
            2,
            accuracy: 0.000_001
        )
    }

    func testPhysicalFallbackClosesBelowTheVisibleBaseline() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Physical Refraction requires macOS 26")
        }

        let rect = CGRect(x: 0, y: 0, width: 160, height: 30)
        let regular = LiquidGlassBellShape(emergence: 1).path(in: rect)
        let physical = LiquidGlassBellShape(
            emergence: 1,
            extendsBelowBaseline: true
        ).path(in: rect)

        XCTAssertEqual(
            regular.boundingRect.maxY,
            rect.height * 0.72,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            physical.boundingRect.maxY,
            rect.maxY,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            physical.boundingRect.minY,
            regular.boundingRect.minY,
            accuracy: 0.000_001
        )
    }

    func testPhysicalShaderDrawsTheOpenEdgeWithoutABottomLine() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Physical Refraction requires macOS 26")
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(
                bundle: .main
              ) else {
            throw XCTSkip("Metal device or compiled shader library is unavailable")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(
            name: "keyLightRefractionVertex"
        )
        pipelineDescriptor.fragmentFunction = library.makeFunction(
            name: "keyLightRefractionFragment"
        )
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(
            descriptor: pipelineDescriptor
        )

        let outputWidth = 1_024
        let outputHeight = 240
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = [.renderTarget]
        let output = try XCTUnwrap(
            device.makeTexture(descriptor: outputDescriptor)
        )

        let backdropWidth = 512
        let backdropHeight = 200
        let backdropDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: backdropWidth,
            height: backdropHeight,
            mipmapped: false
        )
        backdropDescriptor.storageMode = .shared
        backdropDescriptor.usage = [.shaderRead]
        let backdrop = try XCTUnwrap(
            device.makeTexture(descriptor: backdropDescriptor)
        )
        var backdropBytes = [UInt8](
            repeating: 0,
            count: backdropWidth * backdropHeight * 4
        )
        for y in 0..<backdropHeight {
            for x in 0..<backdropWidth {
                let offset = (y * backdropWidth + x) * 4
                backdropBytes[offset] = UInt8((x * 3 + y) % 256)
                backdropBytes[offset + 1] = UInt8((x + y * 2) % 256)
                backdropBytes[offset + 2] = UInt8((x * 2 + y * 3) % 256)
                backdropBytes[offset + 3] = 255
            }
        }
        backdropBytes.withUnsafeBytes { bytes in
            backdrop.replace(
                region: MTLRegionMake2D(
                    0,
                    0,
                    backdropWidth,
                    backdropHeight
                ),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: backdropWidth * 4
            )
        }

        struct TestUniforms {
            var viewport: SIMD4<Float>
            var optics: SIMD4<Float>
            var tuning: SIMD4<Float>
            var counts: SIMD4<UInt32>
        }
        struct TestSurface {
            var frame: SIMD4<Float>
            var optical: SIMD4<Float>
        }
        var uniforms = TestUniforms(
            viewport: SIMD4<Float>(512, 120, 200, 0.05),
            optics: SIMD4<Float>(2.05, 1, 1_024, 240),
            tuning: SIMD4<Float>(1, 26, 0, 0),
            counts: SIMD4<UInt32>(1, 0, 0, 0)
        )
        var surface = TestSurface(
            frame: SIMD4<Float>(176, 98.4, 160, 30),
            optical: SIMD4<Float>(1, 1, 0.7, 0)
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        func renderBytes() throws -> [UInt8] {
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(
                commandBuffer.makeRenderCommandEncoder(descriptor: pass)
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<TestUniforms>.stride,
                index: 0
            )
            encoder.setFragmentBytes(
                &surface,
                length: MemoryLayout<TestSurface>.stride,
                index: 1
            )
            encoder.setFragmentTexture(backdrop, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 3
            )
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error)

            var bytes = [UInt8](
                repeating: 0,
                count: outputWidth * outputHeight * 4
            )
            bytes.withUnsafeMutableBytes { storage in
                output.getBytes(
                    storage.baseAddress!,
                    bytesPerRow: outputWidth * 4,
                    from: MTLRegionMake2D(
                        0,
                        0,
                        outputWidth,
                        outputHeight
                    ),
                    mipmapLevel: 0
                )
            }
            return bytes
        }

        let outputBytes = try renderBytes()
        func alpha(x: Int, y: Int) -> UInt8 {
            outputBytes[(y * outputWidth + x) * 4 + 3]
        }

        var topEdgeMaximum: UInt8 = 0
        for y in 188...214 {
            for x in 420...604 {
                topEdgeMaximum = max(topEdgeMaximum, alpha(x: x, y: y))
            }
        }
        var bottomCenterMaximum: UInt8 = 0
        for x in 420...604 {
            bottomCenterMaximum = max(
                bottomCenterMaximum,
                alpha(x: x, y: outputHeight - 1)
            )
        }

        XCTAssertGreaterThan(topEdgeMaximum, 64)
        XCTAssertLessThanOrEqual(bottomCenterMaximum, 2)
        XCTAssertEqual(alpha(x: 512, y: 228), 0)

        let baselineBytes = outputBytes
        uniforms.tuning = SIMD4<Float>(2.5, 65, 0, 0)
        let strongBytes = try renderBytes()

        var changedEdgePixelCount = 0
        for y in 188...214 {
            for x in 420...604 {
                let offset = (y * outputWidth + x) * 4
                let baselineAlpha = baselineBytes[offset + 3]
                let strongAlpha = strongBytes[offset + 3]
                guard baselineAlpha > 24, strongAlpha > 24 else { continue }
                let colorDelta = (0..<3).reduce(0) { partial, channel in
                    partial + abs(
                        Int(strongBytes[offset + channel])
                            - Int(baselineBytes[offset + channel])
                    )
                }
                if colorDelta > 4 {
                    changedEdgePixelCount += 1
                }
            }
        }

        var strongBottomCenterMaximum: UInt8 = 0
        for x in 420...604 {
            strongBottomCenterMaximum = max(
                strongBottomCenterMaximum,
                strongBytes[
                    ((outputHeight - 1) * outputWidth + x) * 4 + 3
                ]
            )
        }
        XCTAssertGreaterThan(changedEdgePixelCount, 50)
        XCTAssertLessThanOrEqual(strongBottomCenterMaximum, 2)

        // Reproduce the reported pale-ridge failure: a dark captured strip with
        // one bright final row. Strong refraction must use real on-screen pixels
        // above the bezel instead of stretching that terminal row over the lens.
        var brightBoundaryBackdrop = [UInt8](
            repeating: 0,
            count: backdropWidth * backdropHeight * 4
        )
        for y in 0..<backdropHeight {
            for x in 0..<backdropWidth {
                let offset = (y * backdropWidth + x) * 4
                let isTerminalRow = y == backdropHeight - 1
                brightBoundaryBackdrop[offset] = isTerminalRow ? 212 : 45
                brightBoundaryBackdrop[offset + 1] = isTerminalRow ? 192 : 45
                brightBoundaryBackdrop[offset + 2] = isTerminalRow ? 168 : 45
                brightBoundaryBackdrop[offset + 3] = 255
            }
        }
        brightBoundaryBackdrop.withUnsafeBytes { bytes in
            backdrop.replace(
                region: MTLRegionMake2D(
                    0,
                    0,
                    backdropWidth,
                    backdropHeight
                ),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: backdropWidth * 4
            )
        }
        let boundaryBytes = try renderBytes()
        var boundaryEdgeMaximum: UInt8 = 0
        var boundaryAlphaMaximum: UInt8 = 0
        for y in 188...214 {
            for x in 420...604 {
                let offset = (y * outputWidth + x) * 4
                boundaryAlphaMaximum = max(
                    boundaryAlphaMaximum,
                    boundaryBytes[offset + 3]
                )
                for channel in 0..<3 {
                    boundaryEdgeMaximum = max(
                        boundaryEdgeMaximum,
                        boundaryBytes[offset + channel]
                    )
                }
            }
        }
        XCTAssertGreaterThan(boundaryAlphaMaximum, 64)
        XCTAssertLessThanOrEqual(boundaryEdgeMaximum, 80)

        // Transparent capture padding can carry arbitrary RGB. It must never
        // become a visible white optical edge.
        var transparentWhiteBackdrop = [UInt8](
            repeating: 255,
            count: backdropWidth * backdropHeight * 4
        )
        for index in stride(
            from: 3,
            to: transparentWhiteBackdrop.count,
            by: 4
        ) {
            transparentWhiteBackdrop[index] = 0
        }
        transparentWhiteBackdrop.withUnsafeBytes { bytes in
            backdrop.replace(
                region: MTLRegionMake2D(
                    0,
                    0,
                    backdropWidth,
                    backdropHeight
                ),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: backdropWidth * 4
            )
        }
        let transparentBytes = try renderBytes()
        var transparentRGBMaximum: UInt8 = 0
        for index in stride(from: 0, to: transparentBytes.count, by: 4) {
            transparentRGBMaximum = max(
                transparentRGBMaximum,
                max(
                    transparentBytes[index],
                    max(
                        transparentBytes[index + 1],
                        transparentBytes[index + 2]
                    )
                )
            )
        }
        XCTAssertEqual(transparentRGBMaximum, 0)
    }

    @MainActor
    func testPhysicalMetalRendererInitializesAndSleepsWhenIdle() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Physical Refraction requires macOS 26")
        }

        let view = PhysicalRefractionMetalView(
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 120)
        )
        defer { view.stopCapture() }

        XCTAssertTrue(view.isPaused)
        view.update(
            snapshots: [
                LiquidGlassSurfaceSnapshot(
                    id: .physicalKey(1),
                    frame: CGRect(x: 420, y: -34, width: 160, height: 120),
                    opacity: 0.7,
                    visibility: 1,
                    edgeOpacity: 0.8,
                    lensOpacity: 0.8,
                    dimmingOpacity: 0.1,
                    chromaticDisplacement: 1.2,
                    emergence: 1,
                    smoothness: 0.7,
                    horizontalVelocity: 0,
                    isVisible: true
                )
            ],
            bodyOpacity: 0.25,
            edgeStrength: 1
        )
        XCTAssertTrue(
            view.isPaused,
            "event-driven MTKView must remain paused and draw only on demand"
        )

        view.update(
            snapshots: [],
            bodyOpacity: 0.25,
            edgeStrength: 1
        )
        XCTAssertTrue(view.isPaused)
    }

    @MainActor
    func testPhysicalCaptureGraceCancelsOnNewSurfaceAndStopsWithinContract() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Physical Refraction requires macOS 26")
        }

        let view = PhysicalRefractionMetalView(
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 120)
        )
        defer { view.stopCapture() }
        let snapshot = LiquidGlassSurfaceSnapshot(
            id: .physicalKey(1),
            frame: CGRect(x: 420, y: -34, width: 160, height: 120),
            opacity: 0.7,
            visibility: 1,
            edgeOpacity: 0.8,
            lensOpacity: 0.8,
            dimmingOpacity: 0.1,
            chromaticDisplacement: 1.2,
            emergence: 1,
            smoothness: 0.7,
            horizontalVelocity: 0,
            isVisible: true
        )

        view.testArmCaptureAsActive()
        view.testBeginCaptureGracePeriod()
        XCTAssertEqual(view.currentCaptureState, .gracePeriod)
        XCTAssertTrue(view.testHasPendingCaptureStop)

        view.update(
            snapshots: [snapshot],
            bodyOpacity: 0.25,
            edgeStrength: 1
        )
        XCTAssertEqual(view.currentCaptureState, .active)
        XCTAssertFalse(view.testHasPendingCaptureStop)

        let start = ProcessInfo.processInfo.systemUptime
        view.update(
            snapshots: [],
            bodyOpacity: 0.25,
            edgeStrength: 1
        )
        XCTAssertEqual(view.currentCaptureState, .gracePeriod)

        while view.currentCaptureState != .idle,
              ProcessInfo.processInfo.systemUptime - start < 2.25 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertEqual(view.currentCaptureState, .idle)
        XCTAssertGreaterThanOrEqual(elapsed, 1.95)
        XCTAssertLessThan(elapsed, 2.25)
        XCTAssertFalse(view.testHasPendingCaptureStop)
    }

    @MainActor
    func testRefractionStrengthReachesTheSharedSurfaceModel() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Physical Refraction requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                refractionStrength: 2.25
            )
        )

        XCTAssertEqual(
            harness.renderer.testRefractionStrength,
            2.25,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testCurrentWaveAndSolidBlackReuseTheSurfaceMotionEngine() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let window = GlowOverlayWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120)
        )
        defer { window.close() }
        window.setEffectStyle(.solidBlack)
        let renderer = try XCTUnwrap(
            window.glowRenderer as? LiquidGlassGlowView
        )
        renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                fadeDuration: 0.8
            )
        )

        XCTAssertEqual(renderer.testPresentationMode, .solidBlack)
        XCTAssertEqual(renderer.testShapeProfile, .currentWave)
        XCTAssertTrue(renderer.supportsConcurrentPhysicalTargets)

        renderer.show(
            .physicalKey(1, horizontalPosition: 0.48, keyWidth: 1)
        )
        renderer.show(
            .physicalKey(2, horizontalPosition: 0.52, keyWidth: 1)
        )
        runLiquidGlassAnimation(for: 0.03)
        XCTAssertEqual(renderer.testActiveTargetIDs.count, 2)
        XCTAssertEqual(renderer.testVisibleSurfaceGroupCount, 1)
        XCTAssertFalse(renderer.testActiveTransitionDurations.isEmpty)
    }

    @MainActor
    func testChordStyleAndIntensityUpdateHeldGlassWithoutLosingIdentities() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        let left = GlowTarget.physicalKey(
            21,
            horizontalPosition: 0.47,
            keyWidth: 1
        )
        let right = GlowTarget.physicalKey(
            22,
            horizontalPosition: 0.53,
            keyWidth: 1
        )
        harness.renderer.apply(RendererConfiguration(
            colorMode: .solid(.systemBlue),
            maximumOpacity: 0.8,
            chordAppearance: ChordAppearance(
                style: .naturalMerge,
                intensityMultiplier: 0.5
            )
        ))
        harness.renderer.show(left)
        XCTAssertEqual(harness.renderer.testMaterialOpacity, 0.8, accuracy: 0.000_001)
        harness.renderer.show(right)
        runLiquidGlassAnimation(for: 0.08)

        XCTAssertEqual(harness.renderer.testChordSurfaceStyle, .naturalMerge)
        XCTAssertEqual(harness.renderer.testVisibleSurfaceGroupCount, 1)
        XCTAssertEqual(harness.renderer.testMaterialOpacity, 0.4, accuracy: 0.000_001)

        harness.renderer.apply(RendererConfiguration(
            colorMode: .solid(.systemBlue),
            maximumOpacity: 0.8,
            chordAppearance: ChordAppearance(
                style: .independent,
                intensityMultiplier: 1.5
            )
        ))
        XCTAssertEqual(harness.renderer.testChordSurfaceStyle, .independent)
        XCTAssertEqual(harness.renderer.testVisibleSurfaceGroupCount, 2)
        XCTAssertEqual(harness.renderer.testMaterialOpacity, 1, accuracy: 0.000_001)
        XCTAssertEqual(harness.renderer.testActiveTargetIDs, [left.id, right.id])

        harness.renderer.hide(left.id)
        XCTAssertEqual(harness.renderer.testMaterialOpacity, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(harness.renderer.testActiveTargetIDs, [right.id])
    }

    @MainActor
    func testSolidBlackRetractsAtFullOpacityWithoutMovingItsCenter() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let window = GlowOverlayWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 120)
        )
        defer { window.close() }
        window.setEffectStyle(.solidBlack)
        let renderer = try XCTUnwrap(
            window.glowRenderer as? LiquidGlassGlowView
        )
        renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                fadeDuration: 0.8
            )
        )
        let target = GlowTarget.physicalKey(
            77,
            horizontalPosition: 0.48,
            keyWidth: 1
        )

        renderer.show(target)
        runLiquidGlassAnimation(for: 0.36)
        let expanded = try XCTUnwrap(
            renderer.testSurfaceSnapshots.first
        )
        XCTAssertEqual(renderer.testSolidBlackFillOpacity, 1)

        renderer.hide(target.id)
        runLiquidGlassAnimation(for: 0.42)
        let retracting = try XCTUnwrap(
            renderer.testSurfaceSnapshots.first
        )
        XCTAssertEqual(
            retracting.frame.midX,
            expanded.frame.midX,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(retracting.emergence, 0)
        XCTAssertLessThan(retracting.emergence, 1)
        XCTAssertGreaterThan(retracting.visibility, 0)
        XCTAssertLessThan(retracting.visibility, 1)
        XCTAssertEqual(
            renderer.testSolidBlackFillOpacity,
            1,
            "Release visibility must not attenuate the black fill"
        )

        runLiquidGlassAnimation(for: 0.45)
        XCTAssertTrue(renderer.testSurfaceSnapshots.isEmpty)
        XCTAssertNil(renderer.testSolidBlackFillOpacity)
    }

    @MainActor
    func testRendererOwnsOneHostAndOneStableSurfacePerHeldIdentity() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }

        XCTAssertTrue(harness.renderer.testUsesNativeBellShape)
        XCTAssertTrue(harness.renderer.testUsesSystemSelectedTimelineCadence)
        XCTAssertEqual(harness.renderer.testHostingViewCount, 1)
        XCTAssertEqual(harness.renderer.subviews.count, 1)
        XCTAssertTrue(harness.renderer.supportsConcurrentPhysicalTargets)
        XCTAssertTrue(harness.renderer.testSurfaceSnapshots.isEmpty)

        for (index, position) in [0.2, 0.35, 0.65, 0.8].enumerated() {
            harness.renderer.show(
                .physicalKey(
                    UInt16(index + 1),
                    horizontalPosition: position,
                    keyWidth: 1
                )
            )
            runLiquidGlassAnimation(for: 0.025)
            XCTAssertEqual(
                harness.renderer.testSurfaceSnapshots.filter(\.isVisible).count,
                index + 1
            )
        }

        XCTAssertEqual(harness.renderer.testSurfaceSnapshots.count, 4)
        XCTAssertEqual(
            harness.renderer.testActiveTargetIDs,
            (1...4).map { .physicalKey(UInt16($0)) }
        )
        harness.renderer.clear()
        XCTAssertTrue(harness.renderer.testSurfaceSnapshots.isEmpty)
        XCTAssertTrue(harness.renderer.testActiveTargetIDs.isEmpty)
    }

    @MainActor
    func testRapidTransitionStressKeepsTheSurfacePoolBoundedAndStopsWhenCleared() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer { harness.window.close() }
        harness.renderer.apply(
            RendererConfiguration(colorMode: .solid(.systemBlue), maximumOpacity: 0.65)
        )

        for index in 0..<5_000 {
            let position = Double(index % 101) / 100
            harness.renderer.show(
                .physicalKey(UInt16(index % 128), horizontalPosition: position, keyWidth: 1)
            )
        }

        XCTAssertEqual(harness.renderer.testSurfaceSnapshots.count, 128)
        XCTAssertEqual(harness.renderer.testHostingViewCount, 1)
        XCTAssertEqual(harness.renderer.testActiveTargetIDs.count, 128)
        harness.renderer.clear()
        XCTAssertFalse(harness.renderer.testTimelineIsActive)
        XCTAssertTrue(harness.renderer.testSurfaceSnapshots.isEmpty)
    }

    @MainActor
    func testAdjacentHeldKeysMergeIntoOneGroupAndMiddleReleaseKeepsNeighbors() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                fadeDuration: 0.12,
                roundness: 0
            )
        )
        let left = GlowTarget.physicalKey(
            10,
            horizontalPosition: 0.42,
            keyWidth: 1
        )
        let middle = GlowTarget.physicalKey(
            11,
            horizontalPosition: 0.48,
            keyWidth: 1
        )
        let right = GlowTarget.physicalKey(
            12,
            horizontalPosition: 0.54,
            keyWidth: 1
        )

        harness.renderer.show(left)
        harness.renderer.show(middle)
        harness.renderer.show(right)
        runLiquidGlassAnimation(for: 0.11)

        XCTAssertEqual(harness.renderer.testSurfaceSnapshots.count, 3)
        XCTAssertEqual(harness.renderer.testVisibleSurfaceGroupCount, 1)
        XCTAssertEqual(
            harness.renderer.testActiveTargetIDs,
            [left.id, middle.id, right.id]
        )

        harness.renderer.hide(middle.id)
        XCTAssertEqual(
            harness.renderer.testActiveTargetIDs,
            [left.id, right.id]
        )
        XCTAssertTrue(
            harness.renderer.testSurfaceSnapshots.contains {
                $0.id == left.id && $0.isVisible
            }
        )
        XCTAssertTrue(
            harness.renderer.testSurfaceSnapshots.contains {
                $0.id == right.id && $0.isVisible
            }
        )

        runLiquidGlassAnimation(for: 0.17)
        XCTAssertEqual(
            Set(harness.renderer.testSurfaceSnapshots.map(\.id)),
            Set([left.id, right.id])
        )
        XCTAssertEqual(harness.renderer.testVisibleSurfaceGroupCount, 2)
    }

    @MainActor
    func testAdjacentPressAndReleaseKeepBothKeyCentersFixed() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                maximumOpacity: 0.6,
                fadeDuration: 0.24,
                roundness: 0
            )
        )
        let left = GlowTarget.physicalKey(
            40,
            horizontalPosition: 0.42,
            keyWidth: 1
        )
        let right = GlowTarget.physicalKey(
            41,
            horizontalPosition: 0.48,
            keyWidth: 1
        )

        harness.renderer.show(left)
        runLiquidGlassAnimation(for: 0.34)
        let leftAtRest = try XCTUnwrap(
            harness.renderer.testSurfaceSnapshots.first { $0.id == left.id }
        )

        harness.renderer.show(right)
        let pressStartLeft = try XCTUnwrap(
            harness.renderer.testSurfaceSnapshots.first { $0.id == left.id }
        )
        let pressStartRight = try XCTUnwrap(
            harness.renderer.testSurfaceSnapshots.first { $0.id == right.id }
        )
        XCTAssertEqual(
            pressStartRight.frame.midX,
            480,
            accuracy: 0.5
        )
        XCTAssertEqual(
            pressStartLeft.frame.midX,
            leftAtRest.frame.midX,
            accuracy: 0.5
        )
        XCTAssertLessThanOrEqual(pressStartRight.visibility, 0.01)
        XCTAssertLessThanOrEqual(pressStartRight.emergence, 0.01)
        let revealDuration = harness.renderer.testMotionProfile.revealDuration
        XCTAssertTrue(
            harness.renderer.testActiveTransitionDurations.contains {
                abs($0 - revealDuration) < 0.000_001
            }
        )
        XCTAssertEqual(harness.renderer.testVisibleSurfaceGroupCount, 1)

        runLiquidGlassAnimation(for: revealDuration * 0.45)
        let emerging = try XCTUnwrap(
            harness.renderer.testSurfaceSnapshots.first { $0.id == right.id }
        )
        XCTAssertEqual(emerging.frame.midX, 480, accuracy: 0.5)
        XCTAssertGreaterThan(emerging.emergence, 0)
        XCTAssertLessThan(emerging.emergence, 1)

        runLiquidGlassAnimation(for: revealDuration * 0.7 + 0.03)
        let rightAtRest = try XCTUnwrap(
            harness.renderer.testSurfaceSnapshots.first { $0.id == right.id }
        )
        XCTAssertEqual(rightAtRest.frame.midX, 480, accuracy: 0.5)

        harness.renderer.hide(right.id)
        runLiquidGlassAnimation(for: 0.13)
        let survivor = try XCTUnwrap(
            harness.renderer.testSurfaceSnapshots.first { $0.id == left.id }
        )
        let converging = try XCTUnwrap(
            harness.renderer.testSurfaceSnapshots.first { $0.id == right.id }
        )
        XCTAssertEqual(converging.frame.midX, rightAtRest.frame.midX, accuracy: 0.5)
        XCTAssertGreaterThan(converging.visibility, 0)
        XCTAssertLessThan(converging.visibility, 1)
        XCTAssertGreaterThan(converging.emergence, 0)
        XCTAssertLessThan(converging.emergence, 1)
        XCTAssertEqual(harness.renderer.testVisibleSurfaceGroupCount, 1)
        XCTAssertEqual(survivor.frame.midX, 420, accuracy: 0.5)

        runLiquidGlassAnimation(for: 0.16)
        XCTAssertEqual(
            harness.renderer.testSurfaceSnapshots.map(\.id),
            [left.id]
        )
    }

    @MainActor
    func testDistantHeldKeysRemainSeparateGlassGroups() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        let left = GlowTarget.physicalKey(
            20,
            horizontalPosition: 0.15,
            keyWidth: 1
        )
        let right = GlowTarget.physicalKey(
            21,
            horizontalPosition: 0.85,
            keyWidth: 1
        )

        harness.renderer.show(left)
        harness.renderer.show(right)
        runLiquidGlassAnimation(for: 0.32)

        XCTAssertEqual(harness.renderer.testSurfaceSnapshots.count, 2)
        XCTAssertEqual(harness.renderer.testVisibleSurfaceGroupCount, 2)
        XCTAssertEqual(
            Set(harness.renderer.testSurfaceSnapshots.map(\.id)),
            Set([left.id, right.id])
        )
    }

    @MainActor
    func testChordReleaseOrderRemovesOnlyReleasedIdentities() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                fadeDuration: 0.12
            )
        )
        let targets = [
            GlowTarget.physicalKey(30, horizontalPosition: 0.30, keyWidth: 1),
            GlowTarget.physicalKey(31, horizontalPosition: 0.50, keyWidth: 1),
            GlowTarget.physicalKey(32, horizontalPosition: 0.70, keyWidth: 1)
        ]
        targets.forEach(harness.renderer.show)
        runLiquidGlassAnimation(for: 0.11)

        harness.renderer.hide(targets[0].id)
        harness.renderer.hide(targets[2].id)
        XCTAssertEqual(
            harness.renderer.testActiveTargetIDs,
            [targets[1].id]
        )
        XCTAssertTrue(
            harness.renderer.testSurfaceSnapshots.contains {
                $0.id == targets[1].id && $0.isVisible
            }
        )

        runLiquidGlassAnimation(for: 0.17)
        XCTAssertEqual(
            harness.renderer.testSurfaceSnapshots.map(\.id),
            [targets[1].id]
        )

        harness.renderer.hide(targets[1].id)
        runLiquidGlassAnimation(for: 0.17)
        XCTAssertTrue(harness.renderer.testSurfaceSnapshots.isEmpty)
    }

    @MainActor
    func testInvalidGeometryInputsRemainFiniteAndClamped() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                baseKeyWidth: .infinity,
                glowHeight: .nan,
                widthMultiplier: -.infinity,
                maximumOpacity: .nan,
                fadeDuration: .nan,
                roundness: .infinity,
                fullness: -.infinity
            )
        )
        harness.renderer.show(
            .physicalKey(3, horizontalPosition: .nan, keyWidth: .infinity)
        )
        runLiquidGlassAnimation(for: 0.02)

        let visible = harness.renderer.testSurfaceSnapshots.filter(\.isVisible)
        XCTAssertEqual(visible.count, 1)
        let primary = try XCTUnwrap(visible.first)

        XCTAssertTrue(primary.frame.minX.isFinite)
        XCTAssertTrue(primary.frame.minY.isFinite)
        XCTAssertTrue(primary.frame.width.isFinite)
        XCTAssertTrue(primary.frame.height.isFinite)
        XCTAssertTrue(primary.opacity.isFinite)
        XCTAssertTrue(primary.emergence.isFinite)
        XCTAssertGreaterThanOrEqual(primary.frame.width, 8)
        XCTAssertLessThanOrEqual(
            primary.frame.width,
            max(harness.renderer.bounds.width * 1.25, 64)
        )
        XCTAssertGreaterThanOrEqual(primary.frame.height, 4)
        XCTAssertLessThanOrEqual(
            primary.frame.height,
            max(harness.renderer.bounds.height * 0.48, 4)
        )
    }

    @MainActor
    func testPhysicalPressGrowsFromScreenEdgeAndFinalFadeUsesSelectedDuration() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .rainbow,
                glowHeight: 80,
                maximumOpacity: 0.7,
                fadeDuration: 0.8
            )
        )

        let id = GlowID.physicalKey(62)
        harness.renderer.show(.physicalKey(62, horizontalPosition: 0.5, keyWidth: 1))

        let collapsed = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertTrue(collapsed.isVisible)
        XCTAssertLessThanOrEqual(collapsed.opacity, 0.01)
        XCTAssertLessThanOrEqual(collapsed.emergence, 0.01)
        XCTAssertEqual(
            collapsed.frame.maxY,
            collapsed.frame.height * 0.72,
            accuracy: 0.000_001
        )

        runLiquidGlassAnimation(for: 0.035)
        let motionProfile = LiquidGlassMotionProfile(fadeDuration: 0.8)
        XCTAssertTrue(
            harness.renderer.testActiveTransitionDurations.contains {
                abs($0 - motionProfile.revealDuration) < 0.000_001
            }
        )
        let emerging = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertGreaterThan(emerging.opacity, 0)
        XCTAssertGreaterThan(emerging.emergence, 0)
        XCTAssertLessThan(emerging.emergence, 1)

        runLiquidGlassAnimation(for: 0.36)
        let expanded = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertEqual(expanded.emergence, 1, accuracy: 0.000_001)
        XCTAssertEqual(expanded.opacity, 0.7, accuracy: 0.000_001)

        harness.renderer.hide(id)
        XCTAssertTrue(
            harness.renderer.testActiveTransitionDurations.contains {
                abs($0 - 0.8) < 0.000_001
            },
            "The configured Fade Duration must govern both opacity and the return into the bezel"
        )

        runLiquidGlassAnimation(for: 0.58)
        let fading = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertTrue(fading.isVisible, "The glass must not vanish before Fade Duration completes")
        XCTAssertGreaterThan(fading.opacity, 0)
        XCTAssertLessThan(fading.opacity, expanded.opacity)
        XCTAssertGreaterThan(fading.emergence, 0)
        XCTAssertLessThan(fading.emergence, 1)

        runLiquidGlassAnimation(for: 0.29)
        XCTAssertTrue(harness.renderer.testSurfaceSnapshots.isEmpty)
    }

    @MainActor
    func testNearbyKeysRetargetThePersistentPrimaryWithoutOutgoingCopies() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.apply(
            RendererConfiguration(colorMode: .solid(.systemBlue), maximumOpacity: 0.6)
        )
        harness.renderer.show(.physicalKey(1, horizontalPosition: 0.50, keyWidth: 1))
        runLiquidGlassAnimation(for: 0.34)

        harness.renderer.hide(.physicalKey(1))
        harness.renderer.show(.physicalKey(2, horizontalPosition: 0.54, keyWidth: 1))
        XCTAssertTrue(harness.renderer.testTimelineIsActive)
        let nearbyDuration = harness.renderer.testMotionProfile.nearbyMorphDuration
        XCTAssertTrue(
            harness.renderer.testActiveTransitionDurations.contains {
                abs($0 - nearbyDuration) < 0.000_001
            }
        )
        XCTAssertEqual(harness.renderer.testSurfaceSnapshots.count, 1)

        runLiquidGlassAnimation(for: nearbyDuration * 0.5)
        let middle = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertGreaterThan(middle.frame.midX, 500)
        XCTAssertLessThan(middle.frame.midX, 540)

        runLiquidGlassAnimation(for: nearbyDuration * 0.7 + 0.03)
        XCTAssertEqual(
            harness.renderer.testSurfaceSnapshots[0].frame.midX,
            540,
            accuracy: 0.5
        )
        XCTAssertFalse(harness.renderer.testTimelineIsActive)
    }

    @MainActor
    func testDistantKeyUsesOneStretchedFlowingSurface() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.apply(
            RendererConfiguration(colorMode: .solid(.systemBlue), maximumOpacity: 0.55)
        )
        harness.renderer.show(.physicalKey(3, horizontalPosition: 0.10, keyWidth: 1))
        runLiquidGlassAnimation(for: 0.34)
        let resting = harness.renderer.testSurfaceSnapshots[0]

        harness.renderer.hide(.physicalKey(3))
        harness.renderer.show(.physicalKey(4, horizontalPosition: 0.90, keyWidth: 1))
        let travelDuration = try XCTUnwrap(
            harness.renderer.testActiveTransitionDurations.first
        )
        XCTAssertGreaterThan(
            travelDuration,
            harness.renderer.testMotionProfile.nearbyMorphDuration
        )

        runLiquidGlassAnimation(for: travelDuration * 0.35)
        let flowing = harness.renderer.testSurfaceSnapshots
        XCTAssertEqual(flowing.count, 1)
        XCTAssertTrue(flowing[0].isVisible)
        XCTAssertEqual(flowing[0].opacity, 0.55, accuracy: 0.000_1)
        XCTAssertGreaterThan(flowing[0].frame.width, resting.frame.width)
        XCTAssertGreaterThan(flowing[0].frame.midX, resting.frame.midX)
        XCTAssertLessThan(flowing[0].frame.midX, 900)

        runLiquidGlassAnimation(for: travelDuration * 0.75 + 0.03)
        let settled = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertEqual(settled.frame.midX, 900, accuracy: 0.5)
        XCTAssertEqual(settled.frame.width, resting.frame.width, accuracy: 0.5)
        XCTAssertFalse(harness.renderer.testTimelineIsActive)
    }

    @MainActor
    func testInterruptedNearbyMorphPreservesPresentationVelocityBeforeReversing() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.show(.physicalKey(5, horizontalPosition: 0.40, keyWidth: 1))
        runLiquidGlassAnimation(for: 0.34)
        harness.renderer.hide(.physicalKey(5))
        harness.renderer.show(.physicalKey(6, horizontalPosition: 0.48, keyWidth: 1))
        runLiquidGlassAnimation(for: 0.06)

        let beforeReversal = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertGreaterThan(beforeReversal.horizontalVelocity, 0)
        harness.renderer.hide(.physicalKey(6))
        harness.renderer.show(.physicalKey(7, horizontalPosition: 0.32, keyWidth: 1))
        let afterRetarget = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertEqual(afterRetarget.frame.midX, beforeReversal.frame.midX, accuracy: 1)
        XCTAssertGreaterThan(afterRetarget.horizontalVelocity, 0)

        runLiquidGlassAnimation(for: 0.23)
        XCTAssertEqual(
            harness.renderer.testSurfaceSnapshots[0].frame.midX,
            320,
            accuracy: 0.5
        )
    }

    @MainActor
    func testPreviewOpacityAndSmoothnessTrackLiveConfiguration() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.show(.preview(.settings, horizontalPosition: 0.5, keyWidth: 1))
        runLiquidGlassAnimation(for: 0.22)

        var edgeOpacities: [Double] = []
        var lensOpacities: [Double] = []
        var dimmingOpacities: [Double] = []
        var chromaticDisplacements: [CGFloat] = []
        for (opacity, smoothness) in [(0.05, 0.0), (0.50, 0.5), (1.0, 1.0)] {
            harness.renderer.apply(
                RendererConfiguration(
                    colorMode: .solid(.systemBlue),
                    maximumOpacity: Float(opacity),
                    roundness: CGFloat(smoothness)
                )
            )
            runLiquidGlassAnimation(for: 0.12)
            let surface = harness.renderer.testSurfaceSnapshots[0]
            XCTAssertEqual(surface.opacity, opacity, accuracy: 0.000_001)
            XCTAssertEqual(surface.smoothness, smoothness, accuracy: 0.000_001)
            edgeOpacities.append(surface.edgeOpacity)
            lensOpacities.append(surface.lensOpacity)
            dimmingOpacities.append(surface.dimmingOpacity)
            chromaticDisplacements.append(surface.chromaticDisplacement)
        }

        XCTAssertGreaterThan(edgeOpacities[0], edgeOpacities[1])
        XCTAssertGreaterThan(edgeOpacities[1], edgeOpacities[2])
        XCTAssertGreaterThan(lensOpacities[0], lensOpacities[1])
        XCTAssertGreaterThan(lensOpacities[1], lensOpacities[2])
        XCTAssertLessThan(dimmingOpacities[0], dimmingOpacities[1])
        XCTAssertLessThan(dimmingOpacities[1], dimmingOpacities[2])
        XCTAssertGreaterThan(chromaticDisplacements[0], chromaticDisplacements[1])
        XCTAssertGreaterThan(chromaticDisplacements[1], chromaticDisplacements[2])
    }

    @MainActor
    func testFadeDurationChangeRetimesPreviewWithoutAnOpacityOrPositionJump() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.show(.preview(.settings, horizontalPosition: 0.5, keyWidth: 1))
        runLiquidGlassAnimation(for: 0.24)

        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                fadeDuration: 0.2
            )
        )
        let fastProfile = LiquidGlassMotionProfile(fadeDuration: 0.2)
        let fastStart = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertEqual(fastStart.visibility, 1, accuracy: 0.000_001)
        XCTAssertEqual(fastStart.opacity, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(fastStart.frame.midX, 500, accuracy: 0.5)
        XCTAssertEqual(
            try XCTUnwrap(harness.renderer.testActiveTransitionDurations.first),
            fastProfile.revealDuration,
            accuracy: 0.000_001
        )
        runLiquidGlassAnimation(for: fastProfile.revealDuration * 0.35)
        XCTAssertGreaterThan(
            harness.renderer.testSurfaceSnapshots[0].frame.width,
            fastStart.frame.width
        )
        runLiquidGlassAnimation(for: fastProfile.revealDuration + 0.03)
        let fastSettled = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertEqual(fastSettled.visibility, 1, accuracy: 0.000_001)
        XCTAssertEqual(fastSettled.opacity, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(fastSettled.frame.midX, 500, accuracy: 0.5)

        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                fadeDuration: 1.8
            )
        )
        let slowProfile = LiquidGlassMotionProfile(fadeDuration: 1.8)
        XCTAssertGreaterThan(slowProfile.revealDuration, fastProfile.revealDuration)
        XCTAssertEqual(
            try XCTUnwrap(harness.renderer.testActiveTransitionDurations.first),
            slowProfile.revealDuration,
            accuracy: 0.000_001
        )
        let slowStart = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertEqual(slowStart.visibility, 1, accuracy: 0.000_001)
        XCTAssertEqual(slowStart.opacity, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(slowStart.frame.midX, 500, accuracy: 0.5)
    }

    @MainActor
    func testReduceMotionSnapsShapeGeometryAndUsesOpacityOnly() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }
        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                fadeDuration: 0.5,
                reduceMotion: true
            )
        )

        let id = GlowID.physicalKey(10)
        harness.renderer.show(.physicalKey(10, horizontalPosition: 0.42, keyWidth: 1))
        XCTAssertEqual(
            harness.renderer.testSurfaceSnapshots[0].emergence,
            1,
            accuracy: 0.000_001
        )

        runLiquidGlassAnimation(for: 0.025)
        let revealDuration = LiquidGlassMotionProfile(fadeDuration: 0.5).revealDuration
        XCTAssertTrue(
            harness.renderer.testActiveTransitionDurations.contains {
                abs($0 - revealDuration) < 0.000_001
            }
        )
        XCTAssertEqual(
            harness.renderer.testSurfaceSnapshots[0].emergence,
            1,
            accuracy: 0.000_001
        )

        harness.renderer.hide(id)
        runLiquidGlassAnimation(for: 0.25)
        let fading = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertTrue(fading.isVisible)
        XCTAssertEqual(fading.emergence, 1, accuracy: 0.000_001)
        XCTAssertGreaterThan(fading.opacity, 0)
    }

    @MainActor
    func testConfigurationRefreshRetargetsGeometryAndMaterialWithoutResurrection() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }

        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemRed),
                glowHeight: 40,
                widthMultiplier: 0.8,
                reduceMotion: true
            )
        )
        let id = GlowID.physicalKey(50)
        harness.renderer.show(.physicalKey(50, horizontalPosition: 0.5, keyWidth: 1))
        runLiquidGlassAnimation(for: 0.23)
        let original = harness.renderer.testSurfaceSnapshots[0]

        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemBlue),
                glowHeight: 180,
                widthMultiplier: 2.2,
                maximumOpacity: 0.25,
                fadeDuration: 0.6,
                reduceMotion: true,
                reduceTransparency: true,
                increaseContrast: true
            )
        )
        runLiquidGlassAnimation(for: 0.12)

        let refreshed = harness.renderer.testSurfaceSnapshots[0]
        XCTAssertGreaterThan(refreshed.frame.width, original.frame.width)
        XCTAssertGreaterThan(refreshed.frame.height, original.frame.height)
        XCTAssertEqual(
            refreshed.opacity,
            Double(
                LiquidGlassMaterialMath.displayOpacity(
                    userOpacity: 0.25,
                    reduceTransparency: true,
                    increaseContrast: true
                )
            ),
            accuracy: 0.000_001
        )

        harness.renderer.hide(id)
        let retreatFrame = harness.renderer.testSurfaceSnapshots[0].frame
        harness.renderer.apply(
            RendererConfiguration(
                colorMode: .solid(.systemGreen),
                glowHeight: 4,
                widthMultiplier: 0.1
            )
        )
        let unchangedRetreatFrame = harness.renderer.testSurfaceSnapshots[0].frame
        XCTAssertEqual(unchangedRetreatFrame.minX, retreatFrame.minX, accuracy: 0.000_001)
        XCTAssertEqual(unchangedRetreatFrame.minY, retreatFrame.minY, accuracy: 0.000_001)
        XCTAssertEqual(unchangedRetreatFrame.width, retreatFrame.width, accuracy: 0.000_001)
        XCTAssertEqual(unchangedRetreatFrame.height, retreatFrame.height, accuracy: 0.000_001)

        runLiquidGlassAnimation(for: 0.68)
        XCTAssertTrue(harness.renderer.testSurfaceSnapshots.isEmpty)
    }

    @MainActor
    func testRefreshReportsOnlyTheCurrentVisibleIdentity() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer {
            harness.renderer.clear()
            harness.window.close()
        }

        XCTAssertFalse(harness.renderer.refresh(.physicalKey(20)))
        harness.renderer.show(.physicalKey(20, horizontalPosition: 0.3, keyWidth: 1))
        XCTAssertTrue(harness.renderer.refresh(.physicalKey(20)))

        harness.renderer.show(.physicalKey(21, horizontalPosition: 0.7, keyWidth: 1))
        harness.renderer.hide(.physicalKey(20))
        XCTAssertFalse(harness.renderer.refresh(.physicalKey(20)))
        XCTAssertTrue(harness.renderer.refresh(.physicalKey(21)))

        harness.renderer.hide(.physicalKey(21))
        XCTAssertFalse(harness.renderer.refresh(.physicalKey(21)))
        harness.renderer.clear()
        XCTAssertTrue(harness.renderer.testSurfaceSnapshots.allSatisfy { !$0.isVisible })
    }

    @MainActor
    func testClearAndStyleSwitchCannotResurrectCapturedSurfaces() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native Liquid Glass requires macOS 26")
        }

        let harness = try makeLiquidGlassHarness()
        defer { harness.window.close() }

        harness.renderer.show(.physicalKey(30, horizontalPosition: 0.4, keyWidth: 1))
        runLiquidGlassAnimation(for: 0.03)
        harness.renderer.clear()
        XCTAssertTrue(harness.renderer.testSurfaceSnapshots.allSatisfy { !$0.isVisible })

        harness.renderer.show(.physicalKey(31, horizontalPosition: 0.6, keyWidth: 1))
        runLiquidGlassAnimation(for: 0.03)
        harness.window.setEffectStyle(.classicGlow)
        XCTAssertTrue(harness.renderer.testSurfaceSnapshots.allSatisfy { !$0.isVisible })

        harness.window.setEffectStyle(.systemGlass)
        let reused = try XCTUnwrap(harness.window.glowRenderer as? LiquidGlassGlowView)
        XCTAssertTrue(reused === harness.renderer)
        XCTAssertEqual(reused.testHostingViewCount, 1)
        XCTAssertTrue(reused.testSurfaceSnapshots.isEmpty)
    }
}
#endif
