import SwiftUI
import AppKit

// MARK: - Menu Bar Menu

struct MenuBarMenuView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button(appState.isEnabled ? "Disable KeyLight" : "Enable KeyLight") {
            appState.isEnabled.toggle()
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])

        Divider()

        Button("Open Settings...") {
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Adjust Key Positions...") {
            NotificationCenter.default.post(name: .openKeyPositionEditor, object: nil)
        }

        Divider()

        Button("Quit KeyLight") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Label("KeyLight", systemImage: appState.isEnabled ? "keyboard" : "keyboard.badge.ellipsis")
    }
}

// MARK: - Color Helpers

func interpolateColor(from: NSColor, to: NSColor, fraction: CGFloat) -> NSColor {
    let t = max(0.0, min(1.0, fraction))
    let fromColor = from.usingColorSpace(.sRGB) ?? from
    let toColor = to.usingColorSpace(.sRGB) ?? to

    var fr: CGFloat = 0
    var fg: CGFloat = 0
    var fb: CGFloat = 0
    var fa: CGFloat = 0
    var tr: CGFloat = 0
    var tg: CGFloat = 0
    var tb: CGFloat = 0
    var ta: CGFloat = 0

    fromColor.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
    toColor.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)

    return NSColor(
        red: fr + (tr - fr) * t,
        green: fg + (tg - fg) * t,
        blue: fb + (tb - fb) * t,
        alpha: fa + (ta - fa) * t
    )
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }

    func toHex() -> String? {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components else {
            return nil
        }

        let r = components.count > 0 ? components[0] : 0
        let g = components.count > 1 ? components[1] : 0
        let b = components.count > 2 ? components[2] : 0

        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    private let settings = SettingsManager.shared
    private var isLoading = true

    private var persistWorkItem: DispatchWorkItem?
    private var notifyWorkItem: DispatchWorkItem?
    private var randomColorCache: [UInt16: NSColor] = [:]
    private let persistDebounceInterval: TimeInterval = 0.1
    private let notifyDebounceInterval: TimeInterval = 0.016

    @Published var isEnabled: Bool = true {
        didSet {
            if !isLoading {
                settings.isEnabled = isEnabled
                debouncedNotify()
            }
        }
    }

    @Published var glowColor: Color = Color(hex: "68B8FF") ?? Color(red: 0.41, green: 0.72, blue: 1.0) {
        didSet {
            glowNSColor = NSColor(glowColor)
            if !isLoading {
                debouncedPersist()
                debouncedNotify()
            }
        }
    }

    @Published var glowOpacity: Double = 0.8013 {
        didSet {
            if !isLoading {
                debouncedPersist()
                debouncedNotify()
            }
        }
    }

    @Published var glowSize: Double = 80.5536 {
        didSet {
            if !isLoading {
                debouncedPersist()
                debouncedNotify()
            }
        }
    }

    @Published var glowWidth: Double = 1.0 {
        didSet {
            if !isLoading {
                debouncedPersist()
                debouncedNotify()
            }
        }
    }

    @Published var glowRoundness: Double = 0.7069 {
        didSet {
            if !isLoading {
                debouncedPersist()
                debouncedNotify()
            }
        }
    }

    @Published var glowFullness: Double = 0.6046 {
        didSet {
            if !isLoading {
                debouncedPersist()
                debouncedNotify()
            }
        }
    }

    @Published var fadeDuration: Double = 1.0004 {
        didSet {
            if !isLoading {
                debouncedPersist()
                debouncedNotify()
            }
        }
    }

    @Published var launchAtLogin: Bool = false {
        didSet {
            if !isLoading {
                settings.launchAtLogin = launchAtLogin
            }
        }
    }

    @Published var colorMode: SettingsManager.ColorMode = .positionGradient {
        didSet {
            if !isLoading {
                debouncedPersist()
                debouncedNotify()
            }
        }
    }

    @Published var gradientStartColor: Color = Color(hex: "68B8FF") ?? .blue {
        didSet {
            gradientStartNSColor = NSColor(gradientStartColor)
            if !isLoading {
                debouncedPersist()
                debouncedNotify()
            }
        }
    }

    @Published var gradientEndColor: Color = Color(hex: "00E69A") ?? .green {
        didSet {
            gradientEndNSColor = NSColor(gradientEndColor)
            if !isLoading {
                debouncedPersist()
                debouncedNotify()
            }
        }
    }

    private(set) var glowNSColor: NSColor = NSColor(red: 0.41, green: 0.72, blue: 1.0, alpha: 1.0)
    private(set) var gradientStartNSColor: NSColor = NSColor(red: 0.41, green: 0.72, blue: 1.0, alpha: 1.0)
    private(set) var gradientEndNSColor: NSColor = NSColor(red: 0.0, green: 0.90, blue: 0.60, alpha: 1.0)

    init() {
        loadSettings()
        isLoading = false
    }

    private func debouncedPersist() {
        persistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistAllSettings()
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
    }

    private func debouncedNotify() {
        notifyWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            NotificationCenter.default.post(name: .glowSettingsChanged, object: nil)
        }
        notifyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + notifyDebounceInterval, execute: workItem)
    }

    private func persistAllSettings() {
        settings.glowColorHex = glowColor.toHex() ?? "68B8FF"
        settings.glowOpacity = glowOpacity
        settings.glowSize = glowSize
        settings.glowWidth = glowWidth
        settings.glowRoundness = glowRoundness
        settings.glowFullness = glowFullness
        settings.fadeDuration = fadeDuration
        settings.colorMode = colorMode
        settings.gradientStartHex = gradientStartColor.toHex() ?? "68B8FF"
        settings.gradientEndHex = gradientEndColor.toHex() ?? "00E69A"
    }

    func flushPendingPersist() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        persistAllSettings()
    }

    func loadSettings() {
        isLoading = true
        isEnabled = settings.isEnabled
        glowColor = Color(hex: settings.glowColorHex) ?? Color(hex: "68B8FF") ?? Color(red: 0.41, green: 0.72, blue: 1.0)
        glowOpacity = settings.glowOpacity
        glowSize = settings.glowSize
        glowWidth = settings.glowWidth
        glowRoundness = settings.glowRoundness
        glowFullness = settings.glowFullness
        fadeDuration = settings.fadeDuration
        launchAtLogin = settings.launchAtLogin
        colorMode = settings.colorMode
        gradientStartColor = Color(hex: settings.gradientStartHex) ?? Color(hex: "68B8FF") ?? .blue
        gradientEndColor = Color(hex: settings.gradientEndHex) ?? Color(hex: "00E69A") ?? .green
        isLoading = false
    }

    func applyTheme(_ theme: SettingsManager.Theme) {
        notifyWorkItem?.cancel()
        notifyWorkItem = nil

        isLoading = true
        glowColor = Color(hex: theme.colorHex) ?? glowColor
        glowOpacity = theme.opacity
        glowSize = theme.size
        glowWidth = theme.width
        glowRoundness = theme.glowRoundness
        glowFullness = theme.glowFullness
        fadeDuration = theme.fadeDuration
        colorMode = theme.colorMode
        gradientStartColor = Color(hex: theme.gradientStartHex ?? "68B8FF") ?? gradientStartColor
        gradientEndColor = Color(hex: theme.gradientEndHex ?? "00E69A") ?? gradientEndColor
        isLoading = false

        persistWorkItem?.cancel()
        persistAllSettings()
        settings.currentThemeName = theme.name

        NotificationCenter.default.post(name: .glowSettingsChanged, object: nil)
    }

    func currentTheme() -> SettingsManager.Theme {
        SettingsManager.Theme(
            name: settings.currentThemeName,
            colorHex: settings.glowColorHex,
            opacity: glowOpacity,
            size: glowSize,
            width: glowWidth,
            glowRoundness: glowRoundness,
            glowFullness: glowFullness,
            fadeDuration: fadeDuration,
            colorMode: colorMode,
            gradientStartHex: settings.gradientStartHex,
            gradientEndHex: settings.gradientEndHex
        )
    }

    func resolvedNSColor(at horizontalPosition: CGFloat) -> NSColor {
        let clamped = max(0.0, min(1.0, horizontalPosition))
        switch colorMode {
        case .solid:
            return glowNSColor
        case .positionGradient:
            return interpolateColor(from: gradientStartNSColor, to: gradientEndNSColor, fraction: clamped)
        case .randomPerKey:
            return NSColor(hue: clamped, saturation: 0.8, brightness: 1.0, alpha: 1.0)
        case .rainbow:
            return NSColor(hue: clamped, saturation: 0.9, brightness: 1.0, alpha: 1.0)
        }
    }

    func randomPerKeyNSColor(for keyCode: UInt16) -> NSColor {
        if let cached = randomColorCache[keyCode] {
            return cached
        }

        let seed = UInt32(keyCode) &* 1_103_515_245 &+ 12_345
        let hue = CGFloat(seed % 10_000) / 10_000.0
        let color = NSColor(hue: hue, saturation: 0.85, brightness: 1.0, alpha: 1.0)
        randomColorCache[keyCode] = color
        return color
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let glowSettingsChanged = Notification.Name("glowSettingsChanged")
    static let settingsStorageChanged = Notification.Name("settingsStorageChanged")
    static let openKeyPositionEditor = Notification.Name("openKeyPositionEditor")
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
    static let permissionStatusChanged = Notification.Name("permissionStatusChanged")
    static let keyPositionsChanged = Notification.Name("keyPositionsChanged")
    static let keyWidthsChanged = Notification.Name("keyWidthsChanged")
    static let showGlowPreview = Notification.Name("showGlowPreview")
    static let hideGlowPreview = Notification.Name("hideGlowPreview")
    static let physicalKeyDown = Notification.Name("physicalKeyDown")
    static let physicalKeyUp = Notification.Name("physicalKeyUp")
}
