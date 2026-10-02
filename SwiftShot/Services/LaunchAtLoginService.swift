import ServiceManagement

/// Controls the system-owned login item for the main SwiftShot app.
///
/// `SMAppService` keeps the registration with macOS instead of placing a
/// user-managed launch agent on disk, so moving or updating the app remains
/// safe and the user can still revoke it in System Settings.
enum LaunchAtLoginService {
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp

        if enabled {
            switch service.status {
            case .enabled, .requiresApproval:
                return
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        } else {
            switch service.status {
            case .notRegistered:
                return
            case .enabled, .requiresApproval, .notFound:
                try service.unregister()
            @unknown default:
                try service.unregister()
            }
        }
    }
}
