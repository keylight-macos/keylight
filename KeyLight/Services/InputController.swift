import Foundation

@MainActor
protocol InputPermissionProviding: AnyObject {
    var runningApplicationPath: String { get }
    var installationIssue: String? { get }

    func hasInputMonitoringPermission() -> Bool
    func requestInputMonitoringPermission() -> Bool
    func openInputMonitoringSettings()
}

extension PermissionManager: InputPermissionProviding {}

@MainActor
protocol InputMonitoringSession: AnyObject {
    var isRunning: Bool { get }

    @discardableResult
    func start() -> Bool
    func stop()
}

extension KeyboardMonitor: InputMonitoringSession {}

@MainActor
protocol InputControllerRecheckToken: AnyObject {
    func cancel()
}

/// Platform-neutral event accepted from an injected monitor session.
/// Production receives one merged KeyboardMonitor callback while retaining the
/// event-tap versus Consumer-HID source identity.
struct InputMonitorEvent: Equatable, Sendable {
    let keyCode: UInt16
    let isKeyDown: Bool
    let isRepeat: Bool
    let source: KeyboardEvent.Source
    let sequence: UInt64

    init(
        keyCode: UInt16,
        isKeyDown: Bool,
        isRepeat: Bool = false,
        source: KeyboardEvent.Source = .eventTap,
        sequence: UInt64 = 0
    ) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.isRepeat = isKeyDown && isRepeat
        self.source = source
        self.sequence = sequence
    }
}

/// Complete user-facing input status for a mechanical AppDelegate migration.
struct InputControllerStatus: Equatable, Sendable {
    let state: InputMonitoringState
    let runningApplicationPath: String
    let installationIssue: String?
    let lastKnownAuthorization: Bool?
    let monitorRunning: Bool
    let recheckInterval: TimeInterval?
}

/// Owns Input Monitoring permission reconciliation and the global keyboard
/// monitor lifecycle. It deliberately does not own rendering or KeyLightModel.
@MainActor
final class InputController {
    typealias MonitorFactory = @MainActor (
        _ onEvent: @escaping @MainActor (InputMonitorEvent) -> Void,
        _ onStreamReset: @escaping @MainActor () -> Void,
        _ onUnavailable: @escaping @MainActor () -> Void
    ) -> any InputMonitoringSession

    typealias RecheckScheduler = @MainActor (
        _ interval: TimeInterval,
        _ tolerance: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any InputControllerRecheckToken

    private let permissionProvider: any InputPermissionProviding
    private let monitorFactory: MonitorFactory
    private let recheckScheduler: RecheckScheduler
    private let clock: @MainActor () -> TimeInterval
    private let isTestEnvironment: Bool
    private let fastRecheckInterval: TimeInterval
    private let slowRecheckInterval: TimeInterval
    private let onKeyboardEvent: @MainActor (KeyboardEvent) -> Void
    private let onStatusChange: @MainActor (InputControllerStatus) -> Void

    private var monitor: (any InputMonitoringSession)?
    private var monitorGeneration: UInt = 0
    private var recheckToken: (any InputControllerRecheckToken)?
    private var lastEmittedStatus: InputControllerStatus?

    private(set) var state: InputMonitoringState = .checking
    private(set) var isEnabled = false
    private(set) var isStarted = false
    private(set) var isSleeping = false
    private(set) var lastKnownAuthorization: Bool?
    private(set) var currentRecheckInterval: TimeInterval?

    var status: InputControllerStatus {
        InputControllerStatus(
            state: state,
            runningApplicationPath: permissionProvider.runningApplicationPath,
            installationIssue: permissionProvider.installationIssue,
            lastKnownAuthorization: lastKnownAuthorization,
            monitorRunning: monitor?.isRunning == true,
            recheckInterval: currentRecheckInterval
        )
    }

    init(
        permissionProvider: any InputPermissionProviding = PermissionManager(),
        monitorFactory: @escaping MonitorFactory = InputController.makeLiveMonitor,
        recheckScheduler: @escaping RecheckScheduler = InputController.scheduleLiveRecheck,
        clock: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        isTestEnvironment: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
        fastRecheckInterval: TimeInterval = 5,
        slowRecheckInterval: TimeInterval = 300,
        onKeyboardEvent: @escaping @MainActor (KeyboardEvent) -> Void,
        onStatusChange: @escaping @MainActor (InputControllerStatus) -> Void = { _ in }
    ) {
        self.permissionProvider = permissionProvider
        self.monitorFactory = monitorFactory
        self.recheckScheduler = recheckScheduler
        self.clock = clock
        self.isTestEnvironment = isTestEnvironment
        self.fastRecheckInterval = Self.sanitizedInterval(fastRecheckInterval, fallback: 5)
        self.slowRecheckInterval = Self.sanitizedInterval(slowRecheckInterval, fallback: 300)
        self.onKeyboardEvent = onKeyboardEvent
        self.onStatusChange = onStatusChange
    }

    /// Starts permission reconciliation. Calling this repeatedly updates the
    /// enabled intent but never creates a duplicate running monitor.
    func start(isEnabled: Bool, allowPermissionRequest: Bool = false) {
        isStarted = true
        isSleeping = false
        self.isEnabled = isEnabled
        reconcilePermission(allowRequest: allowPermissionRequest)
    }

    /// Stops all controller-owned work. Repeated calls are no-ops.
    func stop() {
        guard isStarted || monitor != nil || recheckToken != nil else { return }
        isStarted = false
        isSleeping = false
        cancelRecheck()
        stopMonitor(emitReset: true, resetSource: .lifecycle)
        state = lastKnownAuthorization == true ? .authorized : .permissionRequired
        publishStatusIfChanged()
    }

    func setEnabled(_ enabled: Bool, allowPermissionRequest: Bool = false) {
        let changed = enabled != isEnabled
        isEnabled = enabled

        if !enabled, changed {
            stopMonitor(emitReset: true, resetSource: .lifecycle)
        }

        guard isStarted, !isSleeping else {
            publishStatusIfChanged()
            return
        }
        reconcilePermission(allowRequest: allowPermissionRequest)
    }

    /// Rechecks TCC when KeyLight becomes active, without prompting.
    func applicationDidBecomeActive() {
        guard isStarted, !isSleeping else { return }
        reconcilePermission(allowRequest: false)
    }

    func handleSleep() {
        guard isStarted, !isSleeping else { return }
        isSleeping = true
        cancelRecheck()
        stopMonitor(emitReset: true, resetSource: .lifecycle)
        state = lastKnownAuthorization == true ? .authorized : .permissionRequired
        publishStatusIfChanged()
    }

    func handleWake() {
        guard isStarted, isSleeping else { return }
        isSleeping = false
        emitStreamReset(source: .lifecycle)
        reconcilePermission(allowRequest: false)
    }

    /// Explicit user permission action from setup or recovery UI.
    func requestPermission() {
        guard isStarted, !isSleeping else { return }
        reconcilePermission(allowRequest: true)
    }

    /// Explicit non-prompting retry from menus or Settings.
    func retry() {
        guard isStarted, !isSleeping else { return }
        reconcilePermission(allowRequest: false)
    }

    func openInputMonitoringSettings() {
        permissionProvider.openInputMonitoringSettings()
    }

    /// Stops the current stream and immediately reconciles a fresh monitor.
    func restart() {
        guard isStarted, !isSleeping else { return }
        stopMonitor(emitReset: true, resetSource: .eventTap)
        reconcilePermission(allowRequest: false)
    }

    // MARK: - Reconciliation

    private func reconcilePermission(allowRequest: Bool) {
        guard isStarted, !isSleeping else { return }

        if isTestEnvironment {
            cancelRecheck()
            stopMonitor(emitReset: monitor != nil, resetSource: .lifecycle)
            state = .checking
            publishStatusIfChanged()
            return
        }

        var authorized = permissionProvider.hasInputMonitoringPermission()
        var action = InputMonitoringReconciliationResolver.resolve(
            installationIssue: permissionProvider.installationIssue,
            authorized: authorized,
            allowRequest: allowRequest,
            isEnabled: isEnabled,
            monitorExists: monitor != nil,
            monitorRunning: monitor?.isRunning == true
        )

        if action == .requestPermission {
            authorized = permissionProvider.requestInputMonitoringPermission()
            action = InputMonitoringReconciliationResolver.resolve(
                installationIssue: permissionProvider.installationIssue,
                authorized: authorized,
                allowRequest: false,
                isEnabled: isEnabled,
                monitorExists: monitor != nil,
                monitorRunning: monitor?.isRunning == true
            )
        }

        lastKnownAuthorization = authorized

        switch action {
        case .requestPermission:
            assertionFailure("Permission requests must resolve before applying reconciliation actions")
            state = .permissionRequired
            rescheduleRecheck(interval: fastRecheckInterval)

        case .settle(let settledState, let shouldStopMonitor):
            if shouldStopMonitor {
                stopMonitor(emitReset: true, resetSource: .lifecycle)
            }
            state = settledState
            let healthy = settledState == .authorized || settledState == .active
            rescheduleRecheck(interval: healthy ? slowRecheckInterval : fastRecheckInterval)

        case .startMonitor(let shouldStopExisting):
            if shouldStopExisting {
                stopMonitor(emitReset: true, resetSource: .eventTap)
            }
            state = .starting
            publishStatusIfChanged()

            let succeeded = startMonitor()
            state = InputMonitoringReconciliationResolver.stateAfterMonitorStart(succeeded: succeeded)
            rescheduleRecheck(interval: succeeded ? slowRecheckInterval : fastRecheckInterval)
        }

        publishStatusIfChanged()
    }

    // MARK: - Monitor lifecycle

    @discardableResult
    private func startMonitor() -> Bool {
        if monitor?.isRunning == true {
            return true
        }

        if monitor != nil {
            stopMonitor(emitReset: true, resetSource: .eventTap)
        }

        monitorGeneration &+= 1
        let generation = monitorGeneration
        let newMonitor = monitorFactory(
            { [weak self] event in
                self?.handleMonitorEvent(event, generation: generation)
            },
            { [weak self] in
                self?.handleMonitorStreamReset(generation: generation)
            },
            { [weak self] in
                self?.handleMonitorUnavailable(generation: generation)
            }
        )
        monitor = newMonitor

        guard newMonitor.start() else {
            newMonitor.stop()
            monitor = nil
            return false
        }
        return true
    }

    private func stopMonitor(
        emitReset: Bool,
        resetSource: KeyboardEvent.Source
    ) {
        guard let existingMonitor = monitor else {
            if emitReset {
                emitStreamReset(source: resetSource)
            }
            return
        }

        monitorGeneration &+= 1
        monitor = nil
        existingMonitor.stop()
        if emitReset {
            emitStreamReset(source: resetSource)
        }
    }

    private func handleMonitorUnavailable(generation: UInt) {
        guard generation == monitorGeneration,
              monitor != nil,
              isStarted,
              !isSleeping else {
            return
        }
        stopMonitor(emitReset: true, resetSource: .eventTap)
        reconcilePermission(allowRequest: false)
    }

    /// A re-enabled event tap may have dropped key-up events while disabled.
    /// Clear downstream held-key state without replacing the healthy session.
    private func handleMonitorStreamReset(generation: UInt) {
        guard generation == monitorGeneration,
              monitor != nil,
              isStarted,
              !isSleeping else {
            return
        }
        emitStreamReset(source: .eventTap)
    }

    private func handleMonitorEvent(_ event: InputMonitorEvent, generation: UInt) {
        guard generation == monitorGeneration,
              monitor != nil,
              isStarted,
              !isSleeping else {
            return
        }

        let keyCode = KeyboardLayoutInfo.canonicalKeyCode(for: event.keyCode)
        let timestamp = clock()
        let normalized: KeyboardEvent
        if event.isKeyDown {
            normalized = .keyDown(
                keyCode,
                isRepeat: event.isRepeat,
                source: event.source,
                timestamp: timestamp,
                sequence: event.sequence
            )
        } else {
            normalized = .keyUp(
                keyCode,
                source: event.source,
                timestamp: timestamp,
                sequence: event.sequence
            )
        }
        KeyLightSignposts.normalizedEventDispatched(
            sequence: normalized.sequence
        )
        onKeyboardEvent(normalized)
    }

    private func emitStreamReset(source: KeyboardEvent.Source) {
        onKeyboardEvent(.streamReset(source: source, timestamp: clock()))
    }

    // MARK: - Rechecks and status

    private func rescheduleRecheck(interval: TimeInterval) {
        if let currentRecheckInterval,
           abs(currentRecheckInterval - interval) < 0.001,
           recheckToken != nil {
            return
        }

        cancelRecheck()
        currentRecheckInterval = interval
        recheckToken = recheckScheduler(
            interval,
            min(10, interval * 0.5)
        ) { [weak self] in
            self?.reconcilePermission(allowRequest: false)
        }
    }

    private func cancelRecheck() {
        recheckToken?.cancel()
        recheckToken = nil
        currentRecheckInterval = nil
    }

    private func publishStatusIfChanged() {
        let next = status
        guard next != lastEmittedStatus else { return }
        lastEmittedStatus = next
        onStatusChange(next)
    }

    private static func sanitizedInterval(_ interval: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        interval.isFinite && interval > 0 ? interval : fallback
    }

    // MARK: - Live adapters

    private static func makeLiveMonitor(
        onEvent: @escaping @MainActor (InputMonitorEvent) -> Void,
        onStreamReset: @escaping @MainActor () -> Void,
        onUnavailable: @escaping @MainActor () -> Void
    ) -> any InputMonitoringSession {
        KeyboardMonitor(
            onStreamReset: { _ in
                Task { @MainActor in
                    onStreamReset()
                }
            },
            onBecameUnavailable: { _ in
                Task { @MainActor in
                    onUnavailable()
                }
            },
            callback: { event in
                onEvent(InputMonitorEvent(
                    keyCode: event.keyCode,
                    isKeyDown: event.isKeyDown,
                    isRepeat: event.isRepeat,
                    source: event.source,
                    sequence: event.sequence
                ))
            }
        )
    }

    private static func scheduleLiveRecheck(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any InputControllerRecheckToken {
        LiveInputControllerRecheckToken(
            interval: interval,
            tolerance: tolerance,
            action: action
        )
    }
}

@MainActor
private final class LiveInputControllerRecheckToken: InputControllerRecheckToken {
    private var timer: Timer?

    init(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
        timer.tolerance = tolerance
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
