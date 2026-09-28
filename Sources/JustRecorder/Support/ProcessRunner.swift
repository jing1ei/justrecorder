import Foundation

/// Runs blocking subprocess work on a dedicated queue with a bounded lifetime.
enum ProcessRunner {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            Log.error("Could not launch encoder: \(error.localizedDescription)")
            return nil
        }
        if finished.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                // Reap the child before the caller removes its partial output.
                process.waitUntilExit()
            }
            return nil
        }
        return process.terminationStatus
    }
}
