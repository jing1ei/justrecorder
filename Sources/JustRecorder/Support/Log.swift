import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.jing1ei.JustRecorder", category: "recording")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
