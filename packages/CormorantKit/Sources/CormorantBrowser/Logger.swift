import OSLog

extension Logger {
    nonisolated public static let app = Logger(subsystem: "dev.baldyeagle.cormorant", category: "app")
}
