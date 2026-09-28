/// Main-thread permission policy. A successful capture is stronger evidence than a
/// stale preflight response; a denial prevents repeated prompts in this process.
struct CapturePermissionState {
    private(set) var captureConfirmed = false
    private(set) var denied = false

    func canAttempt(preflightGranted: Bool, userInitiated: Bool) -> Bool {
        if denied { return false }
        if preflightGranted { return true }
        return captureConfirmed || userInitiated
    }

    mutating func didStart() { captureConfirmed = true; denied = false }
    mutating func didDeny() { captureConfirmed = false; denied = true }
}
