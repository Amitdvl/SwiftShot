import AppKit

@MainActor
protocol CaptureFocusApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
}

extension NSRunningApplication: CaptureFocusApplication {}

/// Retains one process object, never names, window titles, or a persistent
/// history. The object is revalidated before use, including after termination.
@MainActor
struct CaptureFocusHistory<Application: CaptureFocusApplication> {
    private let ownPID: pid_t
    private var previous: Application?

    init(ownPID: pid_t) { self.ownPID = ownPID }

    mutating func record(_ application: Application?) {
        guard let application, eligible(application) else { return }
        previous = application
    }

    func destination(frontmost: Application?) -> Application? {
        if let frontmost, eligible(frontmost) { return frontmost }
        if let previous, eligible(previous) { return previous }
        return nil
    }

    private func eligible(_ application: Application) -> Bool {
        application.processIdentifier > 0 && application.processIdentifier != ownPID &&
            !application.isTerminated && application.activationPolicy == .regular
    }
}

/// Start before showing SwiftShot's own Settings/history UI. Activation events
/// record a return destination; selecting or recording it never activates it.
@MainActor
final class CaptureFocusTracker {
    private let workspace: NSWorkspace
    private var history: CaptureFocusHistory<NSRunningApplication>
    private var observation: CaptureFocusObservation?

    init(workspace: NSWorkspace = .shared, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.workspace = workspace
        history = CaptureFocusHistory(ownPID: ownPID)
    }

    func start() {
        guard observation == nil else { return }
        let center = workspace.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                // The explicit main queue keeps recording synchronous and ordered
                // with destination reads; no delayed task can replay an old app.
                MainActor.assumeIsolated {
                    self?.history.record(application)
                }
            }
        observation = CaptureFocusObservation(center: center, token: token)
        history.record(workspace.frontmostApplication)
    }

    func destination() -> NSRunningApplication? {
        history.destination(frontmost: workspace.frontmostApplication)
    }
}

/// Owns observer cleanup independently of the tracker's actor-isolated state.
/// NotificationCenter removal is safe on whichever thread releases the owner.
private final class CaptureFocusObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit { center.removeObserver(token) }
}
