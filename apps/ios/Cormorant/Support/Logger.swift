import OSLog

extension Logger {
    nonisolated static let app = Logger(subsystem: "dev.baldyeagle.cormorant", category: "app")
}
