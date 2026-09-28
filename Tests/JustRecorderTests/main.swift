import Foundation

// Dependency-free runner so the same suite works with the Command Line Tools.
var failures = 0
func checkTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { failures += 1; print("FAIL \(file):\(line)") }
}
func checkFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { checkTrue(!value, file: file, line: line) }
func checkNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { checkTrue(value == nil, file: file, line: line) }
func checkEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { checkTrue(a == b, file: file, line: line) }
func checkEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) { checkTrue(abs(a-b) <= accuracy, file: file, line: line) }
func checkLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { checkTrue(a < b, file: file, line: line) }
func checkLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { checkTrue(a <= b, file: file, line: line) }
func checkGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { checkTrue(a > b, file: file, line: line) }
struct MissingValue: Error {}
func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw MissingValue() }; return value }
final class Completion {
    var fulfilled = false
    func fulfill() { fulfilled = true }
}
class RegressionCase {
    var cleanup: [() throws -> Void] = []
    func addTeardownBlock(_ work: @escaping () throws -> Void) { cleanup.append(work) }
    func expectation(description: String) -> Completion { Completion() }
    func wait(for completions: [Completion], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while completions.contains(where: { !$0.fulfilled }), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        checkTrue(completions.allSatisfy(\.fulfilled))
    }
    func run(_ name: String, _ body: () throws -> Void) {
        let before = failures
        do { try body() } catch { failures += 1; print("FAIL \(name): \(error)") }
        for work in cleanup { do { try work() } catch { failures += 1; print("Cleanup: \(error)") } }
        cleanup.removeAll()
        print("\(failures == before ? "PASS" : "FAIL") \(name)")
    }
}
let recordings = RecordingTests()
recordings.run("slow writer and closed-file handoff", recordings.testSlowWriterReturnsImmediatelyAndFinalizesOnlyAfterClose)
recordings.run("pre-roll order and drain", recordings.testPreRollKeepsNewestFramesInOrderAndDrainsOnce)
recordings.run("interleaved stereo capture and pre-roll", recordings.testInterleavedStereoSurvivesCaptureAndPreRoll)
recordings.run("stale auto-stop isolation", recordings.testOldAutoStopCannotStopNextRecording)
recordings.run("native audio formats", recordings.testAllNativeFormatsProduceReadableAudio)
recordings.run("failed encoder preserves source", recordings.testFailedEncoderPreservesSourceAndRemovesPartialOutput)
recordings.run("metadata output and timeout", recordings.testMetadataProcessTimeoutAndOutput)
recordings.run("subprocess timeout", recordings.testStuckSubprocessHasBoundedLifetime)
let naming = NamingAndSettingsTests()
naming.run("endpoint paths and query", naming.testEndpointAppendsPathBeforeQueryAndPreservesEncodedValues)
naming.run("invalid preferences", naming.testCorruptPreferencesCannotOverflowOrRequestUnboundedResources)
naming.run("optional names and Unicode", naming.testNamingHandlesOptionalArtistAndLongUnicodeWithoutHiddenFiles)
naming.run("menu status and long captions", naming.testMenuStatusPreservesFullMessageWithoutClassifyingTrackWords)
let permissions = PermissionTests()
permissions.run("background permission checks never prompt", permissions.testBackgroundNeverPrompts)
permissions.run("user capture can recover stale preflight", permissions.testStalePreflightDoesNotBlockUserCapture)
permissions.run("denied capture does not repeatedly prompt", permissions.testDenialDoesNotTriggerRepeatedAttempts)
print("\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
