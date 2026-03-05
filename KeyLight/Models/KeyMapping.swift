import Foundation
import CoreGraphics

/// Maps macOS key codes to horizontal screen positions and widths
/// Based on MacBook Air keyboard layout - keys projected to bottom screen edge
/// Positions are normalized 0.0 (left edge) to 1.0 (right edge)
@MainActor
struct KeyMapping: Sendable {

    /// Key properties including position and width
    struct KeyInfo: Sendable {
        let position: CGFloat  // Center position (0.0 to 1.0)
        let width: CGFloat     // Relative width (1.0 = standard key, 6.0 = space bar)
    }

    private static let defaultKeyInfo = KeyInfo(position: 0.5, width: 1.0)
    private static let mediaAliasKeys: [UInt16] = [500, 501, 502, 503, 504, 505, 506, 507, 516, 517, 518, 519, 520]

    /// Returns key info (position and width) for a given key code
    static func keyInfo(for keyCode: UInt16) -> KeyInfo {
        let index = Int(keyCode)
        if index >= 0 && index < keyTable.count {
            return keyTable[index]
        }
        return defaultKeyInfo
    }

    static func hasMappedKeyCode(_ keyCode: UInt16) -> Bool {
        keyData[keyCode] != nil
    }

    /// Returns horizontal position (0.0 to 1.0) for a given key code
    static func horizontalPosition(for keyCode: UInt16) -> CGFloat {
        return keyInfo(for: keyCode).position
    }

    // MacBook Air keyboard layout mapping
    // The keyboard spans roughly 12% to 88% of screen width (76% total)
    // Key positions are calculated based on actual key centers
    //
    // Key width reference (in key units):
    // - Standard key: 1.0
    // - Tab, Backslash: 1.5
    // - Caps Lock: 1.75, Return: 1.75
    // - Left Shift: 2.25, Right Shift: 2.75
    // - Space bar: ~5.0
    // - Command keys: 1.25
    // - fn, Control, Option: 1.0

    // Layout constants
    private static let leftEdge: CGFloat = 0.12
    private static let rightEdge: CGFloat = 0.88
    private static let keyboardWidth: CGFloat = 0.76  // rightEdge - leftEdge

    // Source of truth for the macOS keyboard position table used by the runtime glow mapper.
    private static let keyData: [UInt16: KeyInfo] = [
        // ============ Function Row ============
        53: KeyInfo(position: 0.135, width: 1.0),   // Escape (left edge)
        122: KeyInfo(position: 0.195, width: 0.8),  // F1
        120: KeyInfo(position: 0.250, width: 0.8),  // F2
        99: KeyInfo(position: 0.305, width: 0.8),   // F3
        118: KeyInfo(position: 0.360, width: 0.8),  // F4
        96: KeyInfo(position: 0.420, width: 0.8),   // F5
        97: KeyInfo(position: 0.475, width: 0.8),   // F6
        98: KeyInfo(position: 0.530, width: 0.8),   // F7
        100: KeyInfo(position: 0.585, width: 0.8),  // F8
        101: KeyInfo(position: 0.640, width: 0.8),  // F9
        109: KeyInfo(position: 0.695, width: 0.8),  // F10
        103: KeyInfo(position: 0.750, width: 0.8),  // F11
        111: KeyInfo(position: 0.805, width: 0.8),  // F12

        // ============ Number Row ============
        50: KeyInfo(position: 0.150, width: 1.0),   // ` ~
        18: KeyInfo(position: 0.205, width: 1.0),   // 1
        19: KeyInfo(position: 0.260, width: 1.0),   // 2
        20: KeyInfo(position: 0.315, width: 1.0),   // 3
        21: KeyInfo(position: 0.370, width: 1.0),   // 4
        23: KeyInfo(position: 0.425, width: 1.0),   // 5
        22: KeyInfo(position: 0.480, width: 1.0),   // 6
        26: KeyInfo(position: 0.535, width: 1.0),   // 7
        28: KeyInfo(position: 0.590, width: 1.0),   // 8
        25: KeyInfo(position: 0.645, width: 1.0),   // 9
        29: KeyInfo(position: 0.700, width: 1.0),   // 0
        27: KeyInfo(position: 0.755, width: 1.0),   // - _
        24: KeyInfo(position: 0.810, width: 1.0),   // = +
        51: KeyInfo(position: 0.860, width: 1.5),   // Delete/Backspace

        // ============ QWERTY Row ============
        48: KeyInfo(position: 0.162, width: 1.5),   // Tab
        12: KeyInfo(position: 0.225, width: 1.0),   // Q
        13: KeyInfo(position: 0.280, width: 1.0),   // W
        14: KeyInfo(position: 0.335, width: 1.0),   // E
        15: KeyInfo(position: 0.390, width: 1.0),   // R
        17: KeyInfo(position: 0.445, width: 1.0),   // T
        16: KeyInfo(position: 0.500, width: 1.0),   // Y
        32: KeyInfo(position: 0.555, width: 1.0),   // U
        34: KeyInfo(position: 0.610, width: 1.0),   // I
        31: KeyInfo(position: 0.665, width: 1.0),   // O
        35: KeyInfo(position: 0.720, width: 1.0),   // P
        33: KeyInfo(position: 0.775, width: 1.0),   // [ {
        30: KeyInfo(position: 0.830, width: 1.0),   // ] }
        42: KeyInfo(position: 0.872, width: 1.5),   // \ |

        // ============ ASDF Row ============
        57: KeyInfo(position: 0.168, width: 1.75),  // Caps Lock
        0: KeyInfo(position: 0.240, width: 1.0),    // A
        1: KeyInfo(position: 0.295, width: 1.0),    // S
        2: KeyInfo(position: 0.350, width: 1.0),    // D
        3: KeyInfo(position: 0.405, width: 1.0),    // F
        5: KeyInfo(position: 0.460, width: 1.0),    // G
        4: KeyInfo(position: 0.515, width: 1.0),    // H
        38: KeyInfo(position: 0.570, width: 1.0),   // J
        40: KeyInfo(position: 0.625, width: 1.0),   // K
        37: KeyInfo(position: 0.680, width: 1.0),   // L
        41: KeyInfo(position: 0.735, width: 1.0),   // ; :
        39: KeyInfo(position: 0.790, width: 1.0),   // ' "
        36: KeyInfo(position: 0.855, width: 1.75),  // Return

        // ============ ZXCV Row ============
        56: KeyInfo(position: 0.155, width: 1.25),  // Left Shift (ISO: narrower)
        10: KeyInfo(position: 0.220, width: 1.0),   // ISO key (< > on German layout, between LShift and Z/Y)
        6: KeyInfo(position: 0.260, width: 1.0),    // Z (Y on German QWERTZ)
        7: KeyInfo(position: 0.315, width: 1.0),    // X
        8: KeyInfo(position: 0.370, width: 1.0),    // C
        9: KeyInfo(position: 0.425, width: 1.0),    // V
        11: KeyInfo(position: 0.480, width: 1.0),   // B
        45: KeyInfo(position: 0.535, width: 1.0),   // N
        46: KeyInfo(position: 0.590, width: 1.0),   // M
        43: KeyInfo(position: 0.645, width: 1.0),   // , <
        47: KeyInfo(position: 0.700, width: 1.0),   // . >
        44: KeyInfo(position: 0.755, width: 1.0),   // / ?
        60: KeyInfo(position: 0.840, width: 2.75),  // Right Shift

        // ============ Bottom Row (Modifiers + Space) ============
        63: KeyInfo(position: 0.145, width: 1.0),   // fn
        59: KeyInfo(position: 0.200, width: 1.0),   // Left Control
        62: KeyInfo(position: 0.200, width: 1.0),   // Right Control (external keyboards)
        58: KeyInfo(position: 0.255, width: 1.0),   // Left Option
        55: KeyInfo(position: 0.320, width: 1.25),  // Left Command

        // SPACE BAR - centered, wide (reduced from 6.0 for tighter proportion)
        49: KeyInfo(position: 0.500, width: 5.0),   // Space

        54: KeyInfo(position: 0.680, width: 1.25),  // Right Command
        61: KeyInfo(position: 0.745, width: 1.0),   // Right Option

        // Arrow keys cluster (inverted T layout)
        123: KeyInfo(position: 0.810, width: 1.0),  // Left Arrow
        126: KeyInfo(position: 0.860, width: 0.8),  // Up Arrow
        125: KeyInfo(position: 0.865, width: 0.8),  // Down Arrow (nudged from Up for visible glow difference)
        124: KeyInfo(position: 0.910, width: 1.0),  // Right Arrow

        // ============ Media Keys (virtual codes from KeyboardMonitor) ============
        // These are used when Fn keys act as media keys (default MacBook behavior)
        500: KeyInfo(position: 0.195, width: 0.8),  // Brightness Down (F1 position)
        501: KeyInfo(position: 0.250, width: 0.8),  // Brightness Up (F2 position)
        502: KeyInfo(position: 0.305, width: 0.8),  // Mission Control (F3 position)
        503: KeyInfo(position: 0.360, width: 0.8),  // Spotlight/Launchpad (F4 position)
        504: KeyInfo(position: 0.420, width: 0.8),  // Dictation (F5 position)
        505: KeyInfo(position: 0.475, width: 0.8),  // Do Not Disturb (F6 position)
        506: KeyInfo(position: 0.530, width: 0.8),  // (F7 position)
        507: KeyInfo(position: 0.585, width: 0.8),  // Rewind (F8 position)
        516: KeyInfo(position: 0.585, width: 0.8),  // Play/Pause (F8 position)
        517: KeyInfo(position: 0.640, width: 0.8),  // Forward (F9 position)
        518: KeyInfo(position: 0.695, width: 0.8),  // Mute (F10 position)
        519: KeyInfo(position: 0.750, width: 0.8),  // Volume Down (F11 position)
        520: KeyInfo(position: 0.805, width: 0.8),  // Volume Up (F12 position)
    ]

    #if DEBUG
    /// Guard rails for the two intentionally-different keyboard geometry tables.
    /// - Runtime table (`KeyMapping`) keeps current glow behavior.
    /// - Editor table (`KeyboardLayoutInfo`) keeps editing UX semantics.
    static func assertParityContracts() {
        let editorByKey = Dictionary(uniqueKeysWithValues: KeyboardLayoutInfo.allKeys.map { ($0.id, $0) })

        // Documented intentional drift: runtime space key width differs from editor display width.
        precondition(keyData[49]?.width == 5.0, "Runtime table contract changed for space width")
        precondition(editorByKey[49]?.width == 6.0, "Editor table contract changed for space width")

        // Documented intentional drift: runtime down-arrow is slightly offset from editor preview.
        precondition(keyData[125]?.position == 0.865, "Runtime table contract changed for down-arrow position")
        precondition(editorByKey[125]?.position == 0.860, "Editor table contract changed for down-arrow position")

        // Every media alias must stay locked to its canonical function-key geometry.
        for alias in mediaAliasKeys {
            let canonical = KeyboardLayoutInfo.canonicalKeyCode(for: alias)
            guard let aliasInfo = keyData[alias], let canonicalInfo = keyData[canonical] else {
                preconditionFailure("Missing media/canonical mapping for key \(alias) -> \(canonical)")
            }
            precondition(aliasInfo.position == canonicalInfo.position && aliasInfo.width == canonicalInfo.width,
                         "Media alias geometry drift for key \(alias) -> \(canonical)")
        }
    }
    #endif

    /// Table lookup for key info to avoid dictionary hashing in hot paths
    private static let keyTable: [KeyInfo] = {
        var table = Array(repeating: defaultKeyInfo, count: 1024)
        for (keyCode, info) in keyData {
            let index = Int(keyCode)
            if index >= 0 && index < table.count {
                table[index] = info
            }
        }
        return table
    }()
}
