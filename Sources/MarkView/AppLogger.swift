import os
import MarkViewAppCore

/// Centralized structured logging for MD_OS.
/// Uses os.Logger only — no remote reporting.
enum AppLogger {
    private static let subsystem = "local.mdos"

    static let file = Logger(subsystem: subsystem, category: "file")
    static let render = Logger(subsystem: subsystem, category: "render")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let general = Logger(subsystem: subsystem, category: "general")

    fileprivate static func logger(for category: String) -> Logger {
        switch category {
        case "file": return file
        case "render": return render
        case "sync": return sync
        case "export": return export
        default: return general
        }
    }

    static func captureError(_ error: Error, category: String, message: String) {
        logger(for: category).error("\(message): \(error.localizedDescription)")
    }

    static func breadcrumb(_ message: String, category: String, level: LogLevel = .info) {
        switch level {
        case .error:
            logger(for: category).error("\(message)")
        case .warning:
            logger(for: category).warning("\(message)")
        default:
            logger(for: category).info("\(message)")
        }
    }

    enum LogLevel {
        case info
        case warning
        case error
    }
}

/// Local bridge for MarkViewAppCore's logging seam. Installed at startup.
struct LocalAppCoreLogger: AppCoreLogging {
    func logError(_ error: Error, category: String, message: String) {
        AppLogger.captureError(error, category: category, message: message)
    }

    func logWarning(_ message: String, category: String) {
        AppLogger.logger(for: category).error("\(message)")
    }
}
