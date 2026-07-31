import Foundation

extension UpscaleEnginePreference {
    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .accelerateVImageHighQuality:
            return "Accelerate vImage High Quality"
        case .mpsBilinear:
            return "Apple MPS Bilinear"
        case .mpsLanczos:
            return "Apple MPS Lanczos"
        }
    }
}

extension UpscaleStrategyPreference {
    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .direct:
            return "Direct"
        case .adaptive:
            return "Adaptive"
        }
    }
}

extension SmoothMotionCadence {
    var title: String {
        switch self {
        case .double:
            return "2× Cadence"
        case .quadruple:
            return "4× Cadence"
        }
    }

    var summary: String {
        switch self {
        case .double:
            return "Emits two output frames for every source frame."
        case .quadruple:
            return "Emits four output frames for every source frame."
        }
    }
}

extension SmoothMotionSceneCutSensitivity {
    var title: String {
        switch self {
        case .low:
            return "Low"
        case .standard:
            return "Standard"
        case .high:
            return "High"
        }
    }

    var summary: String {
        switch self {
        case .low:
            return "Uses holds only for the strongest scene changes."
        case .standard:
            return "Balances cut protection with motion interpolation."
        case .high:
            return "Uses holds for smaller detected scene changes."
        }
    }
}

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
        case .smoothMotion:
            return "Smooth Motion"
        }
    }

    var summary: String {
        switch self {
        case .auto:
            return "Uses ASH content and resource analysis to choose among "
                + "qualified Apple-native engines, with a safe whole-frame "
                + "fallback when a native route is unavailable."
        case .quality:
            return "Prefers quality-oriented VideoToolbox processing, then "
                + "uses qualified high-quality Apple-native fallback paths."
        case .fast:
            return "Prefers low-latency VideoToolbox, MetalFX, and MPS "
                + "processing while retaining a qualified fallback path."
        case .deterministic:
            return "Uses Apple MPS Lanczos with a frozen no-fallback "
                + "processing identity."
        case .smoothMotion:
            return "Upscales with quality-oriented routing, then increases "
                + "cadence with qualified frame interpolation. Scene cuts "
                + "use holds instead of cross-frame synthesis."
        }
    }

    var releasePickerTitle: String {
        title
    }
}

extension MirmirViewModel {
    var engineReadinessText: String {
        switch selectedModeAvailability {
        case .unavailable:
            return "Selected Configuration Unavailable"
        case .available:
            break
        }

        switch state {
        case .running:
            return "Processing with \(engineSelectionText)"
        case .probing:
            return "Reading Source Metadata"
        case .finished:
            return "Completed Output Verified"
        case .failed:
            return "Job Needs Attention"
        case .idle, .ready:
            if sourceProfile == nil {
                return "Engine Available · Choose a Source"
            }
            if canStart {
                return "Ready to Start · \(engineSelectionText)"
            }
            return "Configuration Needs Attention"
        }
    }

    var engineSelectionText: String {
        switch selectedModeAvailability {
        case .available:
            var binding = R13ReleaseModePolicy.binding(
                for: selectedMode,
                enginePreference: enginePreference
            )
            if let sourceProfile {
                binding = binding.resolving(
                    videoFormat: sourceProfile.videoFormat
                )
            }
            if selectedMode == .smoothMotion {
                return "Quality Routing + Smooth Motion"
            }
            switch binding.orchestrationKind {
            case .automatic:
                return "ASH Multi-Engine Routing"
            case .quality:
                return "Quality-Preferred Multi-Engine Routing"
            case .fast:
                return "Low-Latency Multi-Engine Routing"
            case .none:
                break
            }
            switch binding.scalerKind {
            case .highQualityVImage:
                return "Accelerate vImage High Quality"
            case .fastMPSBilinear:
                return "Apple MPS Bilinear"
            case .deterministicMPSLanczos:
                return "Apple MPS Lanczos"
            }
        case .unavailable:
            return "No available release mode"
        }
    }

    var engineAvailabilityReason: String? {
        selectedModeAvailability.unavailableReason
    }

    var selectedModeSummary: String {
        guard enginePreference != .automatic else {
            return selectedMode.summary
        }
        let binding = R13ReleaseModePolicy.binding(
            for: selectedMode,
            enginePreference: enginePreference
        )
        return "\(selectedMode.title) was requested. The explicit "
            + "\(enginePreference.title) engine selection resolves this "
            + "job to \(binding.effectiveMode.title) processing."
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
        case .unknown:
            return "Choose a supported source and target to resolve the "
                + "model requirement for the selected route."
        case .notRequired:
            return "The selected route uses no downloaded model assets."
        case .downloadRequired:
            return "Apple's VideoToolbox quality model is not installed "
                + "for this exact source and target. Download it to enable "
                + "the native quality route; model-free fallback processing "
                + "remains available."
        case .downloading:
            return "macOS is downloading Apple's VideoToolbox quality model "
                + "for this exact source and target."
        case .ready:
            return "Apple's VideoToolbox quality model is installed and "
                + "ready for this exact source and target."
        case .failed(let reason):
            return "\(reason) Model-free fallback processing remains "
                + "available."
        }
    }

    var modelSpecializationText: String {
        switch modelAssetsBinding {
        case .unresolved:
            return "Route specialization unresolved"
        case .notRequired(let routeID):
            return "No model · \(routeID)"
        case .videoToolboxQuality(let binding):
            return "VideoToolbox model · \(binding.subjectID.rawValue)"
        }
    }

    var modelAssetsShowsPreparationControl: Bool {
        modelAssetsBinding.requiresConfigurationModel
    }

    var modelAssetsCanPrepare: Bool {
        guard modelAssetsBinding.requiresConfigurationModel else {
            return false
        }
        switch modelStatus {
        case .downloadRequired, .failed:
            return true
        case .unknown, .notRequired, .downloading, .ready:
            return false
        }
    }

    var modelAssetsPreparationActionTitle: String {
        if case .failed = modelStatus {
            return "Retry Model Download"
        }
        return "Download Model"
    }
}
