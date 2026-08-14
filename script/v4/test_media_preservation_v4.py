#!/usr/bin/env python3
"""Focused fail-closed tests for media-preservation v2 evidence."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent


def load_module(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


media = load_module(
    "media_preservation_v4_for_tests",
    SCRIPT_DIRECTORY / "media_preservation_v4.py",
)


def identity(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


class MediaRouteFixture:
    def __init__(self, fixture_id: str = "rich-track-graph") -> None:
        self.fixture_id = fixture_id
        self.runtime_manifest = identity("runtime-manifest")
        self.runtime_provenance = identity("runtime-provenance")
        self.candidate = {
            "runtimeManifestSHA256": self.runtime_manifest,
            "sourceTreeIdentitySHA256": identity("source-tree"),
        }
        self.capture = {
            "evidenceRequestSHA256": identity("request"),
            "evidenceNonceSHA256": identity("nonce"),
            "packagedCandidateIdentity": {
                "applicationArchiveSHA256": identity("archive"),
                "applicationExecutableSHA256": identity("executable"),
            },
        }
        self.stable_id = "ash.media.track.video.00000000.fixture"
        self.input_track = {
            0: {
                "ordinal": 0,
                "stableID": self.stable_id,
                "kind": "video",
                "enabled": True,
            }
        }
        self.output_track = copy.deepcopy(self.input_track)
        self.metadata = identity("asset-metadata")
        self.chapters = identity("chapter-metadata")
        self.output_pixel = {
            "width": 96,
            "height": 72,
            "preEncodeAlphaFrameSHA256": [],
            "repeatPreEncodeAlphaFrameSHA256": [],
        }
        self.observations = {
            "inputTracks": self.input_track,
            "outputTracks": self.output_track,
            "inputTrackObservation": {
                "enabledTrackCount": 1,
                "assetMetadataSHA256": self.metadata,
                "chapterMetadataSHA256": self.chapters,
            },
            "outputTrackObservation": {
                "enabledTrackCount": 1,
                "assetMetadataSHA256": self.metadata,
                "chapterMetadataSHA256": self.chapters,
            },
            "outputPixels": {0: self.output_pixel},
            "outputTiming": {0: {
                "sampleCount": 2,
                "samples": [
                    {"pts": "0"},
                    {"pts": "1/30"},
                ],
            }},
            "outputAttachments": {0: {"alphaAssociation": None}},
        }
        self.preflight = {
            "schemaVersion": media.PREFLIGHT_SCHEMA,
            "preparedBackendType":
                media.EXPECTED_PREPARED_BACKEND_TYPE_BY_FIXTURE[fixture_id],
            "executor": "cpu_fixed_point",
            "requestedBackendID": "mirmirDeterministicCPU",
            "ashPlanSHA256": identity("ash-plan"),
            "runtimeManifestSHA256": self.runtime_manifest,
            "runtimeProvenanceSHA256": self.runtime_provenance,
            "trackPlanSHA256": identity("track-plan"),
            "sourceGraphSHA256": identity("source-graph"),
            "migrationBlueprintSHA256": identity("migration-blueprint"),
            "primaryTrackOrdinal": 0,
            "plannedTracks": [{
                "ordinal": 0,
                "stableID": self.stable_id,
                "kind": "video",
                "action": "process",
            }],
            "targetWidth": 96,
            "targetHeight": 72,
            "sourceVideoTrackCount": 1,
            "sourceAudioTrackCount": 0,
            "plannedEnabledTrackCount": 1,
        }
        self.receipt = {
            "schemaID": media.EXECUTION_RECEIPT_SCHEMA,
            "preparedBackendType": self.preflight["preparedBackendType"],
            "executor": "cpu_fixed_point",
            "requestedBackendID": "mirmirDeterministicCPU",
            "actualBackendID": "mirmirDeterministicCPU",
            "ashPlanSHA256": self.preflight["ashPlanSHA256"],
            "runtimeManifestSHA256": self.runtime_manifest,
            "runtimeProvenanceSHA256": self.runtime_provenance,
            "trackPlanSHA256": self.preflight["trackPlanSHA256"],
            "sourceGraphSHA256": self.preflight["sourceGraphSHA256"],
            "migrationSourceGraphSHA256": self.preflight["sourceGraphSHA256"],
            "migrationPlanSHA256": self.preflight["trackPlanSHA256"],
            "migrationBlueprintSHA256": self.preflight["migrationBlueprintSHA256"],
            "sourceAssetMetadataSHA256": self.metadata,
            "outputAssetMetadataSHA256": self.metadata,
            "sourceChapterMetadataSHA256": self.chapters,
            "outputChapterMetadataSHA256": self.chapters,
            "outputGraphSHA256": identity("output-graph"),
            "semanticVerificationSHA256": identity("semantic-verification"),
            "primaryTrackOrdinal": 0,
            "plannedTracks": copy.deepcopy(self.preflight["plannedTracks"]),
            "migratedTracks": [{
                "stableID": self.stable_id,
                "action": "process",
                "migratedSampleCount": 2,
                "sourceSampleStreamSHA256": None,
                "outputSampleStreamSHA256": None,
            }],
            "targetWidth": 96,
            "targetHeight": 72,
            "encodedWidth": 96,
            "encodedHeight": 72,
            "processedFrameCount": 2,
            "sourceVideoTrackCount": 1,
            "sourceAudioTrackCount": 0,
            "plannedEnabledTrackCount": 1,
            "alphaVerification": None,
        }
        if fixture_id.startswith("combined-alpha-geometry-"):
            association = (
                "straight" if fixture_id.endswith("-straight")
                else "premultiplied"
            )
            alpha_frames = [identity("alpha-frame-0"), identity("alpha-frame-1")]
            self.output_pixel["preEncodeAlphaFrameSHA256"] = alpha_frames
            self.output_pixel["repeatPreEncodeAlphaFrameSHA256"] = copy.deepcopy(
                alpha_frames
            )
            self.observations["outputAttachments"][0][
                "alphaAssociation"
            ] = association
            self.receipt["alphaVerification"] = {
                "schemaID": "ash.alpha-video-writer-verification.v4.1",
                "codec": "proRes4444",
                "association": association,
                "inputLayout": "bgra8",
                "width": 96,
                "height": 72,
                "encodedFormat": {},
                "frames": [
                    {
                        "ordinal": index,
                        "presentationTime": {
                            "numerator": index,
                            "denominator": 30 if index else 1,
                        },
                        "alphaByteCount": 96 * 72,
                        "sourceAlphaSHA256": alpha_sha,
                        "decodedAlphaSHA256": alpha_sha,
                    }
                    for index, alpha_sha in enumerate(alpha_frames)
                ],
            }
        self.route = {
            "schemaVersion": media.ROUTE_SCHEMA,
            "entryPoint":
                "VideoProcessingSession.processWithDeterministicV4ExecutionReceipt",
            "executionProducer": "exact_archived_mirmir_executable",
            "dispatchRequirement":
                "PreparedDeterministicV4RuntimePlanningBackend",
            "planEvidenceBoundary":
                "actual_session_receipt_matched_independent_preflight",
            "evidenceRequestSHA256": self.capture["evidenceRequestSHA256"],
            "evidenceNonceSHA256": self.capture["evidenceNonceSHA256"],
            "applicationArchiveSHA256": self.capture[
                "packagedCandidateIdentity"
            ]["applicationArchiveSHA256"],
            "applicationExecutableSHA256": self.capture[
                "packagedCandidateIdentity"
            ]["applicationExecutableSHA256"],
            "sourceTreeIdentitySHA256": self.candidate[
                "sourceTreeIdentitySHA256"
            ],
            "independentPreflight": copy.deepcopy(self.preflight),
            "repeatIndependentPreflight": copy.deepcopy(self.preflight),
            "executionReceipt": copy.deepcopy(self.receipt),
            "repeatExecutionReceipt": copy.deepcopy(self.receipt),
            "inputEnabledTrackCount": 1,
            "outputEnabledTrackCount": 1,
        }
        self.reseal()

    def reseal(self) -> None:
        for value_key, hash_key in (
            ("independentPreflight", "independentPreflightSHA256"),
            ("repeatIndependentPreflight", "repeatIndependentPreflightSHA256"),
            ("executionReceipt", "executionReceiptSHA256"),
            ("repeatExecutionReceipt", "repeatExecutionReceiptSHA256"),
        ):
            self.route[hash_key] = media.sha256_bytes(
                media.canonical_bytes(self.route[value_key])
            )
        proof = dict(self.route)
        proof.pop("routeProofSHA256", None)
        self.route["routeProofSHA256"] = media.sha256_bytes(
            media.canonical_bytes(proof)
        )

    @property
    def production(self) -> dict[str, object]:
        return {
            "runtimeManifestSHA256": self.runtime_manifest,
            "routeReceipt": self.route,
        }

    def validate(self) -> str:
        return media.validate_production_route(
            self.fixture_id,
            self.production,
            self.candidate,
            self.capture,
            self.observations,
            self.runtime_provenance,
        )


class MediaPreservationV2Tests(unittest.TestCase):
    def testExactOpaqueFixtureRoutePasses(self) -> None:
        fixture = MediaRouteFixture()
        self.assertEqual(fixture.validate(), fixture.route["routeProofSHA256"])

    def testExactAlphaFixtureRoutePasses(self) -> None:
        fixture = MediaRouteFixture("combined-alpha-geometry-straight")
        self.assertEqual(fixture.validate(), fixture.route["routeProofSHA256"])

    def mutate_backend(self, fixture: MediaRouteFixture, value: str) -> None:
        for key in ("independentPreflight", "repeatIndependentPreflight"):
            fixture.route[key]["preparedBackendType"] = value
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["preparedBackendType"] = value
        fixture.reseal()

    def testNearMatchPreparedBackendFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        self.mutate_backend(fixture, "Mirmir.FakePreparedDeterministicV4Upscaler")
        with self.assertRaisesRegex(media.EvidenceError, "locked fixture route"):
            fixture.validate()

    def testRealButWrongOpaqueBackendFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        self.mutate_backend(
            fixture, "Mirmir.PreparedDeterministicAlphaPlanningBackendV4"
        )
        with self.assertRaisesRegex(media.EvidenceError, "locked fixture route"):
            fixture.validate()

    def testRealButWrongAlphaBackendFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture("combined-alpha-geometry-straight")
        self.mutate_backend(fixture, "Mirmir.PreparedDeterministicV4Upscaler")
        with self.assertRaisesRegex(media.EvidenceError, "locked fixture route"):
            fixture.validate()

    def testReceiptRuntimeMismatchFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["runtimeManifestSHA256"] = identity("forged-runtime")
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "independent preflight"):
            fixture.validate()

    def testMigratedStableIDForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["migratedTracks"][0]["stableID"] = "forged.track"
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "stable-ID/action order"):
            fixture.validate()

    def testMigratedActionForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            row = fixture.route[key]["migratedTracks"][0]
            row["action"] = "pass_through"
            row["sourceSampleStreamSHA256"] = identity("source")
            row["outputSampleStreamSHA256"] = identity("source")
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "stable-ID/action order"):
            fixture.validate()

    def testRepeatOnlyReceiptForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        fixture.route["repeatExecutionReceipt"]["outputGraphSHA256"] = identity(
            "repeat-only-forgery"
        )
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "not repeatable"):
            fixture.validate()

    def testAlphaAssociationForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture("combined-alpha-geometry-straight")
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["alphaVerification"]["association"] = (
                "premultiplied"
            )
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "alpha verification header"):
            fixture.validate()

    def testAlphaByteCountForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture("combined-alpha-geometry-straight")
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["alphaVerification"]["frames"][0][
                "alphaByteCount"
            ] += 1
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "alpha byte count differs"):
            fixture.validate()

    def testAlphaOrdinalForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture("combined-alpha-geometry-straight")
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["alphaVerification"]["frames"][0]["ordinal"] = 1
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "alpha frame ordinal differs"):
            fixture.validate()

    def testAlphaPresentationForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture("combined-alpha-geometry-straight")
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["alphaVerification"]["frames"][0][
                "presentationTime"
            ] = {"numerator": 1, "denominator": 1}
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "alpha presentation time differs"):
            fixture.validate()

    def testRuntimeProvenanceForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        forged = identity("forged-provenance")
        for key in ("independentPreflight", "repeatIndependentPreflight"):
            fixture.route[key]["runtimeProvenanceSHA256"] = forged
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["runtimeProvenanceSHA256"] = forged
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "runtime binding"):
            fixture.validate()

    def testArchiveBindingForgeryFailsAfterRouteIsRehashed(self) -> None:
        fixture = MediaRouteFixture()
        fixture.route["applicationArchiveSHA256"] = identity("other-archive")
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "route binding differs"):
            fixture.validate()

    def testIndependentScalarAlphaOracleLockedGolden(self) -> None:
        actual = media.independent_alpha_oracle(
            bytes([0, 64, 128, 255]), 2, 2, 4, 4
        )
        self.assertEqual(actual.hex(), "20205252202052527e7ecfcf7e7ecfcf")

    def testIndependentScalarAlphaOracleOnePixelReflectsExactly(self) -> None:
        self.assertEqual(
            media.independent_alpha_oracle(bytes([17]), 1, 1, 3, 2),
            bytes([17]) * 6,
        )


if __name__ == "__main__":
    unittest.main()
