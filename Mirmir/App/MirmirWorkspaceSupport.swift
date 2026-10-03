import CoreMedia
import Darwin
import Metal
import Observation
import SwiftUI

enum MirmirPresentation {
    static func sizeText(_ size: CGSize?) -> String {
        guard let size,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              let width = Int(exactly: size.width.rounded()),
              let height = Int(exactly: size.height.rounded()),
              width > 0,
              height > 0 else {
            return "Unknown"
        }
        return "\(width) × \(height)"
    }

    static func durationText(_ duration: CMTime) -> String {
        let seconds = CMTimeGetSeconds(duration)
        guard duration.isNumeric,
              seconds.isFinite,
              seconds >= 0,
              let wholeSeconds = Int(exactly: seconds.rounded()) else {
            return "Unknown"
        }
        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let remainingSeconds = wholeSeconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func frameRateText(_ rate: Float?) -> String {
        rate.map { String(format: "%.3f fps", $0) } ?? "Unknown"
    }

    static func timeIntervalText(_ time: CMTime?) -> String {
        guard let time else { return "Unknown" }
        let seconds = CMTimeGetSeconds(time)
        guard time.isNumeric, seconds.isFinite, seconds > 0 else {
            return "Unknown"
        }
        return String(format: "%.3f ms", seconds * 1_000)
    }

    static func dataRateText(_ rate: Float?) -> String {
        rate.map { String(format: "%.3f Mb/s", Double($0) / 1_000_000) }
            ?? "Unknown"
    }

    static func fileSizeText(_ byteCount: Int64?) -> String {
        guard let byteCount else { return "Unknown" }
        return ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    static func byteRateText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond,
              bytesPerSecond.isFinite,
              bytesPerSecond >= 0,
              bytesPerSecond <= Double(Int64.max) else {
            return "Sampling…"
        }
        if bytesPerSecond < 0.5 { return "0 B/s" }
        let byteCount = Int64(bytesPerSecond.rounded())
        return ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        ) + "/s"
    }

    static func percentageText(_ percentage: Double?) -> String {
        guard let percentage, percentage.isFinite, percentage >= 0 else {
            return "Sampling…"
        }
        return String(format: "%.1f%%", percentage)
    }

    static func audioText(_ info: VideoInfo) -> String {
        guard info.hasAudio else { return "Absent" }
        let suffix = info.audioTrackCount == 1 ? "track" : "tracks"
        return "Present (\(info.audioTrackCount) \(suffix))"
    }

    static func rangeText(_ isFullRange: Bool?) -> String {
        guard let isFullRange else { return "Unknown" }
        return isFullRange ? "Full" : "Video"
    }

    static func apertureText(_ aperture: CGRect?) -> String {
        guard let aperture else { return "Unknown" }
        return String(
            format: "%.0f × %.0f at (%.0f, %.0f)",
            aperture.width,
            aperture.height,
            aperture.origin.x,
            aperture.origin.y
        )
    }

    static func pixelAspectRatioText(
        _ ratio: VideoPixelAspectRatio?
    ) -> String {
        guard let ratio else { return "Unknown" }
        return "\(ratio.horizontalSpacing):\(ratio.verticalSpacing)"
    }

    static func compatibilityWarning(for info: VideoInfo) -> String? {
        var limitations: [String] = []
        if info.color.dynamicRange == .hdr || (info.color.bitDepth ?? 0) > 8 {
            limitations.append(
                "This build has no end-to-end HDR/P010 preservation path. "
                    + "Unsupported methods remain unavailable rather than "
                    + "tone-mapping silently."
            )
        }
        if (info.color.fieldCount ?? 1) > 1 || info.color.fieldDetail != nil {
            limitations.append(
                "Interlaced sources require a defined deinterlace stage."
            )
        }
        if let ratio = info.geometry.pixelAspectRatio,
           ratio.horizontalSpacing != ratio.verticalSpacing {
            limitations.append("Non-square pixels reduce method availability.")
        }
        if let encodedWidth = info.geometry.encodedSize?.width,
           encodedWidth > 1_920 {
            limitations.append(
                "Apple’s quality super-resolution video initializer is "
                    + "limited to 1920-pixel source width."
            )
        }
        return limitations.isEmpty ? nil : limitations.joined(separator: " ")
    }
}

enum MirmirBrandLockupLayout {
    case markOnly
    case horizontal
    case vertical
}

struct MirmirBrandLockup: View {
    let layout: MirmirBrandLockupLayout
    let iconSize: CGFloat
    let theme: MirmirThemeTokens
    var showsTagline = false

    var body: some View {
        Group {
            switch layout {
            case .markOnly:
                mark
            case .horizontal:
                HStack(spacing: max(8, iconSize * 0.24)) {
                    mark
                    wordmark
                }
            case .vertical:
                VStack(spacing: max(8, iconSize * 0.12)) {
                    mark
                    wordmark
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            showsTagline
                ? "Mirmir, Deterministic Video Upscaler"
                : "Mirmir"
        )
    }

    private var mark: some View {
        Image("MirmirBrandIcon")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: iconSize * 0.22,
                    style: .continuous
                )
            )
    }

    private var wordmark: some View {
        VStack(
            alignment: layout == .vertical ? .center : .leading,
            spacing: 2
        ) {
            Text("MIRMIR")
                .font(
                    .system(
                        size: layout == .vertical ? 24 : 16,
                        weight: .semibold,
                        design: .default
                    )
                )
                .tracking(layout == .vertical ? 5 : 4)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            if showsTagline {
                Text("Deterministic Video Upscaler")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

struct MirmirMachTimebase: Equatable, Sendable {
    let numerator: UInt32
    let denominator: UInt32

    static let current: Self = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Self(
            numerator: max(info.numer, 1),
            denominator: max(info.denom, 1)
        )
    }()
}

struct MirmirProcessTelemetryCounters: Equatable, Sendable {
    let timestampTicks: UInt64
    let userNanoseconds: UInt64
    let systemNanoseconds: UInt64
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
}

struct MirmirDashboardTelemetrySnapshot: Equatable, Sendable {
    let processCPUPercent: Double?
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let diskReadBytesPerSecond: Double?
    let diskWrittenBytesPerSecond: Double?
    let cumulativeDiskReadBytes: UInt64
    let cumulativeDiskWrittenBytes: UInt64
}

enum MirmirTelemetryCalculator {
    static func snapshot(
        previous: MirmirProcessTelemetryCounters?,
        current: MirmirProcessTelemetryCounters,
        timebase: MirmirMachTimebase
    ) -> MirmirDashboardTelemetrySnapshot {
        guard let previous,
              current.timestampTicks > previous.timestampTicks else {
            return MirmirDashboardTelemetrySnapshot(
                processCPUPercent: nil,
                residentBytes: current.residentBytes,
                physicalFootprintBytes: current.physicalFootprintBytes,
                diskReadBytesPerSecond: nil,
                diskWrittenBytesPerSecond: nil,
                cumulativeDiskReadBytes: current.diskReadBytes,
                cumulativeDiskWrittenBytes: current.diskWrittenBytes
            )
        }

        let tickDelta = current.timestampTicks - previous.timestampTicks
        let elapsedNanoseconds = Double(tickDelta)
            * Double(timebase.numerator)
            / Double(timebase.denominator)
        guard elapsedNanoseconds.isFinite, elapsedNanoseconds > 0 else {
            return snapshot(
                previous: nil,
                current: current,
                timebase: timebase
            )
        }
        let elapsedSeconds = elapsedNanoseconds / 1_000_000_000

        return MirmirDashboardTelemetrySnapshot(
            processCPUPercent: cpuPercent(
                previous: previous,
                current: current,
                elapsedNanoseconds: elapsedNanoseconds
            ),
            residentBytes: current.residentBytes,
            physicalFootprintBytes: current.physicalFootprintBytes,
            diskReadBytesPerSecond: byteRate(
                previous: previous.diskReadBytes,
                current: current.diskReadBytes,
                elapsedSeconds: elapsedSeconds
            ),
            diskWrittenBytesPerSecond: byteRate(
                previous: previous.diskWrittenBytes,
                current: current.diskWrittenBytes,
                elapsedSeconds: elapsedSeconds
            ),
            cumulativeDiskReadBytes: current.diskReadBytes,
            cumulativeDiskWrittenBytes: current.diskWrittenBytes
        )
    }

    private static func cpuPercent(
        previous: MirmirProcessTelemetryCounters,
        current: MirmirProcessTelemetryCounters,
        elapsedNanoseconds: Double
    ) -> Double? {
        guard current.userNanoseconds >= previous.userNanoseconds,
              current.systemNanoseconds >= previous.systemNanoseconds else {
            return nil
        }
        let userDelta = current.userNanoseconds - previous.userNanoseconds
        let systemDelta = current.systemNanoseconds - previous.systemNanoseconds
        let totalDelta = Double(userDelta) + Double(systemDelta)
        let percentage = totalDelta / elapsedNanoseconds * 100
        return percentage.isFinite && percentage >= 0 ? percentage : nil
    }

    private static func byteRate(
        previous: UInt64,
        current: UInt64,
        elapsedSeconds: Double
    ) -> Double? {
        guard current >= previous,
              elapsedSeconds.isFinite,
              elapsedSeconds > 0 else {
            return nil
        }
        let rate = Double(current - previous) / elapsedSeconds
        return rate.isFinite && rate >= 0 ? rate : nil
    }
}

enum MirmirProcessTelemetryError: LocalizedError {
    case resourceUsageUnavailable(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .resourceUsageUnavailable(let code):
            return "Process resource sampling failed with errno \(code): "
                + String(cString: strerror(code))
        }
    }
}

struct MirmirSystemProcessTelemetrySampler: Sendable {
    func sample() throws -> MirmirProcessTelemetryCounters {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else {
            throw MirmirProcessTelemetryError.resourceUsageUnavailable(
                errno: errno
            )
        }

        return MirmirProcessTelemetryCounters(
            timestampTicks: mach_continuous_time(),
            userNanoseconds: usage.ri_user_time,
            systemNanoseconds: usage.ri_system_time,
            residentBytes: usage.ri_resident_size,
            physicalFootprintBytes: usage.ri_phys_footprint,
            diskReadBytes: usage.ri_diskio_bytesread,
            diskWrittenBytes: usage.ri_diskio_byteswritten
        )
    }
}

typealias MirmirTelemetrySampleProvider = @Sendable () throws
    -> MirmirProcessTelemetryCounters

@MainActor
@Observable
final class MirmirDashboardTelemetry {
    private(set) var snapshot: MirmirDashboardTelemetrySnapshot?
    private(set) var errorDescription: String?
    let metalDeviceName: String?

    @ObservationIgnored private let sampleProvider: MirmirTelemetrySampleProvider
    @ObservationIgnored private let timebase: MirmirMachTimebase
    @ObservationIgnored private let diagnosticRecorder: MirmirDiagnosticRecorder
    @ObservationIgnored private var previousCounters:
        MirmirProcessTelemetryCounters?
    @ObservationIgnored private var hasLoggedFailure = false
    @ObservationIgnored private var successfulSampleCount = 0

    init(
        sampleProvider: @escaping MirmirTelemetrySampleProvider = {
            try MirmirSystemProcessTelemetrySampler().sample()
        },
        timebase: MirmirMachTimebase = .current,
        metalDeviceName: String? = MTLCreateSystemDefaultDevice()?.name,
        diagnosticRecorder: MirmirDiagnosticRecorder = .application
    ) {
        self.sampleProvider = sampleProvider
        self.timebase = timebase
        self.metalDeviceName = metalDeviceName
        self.diagnosticRecorder = diagnosticRecorder
    }

    func monitor() async {
        previousCounters = nil
        MirmirLog.telemetry.debug("Dashboard telemetry sampling started")
        refresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                break
            }
            refresh()
        }
        MirmirLog.telemetry.debug("Dashboard telemetry sampling stopped")
    }

    func refresh() {
        do {
            let counters = try sampleProvider()
            snapshot = MirmirTelemetryCalculator.snapshot(
                previous: previousCounters,
                current: counters,
                timebase: timebase
            )
            previousCounters = counters
            errorDescription = nil
            successfulSampleCount += 1
            if successfulSampleCount <= 2
                || successfulSampleCount.isMultiple(of: 30) {
                recordDiagnosticTelemetry(counters: counters)
            }
            if hasLoggedFailure {
                MirmirLog.telemetry.notice("Dashboard telemetry sampling recovered")
                diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "telemetry",
                    operation: "sample_process",
                    code: "process_telemetry_recovered"
                )
                hasLoggedFailure = false
            }
        } catch {
            snapshot = nil
            previousCounters = nil
            errorDescription = "Live process telemetry is unavailable."
            if !hasLoggedFailure {
                MirmirLog.telemetry.error(
                    "Dashboard telemetry sampling failed: \(error.localizedDescription, privacy: .public)"
                )
                diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "telemetry",
                    operation: "sample_process",
                    code: "process_telemetry_unavailable",
                    error: error
                )
                hasLoggedFailure = true
            }
        }
    }

    private func recordDiagnosticTelemetry(
        counters: MirmirProcessTelemetryCounters
    ) {
        do {
            var fields: [MirmirDiagnosticField] = [
                try MirmirDiagnosticRecorder.field(
                    "resident_bytes", .byteCount(counters.residentBytes)
                ),
                try MirmirDiagnosticRecorder.field(
                    "physical_footprint_bytes",
                    .byteCount(counters.physicalFootprintBytes)
                ),
                try MirmirDiagnosticRecorder.field(
                    "cumulative_disk_read_bytes",
                    .byteCount(counters.diskReadBytes)
                ),
                try MirmirDiagnosticRecorder.field(
                    "cumulative_disk_written_bytes",
                    .byteCount(counters.diskWrittenBytes)
                )
            ]
            if let cpu = snapshot?.processCPUPercent,
               cpu.isFinite, cpu >= 0,
               cpu <= Double(Int64.max) / 100 {
                fields.append(try MirmirDiagnosticRecorder.field(
                    "process_cpu_percent_hundredths",
                    .signedInteger(Int64((cpu * 100).rounded()))
                ))
            }
            if let metalDeviceName {
                fields.append(try MirmirDiagnosticRecorder.textField(
                    "metal_device_name", metalDeviceName
                ))
            }
            diagnosticRecorder.enqueue(
                severity: .info,
                subsystem: "telemetry",
                operation: "sample_process",
                code: "process_telemetry_sample",
                fields: fields
            )
        } catch {
            diagnosticRecorder.enqueue(
                severity: .error,
                subsystem: "telemetry",
                operation: "prepare_sample",
                code: "process_telemetry_recording_failed",
                error: error
            )
        }
    }
}

struct MirmirProductPanel<Content: View>: View {
    let theme: MirmirThemeTokens
    let content: Content

    init(
        theme: MirmirThemeTokens,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        content
            .padding(theme.spacing.space4)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.large)
                    .fill(theme.surfaceElevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.large)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
            .shadow(color: theme.shadowAmbient, radius: 10, y: 4)
    }
}

struct MirmirProductPrimaryButtonStyle: ButtonStyle {
    let theme: MirmirThemeTokens
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.typography.bodyEmphasis)
            .foregroundStyle(theme.viewerOverlayText)
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, theme.spacing.space4)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        configuration.isPressed
                            ? theme.accentSecondary
                            : theme.accentPrimary
                    )
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.45)
    }
}

struct MirmirProductSecondaryButtonStyle: ButtonStyle {
    let theme: MirmirThemeTokens
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.typography.bodyEmphasis)
            .foregroundStyle(theme.textPrimary)
            .frame(minHeight: 34)
            .padding(.horizontal, theme.spacing.space3)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        configuration.isPressed
                            ? theme.surfacePressed
                            : theme.surface
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct MirmirProductIconButtonStyle: ButtonStyle {
    let theme: MirmirThemeTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.typography.bodyEmphasis)
            .foregroundStyle(theme.textSecondary)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        configuration.isPressed
                            ? theme.surfacePressed
                            : theme.surfaceElevated
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
    }
}

struct MirmirProductField<Content: View>: View {
    let title: String
    let theme: MirmirThemeTokens
    let content: Content

    init(
        _ title: String,
        theme: MirmirThemeTokens,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            Text(title.uppercased())
                .font(theme.typography.micro)
                .foregroundStyle(theme.textTertiary)
            content
                .font(theme.typography.body)
        }
    }
}

struct MirmirProductStatusCard: View {
    let title: String
    let primary: String
    let secondary: String
    let symbolName: String
    let tone: MirmirProductStatusTone
    let theme: MirmirThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            HStack(spacing: theme.spacing.space2) {
                Image(systemName: symbolName)
                    .foregroundStyle(tone.color(theme: theme))
                Text(title.uppercased())
                    .font(theme.typography.micro)
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            }
            Text(primary)
                .font(theme.typography.bodyEmphasis.monospacedDigit())
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(secondary)
                .font(theme.typography.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
        }
        .padding(theme.spacing.space3)
        .frame(minWidth: 145, maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.large)
                .fill(theme.surfaceElevated)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.large)
                .stroke(tone.borderColor(theme: theme), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MirmirProductMetricCard: View {
    let title: String
    let primary: String
    let secondary: String
    let symbolName: String
    let tone: MirmirProductStatusTone
    let progress: Double?
    let theme: MirmirThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            HStack(spacing: theme.spacing.space2) {
                Image(systemName: symbolName)
                    .foregroundStyle(tone.color(theme: theme))
                Text(title.uppercased())
                    .font(theme.typography.micro)
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            }
            Text(primary)
                .font(theme.typography.subtitle.monospacedDigit())
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(secondary)
                .font(theme.typography.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(tone.color(theme: theme))
                    .accessibilityHidden(true)
            }
        }
        .padding(theme.spacing.space3)
        .frame(
            minWidth: 148,
            maxWidth: .infinity,
            minHeight: 114,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: theme.radius.large)
                .fill(theme.surfaceElevated)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.large)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MirmirProductProgressRow: View {
    let title: String
    let detail: String
    let valueText: String
    let symbolName: String
    let fraction: Double?
    let theme: MirmirThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            HStack(spacing: theme.spacing.space2) {
                Image(systemName: symbolName)
                    .foregroundStyle(theme.accentPrimary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.typography.bodyEmphasis)
                    Text(detail)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: theme.spacing.space3)
                Text(valueText)
                    .font(theme.typography.bodyEmphasis.monospacedDigit())
                    .foregroundStyle(theme.textPrimary)
            }

            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(theme.accentPrimary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum MirmirProductStatusTone: Equatable {
    case neutral
    case active
    case success
    case warning
    case danger

    func color(theme: MirmirThemeTokens) -> Color {
        switch self {
        case .neutral: theme.textTertiary
        case .active: theme.info
        case .success: theme.success
        case .warning: theme.warning
        case .danger: theme.danger
        }
    }

    func borderColor(theme: MirmirThemeTokens) -> Color {
        self == .neutral ? theme.borderSubtle : color(theme: theme)
    }
}
