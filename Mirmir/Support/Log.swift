import OSLog

enum MirmirLog {
    static let app = Logger(subsystem: "com.mirmir.app", category: "app")
    static let telemetry = Logger(
        subsystem: "com.mirmir.app",
        category: "DashboardTelemetry"
    )
}
