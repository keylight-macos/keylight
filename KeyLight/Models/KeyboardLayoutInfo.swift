import CoreGraphics
import Foundation

/// Provides keyboard layout info for the position editor
struct KeyboardLayoutInfo {
    struct KeyDisplayInfo: Identifiable {
        let id: UInt16
        let label: String
        let position: CGFloat
        let width: CGFloat
        let row: Int
    }

    // Media keys share physical function-key positions on Mac keyboards.
    private static let mediaToFunctionKeyAliases: [UInt16: UInt16] = [
        500: 122,  // Brightness down -> F1
        501: 120,  // Brightness up -> F2
        502: 99,   // Mission Control -> F3
        503: 118,  // Spotlight/Launchpad -> F4
        504: 96,   // Dictation -> F5
        505: 97,   // DND -> F6
        506: 98,   // Previous/Rewind -> F7
        507: 100,  // Legacy F8 media code -> F8
        516: 100,  // Play/Pause -> F8
        517: 101,  // Next -> F9
        518: 109,  // Mute -> F10
        519: 103,  // Volume down -> F11
        520: 111   // Volume up -> F12
    ]

    static func canonicalKeyCode(for keyCode: UInt16) -> UInt16 {
        mediaToFunctionKeyAliases[keyCode] ?? keyCode
    }

    static func isMediaAliasKey(_ keyCode: UInt16) -> Bool {
        mediaToFunctionKeyAliases[keyCode] != nil
    }

    static func fallbackKeyCode(for keyCode: UInt16) -> UInt16? {
        mediaToFunctionKeyAliases[keyCode]
    }

    // Source of truth for key editor positions/rows shown in the in-app layout calibrator.
    static let allKeys: [KeyDisplayInfo] = {
        var keys: [KeyDisplayInfo] = []

        // Function row (row 0)
        keys.append(KeyDisplayInfo(id: 53, label: "esc", position: 0.135, width: 1.0, row: 0))
        keys.append(KeyDisplayInfo(id: 122, label: "F1", position: 0.195, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 120, label: "F2", position: 0.250, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 99, label: "F3", position: 0.305, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 118, label: "F4", position: 0.360, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 96, label: "F5", position: 0.420, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 97, label: "F6", position: 0.475, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 98, label: "F7", position: 0.530, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 100, label: "F8", position: 0.585, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 101, label: "F9", position: 0.640, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 109, label: "F10", position: 0.695, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 103, label: "F11", position: 0.750, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 111, label: "F12", position: 0.805, width: 0.8, row: 0))

        // Number row (row 1)
        keys.append(KeyDisplayInfo(id: 50, label: "`", position: 0.150, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 18, label: "1", position: 0.205, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 19, label: "2", position: 0.260, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 20, label: "3", position: 0.315, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 21, label: "4", position: 0.370, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 23, label: "5", position: 0.425, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 22, label: "6", position: 0.480, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 26, label: "7", position: 0.535, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 28, label: "8", position: 0.590, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 25, label: "9", position: 0.645, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 29, label: "0", position: 0.700, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 27, label: "-", position: 0.755, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 24, label: "=", position: 0.810, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 51, label: "⌫", position: 0.860, width: 1.5, row: 1))

        // QWERTY row (row 2)
        keys.append(KeyDisplayInfo(id: 48, label: "⇥", position: 0.162, width: 1.5, row: 2))
        keys.append(KeyDisplayInfo(id: 12, label: "Q", position: 0.225, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 13, label: "W", position: 0.280, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 14, label: "E", position: 0.335, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 15, label: "R", position: 0.390, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 17, label: "T", position: 0.445, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 16, label: "Y", position: 0.500, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 32, label: "U", position: 0.555, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 34, label: "I", position: 0.610, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 31, label: "O", position: 0.665, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 35, label: "P", position: 0.720, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 33, label: "[", position: 0.775, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 30, label: "]", position: 0.830, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 42, label: "\\", position: 0.872, width: 1.5, row: 2))

        // ASDF row (row 3)
        keys.append(KeyDisplayInfo(id: 57, label: "⇪", position: 0.168, width: 1.75, row: 3))
        keys.append(KeyDisplayInfo(id: 0, label: "A", position: 0.240, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 1, label: "S", position: 0.295, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 2, label: "D", position: 0.350, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 3, label: "F", position: 0.405, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 5, label: "G", position: 0.460, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 4, label: "H", position: 0.515, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 38, label: "J", position: 0.570, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 40, label: "K", position: 0.625, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 37, label: "L", position: 0.680, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 41, label: ";", position: 0.735, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 39, label: "'", position: 0.790, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 36, label: "⏎", position: 0.855, width: 1.75, row: 3))

        // ZXCV row (row 4) - ISO layout with extra key
        keys.append(KeyDisplayInfo(id: 56, label: "⇧", position: 0.155, width: 1.25, row: 4))
        keys.append(KeyDisplayInfo(id: 10, label: "ISO <>", position: 0.220, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 6, label: "Z", position: 0.260, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 7, label: "X", position: 0.315, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 8, label: "C", position: 0.370, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 9, label: "V", position: 0.425, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 11, label: "B", position: 0.480, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 45, label: "N", position: 0.535, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 46, label: "M", position: 0.590, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 43, label: ",", position: 0.645, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 47, label: ".", position: 0.700, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 44, label: "/", position: 0.755, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 60, label: "⇧", position: 0.840, width: 2.75, row: 4))

        // Bottom row (row 5)
        keys.append(KeyDisplayInfo(id: 63, label: "fn", position: 0.145, width: 1.0, row: 5))
        keys.append(KeyDisplayInfo(id: 59, label: "⌃", position: 0.200, width: 1.0, row: 5))
        keys.append(KeyDisplayInfo(id: 58, label: "⌥", position: 0.255, width: 1.0, row: 5))
        keys.append(KeyDisplayInfo(id: 55, label: "⌘", position: 0.320, width: 1.25, row: 5))
        keys.append(KeyDisplayInfo(id: 49, label: "space", position: 0.500, width: 6.0, row: 5))
        keys.append(KeyDisplayInfo(id: 54, label: "⌘", position: 0.680, width: 1.25, row: 5))
        keys.append(KeyDisplayInfo(id: 61, label: "⌥", position: 0.745, width: 1.0, row: 5))
        keys.append(KeyDisplayInfo(id: 123, label: "←", position: 0.810, width: 1.0, row: 5))
        keys.append(KeyDisplayInfo(id: 126, label: "↑", position: 0.860, width: 0.8, row: 5))
        keys.append(KeyDisplayInfo(id: 125, label: "↓", position: 0.860, width: 0.8, row: 5))
        keys.append(KeyDisplayInfo(id: 124, label: "→", position: 0.910, width: 1.0, row: 5))

        return keys
    }()

    static var maxRow: Int {
        allKeys.map(\.row).max() ?? 0
    }

    static func keys(forRow row: Int) -> [KeyDisplayInfo] {
        allKeys.filter { $0.row == row }
    }
}
