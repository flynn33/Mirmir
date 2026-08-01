import Foundation
import XCTest
@testable import Mirmir

final class MirmirPreferencesStoreTests: XCTestCase {
    func testMissingPreferencesLoadCanonicalApplicationDefaults() throws {
        let fixture = try MirmirPreferencesFixture()
        defer { fixture.cleanup() }

        let snapshot = fixture.makeStore().load()

        XCTAssertEqual(snapshot, .default)
        XCTAssertEqual(snapshot.appearanceMode, .system)
        XCTAssertEqual(snapshot.defaultUpscaleMode, .deterministic)
        XCTAssertEqual(snapshot.defaultOutputCodec, .hevc)
        XCTAssertEqual(snapshot.enginePreference, .automatic)
        XCTAssertEqual(snapshot.strategyPreference, .automatic)
        XCTAssertTrue(snapshot.temporalConsistencyEnabled)
        XCTAssertEqual(snapshot.edgeFidelityLevel, .medium)
        XCTAssertEqual(snapshot.detailRecoveryLevel, .medium)
        XCTAssertFalse(snapshot.edgePreservationEnabled)
        XCTAssertFalse(snapshot.compressionCleanupEnabled)
        XCTAssertFalse(snapshot.textureGrainProtectionEnabled)
        XCTAssertFalse(snapshot.temporalStabilityEnabled)
    }

    func testWholeSnapshotRoundTripsAcrossStoreInstances() throws {
        let fixture = try MirmirPreferencesFixture()
        defer { fixture.cleanup() }
        let expected = MirmirPreferencesSnapshot(
            appearanceMode: .midnightNordic,
            defaultUpscaleMode: .fast,
            defaultOutputCodec: .h264,
            enginePreference: .mpsBilinear,
            strategyPreference: .adaptive,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .low,
            edgePreservationEnabled: true,
            compressionCleanupEnabled: true,
            textureGrainProtectionEnabled: true,
            temporalStabilityEnabled: true
        )

        fixture.makeStore().save(expected)
        let reopened = try fixture.makeReopenedStore()

        XCTAssertEqual(reopened.load(), expected)
    }

    func testIndividualSavesRoundTripWithoutResettingOtherFields()
        throws {
        let fixture = try MirmirPreferencesFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()

        store.saveAppearanceMode(.arcticIndigo)
        store.saveDefaultUpscaleMode(.quality)
        store.saveDefaultOutputCodec(.h264)
        store.saveEnginePreference(.accelerateVImageHighQuality)
        store.saveStrategyPreference(.direct)
        store.saveTemporalConsistencyEnabled(false)
        store.saveEdgeFidelityLevel(.low)
        store.saveDetailRecoveryLevel(.high)
        store.saveEdgePreservationEnabled(true)
        store.saveCompressionCleanupEnabled(true)
        store.saveTextureGrainProtectionEnabled(true)
        store.saveTemporalStabilityEnabled(true)

        XCTAssertEqual(store.loadAppearanceMode(), .arcticIndigo)
        XCTAssertEqual(store.loadDefaultUpscaleMode(), .quality)
        XCTAssertEqual(store.loadDefaultOutputCodec(), .h264)
        XCTAssertEqual(
            store.loadEnginePreference(),
            .accelerateVImageHighQuality
        )
        XCTAssertEqual(store.loadStrategyPreference(), .direct)
        XCTAssertFalse(store.loadTemporalConsistencyEnabled())
        XCTAssertEqual(store.loadEdgeFidelityLevel(), .low)
        XCTAssertEqual(store.loadDetailRecoveryLevel(), .high)
        XCTAssertTrue(store.loadEdgePreservationEnabled())
        XCTAssertTrue(store.loadCompressionCleanupEnabled())
        XCTAssertTrue(store.loadTextureGrainProtectionEnabled())
        XCTAssertTrue(store.loadTemporalStabilityEnabled())
        XCTAssertEqual(
            store.load(),
            MirmirPreferencesSnapshot(
                appearanceMode: .arcticIndigo,
                defaultUpscaleMode: .quality,
                defaultOutputCodec: .h264,
                enginePreference: .accelerateVImageHighQuality,
                strategyPreference: .direct,
                temporalConsistencyEnabled: false,
                edgeFidelityLevel: .low,
                detailRecoveryLevel: .high,
                edgePreservationEnabled: true,
                compressionCleanupEnabled: true,
                textureGrainProtectionEnabled: true,
                temporalStabilityEnabled: true
            )
        )
    }

    func testEveryOutputCodecRoundTripsThroughPreferences() throws {
        let fixture = try MirmirPreferencesFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()

        for codec in OutputCodec.allCases {
            store.saveDefaultOutputCodec(codec)

            XCTAssertEqual(
                try fixture.makeReopenedStore()
                    .loadDefaultOutputCodec(),
                codec
            )
            XCTAssertFalse(codec.displayName.isEmpty)
        }
    }

    func testInvalidValuesFallBackPerFieldAndPreserveValidValues()
        throws {
        let fixture = try MirmirPreferencesFixture()
        defer { fixture.cleanup() }
        let valid = MirmirPreferencesSnapshot(
            appearanceMode: .midnightNordic,
            defaultUpscaleMode: .fast,
            defaultOutputCodec: .h264,
            enginePreference: .mpsBilinear,
            strategyPreference: .adaptive,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .low
        )
        let store = fixture.makeStore()
        store.save(valid)

        fixture.defaults.set(
            "unsupported-theme",
            forKey: fixture.keys.appearanceMode
        )
        fixture.defaults.set(
            17,
            forKey: fixture.keys.defaultUpscaleMode
        )
        fixture.defaults.set(
            "unsupported-engine",
            forKey: fixture.keys.enginePreference
        )
        fixture.defaults.set(
            ["unsupported-engine"],
            forKey: fixture.keys.enginePreferences
        )
        fixture.defaults.set(
            "true",
            forKey: fixture.keys.temporalConsistencyEnabled
        )
        fixture.defaults.set(
            "ultra",
            forKey: fixture.keys.detailRecoveryLevel
        )

        let recovered = store.load()

        XCTAssertEqual(recovered.appearanceMode, .system)
        XCTAssertEqual(recovered.defaultUpscaleMode, .deterministic)
        XCTAssertEqual(recovered.defaultOutputCodec, .h264)
        XCTAssertEqual(recovered.enginePreference, .automatic)
        XCTAssertEqual(recovered.strategyPreference, .adaptive)
        XCTAssertTrue(recovered.temporalConsistencyEnabled)
        XCTAssertEqual(recovered.edgeFidelityLevel, .high)
        XCTAssertEqual(recovered.detailRecoveryLevel, .medium)
    }

    func testInjectedSuitesAndKeyNamespacesRemainIsolated()
        throws {
        let first = try MirmirPreferencesFixture(
            keyNamespace: "first"
        )
        let second = try MirmirPreferencesFixture(
            keyNamespace: "first"
        )
        defer {
            first.cleanup()
            second.cleanup()
        }
        let firstValue = MirmirPreferencesSnapshot(
            appearanceMode: .midnightNordic,
            defaultUpscaleMode: .fast,
            defaultOutputCodec: .h264,
            enginePreference: .mpsBilinear,
            strategyPreference: .adaptive,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .low
        )
        first.makeStore().save(firstValue)

        XCTAssertEqual(second.makeStore().load(), .default)

        let alternateKeys = MirmirPreferencesKeys.namespaced("second")
        let alternateStore = MirmirPreferencesStore(
            defaults: first.defaults,
            keys: alternateKeys
        )
        XCTAssertEqual(alternateStore.load(), .default)
        alternateStore.saveDefaultUpscaleMode(.quality)

        XCTAssertEqual(
            first.makeStore().load(),
            firstValue
        )
        XCTAssertEqual(
            alternateStore.loadDefaultUpscaleMode(),
            .quality
        )
    }

    func testSuiteInitializerRejectsAnEmptySuiteName() {
        XCTAssertNil(MirmirPreferencesStore(suiteName: ""))
    }

    @MainActor
    func testViewModelLoadsAndPersistsAppearanceAndJobDefaults()
        throws {
        let fixture = try MirmirPreferencesFixture()
        defer { fixture.cleanup() }
        fixture.makeStore().save(
            MirmirPreferencesSnapshot(
                appearanceMode: .midnightNordic,
                defaultUpscaleMode: .quality,
                defaultOutputCodec: .h264,
                enginePreference: .accelerateVImageHighQuality,
                strategyPreference: .direct,
                temporalConsistencyEnabled: false,
                edgeFidelityLevel: .low,
                detailRecoveryLevel: .high
            )
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService(),
            preferencesStore: fixture.makeStore()
        )

        XCTAssertEqual(viewModel.appearanceMode, .midnightNordic)
        XCTAssertEqual(viewModel.selectedMode, .quality)
        XCTAssertEqual(viewModel.codec, .h264)
        XCTAssertEqual(
            viewModel.enginePreference,
            .accelerateVImageHighQuality
        )
        XCTAssertEqual(viewModel.strategyPreference, .direct)
        XCTAssertFalse(viewModel.temporalConsistencyEnabled)
        XCTAssertEqual(viewModel.edgeFidelityLevel, .low)
        XCTAssertEqual(viewModel.detailRecoveryLevel, .high)
        XCTAssertEqual(
            viewModel.persistedDefaults,
            MirmirPersistedJobDefaults(
                mode: .quality,
                outputCodec: .h264,
                enginePreference: .accelerateVImageHighQuality,
                strategyPreference: .direct,
                temporalConsistencyEnabled: false,
                edgeFidelityLevel: .low,
                detailRecoveryLevel: .high
            )
        )

        XCTAssertTrue(viewModel.selectAppearanceMode(.arcticIndigo))
        XCTAssertTrue(viewModel.selectDefaultMode(.fast))
        XCTAssertTrue(viewModel.selectDefaultOutputCodec(.hevc))
        XCTAssertTrue(
            viewModel.selectDefaultEngine(.mpsBilinear)
        )
        XCTAssertTrue(
            viewModel.selectDefaultStrategy(.adaptive)
        )
        XCTAssertTrue(
            viewModel.setDefaultTemporalConsistency(true)
        )
        XCTAssertTrue(
            viewModel.selectDefaultEdgeFidelity(.high)
        )
        XCTAssertTrue(
            viewModel.selectDefaultDetailRecovery(.medium)
        )

        XCTAssertEqual(
            try fixture.makeReopenedStore().load(),
            MirmirPreferencesSnapshot(
                appearanceMode: .arcticIndigo,
                defaultUpscaleMode: .fast,
                defaultOutputCodec: .hevc,
                enginePreference: .mpsBilinear,
                strategyPreference: .adaptive,
                temporalConsistencyEnabled: true,
                edgeFidelityLevel: .high,
                detailRecoveryLevel: .medium
            )
        )
    }

    @MainActor
    func testPendingJobSelectionsAreOneOffAndDoNotPersistDefaults()
        throws {
        let fixture = try MirmirPreferencesFixture()
        defer { fixture.cleanup() }
        let stored = MirmirPreferencesSnapshot(
            appearanceMode: .system,
            defaultUpscaleMode: .quality,
            defaultOutputCodec: .h264,
            enginePreference: .accelerateVImageHighQuality,
            strategyPreference: .direct,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .low,
            detailRecoveryLevel: .high
        )
        fixture.makeStore().save(stored)
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService(),
            preferencesStore: fixture.makeStore()
        )

        XCTAssertTrue(viewModel.selectModeForPendingJob(.fast))
        XCTAssertTrue(viewModel.selectCodecForPendingJob(.hevc))
        XCTAssertTrue(
            viewModel.selectEngineForPendingJob(.mpsBilinear)
        )
        XCTAssertTrue(
            viewModel.selectStrategyForPendingJob(.adaptive)
        )
        XCTAssertTrue(
            viewModel.setTemporalConsistencyForPendingJob(true)
        )
        XCTAssertTrue(
            viewModel.selectEdgeFidelityForPendingJob(.high)
        )
        XCTAssertTrue(
            viewModel.selectDetailRecoveryForPendingJob(.medium)
        )

        XCTAssertEqual(viewModel.selectedMode, .fast)
        XCTAssertEqual(viewModel.codec, .hevc)
        XCTAssertEqual(viewModel.enginePreference, .mpsBilinear)
        XCTAssertEqual(viewModel.strategyPreference, .adaptive)
        XCTAssertTrue(viewModel.temporalConsistencyEnabled)
        XCTAssertEqual(viewModel.edgeFidelityLevel, .high)
        XCTAssertEqual(viewModel.detailRecoveryLevel, .medium)
        XCTAssertEqual(
            try fixture.makeReopenedStore().load(),
            stored
        )
        XCTAssertEqual(
            viewModel.persistedDefaults,
            MirmirPersistedJobDefaults(preferences: stored)
        )
    }

    @MainActor
    func testDefaultSettingsPersistDuringRunningWithoutChangingActiveJob()
        throws {
        let fixture = try MirmirPreferencesFixture()
        defer { fixture.cleanup() }
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService(),
            preferencesStore: fixture.makeStore()
        )
        viewModel.state = .running

        XCTAssertTrue(viewModel.selectDefaultMode(.fast))
        XCTAssertTrue(viewModel.selectDefaultOutputCodec(.h264))
        XCTAssertTrue(
            viewModel.selectDefaultEngine(.mpsBilinear)
        )
        XCTAssertTrue(
            viewModel.selectDefaultStrategy(.adaptive)
        )
        XCTAssertTrue(
            viewModel.setDefaultTemporalConsistency(false)
        )
        XCTAssertTrue(
            viewModel.selectDefaultEdgeFidelity(.high)
        )
        XCTAssertTrue(
            viewModel.selectDefaultDetailRecovery(.low)
        )

        XCTAssertEqual(viewModel.selectedMode, .deterministic)
        XCTAssertEqual(viewModel.codec, .hevc)
        XCTAssertEqual(viewModel.enginePreference, .automatic)
        XCTAssertEqual(viewModel.strategyPreference, .automatic)
        XCTAssertTrue(viewModel.temporalConsistencyEnabled)
        XCTAssertEqual(viewModel.edgeFidelityLevel, .medium)
        XCTAssertEqual(viewModel.detailRecoveryLevel, .medium)
        XCTAssertFalse(viewModel.selectModeForPendingJob(.quality))
        XCTAssertFalse(viewModel.selectCodecForPendingJob(.h264))
        XCTAssertEqual(
            try fixture.makeReopenedStore().load(),
            MirmirPreferencesSnapshot(
                appearanceMode: .system,
                defaultUpscaleMode: .fast,
                defaultOutputCodec: .h264,
                enginePreference: .mpsBilinear,
                strategyPreference: .adaptive,
                temporalConsistencyEnabled: false,
                edgeFidelityLevel: .high,
                detailRecoveryLevel: .low
            )
        )
    }

    @MainActor
    func testPreSourceDraftSurvivesSourceLoadAndFreshDraftUsesLatestDefaults()
        async throws {
        let fixture = try MirmirPreferencesFixture()
        defer { fixture.cleanup() }
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService(),
            preferencesStore: fixture.makeStore()
        )

        XCTAssertTrue(viewModel.selectDefaultMode(.fast))
        XCTAssertTrue(viewModel.selectDefaultOutputCodec(.hevc))
        XCTAssertTrue(
            viewModel.selectDefaultEngine(.mpsBilinear)
        )
        XCTAssertTrue(
            viewModel.selectDefaultStrategy(.adaptive)
        )
        XCTAssertTrue(
            viewModel.setDefaultTemporalConsistency(false)
        )
        XCTAssertTrue(
            viewModel.selectDefaultEdgeFidelity(.high)
        )
        XCTAssertTrue(
            viewModel.selectDefaultDetailRecovery(.low)
        )
        XCTAssertTrue(viewModel.setDefaultEdgePreservation(true))
        XCTAssertTrue(viewModel.setDefaultCompressionCleanup(true))
        XCTAssertTrue(
            viewModel.setDefaultTextureGrainProtection(true)
        )
        XCTAssertTrue(viewModel.setDefaultTemporalStability(true))
        XCTAssertTrue(
            viewModel.selectDefaultSmoothMotionCadence(.double)
        )
        XCTAssertTrue(
            viewModel.selectDefaultSmoothMotionSceneCutSensitivity(.low)
        )

        XCTAssertTrue(
            viewModel.selectModeForPendingJob(.smoothMotion)
        )
        XCTAssertTrue(viewModel.selectCodecForPendingJob(.h264))
        XCTAssertTrue(
            viewModel.selectEngineForPendingJob(.mpsLanczos)
        )
        XCTAssertTrue(
            viewModel.selectStrategyForPendingJob(.direct)
        )
        XCTAssertTrue(
            viewModel.setTemporalConsistencyForPendingJob(true)
        )
        XCTAssertTrue(
            viewModel.selectEdgeFidelityForPendingJob(.low)
        )
        XCTAssertTrue(
            viewModel.selectDetailRecoveryForPendingJob(.high)
        )
        XCTAssertTrue(
            viewModel.setEdgePreservationForPendingJob(false)
        )
        XCTAssertTrue(
            viewModel.setCompressionCleanupForPendingJob(false)
        )
        XCTAssertTrue(
            viewModel.setTextureGrainProtectionForPendingJob(false)
        )
        XCTAssertTrue(
            viewModel.setTemporalStabilityForPendingJob(false)
        )
        XCTAssertTrue(
            viewModel.selectSmoothMotionCadenceForPendingJob(.quadruple)
        )
        XCTAssertTrue(
            viewModel.selectSmoothMotionSceneCutSensitivityForPendingJob(
                .high
            )
        )

        viewModel.loadSource(
            url: URL(fileURLWithPath: "/tmp/defaults-source.mov")
        )
        for _ in 0..<100 where viewModel.state == .probing {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.selectedMode, .smoothMotion)
        XCTAssertEqual(viewModel.codec, .h264)
        XCTAssertEqual(viewModel.enginePreference, .mpsLanczos)
        XCTAssertEqual(viewModel.strategyPreference, .direct)
        XCTAssertTrue(viewModel.temporalConsistencyEnabled)
        XCTAssertEqual(viewModel.edgeFidelityLevel, .low)
        XCTAssertEqual(viewModel.detailRecoveryLevel, .high)
        XCTAssertFalse(viewModel.edgePreservationEnabled)
        XCTAssertFalse(viewModel.compressionCleanupEnabled)
        XCTAssertFalse(viewModel.textureGrainProtectionEnabled)
        XCTAssertFalse(viewModel.temporalStabilityEnabled)
        XCTAssertEqual(viewModel.smoothMotionCadence, .quadruple)
        XCTAssertEqual(
            viewModel.smoothMotionSceneCutSensitivity,
            .high
        )

        viewModel.upscaleAnotherVideo()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(viewModel.selectedMode, .fast)
        XCTAssertEqual(viewModel.codec, .hevc)
        XCTAssertEqual(viewModel.enginePreference, .mpsBilinear)
        XCTAssertEqual(viewModel.strategyPreference, .adaptive)
        XCTAssertFalse(viewModel.temporalConsistencyEnabled)
        XCTAssertEqual(viewModel.edgeFidelityLevel, .high)
        XCTAssertEqual(viewModel.detailRecoveryLevel, .low)
        XCTAssertTrue(viewModel.edgePreservationEnabled)
        XCTAssertTrue(viewModel.compressionCleanupEnabled)
        XCTAssertTrue(viewModel.textureGrainProtectionEnabled)
        XCTAssertTrue(viewModel.temporalStabilityEnabled)
        XCTAssertEqual(viewModel.smoothMotionCadence, .double)
        XCTAssertEqual(
            viewModel.smoothMotionSceneCutSensitivity,
            .low
        )
    }

    @MainActor
    func testEffectDefaultsPersistAndPendingSelectionsRemainOneOff()
        throws {
        let fixture = try MirmirPreferencesFixture()
        defer { fixture.cleanup() }
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService(),
            preferencesStore: fixture.makeStore()
        )

        XCTAssertTrue(viewModel.setDefaultEdgePreservation(true))
        XCTAssertTrue(viewModel.setDefaultCompressionCleanup(true))
        XCTAssertTrue(
            viewModel.setDefaultTextureGrainProtection(true)
        )
        XCTAssertTrue(viewModel.setDefaultTemporalStability(true))

        XCTAssertFalse(viewModel.edgePreservationEnabled)
        XCTAssertFalse(viewModel.compressionCleanupEnabled)
        XCTAssertFalse(viewModel.textureGrainProtectionEnabled)
        XCTAssertFalse(viewModel.temporalStabilityEnabled)
        XCTAssertEqual(
            try fixture.makeReopenedStore().load(),
            MirmirPreferencesSnapshot(
                edgePreservationEnabled: true,
                compressionCleanupEnabled: true,
                textureGrainProtectionEnabled: true,
                temporalStabilityEnabled: true
            )
        )

        XCTAssertTrue(
            viewModel.setEdgePreservationForPendingJob(false)
        )
        XCTAssertTrue(
            viewModel.setCompressionCleanupForPendingJob(false)
        )
        XCTAssertTrue(
            viewModel.setTextureGrainProtectionForPendingJob(false)
        )
        XCTAssertTrue(
            viewModel.setTemporalStabilityForPendingJob(false)
        )
        XCTAssertEqual(viewModel.currentEffects, .default)
        XCTAssertTrue(
            viewModel.persistedDefaults.effects
                .edgePreservationEnabled
        )
        XCTAssertTrue(
            viewModel.persistedDefaults.effects
                .compressionCleanupEnabled
        )
        XCTAssertTrue(
            viewModel.persistedDefaults.effects
                .textureGrainProtectionEnabled
        )
        XCTAssertTrue(
            viewModel.persistedDefaults.effects
                .temporalStabilityEnabled
        )
    }
}

private final class MirmirPreferencesFixture {
    let defaults: UserDefaults
    let keys: MirmirPreferencesKeys

    private let suiteName: String

    init(keyNamespace: String = "preferences") throws {
        suiteName = "com.mirmir.tests.preferences.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        keys = .namespaced(
            "com.mirmir.tests.\(keyNamespace).\(UUID().uuidString)"
        )
    }

    func makeStore() -> MirmirPreferencesStore {
        MirmirPreferencesStore(defaults: defaults, keys: keys)
    }

    func makeReopenedStore() throws -> MirmirPreferencesStore {
        let reopenedDefaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        return MirmirPreferencesStore(
            defaults: reopenedDefaults,
            keys: keys
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
