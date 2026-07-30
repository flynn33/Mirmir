import Foundation

extension UpscaleMode {
    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .quality:
            return "Quality"
        case .fast:
            return "Fast"
        case .deterministic:
            return "Deterministic"
        }
    }

    var summary: String {
        switch self {
        case .auto:
            return "Visible for clarity, but not available in this release."
        case .quality:
            return Self.releaseScalingSummary
        case .fast:
            return Self.releaseScalingSummary
        case .deterministic:
            return Self.releaseScalingSummary
        }
    }

    private static var releaseScalingSummary: String {
        "Uses Apple MPS Lanczos: the qualified A11 route for canonical "
            + "resolution pairs and a dimension-bound adaptive route for "
            + "other eligible SDR geometry."
    }

    var releasePickerTitle: String {
        self == .auto ? "Auto (Unavailable)" : title
    }
}

extension MirmirViewModel {
    var engineReadinessText: String {
        switch selectedModeAvailability {
        case .available:
            return "Selected Mode Ready"
        case .unavailable:
            return "Selected Mode Unavailable"
        }
    }

    var engineSelectionText: String {
        switch selectedModeAvailability {
        case .available:
            return "Apple MPS Lanczos"
        case .unavailable:
            return "No available release mode"
        }
    }

    var engineAvailabilityReason: String? {
        selectedModeAvailability.unavailableReason
    }

    var selectedModeSummary: String {
        selectedMode.summary
    }

    var modelAssetsStatusText: String {
        switch modelStatus {
        case .unknown:
            return "Model asset status unknown"
        case .notRequired:
            return "No model download required"
        case .downloadRequired:
            return "Model download required"
        case .downloading(let progress):
            return "Model download \(Int((progress * 100).rounded()))%"
        case .ready:
            return "Model assets ready"
        case .failed:
            return "Model assets unavailable"
        }
    }

    var modelAssetsDetailText: String {
        switch modelStatus {
        case .notRequired:
            return "The selected Apple MPS Lanczos mode uses no downloaded model assets."
        case .failed(let reason):
            return reason
        default:
            return modelAssetsStatusText
        }
    }

    var modelSpecializationText: String {
        modelStatus == .notRequired
            ? "Specialization not required"
            : modelAssetsStatusText
    }
}
