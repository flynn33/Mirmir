import Foundation

extension MirmirViewModel {
    func refreshReleaseDiagnostics() {
        guard let provider =
            upscalerEngine as? any R13ReleaseDiagnosticsProviding else {
            return
        }
        releaseDiagnosticsTask?.cancel()
        releaseDiagnosticsTask = Task { [weak self] in
            guard let snapshot =
                await provider.releaseDiagnosticsSnapshot(),
                !Task.isCancelled else {
                return
            }
            let latest = snapshot.records.suffix(8)
            let lines = latest.map { record in
                let fields = record.event.fields.map {
                    "\($0.key.rawValue)=\($0.value)"
                }
                .joined(separator: " ")
                return "#\(record.sequence) "
                    + "\(record.event.code.rawValue) "
                    + "\(record.event.severity.rawValue) "
                    + fields
            }
            self?.releaseDiagnosticsText =
                "\(snapshot.records.count) retained events, "
                + "\(snapshot.retainedByteCount) bytes, "
                + "\(snapshot.droppedRecordCount) dropped"
            self?.releaseDiagnosticLines = lines
        }
    }
}
