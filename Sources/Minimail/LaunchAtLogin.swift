import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` that models the *full* login-item
/// status instead of collapsing it to a Bool.
///
/// The bug this fixes: macOS frequently registers a Developer-ID app's login
/// item in the `.requiresApproval` state — the item exists but is toggled OFF
/// in System Settings ▸ General ▸ Login Items until the user approves it, so it
/// will NOT launch at login. Code that only checks `status == .enabled` then
/// shows the toggle as OFF with no explanation and the user is silently stuck
/// in a registered-but-not-launching state.
///
/// Both Settings and the first-run onboarding offer route through here so the
/// behaviour (and the `.requiresApproval` handling) lives in exactly one place.
enum LaunchAtLogin {
    enum State: Equatable {
        /// Registered and will launch at login.
        case enabled
        /// Registered, but the user must approve it in System Settings first.
        case requiresApproval
        /// Not registered (`.notRegistered` / `.notFound`).
        case disabled
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled // .notRegistered, .notFound, future cases
        }
    }

    /// The toggle should read ON whenever the item is registered — even when it
    /// still needs approval — so the user isn't told "off" while macOS shows it
    /// in their Login Items list.
    static var isOn: Bool {
        switch state {
        case .enabled, .requiresApproval: return true
        case .disabled: return false
        }
    }

    /// Register or unregister the main app as a login item. Returns the
    /// resulting state so callers can surface `.requiresApproval` immediately
    /// rather than after the next status read.
    @discardableResult
    static func set(_ enabled: Bool) throws -> State {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        return state
    }

    /// Deep-link the user to the Login Items pane so they can flip an item that
    /// is stuck in `.requiresApproval`.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
