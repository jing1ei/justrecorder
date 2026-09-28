import Foundation

/// Bounded metadata subprocess; never executes Apple events on the UI thread.
enum MetadataProcess {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        defer { try? FileManager.default.removeItem(at: output) }
        guard let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 0.2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard process.terminationStatus == 0,
              let reader = try? FileHandle(forReadingFrom: output) else { return nil }
        defer { try? reader.close() }
        guard let data = try? reader.read(upToCount: 16_385), data.count <= 16_384 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
