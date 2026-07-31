import CoreFoundation
import Foundation

// This raw-value enum has no associated or mutable state. The unchecked
// annotation is required because the conformance is declared outside the
// enum's source file.
extension MirmirAppearanceMode: @unchecked Sendable {}

struct MirmirPreferencesSnapshot: Equatable, Sendable {
    let appearanceMode: MirmirAppearanceMode
    let defaultUpscaleMode: UpscaleMode
    let defaultOutputCodec: OutputCodec
    let enginePreference: UpscaleEnginePreference
    let strategyPreference: UpscaleStrategyPreference
    let temporalConsistencyEnabled: Bool
    let edgeFidelityLevel: MirmirAdjustmentLevel
    let detailRecoveryLevel: MirmirAdjustmentLevel
    let edgePreservationEnabled: Bool
    let compressionCleanupEnabled: Bool
    let textureGrainProtectionEnabled: Bool
    let temporalStabilityEnabled: Bool
    let smoothMotionCadence: SmoothMotionCadence
    let smoothMotionSceneCutSensitivity:
        SmoothMotionSceneCutSensitivity

    init(
        appearanceMode: MirmirAppearanceMode = .system,
        defaultUpscaleMode: UpscaleMode = .deterministic,
        defaultOutputCodec: OutputCodec = .hevc,
        enginePreference: UpscaleEnginePreference = .automatic,
        strategyPreference: UpscaleStrategyPreference = .automatic,
        temporalConsistencyEnabled: Bool = true,
        edgeFidelityLevel: MirmirAdjustmentLevel = .medium,
        detailRecoveryLevel: MirmirAdjustmentLevel = .medium,
        edgePreservationEnabled: Bool = false,
        compressionCleanupEnabled: Bool = false,
        textureGrainProtectionEnabled: Bool = false,
        temporalStabilityEnabled: Bool = false,
        smoothMotionCadence: SmoothMotionCadence = .double,
        smoothMotionSceneCutSensitivity:
            SmoothMotionSceneCutSensitivity = .standard
    ) {
        self.appearanceMode = appearanceMode
        self.defaultUpscaleMode = defaultUpscaleMode
        self.defaultOutputCodec = defaultOutputCodec
        self.enginePreference = enginePreference
        self.strategyPreference = strategyPreference
        self.temporalConsistencyEnabled = temporalConsistencyEnabled
        self.edgeFidelityLevel = edgeFidelityLevel
        self.detailRecoveryLevel = detailRecoveryLevel
        self.edgePreservationEnabled = edgePreservationEnabled
        self.compressionCleanupEnabled = compressionCleanupEnabled
        self.textureGrainProtectionEnabled =
            textureGrainProtectionEnabled
        self.temporalStabilityEnabled = temporalStabilityEnabled
        self.smoothMotionCadence = smoothMotionCadence
        self.smoothMotionSceneCutSensitivity =
            smoothMotionSceneCutSensitivity
    }

    static let `default` = MirmirPreferencesSnapshot()
}

struct MirmirPreferencesKeys: Equatable, Sendable {
    let appearanceMode: String
    let defaultUpscaleMode: String
    let defaultOutputCodec: String
    let enginePreference: String
    let strategyPreference: String
    let temporalConsistencyEnabled: String
    let edgeFidelityLevel: String
    let detailRecoveryLevel: String
    let edgePreservationEnabled: String
    let compressionCleanupEnabled: String
    let textureGrainProtectionEnabled: String
    let temporalStabilityEnabled: String
    let smoothMotionCadence: String
    let smoothMotionSceneCutSensitivity: String

    static let application = namespaced(
        "com.mirmir.preferences.v1"
    )

    static func namespaced(_ namespace: String)
        -> MirmirPreferencesKeys {
        MirmirPreferencesKeys(
            appearanceMode: "\(namespace).appearance-mode",
            defaultUpscaleMode: "\(namespace).default-upscale-mode",
            defaultOutputCodec: "\(namespace).default-output-codec",
            enginePreference: "\(namespace).engine-preference",
            strategyPreference: "\(namespace).strategy-preference",
            temporalConsistencyEnabled:
                "\(namespace).temporal-consistency-enabled",
            edgeFidelityLevel: "\(namespace).edge-fidelity-level",
            detailRecoveryLevel:
                "\(namespace).detail-recovery-level",
            edgePreservationEnabled:
                "\(namespace).edge-preservation-enabled",
            compressionCleanupEnabled:
                "\(namespace).compression-cleanup-enabled",
            textureGrainProtectionEnabled:
                "\(namespace).texture-grain-protection-enabled",
            temporalStabilityEnabled:
                "\(namespace).temporal-stability-enabled",
            smoothMotionCadence:
                "\(namespace).smooth-motion-cadence",
            smoothMotionSceneCutSensitivity:
                "\(namespace).smooth-motion-scene-cut-sensitivity"
        )
    }
}

final class MirmirPreferencesStore: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let keys: MirmirPreferencesKeys

    init(
        defaults: UserDefaults = .standard,
        keys: MirmirPreferencesKeys = .application
    ) {
        self.defaults = defaults
        self.keys = keys
    }

    convenience init?(
        suiteName: String,
        keys: MirmirPreferencesKeys = .application
    ) {
        guard !suiteName.isEmpty,
              let defaults = UserDefaults(suiteName: suiteName) else {
            return nil
        }
        self.init(defaults: defaults, keys: keys)
    }

    func load() -> MirmirPreferencesSnapshot {
        lock.withLock {
            MirmirPreferencesSnapshot(
                appearanceMode: loadRawValue(
                    MirmirAppearanceMode.self,
                    forKey: keys.appearanceMode,
                    fallback: MirmirPreferencesSnapshot.default
                        .appearanceMode
                ),
                defaultUpscaleMode: loadRawValue(
                    UpscaleMode.self,
                    forKey: keys.defaultUpscaleMode,
                    fallback: MirmirPreferencesSnapshot.default
                        .defaultUpscaleMode
                ),
                defaultOutputCodec: loadRawValue(
                    OutputCodec.self,
                    forKey: keys.defaultOutputCodec,
                    fallback: MirmirPreferencesSnapshot.default
                        .defaultOutputCodec
                ),
                enginePreference: loadRawValue(
                    UpscaleEnginePreference.self,
                    forKey: keys.enginePreference,
                    fallback: MirmirPreferencesSnapshot.default
                        .enginePreference
                ),
                strategyPreference: loadRawValue(
                    UpscaleStrategyPreference.self,
                    forKey: keys.strategyPreference,
                    fallback: MirmirPreferencesSnapshot.default
                        .strategyPreference
                ),
                temporalConsistencyEnabled: loadBool(
                    forKey: keys.temporalConsistencyEnabled,
                    fallback: MirmirPreferencesSnapshot.default
                        .temporalConsistencyEnabled
                ),
                edgeFidelityLevel: loadRawValue(
                    MirmirAdjustmentLevel.self,
                    forKey: keys.edgeFidelityLevel,
                    fallback: MirmirPreferencesSnapshot.default
                        .edgeFidelityLevel
                ),
                detailRecoveryLevel: loadRawValue(
                    MirmirAdjustmentLevel.self,
                    forKey: keys.detailRecoveryLevel,
                    fallback: MirmirPreferencesSnapshot.default
                        .detailRecoveryLevel
                ),
                edgePreservationEnabled: loadBool(
                    forKey: keys.edgePreservationEnabled,
                    fallback: MirmirPreferencesSnapshot.default
                        .edgePreservationEnabled
                ),
                compressionCleanupEnabled: loadBool(
                    forKey: keys.compressionCleanupEnabled,
                    fallback: MirmirPreferencesSnapshot.default
                        .compressionCleanupEnabled
                ),
                textureGrainProtectionEnabled: loadBool(
                    forKey: keys.textureGrainProtectionEnabled,
                    fallback: MirmirPreferencesSnapshot.default
                        .textureGrainProtectionEnabled
                ),
                temporalStabilityEnabled: loadBool(
                    forKey: keys.temporalStabilityEnabled,
                    fallback: MirmirPreferencesSnapshot.default
                        .temporalStabilityEnabled
                ),
                smoothMotionCadence: loadRawValue(
                    SmoothMotionCadence.self,
                    forKey: keys.smoothMotionCadence,
                    fallback: MirmirPreferencesSnapshot.default
                        .smoothMotionCadence
                ),
                smoothMotionSceneCutSensitivity: loadRawValue(
                    SmoothMotionSceneCutSensitivity.self,
                    forKey: keys.smoothMotionSceneCutSensitivity,
                    fallback: MirmirPreferencesSnapshot.default
                        .smoothMotionSceneCutSensitivity
                )
            )
        }
    }

    func save(_ snapshot: MirmirPreferencesSnapshot) {
        lock.withLock {
            defaults.set(
                snapshot.appearanceMode.rawValue,
                forKey: keys.appearanceMode
            )
            defaults.set(
                snapshot.defaultUpscaleMode.rawValue,
                forKey: keys.defaultUpscaleMode
            )
            defaults.set(
                snapshot.defaultOutputCodec.rawValue,
                forKey: keys.defaultOutputCodec
            )
            defaults.set(
                snapshot.enginePreference.rawValue,
                forKey: keys.enginePreference
            )
            defaults.set(
                snapshot.strategyPreference.rawValue,
                forKey: keys.strategyPreference
            )
            defaults.set(
                snapshot.temporalConsistencyEnabled,
                forKey: keys.temporalConsistencyEnabled
            )
            defaults.set(
                snapshot.edgeFidelityLevel.rawValue,
                forKey: keys.edgeFidelityLevel
            )
            defaults.set(
                snapshot.detailRecoveryLevel.rawValue,
                forKey: keys.detailRecoveryLevel
            )
            defaults.set(
                snapshot.edgePreservationEnabled,
                forKey: keys.edgePreservationEnabled
            )
            defaults.set(
                snapshot.compressionCleanupEnabled,
                forKey: keys.compressionCleanupEnabled
            )
            defaults.set(
                snapshot.textureGrainProtectionEnabled,
                forKey: keys.textureGrainProtectionEnabled
            )
            defaults.set(
                snapshot.temporalStabilityEnabled,
                forKey: keys.temporalStabilityEnabled
            )
            defaults.set(
                snapshot.smoothMotionCadence.rawValue,
                forKey: keys.smoothMotionCadence
            )
            defaults.set(
                snapshot.smoothMotionSceneCutSensitivity.rawValue,
                forKey: keys.smoothMotionSceneCutSensitivity
            )
        }
    }

    func loadAppearanceMode() -> MirmirAppearanceMode {
        lock.withLock {
            loadRawValue(
                MirmirAppearanceMode.self,
                forKey: keys.appearanceMode,
                fallback: MirmirPreferencesSnapshot.default.appearanceMode
            )
        }
    }

    func saveAppearanceMode(_ value: MirmirAppearanceMode) {
        save(value.rawValue, forKey: keys.appearanceMode)
    }

    func loadDefaultUpscaleMode() -> UpscaleMode {
        lock.withLock {
            loadRawValue(
                UpscaleMode.self,
                forKey: keys.defaultUpscaleMode,
                fallback: MirmirPreferencesSnapshot.default
                    .defaultUpscaleMode
            )
        }
    }

    func saveDefaultUpscaleMode(_ value: UpscaleMode) {
        save(value.rawValue, forKey: keys.defaultUpscaleMode)
    }

    func loadDefaultOutputCodec() -> OutputCodec {
        lock.withLock {
            loadRawValue(
                OutputCodec.self,
                forKey: keys.defaultOutputCodec,
                fallback: MirmirPreferencesSnapshot.default
                    .defaultOutputCodec
            )
        }
    }

    func saveDefaultOutputCodec(_ value: OutputCodec) {
        save(value.rawValue, forKey: keys.defaultOutputCodec)
    }

    func loadEnginePreference() -> UpscaleEnginePreference {
        lock.withLock {
            loadRawValue(
                UpscaleEnginePreference.self,
                forKey: keys.enginePreference,
                fallback: MirmirPreferencesSnapshot.default
                    .enginePreference
            )
        }
    }

    func saveEnginePreference(_ value: UpscaleEnginePreference) {
        save(value.rawValue, forKey: keys.enginePreference)
    }

    func loadStrategyPreference() -> UpscaleStrategyPreference {
        lock.withLock {
            loadRawValue(
                UpscaleStrategyPreference.self,
                forKey: keys.strategyPreference,
                fallback: MirmirPreferencesSnapshot.default
                    .strategyPreference
            )
        }
    }

    func saveStrategyPreference(_ value: UpscaleStrategyPreference) {
        save(value.rawValue, forKey: keys.strategyPreference)
    }

    func loadTemporalConsistencyEnabled() -> Bool {
        lock.withLock {
            loadBool(
                forKey: keys.temporalConsistencyEnabled,
                fallback: MirmirPreferencesSnapshot.default
                    .temporalConsistencyEnabled
            )
        }
    }

    func saveTemporalConsistencyEnabled(_ value: Bool) {
        save(value, forKey: keys.temporalConsistencyEnabled)
    }

    func loadEdgeFidelityLevel() -> MirmirAdjustmentLevel {
        lock.withLock {
            loadRawValue(
                MirmirAdjustmentLevel.self,
                forKey: keys.edgeFidelityLevel,
                fallback: MirmirPreferencesSnapshot.default
                    .edgeFidelityLevel
            )
        }
    }

    func saveEdgeFidelityLevel(_ value: MirmirAdjustmentLevel) {
        save(value.rawValue, forKey: keys.edgeFidelityLevel)
    }

    func loadDetailRecoveryLevel() -> MirmirAdjustmentLevel {
        lock.withLock {
            loadRawValue(
                MirmirAdjustmentLevel.self,
                forKey: keys.detailRecoveryLevel,
                fallback: MirmirPreferencesSnapshot.default
                    .detailRecoveryLevel
            )
        }
    }

    func saveDetailRecoveryLevel(_ value: MirmirAdjustmentLevel) {
        save(value.rawValue, forKey: keys.detailRecoveryLevel)
    }

    func loadEdgePreservationEnabled() -> Bool {
        loadEffectFlag(
            forKey: keys.edgePreservationEnabled,
            fallback: MirmirPreferencesSnapshot.default
                .edgePreservationEnabled
        )
    }

    func saveEdgePreservationEnabled(_ value: Bool) {
        save(value, forKey: keys.edgePreservationEnabled)
    }

    func loadCompressionCleanupEnabled() -> Bool {
        loadEffectFlag(
            forKey: keys.compressionCleanupEnabled,
            fallback: MirmirPreferencesSnapshot.default
                .compressionCleanupEnabled
        )
    }

    func saveCompressionCleanupEnabled(_ value: Bool) {
        save(value, forKey: keys.compressionCleanupEnabled)
    }

    func loadTextureGrainProtectionEnabled() -> Bool {
        loadEffectFlag(
            forKey: keys.textureGrainProtectionEnabled,
            fallback: MirmirPreferencesSnapshot.default
                .textureGrainProtectionEnabled
        )
    }

    func saveTextureGrainProtectionEnabled(_ value: Bool) {
        save(value, forKey: keys.textureGrainProtectionEnabled)
    }

    func loadTemporalStabilityEnabled() -> Bool {
        loadEffectFlag(
            forKey: keys.temporalStabilityEnabled,
            fallback: MirmirPreferencesSnapshot.default
                .temporalStabilityEnabled
        )
    }

    func saveTemporalStabilityEnabled(_ value: Bool) {
        save(value, forKey: keys.temporalStabilityEnabled)
    }

    func loadSmoothMotionCadence() -> SmoothMotionCadence {
        lock.withLock {
            loadRawValue(
                SmoothMotionCadence.self,
                forKey: keys.smoothMotionCadence,
                fallback: MirmirPreferencesSnapshot.default
                    .smoothMotionCadence
            )
        }
    }

    func saveSmoothMotionCadence(_ value: SmoothMotionCadence) {
        save(value.rawValue, forKey: keys.smoothMotionCadence)
    }

    func loadSmoothMotionSceneCutSensitivity()
        -> SmoothMotionSceneCutSensitivity {
        lock.withLock {
            loadRawValue(
                SmoothMotionSceneCutSensitivity.self,
                forKey: keys.smoothMotionSceneCutSensitivity,
                fallback: MirmirPreferencesSnapshot.default
                    .smoothMotionSceneCutSensitivity
            )
        }
    }

    func saveSmoothMotionSceneCutSensitivity(
        _ value: SmoothMotionSceneCutSensitivity
    ) {
        save(
            value.rawValue,
            forKey: keys.smoothMotionSceneCutSensitivity
        )
    }

    private func save(_ value: Any, forKey key: String) {
        lock.withLock {
            defaults.set(value, forKey: key)
        }
    }

    private func loadRawValue<Value>(
        _ type: Value.Type,
        forKey key: String,
        fallback: Value
    ) -> Value where Value: RawRepresentable, Value.RawValue == String {
        guard let rawValue = defaults.object(forKey: key) as? String,
              let value = Value(rawValue: rawValue) else {
            return fallback
        }
        return value
    }

    private func loadBool(
        forKey key: String,
        fallback: Bool
    ) -> Bool {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return fallback
        }
        return number.boolValue
    }

    private func loadEffectFlag(
        forKey key: String,
        fallback: Bool
    ) -> Bool {
        lock.withLock {
            loadBool(forKey: key, fallback: fallback)
        }
    }
}
