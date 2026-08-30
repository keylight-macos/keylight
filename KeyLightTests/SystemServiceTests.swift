import Foundation
import AppKit
import Carbon.HIToolbox
import XCTest
@testable import KeyLight

final class UpdateServiceConfigurationTests: XCTestCase {
    func testSecureUpdaterConfigurationRequiresHTTPSAndAnEd25519PublicKey() {
        let validKey = Data(repeating: 0xA5, count: 32).base64EncodedString()

        XCTAssertTrue(UpdateService.hasSecureConfiguration(
            feed: "https://keylight.example/appcast.xml",
            publicKey: validKey
        ))
        XCTAssertFalse(UpdateService.hasSecureConfiguration(
            feed: "http://keylight.example/appcast.xml",
            publicKey: validKey
        ))
        XCTAssertFalse(UpdateService.hasSecureConfiguration(
            feed: "https://placeholder:placeholder@keylight.example/appcast.xml",
            publicKey: validKey
        ))
        XCTAssertFalse(UpdateService.hasSecureConfiguration(
            feed: "https://keylight.example/appcast.xml",
            publicKey: Data(repeating: 0xA5, count: 31).base64EncodedString()
        ))
        XCTAssertFalse(UpdateService.hasSecureConfiguration(
            feed: nil,
            publicKey: validKey
        ))
    }
}

final class BuildIdentityTests: XCTestCase {
    func testExplicitBuildChannelProducesCopyableSupportSummary() {
        let identity = KeyLightBuildIdentity(
            info: [
                "CFBundleDisplayName": "KeyLight Motion Preview",
                "CFBundleShortVersionString": "2.1.0",
                "CFBundleVersion": "25",
                "KeyLightBuildChannel": "Motion Preview Local"
            ],
            bundleIdentifier: "com.keylight.app.motionpreview",
            bundlePath: "/Applications/KeyLight Motion Preview.app"
        )

        XCTAssertEqual(identity.versionDescription, "2.1.0 (25)")
        XCTAssertEqual(identity.channel, "Motion Preview Local")
        XCTAssertEqual(
            identity.supportSummary,
            """
            KeyLight Motion Preview 2.1.0 (25)
            Channel: Motion Preview Local
            Bundle ID: com.keylight.app.motionpreview
            Bundle path: /Applications/KeyLight Motion Preview.app
            """
        )
    }

    func testMissingChannelFallsBackFromKnownBundleIdentity() {
        let identity = KeyLightBuildIdentity(
            info: [:],
            bundleIdentifier: "com.keylight.app.motionpreview",
            bundlePath: "/tmp/KeyLight Motion Preview.app"
        )

        XCTAssertEqual(identity.displayName, "KeyLight")
        XCTAssertEqual(identity.versionDescription, "—")
        XCTAssertEqual(identity.channel, "Motion Preview")
    }
}

final class CalibrationKeyPolicyTests: XCTestCase {
    func testSpaceIsReservedForPhysicalPreviewInsteadOfButtonActivation() {
        XCTAssertTrue(
            KeyLightCalibrationKeyPolicy.consumesLocalControlActivation(
                keyCode: 49,
                modifierFlags: []
            )
        )
        XCTAssertTrue(
            KeyLightCalibrationKeyPolicy.consumesLocalControlActivation(
                keyCode: 49,
                modifierFlags: [.shift]
            )
        )
        XCTAssertFalse(
            KeyLightCalibrationKeyPolicy.consumesLocalControlActivation(
                keyCode: 49,
                modifierFlags: [.command]
            )
        )
        XCTAssertFalse(
            KeyLightCalibrationKeyPolicy.consumesLocalControlActivation(
                keyCode: 36,
                modifierFlags: []
            )
        )
    }
}

final class LocalPrivacyAndOnboardingTests: XCTestCase {
    @MainActor
    func testFreshOnboardingCanBeDeferredAndCompletedWithoutChangingEffect() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        let store = PreferencesStore(userDefaults: isolated.defaults)
        let service = FakeLaunchAtLoginService(status: .disabled)
        let settings = SettingsManager(
            preferencesStore: store,
            launchAtLoginService: service
        )

        XCTAssertTrue(settings.shouldPresentOnboarding)
        settings.effectStyle = .systemGlass
        settings.deferOnboarding()
        XCTAssertFalse(settings.shouldPresentOnboarding)

        let deferred = SettingsManager(
            preferencesStore: store,
            launchAtLoginService: service
        )
        XCTAssertFalse(deferred.shouldPresentOnboarding)
        XCTAssertEqual(deferred.effectStyle, .systemGlass)

        deferred.completeOnboarding()
        let completed = SettingsManager(
            preferencesStore: store,
            launchAtLoginService: service
        )
        XCTAssertFalse(completed.shouldPresentOnboarding)
        XCTAssertEqual(completed.effectStyle, .systemGlass)
    }
}

final class LaunchAtLoginServiceTests: XCTestCase {
    @MainActor
    func testSuccessfulRegistrationUsesReadBackStatus() {
        let client = FakeLaunchAtLoginSystemClient(status: .disabled)
        client.statusAfterRegister = .enabled
        let service = LaunchAtLoginService(systemClient: client)

        let result = service.setEnabled(true)

        XCTAssertEqual(client.registerCount, 1)
        XCTAssertEqual(client.unregisterCount, 0)
        XCTAssertEqual(result, LaunchAtLoginChangeResult(
            requestedEnabled: true,
            status: .enabled,
            outcome: .applied
        ))
        XCTAssertTrue(result.isApplied)
        XCTAssertEqual(service.status, .enabled)
    }

    @MainActor
    func testApprovalRequiredIsReportedWithoutPretendingRequestApplied() {
        let client = FakeLaunchAtLoginSystemClient(status: .disabled)
        client.statusAfterRegister = .requiresApproval
        let service = LaunchAtLoginService(systemClient: client)

        let result = service.setEnabled(true)

        XCTAssertEqual(result.status, .requiresApproval)
        XCTAssertEqual(result.outcome, .requiresApproval)
        XCTAssertFalse(result.isApplied)
        XCTAssertFalse(result.status.isEnabled)
    }

    @MainActor
    func testThrownRegistrationReportsFailureAndActualState() {
        let client = FakeLaunchAtLoginSystemClient(status: .disabled)
        client.registerShouldThrow = true
        let service = LaunchAtLoginService(systemClient: client)

        let result = service.setEnabled(true)

        XCTAssertEqual(result, LaunchAtLoginChangeResult(
            requestedEnabled: true,
            status: .disabled,
            outcome: .failed(.registrationFailed)
        ))
        XCTAssertFalse(result.isApplied)
    }

    @MainActor
    func testSuccessfulUnregistrationUsesReadBackStatus() {
        let client = FakeLaunchAtLoginSystemClient(status: .enabled)
        client.statusAfterUnregister = .disabled
        let service = LaunchAtLoginService(systemClient: client)

        let result = service.setEnabled(false)

        XCTAssertEqual(client.registerCount, 0)
        XCTAssertEqual(client.unregisterCount, 1)
        XCTAssertEqual(result.status, .disabled)
        XCTAssertEqual(result.outcome, .applied)
    }

    @MainActor
    func testAlreadySatisfiedRequestDoesNotCallSystemOperationAgain() {
        let enabledClient = FakeLaunchAtLoginSystemClient(status: .enabled)
        let enabledService = LaunchAtLoginService(systemClient: enabledClient)
        let disabledClient = FakeLaunchAtLoginSystemClient(status: .disabled)
        let disabledService = LaunchAtLoginService(systemClient: disabledClient)

        XCTAssertTrue(enabledService.setEnabled(true).isApplied)
        XCTAssertTrue(disabledService.setEnabled(false).isApplied)

        XCTAssertEqual(enabledClient.registerCount, 0)
        XCTAssertEqual(enabledClient.unregisterCount, 0)
        XCTAssertEqual(disabledClient.registerCount, 0)
        XCTAssertEqual(disabledClient.unregisterCount, 0)
    }

    @MainActor
    func testDisablingPendingApprovalUnregistersTheLoginItem() {
        let client = FakeLaunchAtLoginSystemClient(status: .requiresApproval)
        client.statusAfterUnregister = .disabled
        let service = LaunchAtLoginService(systemClient: client)

        let result = service.setEnabled(false)

        XCTAssertEqual(client.unregisterCount, 1)
        XCTAssertEqual(result.status, .disabled)
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertTrue(result.isApplied)
    }

    @MainActor
    func testSettingsManagerMirrorsOnlyAuthoritativeSystemState() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        let store = PreferencesStore(
            userDefaults: isolated.defaults,
            usesSystemPreferences: true
        )
        let service = FakeLaunchAtLoginService(status: .disabled)
        service.nextResult = LaunchAtLoginChangeResult(
            requestedEnabled: true,
            status: .requiresApproval,
            outcome: .requiresApproval
        )
        let settings = SettingsManager(
            preferencesStore: store,
            launchAtLoginService: service
        )

        let result = settings.setLaunchAtLogin(true)

        XCTAssertEqual(result.outcome, .requiresApproval)
        XCTAssertEqual(service.requests, [true])
        XCTAssertFalse(isolated.defaults.bool(forKey: "launchAtLogin"))
        XCTAssertFalse(settings.launchAtLogin)

        service.nextResult = LaunchAtLoginChangeResult(
            requestedEnabled: false,
            status: .enabled,
            outcome: .failed(.unregistrationFailed)
        )
        let failure = settings.setLaunchAtLogin(false)

        XCTAssertEqual(failure.outcome, .failed(.unregistrationFailed))
        XCTAssertTrue(isolated.defaults.bool(forKey: "launchAtLogin"))
        XCTAssertTrue(settings.launchAtLogin)
    }

    @MainActor
    func testIsolatedSettingsStoreKeepsLegacyBehaviorWithoutCallingSystem() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        let service = FakeLaunchAtLoginService(status: .unavailable)
        let settings = SettingsManager(
            preferencesStore: PreferencesStore(userDefaults: isolated.defaults),
            launchAtLoginService: service
        )

        let result = settings.setLaunchAtLogin(true)

        XCTAssertEqual(result.outcome, .applied)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(isolated.defaults.bool(forKey: "launchAtLogin"))
        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertEqual(service.statusReadCount, 0)
    }

    @MainActor
    func testKeyLightModelRollsBackApprovalRequiredLaunchRequestWithTypedFeedback() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        let service = FakeLaunchAtLoginService(status: .disabled)
        let settings = SettingsManager(
            preferencesStore: PreferencesStore(
                userDefaults: isolated.defaults,
                usesSystemPreferences: true
            ),
            launchAtLoginService: service
        )
        let model = KeyLightModel(settings: settings)
        service.nextResult = LaunchAtLoginChangeResult(
            requestedEnabled: true,
            status: .requiresApproval,
            outcome: .requiresApproval
        )

        model.launchAtLogin = true

        XCTAssertFalse(model.launchAtLogin)
        XCTAssertEqual(model.feedback?.severity, .warning)
        XCTAssertEqual(model.feedback?.title, "Launch at Login Needs Approval")
        XCTAssertEqual(service.requests, [true])
    }

    @MainActor
    func testKeyLightModelRollsBackFailedLaunchRequestToAuthoritativeState() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        let service = FakeLaunchAtLoginService(status: .enabled)
        let settings = SettingsManager(
            preferencesStore: PreferencesStore(
                userDefaults: isolated.defaults,
                usesSystemPreferences: true
            ),
            launchAtLoginService: service
        )
        let model = KeyLightModel(settings: settings)
        service.nextResult = LaunchAtLoginChangeResult(
            requestedEnabled: false,
            status: .enabled,
            outcome: .failed(.unregistrationFailed)
        )

        model.launchAtLogin = false

        XCTAssertTrue(model.launchAtLogin)
        XCTAssertEqual(model.feedback?.severity, .error)
        XCTAssertEqual(model.feedback?.title, "Launch at Login Failed")
        XCTAssertEqual(service.requests, [false])
    }

    @MainActor
    func testKeyLightModelRefreshesExternallyChangedLaunchStatus() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        let service = FakeLaunchAtLoginService(status: .disabled)
        let settings = SettingsManager(
            preferencesStore: PreferencesStore(
                userDefaults: isolated.defaults,
                usesSystemPreferences: true
            ),
            launchAtLoginService: service
        )
        let model = KeyLightModel(settings: settings, feedbackAnnouncer: { _ in })
        XCTAssertFalse(model.launchAtLogin)

        service.simulateStatus(.enabled)
        model.refreshLaunchAtLoginStatus()

        XCTAssertTrue(model.launchAtLogin)
        XCTAssertTrue(isolated.defaults.bool(forKey: "launchAtLogin"))
        XCTAssertTrue(service.requests.isEmpty)
    }
}

final class KeyLightModelRuntimeTests: XCTestCase {
    @MainActor
    func testSavedThemeIdentityAndEditedStateLiveInModel() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        let settings = SettingsManager(
            preferencesStore: PreferencesStore(userDefaults: isolated.defaults),
            launchAtLoginService: FakeLaunchAtLoginService(status: .disabled)
        )
        let theme = Theme(
            id: UUID(),
            name: "Baseline",
            colorHex: settings.glowColorHex,
            opacity: settings.glowOpacity,
            refractionStrength: settings.physicalRefractionStrength,
            size: settings.glowSize,
            width: settings.glowWidth,
            glowRoundness: settings.glowRoundness,
            glowFullness: settings.glowFullness,
            fadeDuration: settings.fadeDuration,
            colorMode: settings.colorMode,
            effectStyle: settings.effectStyle,
            gradientStartHex: settings.gradientStartHex,
            gradientEndHex: settings.gradientEndHex
        )
        settings.savedThemes = [theme]
        settings.activeThemeID = theme.id

        let model = KeyLightModel(settings: settings, feedbackAnnouncer: { _ in })

        XCTAssertEqual(model.selectedTheme?.id, theme.id)
        XCTAssertFalse(model.selectedThemeIsEdited)

        model.glowOpacity = max(0, theme.opacity - 0.1)
        XCTAssertTrue(model.selectedThemeIsEdited)

        model.applyTheme(theme)
        XCTAssertFalse(model.selectedThemeIsEdited)

        settings.renameTheme(from: theme.name, to: "Renamed")
        model.reloadSavedThemes()
        XCTAssertEqual(model.selectedTheme?.id, theme.id)
        XCTAssertEqual(model.selectedTheme?.name, "Renamed")
        XCTAssertFalse(model.selectedThemeIsEdited)
    }

    @MainActor
    func testRuntimeCallbacksAreDirectImmediateAndDisconnectable() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        let settings = SettingsManager(
            preferencesStore: PreferencesStore(userDefaults: isolated.defaults),
            launchAtLoginService: FakeLaunchAtLoginService(status: .disabled)
        )
        let model = KeyLightModel(settings: settings, feedbackAnnouncer: { _ in })
        var enabledValues: [Bool] = []
        var configurationChangeCount = 0
        var permissionRequestCount = 0
        var permissionRetryCount = 0
        var openSettingsCount = 0
        var previewTargets: [(GlowTarget, PreviewSource)] = []
        var clearedPreviewSources: [PreviewSource] = []
        var chordPreviewTargets: [[GlowTarget]] = []
        var chordPreviewClearCount = 0
        model.connectRuntime(
            onEnabledChange: { enabledValues.append($0) },
            onConfigurationChange: { configurationChangeCount += 1 },
            onPermissionRequest: { permissionRequestCount += 1 },
            onPermissionRetry: { permissionRetryCount += 1 },
            onOpenInputMonitoringSettings: { openSettingsCount += 1 },
            onPreviewSet: { previewTargets.append(($0, $1)) },
            onPreviewClear: { clearedPreviewSources.append($0) },
            onChordPreviewSet: { chordPreviewTargets.append($0) },
            onChordPreviewClear: { chordPreviewClearCount += 1 }
        )

        model.glowOpacity = 0.42
        model.isEnabled = false
        model.requestInputMonitoringPermission()
        model.retryInputMonitoring()
        model.openInputMonitoringSettings()
        let preview = GlowTarget.preview(
            .settings,
            horizontalPosition: 0.5,
            keyWidth: 1
        )
        model.setPreview(preview, source: .settings)
        model.clearPreview(.settings)
        let chord = [GlowTarget.preview(
            .chordTest1,
            colorReferenceKeyCode: 0,
            horizontalPosition: 0.4,
            keyWidth: 1
        )]
        model.setChordPreview(chord)
        model.clearChordPreview()

        XCTAssertEqual(enabledValues, [false])
        XCTAssertEqual(configurationChangeCount, 2)
        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(permissionRetryCount, 1)
        XCTAssertEqual(openSettingsCount, 1)
        XCTAssertEqual(previewTargets.first?.0, preview)
        XCTAssertEqual(previewTargets.first?.1, .settings)
        XCTAssertEqual(clearedPreviewSources, [.settings])
        XCTAssertEqual(chordPreviewTargets, [chord])
        XCTAssertEqual(chordPreviewClearCount, 1)

        model.disconnectRuntime()
        model.isEnabled = true
        model.requestInputMonitoringPermission()
        model.retryInputMonitoring()
        model.openInputMonitoringSettings()
        model.setPreview(preview, source: .settings)
        model.clearPreview(.settings)
        model.setChordPreview(chord)
        model.clearChordPreview()
        XCTAssertEqual(enabledValues, [false])
        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(permissionRetryCount, 1)
        XCTAssertEqual(openSettingsCount, 1)
        XCTAssertEqual(previewTargets.count, 1)
        XCTAssertEqual(clearedPreviewSources, [.settings])
        XCTAssertEqual(chordPreviewTargets, [chord])
        XCTAssertEqual(chordPreviewClearCount, 1)
        model.flushPendingPersist()
    }

    @MainActor
    func testPhysicalActivityIsEphemeralCanonicalMetadataOnly() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        let model = KeyLightModel(
            settings: SettingsManager(
                preferencesStore: PreferencesStore(userDefaults: isolated.defaults),
                launchAtLoginService: FakeLaunchAtLoginService(status: .disabled)
            ),
            feedbackAnnouncer: { _ in }
        )

        model.receivePhysicalKeyboardEvent(.keyDown(
            12,
            source: .eventTap,
            timestamp: 1
        ))
        XCTAssertEqual(model.physicalKeyActivity, PhysicalKeyActivity(
            sequence: 1,
            keyCode: 12,
            isDown: true
        ))

        model.receivePhysicalKeyboardEvent(.keyUp(
            12,
            source: .eventTap,
            timestamp: 2
        ))
        XCTAssertEqual(model.physicalKeyActivity, PhysicalKeyActivity(
            sequence: 2,
            keyCode: 12,
            isDown: false
        ))

        model.receivePhysicalKeyboardEvent(.streamReset(timestamp: 3))
        XCTAssertNil(model.physicalKeyActivity)
    }

    @MainActor
    func testTypedFeedbackProducesOneAccessibilityAnnouncement() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        var announcements: [String] = []
        let model = KeyLightModel(
            settings: SettingsManager(
                preferencesStore: PreferencesStore(userDefaults: isolated.defaults),
                launchAtLoginService: FakeLaunchAtLoginService(status: .disabled)
            ),
            feedbackAnnouncer: { announcements.append($0) }
        )
        let feedback = UserFeedback(
            severity: .success,
            title: "Theme Saved",
            detail: "Ocean is now up to date."
        )

        model.feedback = feedback
        model.feedback = feedback

        XCTAssertEqual(announcements, ["Theme Saved. Ocean is now up to date."])
    }

    @MainActor
    func testPermissionTransitionsProduceTypedRecoverableFeedbackOnce() {
        let isolated = IsolatedSystemServiceDefaults()
        defer { isolated.remove() }
        var announcements: [String] = []
        let model = KeyLightModel(
            settings: SettingsManager(
                preferencesStore: PreferencesStore(userDefaults: isolated.defaults),
                launchAtLoginService: FakeLaunchAtLoginService(status: .disabled)
            ),
            feedbackAnnouncer: { announcements.append($0) }
        )

        model.updateInputMonitoring(
            state: .permissionRequired,
            appPath: "/Applications/KeyLight.app",
            installationIssue: nil
        )
        model.updateInputMonitoring(
            state: .permissionRequired,
            appPath: "/Applications/KeyLight.app",
            installationIssue: nil
        )

        XCTAssertEqual(model.feedback?.severity, .warning)
        XCTAssertEqual(model.feedback?.recoveryAction, .openInputMonitoringSettings)
        XCTAssertEqual(announcements.count, 1)

        model.updateInputMonitoring(
            state: .active,
            appPath: "/Applications/KeyLight.app",
            installationIssue: nil
        )
        XCTAssertEqual(model.feedback?.severity, .success)
        XCTAssertEqual(announcements.count, 2)
    }
}

final class HotKeyServiceTests: XCTestCase {
    @MainActor
    func testStartRegistersOnceAndDeliversPresses() {
        let registrar = FakeHotKeyRegistrar()
        let recorder = HotKeyServiceRecorder()
        let service = HotKeyService(
            registrar: registrar,
            onPress: recorder.recordPress,
            onStatusChange: recorder.recordStatus
        )

        service.start()
        service.start()

        XCTAssertEqual(service.status, .registered)
        XCTAssertEqual(registrar.registerCount, 1)
        XCTAssertEqual(registrar.shortcuts, [.default])
        XCTAssertEqual(recorder.statuses, [.registering, .registered])

        registrar.registrations[0].press()
        XCTAssertEqual(recorder.pressCount, 1)
    }

    @MainActor
    func testChangingShortcutAtomicallyReplacesRegistrationAndInvalidatesOldCallback() throws {
        let registrar = FakeHotKeyRegistrar()
        let recorder = HotKeyServiceRecorder()
        let service = HotKeyService(
            registrar: registrar,
            onPress: recorder.recordPress,
            onStatusChange: recorder.recordStatus
        )
        let replacement = try XCTUnwrap(GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(controlKey | optionKey)
        ))

        service.start()
        let staleRegistration = registrar.registrations[0]
        service.setShortcut(replacement)
        staleRegistration.press()
        registrar.registrations[1].press()

        XCTAssertEqual(registrar.shortcuts, [.default, replacement])
        XCTAssertEqual(staleRegistration.unregisterCount, 1)
        XCTAssertEqual(recorder.pressCount, 1)
        XCTAssertEqual(service.status, .registered)
    }

    func testShortcutValidationAndDisplayName() throws {
        XCTAssertNil(GlobalShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: 0))
        XCTAssertNil(GlobalShortcut(keyCode: 999, modifiers: UInt32(cmdKey)))
        XCTAssertEqual(GlobalShortcut.default.displayName, "⌘⇧K")
        let custom = try XCTUnwrap(GlobalShortcut(
            keyCode: UInt32(kVK_LeftArrow),
            modifiers: UInt32(controlKey | optionKey | cmdKey)
        ))
        XCTAssertEqual(custom.displayName, "⌘⌃⌥←")
    }

    @MainActor
    func testStopIsIdempotentAndInvalidatesStalePresses() {
        let registrar = FakeHotKeyRegistrar()
        let recorder = HotKeyServiceRecorder()
        let service = HotKeyService(
            registrar: registrar,
            onPress: recorder.recordPress,
            onStatusChange: recorder.recordStatus
        )
        service.start()
        let registration = registrar.registrations[0]

        service.stop()
        service.stop()
        registration.press()

        XCTAssertEqual(service.status, .stopped)
        XCTAssertEqual(registration.unregisterCount, 1)
        XCTAssertEqual(recorder.pressCount, 0)
        XCTAssertEqual(recorder.statuses, [.registering, .registered, .stopped])
    }

    @MainActor
    func testTypedRegistrationFailureCanBeRetried() {
        let registrar = FakeHotKeyRegistrar(failures: [
            .hotKeyRegistrationFailed(status: -9876)
        ])
        let recorder = HotKeyServiceRecorder()
        let service = HotKeyService(
            registrar: registrar,
            onPress: recorder.recordPress,
            onStatusChange: recorder.recordStatus
        )

        service.start()
        XCTAssertEqual(service.status, .unavailable(
            .hotKeyRegistrationFailed(status: -9876)
        ))
        XCTAssertEqual(registrar.registerCount, 1)

        service.start()
        XCTAssertEqual(service.status, .registered)
        XCTAssertEqual(registrar.registerCount, 2)
        XCTAssertEqual(registrar.registrations.count, 1)
        XCTAssertEqual(recorder.statuses, [
            .registering,
            .unavailable(.hotKeyRegistrationFailed(status: -9876)),
            .registering,
            .registered
        ])
    }

    @MainActor
    func testHandlerInstallationFailureAndStopRemainTypedAndIdempotent() {
        let failure = HotKeyRegistrationFailure.eventHandlerInstallationFailed(status: -50)
        let registrar = FakeHotKeyRegistrar(failures: [failure, failure])
        let recorder = HotKeyServiceRecorder()
        let service = HotKeyService(
            registrar: registrar,
            onPress: recorder.recordPress,
            onStatusChange: recorder.recordStatus
        )

        service.start()
        service.stop()
        service.stop()

        XCTAssertEqual(service.status, .stopped)
        XCTAssertEqual(registrar.registerCount, 1)
        XCTAssertTrue(registrar.registrations.isEmpty)
        XCTAssertEqual(recorder.statuses, [
            .registering,
            .unavailable(failure),
            .stopped
        ])
    }

    @MainActor
    func testStopDuringRegistrationCleansUpLateRegistration() {
        let registrar = FakeHotKeyRegistrar()
        var service: HotKeyService?
        service = HotKeyService(
            registrar: registrar,
            onPress: {},
            onStatusChange: { status in
                if status == .registering {
                    service?.stop()
                }
            }
        )

        service?.start()

        XCTAssertEqual(service?.status, .stopped)
        XCTAssertEqual(registrar.registerCount, 1)
        XCTAssertEqual(registrar.registrations.first?.unregisterCount, 1)
    }
}

@MainActor
private final class FakeLaunchAtLoginSystemClient: LaunchAtLoginSystemClient {
    var status: LaunchAtLoginStatus
    var statusAfterRegister: LaunchAtLoginStatus?
    var statusAfterUnregister: LaunchAtLoginStatus?
    var registerShouldThrow = false
    var unregisterShouldThrow = false
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if registerShouldThrow {
            throw FakeSystemServiceError.operationFailed
        }
        if let statusAfterRegister {
            status = statusAfterRegister
        }
    }

    func unregister() throws {
        unregisterCount += 1
        if unregisterShouldThrow {
            throw FakeSystemServiceError.operationFailed
        }
        if let statusAfterUnregister {
            status = statusAfterUnregister
        }
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    private var storedStatus: LaunchAtLoginStatus
    var nextResult: LaunchAtLoginChangeResult?
    private(set) var requests: [Bool] = []
    private(set) var statusReadCount = 0

    var status: LaunchAtLoginStatus {
        statusReadCount += 1
        return storedStatus
    }

    init(status: LaunchAtLoginStatus) {
        storedStatus = status
    }

    func simulateStatus(_ status: LaunchAtLoginStatus) {
        storedStatus = status
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtLoginChangeResult {
        requests.append(enabled)
        let result = nextResult ?? LaunchAtLoginChangeResult(
            requestedEnabled: enabled,
            status: enabled ? .enabled : .disabled,
            outcome: .applied
        )
        storedStatus = result.status
        return result
    }
}

@MainActor
private final class FakeHotKeyRegistration: HotKeyRegistration {
    private let onPress: @MainActor @Sendable () -> Void
    private(set) var unregisterCount = 0

    init(onPress: @escaping @MainActor @Sendable () -> Void) {
        self.onPress = onPress
    }

    func unregister() {
        unregisterCount += 1
    }

    func press() {
        onPress()
    }
}

@MainActor
private final class FakeHotKeyRegistrar: HotKeyRegistering {
    private var failures: [HotKeyRegistrationFailure]
    private(set) var registerCount = 0
    private(set) var registrations: [FakeHotKeyRegistration] = []
    private(set) var shortcuts: [GlobalShortcut] = []

    init(failures: [HotKeyRegistrationFailure] = []) {
        self.failures = failures
    }

    func register(
        _ shortcut: GlobalShortcut,
        onPress: @escaping @MainActor @Sendable () -> Void
    ) -> Result<any HotKeyRegistration, HotKeyRegistrationFailure> {
        registerCount += 1
        shortcuts.append(shortcut)
        if !failures.isEmpty {
            return .failure(failures.removeFirst())
        }

        let registration = FakeHotKeyRegistration(onPress: onPress)
        registrations.append(registration)
        return .success(registration)
    }
}

@MainActor
private final class HotKeyServiceRecorder {
    private(set) var pressCount = 0
    private(set) var statuses: [HotKeyServiceStatus] = []

    func recordPress() {
        pressCount += 1
    }

    func recordStatus(_ status: HotKeyServiceStatus) {
        statuses.append(status)
    }
}

private enum FakeSystemServiceError: Error {
    case operationFailed
}

private final class IsolatedSystemServiceDefaults {
    let suiteName = "KeyLight.SystemServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated defaults suite")
        }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
