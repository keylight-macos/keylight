import XCTest
@testable import KeyLight

final class InputControllerTests: XCTestCase {
    func testKeyboardMonitorReportsRecoveredTapInterruption() {
        var resetCount = 0
        var unavailableCount = 0
        let monitor = KeyboardMonitor(
            onStreamReset: { _ in resetCount += 1 },
            onBecameUnavailable: { _ in unavailableCount += 1 },
            callback: { _ in }
        )

        XCTAssertEqual(
            monitor._testResolveModifierFlagsChanged(keyCode: 55, flags: [.maskCommand]),
            true
        )
        monitor._testReportEventTapRecoveryOutcome(reenabled: true)

        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(unavailableCount, 0)
        XCTAssertEqual(
            monitor._testResolveModifierFlagsChanged(keyCode: 55, flags: [.maskCommand]),
            true,
            "Recovered streams must not retain stale modifier state"
        )
    }

    @MainActor
    func testAuthorizedStartIsActiveSlowPollingAndIdempotent() {
        let permission = FakeInputPermission(authorized: true)
        let monitors = FakeInputMonitorFactory()
        let scheduler = FakeInputRecheckScheduler()
        let recorder = InputControllerRecorder()
        let controller = makeController(
            permission: permission,
            monitors: monitors,
            scheduler: scheduler,
            recorder: recorder
        )

        controller.start(isEnabled: true)

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(monitors.sessions.count, 1)
        XCTAssertEqual(monitors.sessions[0].startCount, 1)
        XCTAssertEqual(controller.currentRecheckInterval, 300)
        XCTAssertEqual(scheduler.activeToken?.interval, 300)
        XCTAssertEqual(recorder.statuses.last?.runningApplicationPath, "/Applications/KeyLight.app")
        XCTAssertTrue(recorder.statuses.last?.monitorRunning == true)

        controller.start(isEnabled: true)
        controller.applicationDidBecomeActive()

        XCTAssertEqual(monitors.sessions.count, 1)
        XCTAssertEqual(monitors.sessions[0].startCount, 1)
        XCTAssertEqual(scheduler.createdTokens.count, 1)
    }

    @MainActor
    func testPermissionRequestRequiresExplicitActionAndValidInstallation() {
        let permission = FakeInputPermission(authorized: false, requestResult: false)
        let monitors = FakeInputMonitorFactory()
        let scheduler = FakeInputRecheckScheduler()
        let recorder = InputControllerRecorder()
        let controller = makeController(
            permission: permission,
            monitors: monitors,
            scheduler: scheduler,
            recorder: recorder
        )

        controller.start(isEnabled: true)
        XCTAssertEqual(controller.state, .permissionRequired)
        XCTAssertEqual(permission.requestCount, 0)
        XCTAssertEqual(controller.currentRecheckInterval, 5)

        controller.requestPermission()
        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(controller.state, .permissionRequired)

        permission.installationIssue = "Running from a disk image"
        controller.requestPermission()
        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(recorder.statuses.last?.installationIssue, "Running from a disk image")
    }

    @MainActor
    func testOpeningInputMonitoringSettingsUsesInjectedPermissionProvider() {
        let permission = FakeInputPermission(authorized: false)
        let controller = makeController(
            permission: permission,
            monitors: FakeInputMonitorFactory(),
            scheduler: FakeInputRecheckScheduler(),
            recorder: InputControllerRecorder()
        )

        controller.openInputMonitoringSettings()

        XCTAssertEqual(permission.openSettingsCount, 1)
    }

    @MainActor
    func testSuccessfulPermissionRequestStartsMonitor() {
        let permission = FakeInputPermission(authorized: false, requestResult: true)
        let monitors = FakeInputMonitorFactory()
        let scheduler = FakeInputRecheckScheduler()
        let recorder = InputControllerRecorder()
        let controller = makeController(
            permission: permission,
            monitors: monitors,
            scheduler: scheduler,
            recorder: recorder
        )

        controller.start(isEnabled: true)
        controller.requestPermission()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertTrue(permission.authorized)
        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(monitors.sessions.count, 1)
        XCTAssertEqual(controller.currentRecheckInterval, 300)
    }

    @MainActor
    func testExplicitPermissionRequestWorksWhileEffectIsDisabledWithoutStartingMonitor() {
        let permission = FakeInputPermission(authorized: false, requestResult: true)
        let monitors = FakeInputMonitorFactory()
        let scheduler = FakeInputRecheckScheduler()
        let recorder = InputControllerRecorder()
        let controller = makeController(
            permission: permission,
            monitors: monitors,
            scheduler: scheduler,
            recorder: recorder
        )

        controller.start(isEnabled: false)
        controller.requestPermission()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertTrue(permission.authorized)
        XCTAssertEqual(controller.state, .authorized)
        XCTAssertTrue(monitors.sessions.isEmpty)
        XCTAssertEqual(controller.currentRecheckInterval, 300)
    }

    @MainActor
    func testDisableStopsOnceEmitsResetAndRetainsAuthorizedState() {
        let harness = makeAuthorizedHarness()
        harness.controller.start(isEnabled: true)
        harness.recorder.events.removeAll()

        harness.controller.setEnabled(false)

        XCTAssertEqual(harness.controller.state, .authorized)
        XCTAssertEqual(harness.monitors.sessions[0].stopCount, 1)
        XCTAssertEqual(harness.recorder.events, [
            .streamReset(source: .lifecycle, timestamp: 10)
        ])
        XCTAssertEqual(harness.controller.currentRecheckInterval, 300)

        harness.controller.setEnabled(false)
        XCTAssertEqual(harness.monitors.sessions[0].stopCount, 1)
        XCTAssertEqual(harness.recorder.events.count, 1)
    }

    @MainActor
    func testSleepWakeAreIdempotentAndRestartFreshSession() {
        let harness = makeAuthorizedHarness()
        harness.controller.start(isEnabled: true)
        harness.recorder.events.removeAll()

        harness.controller.handleSleep()
        harness.controller.handleSleep()

        XCTAssertTrue(harness.controller.isSleeping)
        XCTAssertEqual(harness.monitors.sessions[0].stopCount, 1)
        XCTAssertNil(harness.scheduler.activeToken)
        XCTAssertEqual(harness.recorder.events, [
            .streamReset(source: .lifecycle, timestamp: 10)
        ])

        harness.controller.handleWake()
        harness.controller.handleWake()

        XCTAssertFalse(harness.controller.isSleeping)
        XCTAssertEqual(harness.controller.state, .active)
        XCTAssertEqual(harness.monitors.sessions.count, 2)
        XCTAssertEqual(harness.recorder.events, [
            .streamReset(source: .lifecycle, timestamp: 10),
            .streamReset(source: .lifecycle, timestamp: 10)
        ])
    }

    @MainActor
    func testUnavailableMonitorResetsAndRestartsWhileStaleCallbackIsIgnored() {
        let harness = makeAuthorizedHarness()
        harness.controller.start(isEnabled: true)
        harness.recorder.events.removeAll()
        let first = harness.monitors.sessions[0]

        first.becomeUnavailable()

        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(harness.monitors.sessions.count, 2)
        XCTAssertEqual(harness.controller.state, .active)
        XCTAssertEqual(harness.recorder.events, [
            .streamReset(source: .eventTap, timestamp: 10)
        ])

        first.becomeUnavailable()
        XCTAssertEqual(harness.monitors.sessions.count, 2)
        XCTAssertEqual(harness.recorder.events.count, 1)
    }

    @MainActor
    func testRecoveredMonitorStreamResetsHeldKeysWithoutRestartingSession() {
        let harness = makeAuthorizedHarness()
        harness.controller.start(isEnabled: true)
        harness.recorder.events.removeAll()
        let monitor = harness.monitors.sessions[0]

        monitor.emit(InputMonitorEvent(keyCode: 0, isKeyDown: true))
        monitor.reportRecoveredStreamInterruption()

        XCTAssertEqual(harness.controller.state, .active)
        XCTAssertEqual(harness.monitors.sessions.count, 1)
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(monitor.stopCount, 0)
        XCTAssertEqual(harness.recorder.events, [
            .keyDown(0, source: .eventTap, timestamp: 10),
            .streamReset(source: .eventTap, timestamp: 10)
        ])
    }

    @MainActor
    func testFailedMonitorStartUsesFastRetryThenRecovers() {
        let permission = FakeInputPermission(authorized: true)
        let monitors = FakeInputMonitorFactory(startResults: [false, true])
        let scheduler = FakeInputRecheckScheduler()
        let recorder = InputControllerRecorder()
        let controller = makeController(
            permission: permission,
            monitors: monitors,
            scheduler: scheduler,
            recorder: recorder
        )

        controller.start(isEnabled: true)

        XCTAssertEqual(controller.state, .monitorUnavailable)
        XCTAssertEqual(controller.currentRecheckInterval, 5)
        XCTAssertEqual(monitors.sessions[0].stopCount, 1)

        scheduler.fireActive()

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(monitors.sessions.count, 2)
        XCTAssertEqual(controller.currentRecheckInterval, 300)
        XCTAssertTrue(scheduler.createdTokens[0].isCancelled)
    }

    @MainActor
    func testMonitorEventsAreCanonicalPrivacySafeKeyboardEvents() {
        let permission = FakeInputPermission(authorized: true)
        let monitors = FakeInputMonitorFactory()
        let scheduler = FakeInputRecheckScheduler()
        let recorder = InputControllerRecorder()
        var timestamp: TimeInterval = 20
        let controller = InputController(
            permissionProvider: permission,
            monitorFactory: monitors.makeMonitor,
            recheckScheduler: scheduler.schedule,
            clock: {
                defer { timestamp += 1 }
                return timestamp
            },
            isTestEnvironment: false,
            onKeyboardEvent: recorder.record(event:),
            onStatusChange: recorder.record(status:)
        )
        controller.start(isEnabled: true)
        let monitor = monitors.sessions[0]

        monitor.emit(InputMonitorEvent(
            keyCode: 500,
            isKeyDown: true,
            isRepeat: true,
            source: .consumerHID
        ))
        monitor.emit(InputMonitorEvent(
            keyCode: 500,
            isKeyDown: false,
            isRepeat: true,
            source: .consumerHID
        ))

        XCTAssertEqual(recorder.events, [
            .keyDown(122, isRepeat: true, source: .consumerHID, timestamp: 20),
            .keyUp(122, source: .consumerHID, timestamp: 21)
        ])
    }

    @MainActor
    func testFastTimerReconcilesPermissionAndSwitchesToSlowPolling() {
        let permission = FakeInputPermission(authorized: false)
        let monitors = FakeInputMonitorFactory()
        let scheduler = FakeInputRecheckScheduler()
        let recorder = InputControllerRecorder()
        let controller = makeController(
            permission: permission,
            monitors: monitors,
            scheduler: scheduler,
            recorder: recorder
        )
        controller.start(isEnabled: true)
        XCTAssertEqual(scheduler.activeToken?.interval, 5)

        permission.authorized = true
        scheduler.fireActive()

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(monitors.sessions.count, 1)
        XCTAssertEqual(scheduler.activeToken?.interval, 300)
    }

    @MainActor
    func testStopIsIdempotentAndCancelsControllerWork() {
        let harness = makeAuthorizedHarness()
        harness.controller.start(isEnabled: true)
        harness.recorder.events.removeAll()

        harness.controller.stop()
        harness.controller.stop()

        XCTAssertFalse(harness.controller.isStarted)
        XCTAssertEqual(harness.monitors.sessions[0].stopCount, 1)
        XCTAssertNil(harness.scheduler.activeToken)
        XCTAssertEqual(harness.recorder.events, [
            .streamReset(source: .lifecycle, timestamp: 10)
        ])
    }

    @MainActor
    func testAppHostedTestModeNeverTouchesPermissionOrMonitor() {
        let permission = FakeInputPermission(authorized: true)
        let monitors = FakeInputMonitorFactory()
        let scheduler = FakeInputRecheckScheduler()
        let recorder = InputControllerRecorder()
        let controller = InputController(
            permissionProvider: permission,
            monitorFactory: monitors.makeMonitor,
            recheckScheduler: scheduler.schedule,
            isTestEnvironment: true,
            onKeyboardEvent: recorder.record(event:),
            onStatusChange: recorder.record(status:)
        )

        controller.start(isEnabled: true, allowPermissionRequest: true)
        controller.applicationDidBecomeActive()

        XCTAssertEqual(controller.state, .checking)
        XCTAssertEqual(permission.preflightCount, 0)
        XCTAssertEqual(permission.requestCount, 0)
        XCTAssertTrue(monitors.sessions.isEmpty)
        XCTAssertNil(scheduler.activeToken)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    // MARK: - Harness

    @MainActor
    private func makeController(
        permission: FakeInputPermission,
        monitors: FakeInputMonitorFactory,
        scheduler: FakeInputRecheckScheduler,
        recorder: InputControllerRecorder
    ) -> InputController {
        InputController(
            permissionProvider: permission,
            monitorFactory: monitors.makeMonitor,
            recheckScheduler: scheduler.schedule,
            clock: { 10 },
            isTestEnvironment: false,
            onKeyboardEvent: recorder.record(event:),
            onStatusChange: recorder.record(status:)
        )
    }

    @MainActor
    private func makeAuthorizedHarness() -> AuthorizedInputHarness {
        let permission = FakeInputPermission(authorized: true)
        let monitors = FakeInputMonitorFactory()
        let scheduler = FakeInputRecheckScheduler()
        let recorder = InputControllerRecorder()
        return AuthorizedInputHarness(
            controller: makeController(
                permission: permission,
                monitors: monitors,
                scheduler: scheduler,
                recorder: recorder
            ),
            monitors: monitors,
            scheduler: scheduler,
            recorder: recorder
        )
    }
}

final class KeyboardEventDecoderTests: XCTestCase {
    func testModifierFixtureHandlesSharedFlagsAndUnknownKeys() {
        var decoder = KeyboardEventDecoder()

        XCTAssertEqual(decoder.resolveModifierFlagsChanged(keyCode: 55, flagIsSet: true), true)
        XCTAssertEqual(decoder.resolveModifierFlagsChanged(keyCode: 54, flagIsSet: true), true)
        XCTAssertEqual(decoder.resolveModifierFlagsChanged(keyCode: 54, flagIsSet: true), false)
        XCTAssertEqual(decoder.resolveModifierFlagsChanged(keyCode: 55, flagIsSet: false), false)
        XCTAssertNil(decoder.resolveModifierFlagsChanged(keyCode: 12, flagIsSet: true))
    }

    func testCapsLockFixtureProducesMomentaryPulse() {
        var decoder = KeyboardEventDecoder()

        XCTAssertEqual(decoder.resolveModifierFlagsChanged(keyCode: 57, flagIsSet: true), true)
        XCTAssertEqual(decoder.capsLockEmitSequence(isKeyDown: true), [true, false])
        XCTAssertEqual(decoder.resolveModifierFlagsChanged(keyCode: 57, flagIsSet: false), false)
        XCTAssertEqual(decoder.capsLockEmitSequence(isKeyDown: false), [false])
    }

    func testMediaFixtureParsesTransitionsAndPrefersHIDDuplicates() throws {
        var decoder = KeyboardEventDecoder()
        let keyDownData = (UInt32(16) << 16) | (UInt32(0x0A) << 8)
        let keyUpData = (UInt32(16) << 16) | (UInt32(0x0B) << 8)

        let down = try XCTUnwrap(decoder.decodeSystemDefinedMediaEvent(
            subtypeRawValue: 8,
            data1: keyDownData,
            now: 100
        ))
        let up = try XCTUnwrap(decoder.decodeSystemDefinedMediaEvent(
            subtypeRawValue: 8,
            data1: keyUpData,
            now: 100.01
        ))
        XCTAssertEqual(down, .init(keyCode: 516, isKeyDown: true))
        XCTAssertEqual(up, .init(keyCode: 516, isKeyDown: false))
        XCTAssertNil(decoder.decodeSystemDefinedMediaEvent(
            subtypeRawValue: 7,
            data1: keyDownData,
            now: 100
        ))

        XCTAssertFalse(decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: 517,
            isKeyDown: true,
            source: .hid,
            now: 101
        ))
        XCTAssertTrue(decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: 517,
            isKeyDown: true,
            source: .systemDefined,
            now: 101.01
        ))
        XCTAssertFalse(decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: 517,
            isKeyDown: true,
            source: .systemDefined,
            now: 101.05
        ))
    }

    func testSystemMediaFixtureMapsRewindAndFastForwardToF7AndF9() throws {
        let fixtures: [(nxCode: UInt32, alias: UInt16, functionKey: UInt16)] = [
            (20, 506, 98),
            (19, 517, 101),
        ]

        for fixture in fixtures {
            let decoder = KeyboardEventDecoder()
            let keyDownData = (fixture.nxCode << 16) | (UInt32(0x0A) << 8)
            let keyUpData = (fixture.nxCode << 16) | (UInt32(0x0B) << 8)
            let down = try XCTUnwrap(decoder.decodeSystemDefinedMediaEvent(
                subtypeRawValue: 8,
                data1: keyDownData,
                now: 300
            ))
            let up = try XCTUnwrap(decoder.decodeSystemDefinedMediaEvent(
                subtypeRawValue: 8,
                data1: keyUpData,
                now: 300.01
            ))

            XCTAssertEqual(down, .init(keyCode: fixture.alias, isKeyDown: true))
            XCTAssertEqual(up, .init(keyCode: fixture.alias, isKeyDown: false))
            XCTAssertEqual(
                KeyboardLayoutInfo.canonicalKeyCode(for: fixture.alias),
                fixture.functionKey
            )
        }
    }

    func testNewerAppleDoNotDisturbRawCodeMapsToF6() throws {
        let decoder = KeyboardEventDecoder()
        let event = try XCTUnwrap(decoder.decodeKeyboardEvent(
            rawKeyCode: 178,
            isKeyDown: true,
            isRepeat: false,
            charactersIgnoringModifiers: nil,
            specialKeyRawValue: nil,
            isMappedKeyCode: false
        ))

        XCTAssertEqual(event.keyCode, 97)
        XCTAssertTrue(event.isKeyDown)
        XCTAssertEqual(event.source, .eventTap)
    }

    func testRepeatFixtureRetainsRepeatOnlyForKeyDown() throws {
        let decoder = KeyboardEventDecoder()
        let down = try XCTUnwrap(decoder.decodeKeyboardEvent(
            rawKeyCode: 0,
            isKeyDown: true,
            isRepeat: true,
            charactersIgnoringModifiers: nil,
            specialKeyRawValue: nil,
            isMappedKeyCode: true
        ))
        let up = try XCTUnwrap(decoder.decodeKeyboardEvent(
            rawKeyCode: 0,
            isKeyDown: false,
            isRepeat: true,
            charactersIgnoringModifiers: nil,
            specialKeyRawValue: nil,
            isMappedKeyCode: true
        ))

        XCTAssertTrue(down.isRepeat)
        XCTAssertFalse(up.isRepeat)
    }

    func testUnknownRawFixtureRequiresTrustedMetadata() throws {
        let decoder = KeyboardEventDecoder()

        XCTAssertNil(decoder.decodeKeyboardEvent(
            rawKeyCode: 163,
            isKeyDown: true,
            isRepeat: false,
            charactersIgnoringModifiers: nil,
            specialKeyRawValue: nil,
            isMappedKeyCode: false
        ))

        let trusted = try XCTUnwrap(decoder.decodeKeyboardEvent(
            rawKeyCode: 163,
            isKeyDown: true,
            isRepeat: false,
            charactersIgnoringModifiers: String(UnicodeScalar(0xF706)!),
            specialKeyRawValue: nil,
            isMappedKeyCode: false
        ))
        XCTAssertEqual(trusted.keyCode, 99)
    }

    func testResetClearsModifierTopRowAndMediaDedupeState() {
        var decoder = KeyboardEventDecoder()
        XCTAssertEqual(decoder.resolveModifierFlagsChanged(keyCode: 55, flagIsSet: true), true)
        decoder.recordTrustedKeyboardTopRowEvent(
            canonicalKeyCode: 122,
            isKeyDown: true,
            now: 200
        )
        XCTAssertTrue(decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: 122,
            isKeyDown: true,
            source: .systemDefined,
            now: 200.01
        ))
        XCTAssertFalse(decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: 516,
            isKeyDown: true,
            source: .systemDefined,
            now: 201
        ))
        XCTAssertTrue(decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: 516,
            isKeyDown: true,
            source: .systemDefined,
            now: 201.01
        ))

        decoder.reset()

        XCTAssertEqual(decoder.resolveModifierFlagsChanged(keyCode: 55, flagIsSet: true), true)
        XCTAssertFalse(decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: 122,
            isKeyDown: true,
            source: .systemDefined,
            now: 200.01
        ))
        XCTAssertFalse(decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: 516,
            isKeyDown: true,
            source: .systemDefined,
            now: 201.01
        ))
    }
}

@MainActor
private final class FakeInputPermission: InputPermissionProviding {
    var runningApplicationPath = "/Applications/KeyLight.app"
    var installationIssue: String?
    var authorized: Bool
    var requestResult: Bool
    private(set) var preflightCount = 0
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    init(authorized: Bool, requestResult: Bool? = nil) {
        self.authorized = authorized
        self.requestResult = requestResult ?? authorized
    }

    func hasInputMonitoringPermission() -> Bool {
        preflightCount += 1
        return authorized
    }

    func requestInputMonitoringPermission() -> Bool {
        requestCount += 1
        authorized = requestResult
        return requestResult
    }

    func openInputMonitoringSettings() {
        openSettingsCount += 1
    }
}

@MainActor
private final class FakeInputMonitor: InputMonitoringSession {
    private let startResult: Bool
    private let onEvent: @MainActor (InputMonitorEvent) -> Void
    private let onStreamReset: @MainActor () -> Void
    private let onUnavailable: @MainActor () -> Void

    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        startResult: Bool,
        onEvent: @escaping @MainActor (InputMonitorEvent) -> Void,
        onStreamReset: @escaping @MainActor () -> Void,
        onUnavailable: @escaping @MainActor () -> Void
    ) {
        self.startResult = startResult
        self.onEvent = onEvent
        self.onStreamReset = onStreamReset
        self.onUnavailable = onUnavailable
    }

    func start() -> Bool {
        startCount += 1
        isRunning = startResult
        return startResult
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func emit(_ event: InputMonitorEvent) {
        onEvent(event)
    }

    func becomeUnavailable() {
        isRunning = false
        onUnavailable()
    }

    func reportRecoveredStreamInterruption() {
        onStreamReset()
    }
}

@MainActor
private final class FakeInputMonitorFactory {
    private var startResults: [Bool]
    private(set) var sessions: [FakeInputMonitor] = []

    init(startResults: [Bool] = []) {
        self.startResults = startResults
    }

    func makeMonitor(
        onEvent: @escaping @MainActor (InputMonitorEvent) -> Void,
        onStreamReset: @escaping @MainActor () -> Void,
        onUnavailable: @escaping @MainActor () -> Void
    ) -> any InputMonitoringSession {
        let startResult = startResults.isEmpty ? true : startResults.removeFirst()
        let monitor = FakeInputMonitor(
            startResult: startResult,
            onEvent: onEvent,
            onStreamReset: onStreamReset,
            onUnavailable: onUnavailable
        )
        sessions.append(monitor)
        return monitor
    }
}

@MainActor
private final class FakeInputRecheckToken: InputControllerRecheckToken {
    let interval: TimeInterval
    let tolerance: TimeInterval
    let action: @MainActor () -> Void
    private(set) var isCancelled = false

    init(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        self.interval = interval
        self.tolerance = tolerance
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }
}

@MainActor
private final class FakeInputRecheckScheduler {
    private(set) var createdTokens: [FakeInputRecheckToken] = []

    var activeToken: FakeInputRecheckToken? {
        createdTokens.last(where: { !$0.isCancelled })
    }

    func schedule(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any InputControllerRecheckToken {
        let token = FakeInputRecheckToken(
            interval: interval,
            tolerance: tolerance,
            action: action
        )
        createdTokens.append(token)
        return token
    }

    func fireActive() {
        activeToken?.action()
    }
}

@MainActor
private final class InputControllerRecorder {
    var events: [KeyboardEvent] = []
    var statuses: [InputControllerStatus] = []

    func record(event: KeyboardEvent) {
        events.append(event)
    }

    func record(status: InputControllerStatus) {
        statuses.append(status)
    }
}

@MainActor
private struct AuthorizedInputHarness {
    let controller: InputController
    let monitors: FakeInputMonitorFactory
    let scheduler: FakeInputRecheckScheduler
    let recorder: InputControllerRecorder
}
