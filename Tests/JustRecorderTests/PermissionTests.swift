import Foundation

final class PermissionTests: RegressionCase {
    func testBackgroundNeverPrompts() {
        let state = CapturePermissionState()
        checkFalse(state.canAttempt(preflightGranted: false, userInitiated: false))
        checkTrue(state.canAttempt(preflightGranted: true, userInitiated: false))
    }
    func testStalePreflightDoesNotBlockUserCapture() {
        var state = CapturePermissionState()
        checkTrue(state.canAttempt(preflightGranted: false, userInitiated: true))
        state.didStart()
        checkTrue(state.canAttempt(preflightGranted: false, userInitiated: false))
    }
    func testDenialDoesNotTriggerRepeatedAttempts() {
        var state = CapturePermissionState()
        state.didStart()
        state.didDeny()
        checkFalse(state.captureConfirmed)
        checkFalse(state.canAttempt(preflightGranted: false, userInitiated: true))
        checkFalse(state.canAttempt(preflightGranted: false, userInitiated: false))
        checkFalse(state.canAttempt(preflightGranted: true, userInitiated: true))
        state.didStart()
        checkTrue(state.captureConfirmed)
        checkFalse(state.denied)
    }
}
