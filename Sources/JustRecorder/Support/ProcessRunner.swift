import Foundation

/// Runs a blocking subprocess with a bounded lifetime. Call off the UI thread.
enum ProcessRunner {
    static func run(executable: String, arguments: [String], timeout: TimeInterval,
                    output: FileHandle = .nullDevice) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            Log.error("Could not launch \(executable): \(error.localizedDescription)")
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
