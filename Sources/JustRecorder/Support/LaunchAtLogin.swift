import Foundation
import ServiceManagement

enum LaunchAtLogin {

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns `nil` on success, or a human-readable error.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return nil }
                try SMAppService.mainApp.register()
            } else {
                // Unregistering something that was never registered throws — and would
                // surface as a spurious error in Settings.
                guard SMAppService.mainApp.status != .notRegistered else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            Log.error("Launch-at-login toggle failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
