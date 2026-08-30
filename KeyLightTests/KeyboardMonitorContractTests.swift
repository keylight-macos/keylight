import XCTest
import CoreGraphics
import AppKit
import IOKit.hid
@testable import KeyLight

final class KeyboardMonitorContractTests: XCTestCase {
    func testMediaVirtualKeyResolutionAndDedupeWindow() {
        let monitor = KeyboardMonitor { _ in }

        XCTAssertEqual(monitor._testResolveVirtualKeyCode(nxCode: 0), 520)  // sound up
        XCTAssertEqual(monitor._testResolveVirtualKeyCode(nxCode: 3), 500)  // brightness down
        XCTAssertEqual(monitor._testResolveVirtualKeyCode(nxCode: 7), 518)  // mute
        XCTAssertEqual(monitor._testResolveVirtualKeyCode(nxCode: 19), 517) // fast-forward/F9
        XCTAssertEqual(monitor._testResolveVirtualKeyCode(nxCode: 20), 506) // rewind/F7
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 4))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 5))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 6))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 999))

        let t0: CFAbsoluteTime = 1000
        XCTAssertFalse(monitor._testShouldDedupeMediaEvent(keyCode: 516, isKeyDown: true, now: t0))
        XCTAssertTrue(monitor._testShouldDedupeMediaEvent(keyCode: 516, isKeyDown: true, now: t0 + 0.01))
        XCTAssertFalse(monitor._testShouldDedupeMediaEvent(keyCode: 516, isKeyDown: true, now: t0 + 0.05))

        // HID wins when both sources report the same physical press in a short window.
        XCTAssertFalse(
            monitor._testShouldDedupeMediaEventWithSource(
                keyCode: 517,
                isKeyDown: true,
                source: "hid",
                now: t0 + 1.0
            )
        )
        XCTAssertTrue(
            monitor._testShouldDedupeMediaEventWithSource(
                keyCode: 517,
                isKeyDown: true,
                source: "system",
                now: t0 + 1.01
            )
        )

        XCTAssertEqual(
            monitor._testResolveHIDConsumerUsage(
                UInt32(kHIDUsage_Csmr_VolumeIncrement)
            ),
            520
        )
        XCTAssertNil(monitor._testResolveHIDConsumerUsage(0xFFFF))
    }

    func testAppleMediaRowHIDUsagesResolveToF6F7AndF9AliasesOnlyOnAllowedPages() {
        let monitor = KeyboardMonitor { _ in }
        let hardwareMappings: [(UInt32, UInt32, UInt16, UInt16)] = [
            (UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_DoNotDisturb), 505, 97),
            (UInt32(kHIDPage_KeyboardOrKeypad), UInt32(kHIDUsage_KeyboardF6), 505, 97),
            (UInt32(kHIDPage_KeyboardOrKeypad), UInt32(kHIDUsage_KeyboardF7), 506, 98),
            (UInt32(kHIDPage_KeyboardOrKeypad), UInt32(kHIDUsage_KeyboardF9), 517, 101),
            (UInt32(kHIDPage_Consumer), UInt32(kHIDUsage_Csmr_Rewind), 506, 98),
            (UInt32(kHIDPage_Consumer), UInt32(kHIDUsage_Csmr_ScanPreviousTrack), 506, 98),
            (UInt32(kHIDPage_Consumer), UInt32(kHIDUsage_Csmr_FastForward), 517, 101),
            (UInt32(kHIDPage_Consumer), UInt32(kHIDUsage_Csmr_ScanNextTrack), 517, 101),
        ]

        for (page, usage, alias, functionKey) in hardwareMappings {
            XCTAssertEqual(monitor._testResolveHIDUsage(page: page, usage: usage), alias)
            XCTAssertEqual(KeyboardLayoutInfo.canonicalKeyCode(for: alias), functionKey)
        }

        XCTAssertNil(
            monitor._testResolveHIDUsage(
                page: UInt32(kHIDPage_Consumer),
                usage: UInt32(kHIDUsage_GD_DoNotDisturb)
            )
        )
        XCTAssertNil(
            monitor._testResolveHIDUsage(
                page: UInt32(kHIDPage_GenericDesktop),
                usage: UInt32(kHIDUsage_Csmr_Rewind)
            )
        )
        XCTAssertNil(
            monitor._testResolveHIDUsage(
                page: UInt32(kHIDPage_KeyboardOrKeypad),
                usage: UInt32(kHIDUsage_KeyboardF8)
            )
        )
    }

    func testDeterministicTopRowMappingAndUnknownRawBehavior() {
        let monitor = KeyboardMonitor { _ in }

        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 160,
                charactersIgnoringModifiers: String(UnicodeScalar(0xF706)!)
            ),
            99 // F3
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventConfidence(
                rawKeyCode: 160,
                charactersIgnoringModifiers: String(UnicodeScalar(0xF706)!)
            ),
            "high"
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 161,
                charactersIgnoringModifiers: String(UnicodeScalar(0xF707)!)
            ),
            118 // F4
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 162,
                charactersIgnoringModifiers: String(UnicodeScalar(0xF708)!)
            ),
            96 // F5
        )

        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 163,
                charactersIgnoringModifiers: "A"
            ),
            163
        )

        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 122,
                charactersIgnoringModifiers: String(UnicodeScalar(0xF706)!)
            ),
            122
        )

        let trustedRawMappings: [(UInt16, UInt16)] = [
            (145, 122),
            (144, 120),
            (160, 99),
            (131, 118),
            (177, 96),
            (176, 97),
            (178, 97),
            (173, 98),
            (174, 100),
            (175, 101),
            (74, 109),
            (73, 103),
            (72, 111)
        ]

        for (raw, expected) in trustedRawMappings {
            XCTAssertEqual(
                monitor._testResolveKeyboardEventKeyCode(
                    rawKeyCode: raw,
                    charactersIgnoringModifiers: nil
                ),
                expected
            )
            XCTAssertEqual(
                monitor._testResolveKeyboardEventConfidence(
                    rawKeyCode: raw,
                    charactersIgnoringModifiers: nil
                ),
                "high"
            )
        }

        // Unknown raw key remains unresolved.
        XCTAssertEqual(
            monitor._testResolveKeyboardEventConfidence(
                rawKeyCode: 163,
                charactersIgnoringModifiers: nil
            ),
            "unknown"
        )

        // NSEvent specialKey provides deterministic top-row mapping for hardware-specific raw codes.
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 160,
                specialKeyRawValue: NSEvent.SpecialKey.f4.rawValue
            ),
            118
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 177,
                specialKeyRawValue: NSEvent.SpecialKey.f5.rawValue
            ),
            96
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 173,
                specialKeyRawValue: NSEvent.SpecialKey.f7.rawValue
            ),
            98
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 175,
                specialKeyRawValue: NSEvent.SpecialKey.f9.rawValue
            ),
            101
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventConfidenceWithSpecialKey(
                rawKeyCode: 173,
                specialKeyRawValue: NSEvent.SpecialKey.f7.rawValue
            ),
            "high"
        )
    }

    func testEventLoopKeyboardDecodingIsSafeOffMainQueueWithoutAppKitMetadata() {
        let monitor = KeyboardMonitor { _ in }
        let result = DispatchQueue(
            label: "KeyLightTests.KeyboardEventLoop"
        ).sync {
            (
                monitor._testDecodeEventLoopKeyboardEvent(
                    rawKeyCode: 49,
                    isKeyDown: true
                ),
                monitor._testDecodeEventLoopKeyboardEvent(
                    rawKeyCode: 160,
                    isKeyDown: true
                ),
                monitor._testDecodeEventLoopKeyboardEvent(
                    rawKeyCode: 163,
                    isKeyDown: true
                )
            )
        }

        XCTAssertEqual(result.0?.keyCode, 49)
        XCTAssertEqual(result.1?.keyCode, 99)
        XCTAssertNil(result.2)
    }

    func testUnresolvedKeyboardRawDoesNotSuppressMediaSource() {
        let monitor = KeyboardMonitor { _ in }
        let t0: CFAbsoluteTime = 2100

        XCTAssertEqual(
            monitor._testResolveKeyboardEventConfidence(
                rawKeyCode: 163,
                charactersIgnoringModifiers: nil
            ),
            "unknown"
        )

        // No keyboard-first suppression: first media event for this key/state should pass.
        XCTAssertFalse(
            monitor._testShouldDedupeMediaEventWithSource(
                keyCode: 506,
                isKeyDown: true,
                source: "system",
                now: t0 + 0.01
            )
        )
        // Duplicate key/state in-window still dedupes normally.
        XCTAssertTrue(
            monitor._testShouldDedupeMediaEventWithSource(
                keyCode: 506,
                isKeyDown: true,
                source: "system",
                now: t0 + 0.02
            )
        )
    }

    func testTrustedRawTopRowMediaCodesMapToFunctionKeys() {
        let monitor = KeyboardMonitor { _ in }

        let rawMediaCodesToExpected: [(UInt16, UInt16)] = [
            (145, 122),
            (144, 120),
            (160, 99),
            (131, 118),
            (177, 96),
            (176, 97),
            (178, 97),
            (173, 98),
            (174, 100),
            (175, 101),
            (74, 109),
            (73, 103),
            (72, 111)
        ]
        for (code, expected) in rawMediaCodesToExpected {
            XCTAssertEqual(
                monitor._testResolveKeyboardEventKeyCode(
                    rawKeyCode: code,
                    charactersIgnoringModifiers: nil
                ),
                expected,
                "Raw top-row code \(code) should resolve to F-key \(expected)"
            )
            XCTAssertEqual(
                monitor._testResolveKeyboardEventConfidence(
                    rawKeyCode: code,
                    charactersIgnoringModifiers: nil
                ),
                "high",
                "Raw top-row code \(code) should be trusted via explicit map"
            )
        }
    }

    func testTrustedMetadataStillMapsF4F5F7F9() {
        let monitor = KeyboardMonitor { _ in }

        XCTAssertEqual(
            monitor._testResolveKeyboardEventConfidenceWithSpecialKey(
                rawKeyCode: 160,
                specialKeyRawValue: NSEvent.SpecialKey.f4.rawValue
            ),
            "high"
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 160,
                specialKeyRawValue: NSEvent.SpecialKey.f4.rawValue
            ),
            118
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 177,
                specialKeyRawValue: NSEvent.SpecialKey.f5.rawValue
            ),
            96
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 173,
                specialKeyRawValue: NSEvent.SpecialKey.f7.rawValue
            ),
            98
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 175,
                specialKeyRawValue: NSEvent.SpecialKey.f9.rawValue
            ),
            101
        )
    }

    func testUnsupportedNXTopRowOverridesRemainDisabled() {
        let monitor = KeyboardMonitor { _ in }

        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 4))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 5))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 6))
    }

    func testModifierFlagsChangedResolutionForCommandOptionControlAndFn() {
        let monitor = KeyboardMonitor { _ in }

        // Left and right Command
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 55, flags: [.maskCommand]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 54, flags: [.maskCommand]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 54, flags: [.maskCommand]), false)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 55, flags: []), false)

        // Left and right Option
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 58, flags: [.maskAlternate]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 61, flags: [.maskAlternate]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 61, flags: [.maskAlternate]), false)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 58, flags: []), false)

        // Left and right Control
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 59, flags: [.maskControl]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 62, flags: [.maskControl]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 62, flags: [.maskControl]), false)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 59, flags: []), false)

        // Fn
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 63, flags: [.maskSecondaryFn]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 63, flags: []), false)

        // Caps Lock stays isolated to key 57 and never maps to top-row aliases.
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 57, flags: [.maskAlphaShift]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 57, flags: []), false)
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 57,
                charactersIgnoringModifiers: nil
            ),
            57
        )
        XCTAssertEqual(monitor._testCapsLockEmitSequence(isKeyDown: true), [true, false])
        XCTAssertEqual(monitor._testCapsLockEmitSequence(isKeyDown: false), [false])

        // Unknown/non-modifier key should be ignored
        XCTAssertNil(monitor._testResolveModifierFlagsChanged(keyCode: 12, flags: [.maskCommand]))
    }
}
