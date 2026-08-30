import Foundation

/// Owns Settings preview visibility so delayed hides cannot outlive an
/// interaction or window. Rendering priority remains in OverlayController.
@MainActor
final class SettingsGlowPreviewSession {
    typealias ShowHandler = @MainActor () -> Void
    typealias HideHandler = @MainActor () -> Void

    private let hideDelay: TimeInterval
    private let showHandler: ShowHandler
    private let hideHandler: HideHandler
    private var hideTask: Task<Void, Never>?
    private var isEditing = false

    init(
        hideDelay: TimeInterval = 0.5,
        show: @escaping ShowHandler,
        hide: @escaping HideHandler
    ) {
        self.hideDelay = hideDelay.isFinite ? max(hideDelay, 0) : 0.5
        showHandler = show
        hideHandler = hide
    }

    func configurationChanged(isEnabled: Bool) {
        cancelPendingHide()
        guard isEnabled else {
            hideHandler()
            return
        }

        showHandler()
        guard !isEditing else { return }
        scheduleHide()
    }

    func editingChanged(_ editing: Bool, isEnabled: Bool) {
        isEditing = editing
        configurationChanged(isEnabled: isEnabled)
    }

    func stop() {
        cancelPendingHide()
        isEditing = false
        hideHandler()
    }

    private func scheduleHide() {
        let delay = hideDelay
        hideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            hideTask = nil
            hideHandler()
        }
    }

    private func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
    }
}
