import AppKit
import XCTest

#if canImport(KeyLight)
@testable import KeyLight
#endif

final class OverlayControllerTests: XCTestCase {
    func testBuiltInDisplayWinsOverMainAndExternalDisplays() {
        let candidates = [
            OverlayDisplayCandidate(id: 10, isBuiltIn: false, isMain: true),
            OverlayDisplayCandidate(id: 20, isBuiltIn: true, isMain: false),
            OverlayDisplayCandidate(id: 30, isBuiltIn: false, isMain: false)
        ]

        XCTAssertEqual(OverlayDisplayResolver.targetID(in: candidates), 20)
    }

    func testMainDisplayIsFallbackWhenNoBuiltInDisplayExists() {
        let candidates = [
            OverlayDisplayCandidate(id: 10, isBuiltIn: false, isMain: false),
            OverlayDisplayCandidate(id: 20, isBuiltIn: false, isMain: true)
        ]

        XCTAssertEqual(OverlayDisplayResolver.targetID(in: candidates), 20)
    }

    func testFirstDisplayIsDeterministicLastFallback() {
        let candidates = [
            OverlayDisplayCandidate(id: 10, isBuiltIn: false, isMain: false),
            OverlayDisplayCandidate(id: 20, isBuiltIn: false, isMain: false)
        ]

        XCTAssertEqual(OverlayDisplayResolver.targetID(in: candidates), 10)
        XCTAssertNil(OverlayDisplayResolver.targetID(in: []))
    }

    func testExplicitDisplaySelectionsUseStableIdentityAndSafeFallbacks() {
        let candidates = [
            OverlayDisplayCandidate(
                id: 10,
                persistentID: "external",
                name: "Studio Display",
                isBuiltIn: false,
                isMain: true
            ),
            OverlayDisplayCandidate(
                id: 20,
                persistentID: "internal",
                name: "Built-in Display",
                isBuiltIn: true,
                isMain: false
            )
        ]

        XCTAssertEqual(
            OverlayDisplayResolver.targetID(in: candidates, selection: .specific("external")),
            10
        )
        XCTAssertEqual(
            OverlayDisplayResolver.targetID(in: candidates, selection: .main),
            10
        )
        XCTAssertEqual(
            OverlayDisplayResolver.targetID(in: candidates, selection: .builtIn),
            20
        )
        XCTAssertEqual(
            OverlayDisplayResolver.targetID(in: candidates, selection: .specific("disconnected")),
            20,
            "A disconnected explicit display must retain the original automatic fallback"
        )
    }

    func testDisplaySelectionPersistenceRejectsMalformedSpecificValues() {
        XCTAssertEqual(OverlayDisplaySelection(persistedValue: nil), .automatic)
        XCTAssertEqual(OverlayDisplaySelection(persistedValue: "unknown"), .automatic)
        XCTAssertEqual(OverlayDisplaySelection(persistedValue: "display:"), .automatic)
        XCTAssertEqual(
            OverlayDisplaySelection(persistedValue: "display:stable-id"),
            .specific("stable-id")
        )
        XCTAssertEqual(OverlayDisplaySelection.main.persistedValue, "main")
    }

    @MainActor
    func testControllerRetargetsWhenDisplaySelectionChanges() {
        let source = MutableOverlayDisplaySource(displays: [
            OverlayDisplayCandidate(
                id: 10,
                persistentID: "external",
                name: "Studio Display",
                isBuiltIn: false,
                isMain: true,
                frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
            ),
            OverlayDisplayCandidate(
                id: 20,
                persistentID: "internal",
                name: "Built-in Display",
                isBuiltIn: true,
                isMain: false,
                frame: CGRect(x: 1_920, y: 0, width: 1_440, height: 900)
            )
        ])
        var panels: [FakeOverlayPanel] = []
        let controller = OverlayController(
            displayProvider: { source.displays },
            windowFactory: { frame in
                let panel = FakeOverlayPanel(frame: frame)
                panels.append(panel)
                return panel
            }
        )

        controller.start()
        XCTAssertEqual(controller.activeDisplayPersistentID, "internal")

        controller.setDisplaySelection(.specific("external"))

        XCTAssertEqual(controller.activeDisplayPersistentID, "external")
        XCTAssertEqual(controller.availableDisplays.map(\.id), ["external", "internal"])
        XCTAssertEqual(panels.count, 2)
        XCTAssertTrue(panels[0].isClosed)
    }

    @MainActor
    func testControllerKeepsExactlyOnePanelAndRetargetsTopology() {
        let displaySource = MutableOverlayDisplaySource(displays: [
            OverlayDisplayCandidate(
                id: 10,
                isBuiltIn: true,
                isMain: true,
                frame: CGRect(x: 20, y: 30, width: 1_440, height: 900)
            )
        ])
        var panels: [FakeOverlayPanel] = []
        let controller = OverlayController(
            displayProvider: { displaySource.displays },
            windowFactory: { frame in
                let panel = FakeOverlayPanel(frame: frame)
                panels.append(panel)
                return panel
            }
        )

        controller.start()
        controller.updateDisplayTopology()

        XCTAssertEqual(panels.count, 1)
        XCTAssertEqual(panels[0].frame, CGRect(x: 20, y: 30, width: 1_440, height: 120))
        XCTAssertEqual(panels[0].orderFrontCount, 1)
        XCTAssertFalse(panels[0].isClosed)

        displaySource.displays = [
            OverlayDisplayCandidate(
                id: 20,
                isBuiltIn: false,
                isMain: true,
                frame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
            )
        ]
        controller.updateDisplayTopology()

        XCTAssertEqual(panels.count, 2)
        XCTAssertTrue(panels[0].isClosed)
        XCTAssertEqual(panels[1].frame, CGRect(x: -1_920, y: 0, width: 1_920, height: 120))
        XCTAssertEqual(controller.activeDisplayID, 20)
    }

    @MainActor
    func testSameDisplayResizePreservesAndRedrawsHeldPhysicalTarget() {
        let displaySource = MutableOverlayDisplaySource(displays: [
            OverlayDisplayCandidate(
                id: 10,
                isBuiltIn: true,
                isMain: true,
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            )
        ])
        let panel = FakeOverlayPanel(frame: .zero)
        var physicalEvents: [KeyboardEvent] = []
        let controller = OverlayController(
            displayProvider: { displaySource.displays },
            windowFactory: { frame in
                panel.setFrame(frame, display: false)
                return panel
            },
            onPhysicalEvent: { physicalEvents.append($0) }
        )
        let preview = GlowTarget.preview(
            .settings,
            horizontalPosition: 0.5,
            keyWidth: 1
        )

        controller.start()
        controller.setPreview(preview, source: .settings)
        controller.handle(
            .keyDown(12, source: .eventTap, timestamp: 1),
            target: .physicalKey(12, horizontalPosition: 0.2, keyWidth: 1)
        )
        displaySource.displays = [
            OverlayDisplayCandidate(
                id: 10,
                isBuiltIn: true,
                isMain: true,
                frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
            )
        ]

        controller.updateDisplayTopology()

        XCTAssertEqual(panel.frame, CGRect(x: 0, y: 0, width: 1_200, height: 120))
        XCTAssertEqual(
            controller.resolvedTarget,
            .physicalKey(12, horizontalPosition: 0.2, keyWidth: 1)
        )
        XCTAssertEqual(physicalEvents.map(\.action), [.down])
        XCTAssertEqual(panel.renderer.shown, [
            preview,
            .physicalKey(12, horizontalPosition: 0.2, keyWidth: 1),
            .physicalKey(12, horizontalPosition: 0.2, keyWidth: 1)
        ])
        XCTAssertEqual(panel.renderer.clearCount, 1)
    }

    @MainActor
    func testAtomicConfigurationAndInteractionPriorityReachRenderer() {
        let panel = FakeOverlayPanel(frame: .zero)
        var physicalEvents: [KeyboardEvent] = []
        let controller = OverlayController(
            displayProvider: {
                [OverlayDisplayCandidate(
                    id: 1,
                    isBuiltIn: true,
                    isMain: true,
                    frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
                )]
            },
            windowFactory: { _ in panel },
            onPhysicalEvent: { physicalEvents.append($0) }
        )
        let configuration = RendererConfiguration(
            colorMode: .rainbow,
            glowHeight: 77,
            maximumOpacity: 0.42,
            reduceMotion: true
        )
        let settingsPreview = GlowTarget.preview(
            .settings,
            horizontalPosition: 0.5,
            keyWidth: 1
        )
        let physicalTarget = GlowTarget.physicalKey(
            12,
            horizontalPosition: 0.2,
            keyWidth: 1.4
        )

        controller.start()
        controller.apply(effectStyle: .classicGlow, configuration: configuration)
        controller.setPreview(settingsPreview, source: .settings)
        controller.handle(
            .keyDown(12, source: .eventTap, timestamp: 1),
            target: physicalTarget
        )
        controller.handle(.keyUp(12, source: .eventTap, timestamp: 2))

        XCTAssertEqual(panel.renderer.applied.last, configuration)
        XCTAssertEqual(panel.renderer.shown, [settingsPreview, physicalTarget, settingsPreview])
        XCTAssertEqual(panel.renderer.hidden, [.preview(.settings), .physicalKey(12)])
        XCTAssertEqual(physicalEvents.count, 2)
        XCTAssertEqual(controller.resolvedTarget, settingsPreview)
    }

    @MainActor
    func testStreamResetIsForwardedToCalibrationActivity() {
        let panel = FakeOverlayPanel(frame: .zero)
        var physicalEvents: [KeyboardEvent] = []
        let controller = OverlayController(
            displayProvider: {
                [OverlayDisplayCandidate(
                    id: 1,
                    isBuiltIn: true,
                    isMain: true,
                    frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
                )]
            },
            windowFactory: { _ in panel },
            onPhysicalEvent: { physicalEvents.append($0) }
        )

        controller.start()
        controller.handle(
            .keyDown(12, source: .eventTap, timestamp: 1),
            target: .physicalKey(12, horizontalPosition: 0.5, keyWidth: 1)
        )
        controller.handle(.streamReset(source: .lifecycle, timestamp: 2))

        XCTAssertEqual(physicalEvents.map(\.action), [.down, .streamReset])
    }

    @MainActor
    func testControllerRestoresNewestRemainingChordKey() {
        let panel = FakeOverlayPanel(frame: .zero)
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
        let first = GlowTarget.physicalKey(10, horizontalPosition: 0.2, keyWidth: 1)
        let second = GlowTarget.physicalKey(11, horizontalPosition: 0.8, keyWidth: 1)

        controller.start()
        controller.handle(
            .keyDown(10, source: .eventTap, timestamp: 1),
            target: first
        )
        controller.handle(
            .keyDown(11, source: .eventTap, timestamp: 2),
            target: second
        )
        controller.handle(.keyUp(11, source: .eventTap, timestamp: 3))

        XCTAssertEqual(panel.renderer.shown, [first, second, first])
        XCTAssertEqual(panel.renderer.hidden, [.physicalKey(11)])
        XCTAssertEqual(controller.resolvedTarget, first)
    }

    @MainActor
    func testConcurrentRendererKeepsEveryHeldKeyAndReleasesOnlyItsOwnIdentity() {
        let panel = FakeOverlayPanel(
            frame: .zero,
            supportsConcurrentPhysicalTargets: true
        )
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
        let preview = GlowTarget.preview(
            .settings,
            horizontalPosition: 0.5,
            keyWidth: 1
        )
        let first = GlowTarget.physicalKey(
            10,
            horizontalPosition: 0.20,
            keyWidth: 1
        )
        let second = GlowTarget.physicalKey(
            11,
            horizontalPosition: 0.26,
            keyWidth: 1
        )

        controller.start()
        controller.setPreview(preview, source: .settings)
        controller.handle(
            .keyDown(10, source: .eventTap, timestamp: 1),
            target: first
        )
        controller.handle(
            .keyDown(11, source: .eventTap, timestamp: 2),
            target: second
        )
        controller.handle(.keyUp(10, source: .eventTap, timestamp: 3))

        XCTAssertEqual(panel.renderer.shown, [preview, first, second])
        XCTAssertEqual(
            panel.renderer.hidden,
            [.preview(.settings), .physicalKey(10)]
        )
        XCTAssertEqual(controller.resolvedTarget, second)

        controller.handle(.keyUp(11, source: .eventTap, timestamp: 4))

        XCTAssertEqual(panel.renderer.shown, [preview, first, second, preview])
        XCTAssertEqual(
            panel.renderer.hidden,
            [.preview(.settings), .physicalKey(10), .physicalKey(11)]
        )
        XCTAssertEqual(controller.resolvedTarget, preview)
    }

    @MainActor
    func testEphemeralChordPreviewShowsTogetherAndPhysicalInputTemporarilyWins() {
        let panel = FakeOverlayPanel(
            frame: .zero,
            supportsConcurrentPhysicalTargets: true
        )
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
        let settings = GlowTarget.preview(.settings, horizontalPosition: 0.5, keyWidth: 1)
        let chord = PreviewSource.chordTestSources.enumerated().map { index, source in
            GlowTarget.preview(
                source,
                colorReferenceKeyCode: UInt16(index),
                horizontalPosition: 0.3 + Double(index) * 0.1,
                keyWidth: 1
            )
        }
        let physical = GlowTarget.physicalKey(18, horizontalPosition: 0.2, keyWidth: 1)

        controller.start()
        controller.setPreview(settings, source: .settings)
        controller.setChordPreview(chord)

        XCTAssertEqual(Array(panel.renderer.shown.suffix(4)), chord)
        XCTAssertEqual(panel.renderer.hidden.last, settings.id)

        controller.handle(.keyDown(18, source: .eventTap, timestamp: 1), target: physical)
        XCTAssertEqual(Array(panel.renderer.hidden.suffix(4)), chord.map(\.id))
        XCTAssertEqual(panel.renderer.shown.last, physical)

        controller.handle(.keyUp(18, source: .eventTap, timestamp: 2))
        XCTAssertEqual(Array(panel.renderer.shown.suffix(4)), chord)

        controller.clearChordPreview()
        XCTAssertEqual(panel.renderer.shown.last, settings)
        XCTAssertTrue(controller.activePreviewSources.contains(.settings))
        XCTAssertFalse(controller.activePreviewSources.contains(where: { $0.isChordTest }))
    }

    @MainActor
    func testDisablingClearsRuntimeAndNeverResurrectsPreview() {
        let panel = FakeOverlayPanel(frame: .zero)
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
        controller.start()
        controller.setPreview(
            .preview(.settings, horizontalPosition: 0.5, keyWidth: 1),
            source: .settings
        )

        controller.setEnabled(false)
        controller.setPreview(
            .preview(.settings, horizontalPosition: 0.6, keyWidth: 1),
            source: .settings
        )
        controller.setEnabled(true)

        XCTAssertNil(controller.resolvedTarget)
        XCTAssertEqual(panel.renderer.clearCount, 1)
        XCTAssertEqual(panel.renderer.shown.count, 1)
    }

    @MainActor
    func testMirroringBroadcastsConfigurationAndHeldKeysToThreePanels() {
        let source = MutableOverlayDisplaySource(displays: [
            display(id: 1, persistentID: "primary", builtIn: true, main: true),
            display(id: 2, persistentID: "left", x: -1_000),
            display(id: 3, persistentID: "right", x: 1_000)
        ])
        var panels: [FakeOverlayPanel] = []
        let controller = OverlayController(
            displayProvider: { source.displays },
            windowFactory: { frame in
                let panel = FakeOverlayPanel(
                    frame: frame,
                    supportsConcurrentPhysicalTargets: true
                )
                panels.append(panel)
                return panel
            }
        )

        controller.setMirroredDisplayIDs(["left", "right"])
        controller.start()
        XCTAssertEqual(panels.count, 3)
        XCTAssertEqual(
            controller.activeDisplayPersistentIDs,
            ["primary", "left", "right"]
        )

        let configuration = RendererConfiguration(
            colorMode: .rainbow,
            maximumOpacity: 0.44
        )
        controller.apply(effectStyle: .systemGlass, configuration: configuration)
        XCTAssertTrue(panels.allSatisfy { $0.renderer.applied.last == configuration })
        XCTAssertTrue(panels.allSatisfy { $0.effectStyles.last == .systemGlass })

        let first = GlowTarget.physicalKey(10, horizontalPosition: 0.25, keyWidth: 1)
        let second = GlowTarget.physicalKey(11, horizontalPosition: 0.75, keyWidth: 1.2)
        controller.handle(
            .keyDown(10, source: .eventTap, timestamp: 1),
            target: first
        )
        controller.handle(
            .keyDown(11, source: .eventTap, timestamp: 2),
            target: second
        )
        XCTAssertTrue(panels.allSatisfy { $0.renderer.shown.suffix(2) == [first, second] })

        controller.handle(.keyUp(10, source: .eventTap, timestamp: 3))
        XCTAssertTrue(panels.allSatisfy { $0.renderer.hidden.last == first.id })
        XCTAssertEqual(controller.resolvedTarget, second)
    }

    @MainActor
    func testPrimaryMirrorDeduplicationClosesTheFormerPrimaryPanel() {
        let source = MutableOverlayDisplaySource(displays: [
            display(id: 1, persistentID: "internal", builtIn: true),
            display(id: 2, persistentID: "external", main: true)
        ])
        var panels: [FakeOverlayPanel] = []
        let controller = OverlayController(
            displayProvider: { source.displays },
            windowFactory: { frame in
                let panel = FakeOverlayPanel(frame: frame)
                panels.append(panel)
                return panel
            }
        )

        controller.setMirroredDisplayIDs(["external"])
        controller.start()
        XCTAssertEqual(Set(controller.activeDisplayPersistentIDs), ["internal", "external"])

        controller.setDisplaySelection(.specific("external"))

        XCTAssertEqual(controller.activeDisplayPersistentIDs, ["external"])
        XCTAssertEqual(panels.filter { !$0.isClosed }.count, 1)
        XCTAssertTrue(panels[0].isClosed)
    }

    @MainActor
    func testDisconnectedMirrorReturnsWithItsStableIDAndNewDisplayID() {
        let source = MutableOverlayDisplaySource(displays: [
            display(id: 1, persistentID: "primary", builtIn: true, main: true),
            display(id: 2, persistentID: "mirror")
        ])
        var panels: [FakeOverlayPanel] = []
        let controller = OverlayController(
            displayProvider: { source.displays },
            windowFactory: { frame in
                let panel = FakeOverlayPanel(frame: frame)
                panels.append(panel)
                return panel
            }
        )
        controller.setMirroredDisplayIDs(["mirror"])
        controller.start()
        XCTAssertEqual(controller.activeDisplayPersistentIDs.count, 2)

        source.displays.removeAll { $0.persistentID == "mirror" }
        controller.updateDisplayTopology()
        XCTAssertEqual(controller.activeDisplayPersistentIDs, ["primary"])
        XCTAssertTrue(panels[1].isClosed)

        source.displays.append(display(
            id: 42,
            persistentID: "mirror",
            x: 1_000
        ))
        controller.updateDisplayTopology()
        XCTAssertEqual(
            controller.activeDisplayPersistentIDs,
            ["primary", "mirror"]
        )
        XCTAssertEqual(panels.filter { !$0.isClosed }.count, 2)
        XCTAssertEqual(panels.count, 3)
    }

    @MainActor
    func testMirrorResizeReplaysHeldStateOnlyOnTheAffectedPanel() {
        let source = MutableOverlayDisplaySource(displays: [
            display(id: 1, persistentID: "primary", builtIn: true, main: true),
            display(id: 2, persistentID: "mirror", x: 1_000)
        ])
        var panels: [FakeOverlayPanel] = []
        let controller = OverlayController(
            displayProvider: { source.displays },
            windowFactory: { frame in
                let panel = FakeOverlayPanel(
                    frame: frame,
                    supportsConcurrentPhysicalTargets: true
                )
                panels.append(panel)
                return panel
            }
        )
        controller.setMirroredDisplayIDs(["mirror"])
        controller.start()
        let held = GlowTarget.physicalKey(7, horizontalPosition: 0.4, keyWidth: 1)
        controller.handle(
            .keyDown(7, source: .eventTap, timestamp: 1),
            target: held
        )
        let primaryClearCount = panels[0].renderer.clearCount
        let mirrorClearCount = panels[1].renderer.clearCount

        source.displays[1] = display(
            id: 2,
            persistentID: "mirror",
            x: 1_000,
            width: 1_400
        )
        controller.updateDisplayTopology()

        XCTAssertEqual(panels[0].renderer.clearCount, primaryClearCount)
        XCTAssertEqual(panels[1].renderer.clearCount, mirrorClearCount + 1)
        XCTAssertEqual(panels[1].renderer.shown.last, held)
        XCTAssertEqual(controller.resolvedTarget, held)
    }

    @MainActor
    func testRuntimeStatusAggregatesWorstPanelAndPublishesStableIDs() {
        let source = MutableOverlayDisplaySource(displays: [
            display(id: 1, persistentID: "primary", builtIn: true, main: true),
            display(id: 2, persistentID: "mirror", x: 1_000)
        ])
        var panels: [FakeOverlayPanel] = []
        let controller = OverlayController(
            displayProvider: { source.displays },
            windowFactory: { frame in
                let panel = FakeOverlayPanel(frame: frame)
                panels.append(panel)
                return panel
            }
        )
        var statuses: [EffectRuntimeStatus] = []
        controller.setRuntimeStatusHandler { statuses.append($0) }
        controller.setMirroredDisplayIDs(["mirror"])
        controller.start()

        panels[1].renderer.emitRuntimeState(GlowRendererRuntimeState(
            readiness: .fallback,
            captureState: .permissionRequired,
            fallbackReason: "Mirror fallback"
        ))
        XCTAssertEqual(statuses.last?.rendererReadiness, .fallback)
        XCTAssertEqual(statuses.last?.fallbackReason, "Mirror fallback")
        XCTAssertEqual(
            statuses.last?.activeDisplayPersistentIDs,
            ["primary", "mirror"]
        )

        panels[0].renderer.emitRuntimeState(GlowRendererRuntimeState(
            readiness: .failed,
            captureState: .failed,
            fallbackReason: "Primary failed"
        ))
        XCTAssertEqual(statuses.last?.rendererReadiness, .failed)
        XCTAssertEqual(statuses.last?.fallbackReason, "Primary failed")

        controller.shutdown()
        XCTAssertTrue(panels.allSatisfy(\.isClosed))
        XCTAssertTrue(controller.activeDisplayPersistentIDs.isEmpty)
    }

    private func display(
        id: CGDirectDisplayID,
        persistentID: String,
        builtIn: Bool = false,
        main: Bool = false,
        x: CGFloat = 0,
        width: CGFloat = 1_000
    ) -> OverlayDisplayCandidate {
        OverlayDisplayCandidate(
            id: id,
            persistentID: persistentID,
            name: persistentID.capitalized,
            isBuiltIn: builtIn,
            isMain: main,
            frame: CGRect(x: x, y: 0, width: width, height: 800)
        )
    }
}

@MainActor
private final class MutableOverlayDisplaySource {
    var displays: [OverlayDisplayCandidate]

    init(displays: [OverlayDisplayCandidate]) {
        self.displays = displays
    }
}

@MainActor
private final class FakeOverlayPanel: OverlayPanel {
    let renderer: FakeOverlayRenderer
    private(set) var frame: NSRect
    private(set) var effectStyles: [EffectStyle] = []
    private(set) var orderFrontCount = 0
    private(set) var isClosed = false

    var glowRenderer: (any GlowRenderer)? { renderer }

    init(
        frame: NSRect,
        supportsConcurrentPhysicalTargets: Bool = false
    ) {
        self.frame = frame
        renderer = FakeOverlayRenderer(
            supportsConcurrentPhysicalTargets: supportsConcurrentPhysicalTargets
        )
    }

    func setEffectStyle(_ requestedStyle: EffectStyle) {
        effectStyles.append(requestedStyle)
    }

    func setFrame(_ frameRect: NSRect, display flag: Bool) {
        frame = frameRect
    }

    func orderFrontRegardless() {
        orderFrontCount += 1
    }

    func close() {
        isClosed = true
    }
}

@MainActor
private final class FakeOverlayRenderer: GlowRenderer {
    let view = NSView(frame: .zero)
    let supportsConcurrentPhysicalTargets: Bool
    private(set) var applied: [RendererConfiguration] = []
    private(set) var shown: [GlowTarget] = []
    private(set) var hidden: [GlowID] = []
    private(set) var clearCount = 0
    private var runtimeStatusHandler:
        (@MainActor (GlowRendererRuntimeState) -> Void)?

    init(supportsConcurrentPhysicalTargets: Bool = false) {
        self.supportsConcurrentPhysicalTargets = supportsConcurrentPhysicalTargets
    }

    func apply(_ configuration: RendererConfiguration) {
        applied.append(configuration)
    }

    func show(_ target: GlowTarget) {
        shown.append(target)
    }

    func refresh(_ id: GlowID) -> Bool {
        false
    }

    func hide(_ id: GlowID) {
        hidden.append(id)
    }

    func clear() {
        clearCount += 1
    }

    func setRuntimeStatusHandler(
        _ handler: (@MainActor (GlowRendererRuntimeState) -> Void)?
    ) {
        runtimeStatusHandler = handler
        handler?(.ready)
    }

    func emitRuntimeState(_ state: GlowRendererRuntimeState) {
        runtimeStatusHandler?(state)
    }
}
