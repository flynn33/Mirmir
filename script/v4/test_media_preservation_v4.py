#!/usr/bin/env python3
"""Focused fail-closed tests for media-preservation v2 evidence."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
from fractions import Fraction
from pathlib import Path
import tempfile
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


def p010_bytes(frames: list[dict[str, list[int]]]) -> bytes:
    result = bytearray()
    for frame in frames:
        for plane in ("luma", "chroma"):
            for code in frame[plane]:
                result.extend(int(code << 6).to_bytes(2, "little"))
    return bytes(result)


def p010_track(width: int, height: int, frame_count: int) -> dict[str, object]:
    return {
        "pixelFormat": "x420",
        "bitDepth": 10,
        "width": width,
        "height": height,
        "frameCount": frame_count,
    }


def constant_p010_frame(
    width: int,
    height: int,
    top_luma: int,
    bottom_luma: int | None = None,
) -> dict[str, list[int]]:
    if bottom_luma is None:
        bottom_luma = top_luma
    luma = [
        top_luma if y & 1 == 0 else bottom_luma
        for y in range(height)
        for _ in range(width)
    ]
    chroma = [
        (320 if y & 1 == 0 else 704) if x & 1 == 0
        else (448 if y & 1 == 0 else 576)
        for y in range(height // 2)
        for x in range(width)
    ]
    return {"luma": luma, "chroma": chroma}


def hdr_attachment(transfer: str, dynamic: list[dict[str, object]] | None = None) -> dict[str, object]:
    return {
        "colorPrimaries": "ITU_R_2020",
        "transferFunction": transfer,
        "yCbCrMatrix": "ITU_R_2020",
        "masteringDisplaySHA256": identity("mastering"),
        "contentLightSHA256": identity("content-light"),
        "ambientViewingEnvironmentSHA256": identity("ambient"),
        "dynamicHDRSamples": [] if dynamic is None else dynamic,
    }


class MediaRouteFixture:
    def __init__(self, fixture_id: str = "rich-track-graph", *,
                 with_audio: bool = False) -> None:
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
            "inputTiming": {0: {
                "sampleCount": 2,
                "samples": [
                    {"pts": "0", "duration": "1/30"},
                    {"pts": "1/30", "duration": "1/30"},
                ],
            }},
            "outputTiming": {0: {
                "sampleCount": 2,
                "samples": [
                    {"pts": "0", "duration": "1/30"},
                    {"pts": "1/30", "duration": "1/30"},
                ],
            }},
            "inputAttachments": {0: {
                "alphaAssociation": None,
                "dynamicHDRSamples": [],
            }},
            "outputAttachments": {0: {
                "alphaAssociation": None,
                "dynamicHDRSamples": [],
            }},
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
                "sourceSampleStreamSHA256": identity("processed-stream"),
                "outputSampleStreamSHA256": identity("processed-stream"),
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
            "hdr10PlusPreservation":
                media.expected_hdr10plus_preservation_report(
                    self.observations["inputTiming"][0]["samples"],
                    self.observations["outputTiming"][0]["samples"],
                    self.observations["inputAttachments"][0],
                    self.observations["outputAttachments"][0],
                    fixture_id,
                    self.preflight["trackPlanSHA256"],
                ),
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
        if with_audio:
            audio_id = "ash.media.track.audio.00000001.fixture"
            audio_track = {"ordinal": 1, "stableID": audio_id,
                           "kind": "audio", "enabled": True}
            self.input_track[1] = audio_track
            self.output_track[1] = copy.deepcopy(audio_track)
            for side in ("input", "output"):
                self.observations[side + "TrackObservation"]["enabledTrackCount"] = 2
                self.observations[side + "Timing"][1] = copy.deepcopy(
                    self.observations[side + "Timing"][0]
                )
                self.observations[side + "Attachments"][1] = {
                    "alphaAssociation": None, "dynamicHDRSamples": []
                }
            audio_row = {"ordinal": 1, "stableID": audio_id,
                         "kind": "audio", "action": "pass_through"}
            for document in (self.preflight, self.receipt):
                document["sourceAudioTrackCount"] = 1
                document["plannedEnabledTrackCount"] = 2
                document["plannedTracks"].append(copy.deepcopy(audio_row))
            self.receipt["migratedTracks"].append({
                "stableID": audio_id, "action": "pass_through",
                "migratedSampleCount": 2,
                "sourceSampleStreamSHA256": identity("audio-stream"),
                "outputSampleStreamSHA256": identity("audio-stream"),
            })

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
            "inputEnabledTrackCount": self.observations[
                "inputTrackObservation"]["enabledTrackCount"],
            "outputEnabledTrackCount": self.observations[
                "outputTrackObservation"]["enabledTrackCount"],
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
    def testCheckedInContractPinsEveryNormativeMediaTool(self) -> None:
        repository = SCRIPT_DIRECTORY.parent.parent
        contract_path = SCRIPT_DIRECTORY / "media-preservation-contract-v1.json"
        contract, contract_sha256 = media.load_contract(contract_path)
        self.assertEqual(
            contract_sha256,
            media.sha256_file(contract_path),
        )
        expected_capture = {
            "buildConfiguration": "Release",
            "captureSourceSHA256": media.sha256_file(
                repository / "script/v4/MediaPreservationCaptureTests.swift"
            ),
            "evaluatorSHA256": media.sha256_file(
                repository / "script/v4/media_preservation_v4.py"
            ),
            "fixtureSourceSHA256": media.sha256_file(
                repository
                / "MirmirTests/AVFoundationTrackMigrationExecutorV4Tests.swift"
            ),
            "observerSourceSHA256": media.sha256_file(
                repository / "Mirmir/App/MirmirApp.swift"
            ),
            "packagedEvidenceToolSHA256": media.sha256_file(
                repository / "script/v4/packaged_candidate_evidence_v4.py"
            ),
            "releaseCandidateArchiveToolSHA256": media.sha256_file(
                repository / "script/v4/release_candidate_archive_v4.py"
            ),
            "runnerSHA256": media.sha256_file(
                repository / "script/v4/run_media_preservation_v4.sh"
            ),
        }
        self.assertEqual(set(contract["capture"]), set(expected_capture))
        for key, expected in expected_capture.items():
            with self.subTest(key=key):
                self.assertEqual(contract["capture"][key], expected)

    def boundedHDRRouteFixture(self) -> MediaRouteFixture:
        fixture = MediaRouteFixture()
        dynamic = [
            {
                "pts": "0",
                "hdr10PlusSHA256": identity("bounded-hdr-0"),
                "postDecodeSHA256": None,
            },
            {
                "pts": "1/30",
                "hdr10PlusSHA256": identity("bounded-hdr-1"),
                "postDecodeSHA256": None,
            },
        ]
        fixture.observations["inputAttachments"][0][
            "dynamicHDRSamples"
        ] = copy.deepcopy(dynamic)
        fixture.observations["outputAttachments"][0][
            "dynamicHDRSamples"
        ] = copy.deepcopy(dynamic)
        expected = media.expected_hdr10plus_preservation_report(
            fixture.observations["inputTiming"][0]["samples"],
            fixture.observations["outputTiming"][0]["samples"],
            fixture.observations["inputAttachments"][0],
            fixture.observations["outputAttachments"][0],
            fixture.fixture_id,
            fixture.preflight["trackPlanSHA256"],
        )
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["hdr10PlusPreservation"] = copy.deepcopy(
                expected
            )
        fixture.reseal()
        return fixture

    def testExactOpaqueFixtureRoutePasses(self) -> None:
        fixture = MediaRouteFixture()
        self.assertEqual(fixture.validate(), fixture.route["routeProofSHA256"])

    def testGaplessTranslationCannotAuthorizeLockedAudioTranscode(self) -> None:
        fixture = MediaRouteFixture(with_audio=True)
        self.assertEqual(fixture.validate(), fixture.route["routeProofSHA256"])
        audio = next(row for row in fixture.preflight["plannedTracks"]
                     if row["kind"] == "audio")
        for key in ("independentPreflight", "repeatIndependentPreflight",
                    "executionReceipt", "repeatExecutionReceipt"):
            next(row for row in fixture.route[key]["plannedTracks"]
                 if row["stableID"] == audio["stableID"])["action"] = "transcode"
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            receipt = fixture.route[key]
            receipt["schemaID"] = "ash.deterministic-media-execution-receipt.v4.4"
            next(row for row in receipt["migratedTracks"]
                 if row["stableID"] == audio["stableID"])["action"] = "transcode"
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "planned actions differ"):
            fixture.validate()

    def testLockedLegacyReceiptRejectsGaplessExtensionAndNewSchema(self) -> None:
        variants = [
            (media.EXECUTION_RECEIPT_SCHEMA, True, None),
            (media.EXECUTION_RECEIPT_SCHEMA, True, {}),
            ("ash.deterministic-media-execution-receipt.v4.4", False, None),
        ]
        for schema, has_extension, extension in variants:
            with self.subTest(schema=schema, extension=extension):
                fixture = MediaRouteFixture()
                self.assertEqual(fixture.validate(), fixture.route["routeProofSHA256"])
                for key in ("executionReceipt", "repeatExecutionReceipt"):
                    receipt = fixture.route[key]
                    receipt["schemaID"] = schema
                    if has_extension:
                        receipt["aacGaplessMetadataTranslation"] = extension
                fixture.reseal()
                with self.assertRaises(media.EvidenceError):
                    fixture.validate()

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

    def testHDRParserIdentityForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["hdr10PlusPreservation"]["parserID"] = (
                "ash.hevc-hdr10plus-length-prefixed-parser.v4.0"
            )
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "ledger, or count identity"):
            fixture.validate()

    def testHDRRewriterIdentityForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["hdr10PlusPreservation"]["rewriterID"] = (
                "ash.hevc-hdr10plus-prefix-sei-rewriter.v4.0"
            )
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "ledger, or count identity"):
            fixture.validate()

    def testHDRRouteIdentityForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["hdr10PlusPreservation"]["routeID"] = (
                media.HDR10PLUS_BOUNDED_SEGMENT_ROUTE
            )
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "ledger, or count identity"):
            fixture.validate()

    def testHDRLedgerForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["hdr10PlusPreservation"][
                "outputLedgerSHA256"
            ] = identity("forged-output-ledger")
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "ledger, or count identity"):
            fixture.validate()

    def testHDRTimelineMappingForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["hdr10PlusPreservation"][
                "timelineMappingSHA256"
            ] = identity("forged-absent-timeline-mapping")
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "ledger, or count identity"):
            fixture.validate()

    def testHDRRewrittenCountForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["hdr10PlusPreservation"][
                "rewrittenSampleCount"
            ] = 1
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "ledger, or count identity"):
            fixture.validate()

    def testHDRSegmentCountForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["hdr10PlusPreservation"]["segmentCount"] = 2
        fixture.reseal()
        with self.assertRaisesRegex(media.EvidenceError, "ledger, or count identity"):
            fixture.validate()

    def testBoundedHDRRouteCountAndLedgerSubstitutionsFailAfterReseal(self) -> None:
        mutations = (
            ("routeID", media.HDR10PLUS_ABSENT_ONE_PASS_ROUTE),
            ("segmentCount", 2),
            ("rewrittenSampleCount", 1),
            ("sourceLedgerSHA256", identity("bounded-source-forgery")),
            ("outputLedgerSHA256", identity("bounded-output-forgery")),
            ("timelineMappingSHA256", identity("bounded-timeline-forgery")),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                fixture = self.boundedHDRRouteFixture()
                for key in ("executionReceipt", "repeatExecutionReceipt"):
                    fixture.route[key]["hdr10PlusPreservation"][field] = value
                fixture.reseal()
                with self.assertRaisesRegex(
                    media.EvidenceError,
                    "ledger, or count identity",
                ):
                    fixture.validate()

    def testHDRLedgerRecomputationPreservesGapAtSegmentBoundary(self) -> None:
        input_samples = [
            {
                "pts": str(Fraction(index, 30)),
                "duration": "1/30",
            }
            for index in range(60)
        ] + [{"pts": "3", "duration": "1/30"}]
        output_samples = copy.deepcopy(input_samples)
        dynamic = {"dynamicHDRSamples": [
            {
                "pts": "0",
                "hdr10PlusSHA256": identity("hdr-gap-0"),
                "postDecodeSHA256": None,
            },
            {
                "pts": "3",
                "hdr10PlusSHA256": identity("hdr-gap-1"),
                "postDecodeSHA256": None,
            },
        ]}
        report = media.expected_hdr10plus_preservation_report(
            input_samples,
            output_samples,
            dynamic,
            dynamic,
            "gap-boundary",
            identity("gap-boundary-plan"),
        )
        self.assertEqual(report["segmentCount"], 2)
        self.assertEqual(report["rewrittenSampleCount"], 2)

        collapsed = copy.deepcopy(input_samples)
        collapsed[-1]["pts"] = "2"
        collapsed_dynamic = copy.deepcopy(dynamic)
        collapsed_dynamic["dynamicHDRSamples"][-1]["pts"] = "2"
        collapsed_report = media.expected_hdr10plus_preservation_report(
            collapsed,
            copy.deepcopy(collapsed),
            collapsed_dynamic,
            collapsed_dynamic,
            "collapsed-boundary",
            identity("gap-boundary-plan"),
        )
        self.assertNotEqual(
            report["sourceLedgerSHA256"],
            collapsed_report["sourceLedgerSHA256"],
        )

    def testHDRLedgerRecomputationPreservesNonzeroPrimaryTimeline(self) -> None:
        input_samples = [
            {
                "pts": str(Fraction(index, 30)),
                "duration": "1/30",
            }
            for index in range(60)
        ] + [{"pts": "3", "duration": "1/30"}]
        output_samples = copy.deepcopy(input_samples)
        dynamic = {"dynamicHDRSamples": [
            {
                "pts": "0",
                "hdr10PlusSHA256": identity("hdr-nonzero-0"),
                "postDecodeSHA256": None,
            },
            {
                "pts": "3",
                "hdr10PlusSHA256": identity("hdr-nonzero-1"),
                "postDecodeSHA256": None,
            },
        ]}
        preserved = media.expected_hdr10plus_preservation_report(
            input_samples,
            output_samples,
            dynamic,
            dynamic,
            "nonzero-gap-boundary",
            identity("nonzero-gap-boundary-plan"),
            target_timeline_start=Fraction(2),
            topology="leading_empty_then_single_nonempty",
        )
        self.assertEqual(preserved["segmentCount"], 2)
        zero_target = media.expected_hdr10plus_preservation_report(
            input_samples,
            output_samples,
            dynamic,
            dynamic,
            "zero-target-gap-boundary",
            identity("nonzero-gap-boundary-plan"),
            target_timeline_start=Fraction(0),
            topology="single_nonempty",
        )
        self.assertNotEqual(
            preserved["timelineMappingSHA256"],
            zero_target["timelineMappingSHA256"],
        )

        presentation_shifted = copy.deepcopy(output_samples)
        for sample in presentation_shifted:
            sample["pts"] = str(Fraction(sample["pts"]) + 2)
        shifted_dynamic = copy.deepcopy(dynamic)
        for sample in shifted_dynamic["dynamicHDRSamples"]:
            sample["pts"] = str(Fraction(sample["pts"]) + 2)
        with self.assertRaisesRegex(
            media.EvidenceError,
            "not zero-normalized",
        ):
            media.expected_hdr10plus_preservation_report(
                input_samples,
                presentation_shifted,
                dynamic,
                shifted_dynamic,
                "presentation-shifted-forgery",
                identity("nonzero-gap-boundary-plan"),
                target_timeline_start=Fraction(2),
                topology="leading_empty_then_single_nonempty",
            )

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

    def evaluate_p010_artifacts(
        self,
        source_frames: list[dict[str, list[int]]],
        output_frames: list[dict[str, list[int]]],
        source_size: tuple[int, int],
        output_size: tuple[int, int],
        oracle: dict[str, object],
    ) -> dict[str, object]:
        with tempfile.TemporaryDirectory(prefix="mirmir-p010-oracle-test-") as temporary:
            root = Path(temporary)
            source_path = root / "input.bin"
            output_path = root / "output.bin"
            source_path.write_bytes(p010_bytes(source_frames))
            output_bytes = p010_bytes(output_frames)
            output_path.write_bytes(output_bytes)
            input_track = p010_track(*source_size, len(source_frames))
            output_track = p010_track(*output_size, len(output_frames))
            # These hashes model a fully refreshed observation/seal. The
            # absolute oracle deliberately ignores them and recomputes from
            # the artifact bytes and release-locked mathematics.
            output_identity = hashlib.sha256(output_bytes).hexdigest()
            input_identity = hashlib.sha256(source_path.read_bytes()).hexdigest()
            input_track["visibleSHA256"] = input_identity
            input_track["repeatVisibleSHA256"] = input_identity
            output_track["visibleSHA256"] = output_identity
            output_track["repeatVisibleSHA256"] = output_identity
            return media.validate_p010_absolute_oracle(
                "oracle-test",
                oracle,
                input_track,
                output_track,
                {0: input_track},
                {0: output_track},
                0,
                0,
                source_path,
                output_path,
            )

    def testIndependentP010ProgressiveOracleExactGolden(self) -> None:
        source = [constant_p010_frame(4, 4, 384)]
        expected = media.independent_p010_oracle_frames(
            source, 4, 4, 6, 6, "progressive"
        )
        oracle = copy.deepcopy(
            media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
                "auxiliary-picture-track"
            ]
        )
        result = self.evaluate_p010_artifacts(
            source, expected, (4, 4), (6, 6), oracle
        )
        self.assertEqual(result["luma"]["acceptanceScope"], "every_frame")
        self.assertEqual(result["luma"]["maximumAbsoluteCodeError"], 0)
        self.assertEqual(result["chroma"]["maximumAbsoluteCodeError"], 0)

    def testIndependentP010CatmullRomQ14LockedGolden(self) -> None:
        self.assertEqual(
            media.catmull_rom_q14_coefficients(Fraction(1, 3)),
            (-1_213, 12_743, 5_461, -607),
        )
        self.assertEqual(
            media.catmull_rom_q14_plane(
                [64, 128, 256, 512, 768, 900],
                3,
                2,
                5,
                3,
                1,
                "locked-golden",
            ),
            [
                102, 115, 175, 268, 294,
                300, 330, 448, 546, 569,
                498, 546, 721, 824, 845,
            ],
        )

    def testIndependentP010EdgeDirectedFieldGolden(self) -> None:
        samples = [
            100, 200, 850, 900,
            700, 700, 700, 700,
            300, 900, 950, 960,
            800, 800, 800, 800,
        ]
        actual = media.edge_directed_field_plane(
            samples, 4, 4, 1, 0, None, 16, 128, "locked-golden"
        )
        self.assertEqual(actual[5], 575)
        self.assertEqual(actual[6], 900)
        self.assertEqual(actual[:4], samples[:4])
        self.assertEqual(actual[8:12], samples[8:12])

    def testWrongP010PixelsFailAfterObservationHashesAreRefreshed(self) -> None:
        source = [constant_p010_frame(4, 4, 384)]
        wrong = media.independent_p010_oracle_frames(
            source, 4, 4, 6, 6, "progressive"
        )
        wrong[0]["luma"][7] += 512
        oracle = copy.deepcopy(
            media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
                "auxiliary-picture-track"
            ]
        )
        with self.assertRaisesRegex(
            media.EvidenceError, "maximum absolute code error"
        ):
            self.evaluate_p010_artifacts(
                source, wrong, (4, 4), (6, 6), oracle
            )

    def testConstantP010BiasFailsAfterObservationHashesAreRefreshed(self) -> None:
        source = [constant_p010_frame(4, 4, 384)]
        biased = media.independent_p010_oracle_frames(
            source, 4, 4, 6, 6, "progressive"
        )
        biased[0]["luma"] = [code + 5 for code in biased[0]["luma"]]
        oracle = copy.deepcopy(
            media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
                "auxiliary-picture-track"
            ]
        )
        with self.assertRaisesRegex(
            media.EvidenceError, "absolute mean signed code error"
        ):
            self.evaluate_p010_artifacts(
                source, biased, (4, 4), (6, 6), oracle
            )

    def testSingleFrameP010BiasFailsAcrossMultiFrameArtifact(self) -> None:
        source = [constant_p010_frame(4, 4, 384) for _ in range(8)]
        biased = media.independent_p010_oracle_frames(
            source, 4, 4, 6, 6, "progressive"
        )
        biased[5]["luma"] = [code + 5 for code in biased[5]["luma"]]
        oracle = copy.deepcopy(
            media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
                "auxiliary-picture-track"
            ]
        )
        with self.assertRaisesRegex(
            media.EvidenceError,
            "frame 5 absolute mean signed code error",
        ):
            self.evaluate_p010_artifacts(
                source, biased, (4, 4), (6, 6), oracle
            )

    def testP010EdgeShiftFailsAfterObservationHashesAreRefreshed(self) -> None:
        source_width = 64
        source_height = 48
        source = [{
            "luma": [
                300 if x < source_width // 2 else 600
                for _y in range(source_height)
                for x in range(source_width)
            ],
            "chroma": [512] * (source_width * source_height // 2),
        }]
        shifted = media.independent_p010_oracle_frames(
            source, source_width, source_height, 96, 72, "progressive"
        )
        luma = shifted[0]["luma"]
        shifted[0]["luma"] = [
            code
            for y in range(72)
            for code in (
                [luma[y * 96]]
                + luma[y * 96 : (y + 1) * 96 - 1]
            )
        ]
        oracle = copy.deepcopy(
            media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
                "auxiliary-picture-track"
            ]
        )
        with self.assertRaisesRegex(
            media.EvidenceError, "p99 absolute code error"
        ):
            self.evaluate_p010_artifacts(
                source,
                shifted,
                (source_width, source_height),
                (96, 72),
                oracle,
            )

    def testWrongFieldDominanceFailsAfterPixelHashesAreRefreshed(self) -> None:
        source = [constant_p010_frame(4, 4, 192, 768)]
        top_first = media.independent_p010_oracle_frames(
            source, 4, 4, 6, 6, "top_field_first"
        )
        wrong_oracle = copy.deepcopy(
            media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
                "combined-p010-hdr-interlaced"
            ]
        )
        wrong_oracle["dominance"] = "bottom_field_first"
        with self.assertRaisesRegex(
            media.EvidenceError, "maximum absolute code error"
        ):
            self.evaluate_p010_artifacts(
                source, top_first, (4, 4), (6, 6), wrong_oracle
            )

    def testWrongFieldCadenceFailsAfterSemanticHashesAreRefreshed(self) -> None:
        source = {
            "fieldCount": 2,
            "fieldDetail": "temporal_top_first",
            "cadence": "interlaced_tff_2_fields_per_sample",
        }
        target = {
            "fieldCount": 1,
            "fieldDetail": "progressive",
            "cadence": "progressive_double_rate",
        }
        input_samples = [{"pts": "0/1", "duration": "1/30"}]
        output_samples = [
            {"pts": "0/1", "duration": "1/60"},
            {"pts": "1/30", "duration": "1/60"},
        ]
        with self.assertRaisesRegex(media.EvidenceError, "second-field PTS"):
            media.validate_interlaced_cadence(
                "cadence-test",
                "top_field_first",
                source,
                target,
                input_samples,
                output_samples,
            )

    def testWrongFieldDetailFailsAfterSemanticHashesAreRefreshed(self) -> None:
        source = {
            "fieldCount": 2,
            "fieldDetail": "temporal_bottom_first",
            "cadence": "interlaced_bff_2_fields_per_sample",
        }
        target = {
            "fieldCount": 1,
            "fieldDetail": "progressive",
            "cadence": "progressive_double_rate",
        }
        with self.assertRaisesRegex(
            media.EvidenceError, "input field dominance/cadence"
        ):
            media.validate_interlaced_cadence(
                "dominance-test",
                "top_field_first",
                source,
                target,
                [{"pts": "0/1", "duration": "1/30"}],
                [
                    {"pts": "0/1", "duration": "1/60"},
                    {"pts": "1/60", "duration": "1/60"},
                ],
            )

    def testHLGAndPQSwapFailsAfterAttachmentHashesAreRefreshed(self) -> None:
        cases = (
            ("auxiliary-picture-track", "SMPTE_ST_2084_PQ"),
            ("combined-p010-hdr-interlaced", "ITU_R_2100_HLG"),
        )
        for fixture_id, swapped_transfer in cases:
            with self.subTest(fixture_id=fixture_id):
                oracle = media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
                    fixture_id
                ]
                swapped = hdr_attachment(swapped_transfer)
                with self.assertRaisesRegex(
                    media.EvidenceError, "locked HDR transfer"
                ):
                    media.validate_hdr_transfer_profile(
                        fixture_id,
                        oracle,
                        swapped,
                        copy.deepcopy(swapped),
                        [],
                        [],
                    )

    def testHLGStaticMetadataPassesAndDynamicMetadataIsForbidden(self) -> None:
        oracle = media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
            "auxiliary-picture-track"
        ]
        attachment = hdr_attachment("ITU_R_2100_HLG")
        media.validate_hdr_transfer_profile(
            "hlg-test", oracle, attachment, copy.deepcopy(attachment), [], []
        )
        forged = copy.deepcopy(attachment)
        forged["dynamicHDRSamples"] = [{"sampleOrdinal": 0}]
        with self.assertRaisesRegex(media.EvidenceError, "forbidden dynamic HDR"):
            media.validate_hdr_transfer_profile(
                "hlg-test", oracle, forged, copy.deepcopy(forged), [], []
            )

    def testPQDynamicMetadataMustBindToBothFieldTimes(self) -> None:
        oracle = media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
            "combined-p010-hdr-interlaced"
        ]
        source_dynamic = [{
            "sampleOrdinal": 0,
            "pts": "0/1",
            "hdr10PlusSHA256": identity("hdr10-plus"),
            "postDecodeSHA256": None,
        }]
        output_dynamic = [
            {**source_dynamic[0], "sampleOrdinal": 0, "pts": "0/1"},
            {**source_dynamic[0], "sampleOrdinal": 1, "pts": "1/60"},
        ]
        source = hdr_attachment("SMPTE_ST_2084_PQ", source_dynamic)
        target = hdr_attachment("SMPTE_ST_2084_PQ", output_dynamic)
        input_samples = [{"pts": "0/1"}]
        output_samples = [{"pts": "0/1"}, {"pts": "1/60"}]
        media.validate_hdr_transfer_profile(
            "pq-test",
            oracle,
            source,
            target,
            input_samples,
            output_samples,
        )
        forged = copy.deepcopy(target)
        forged["dynamicHDRSamples"][1]["pts"] = "1/30"
        with self.assertRaisesRegex(
            media.EvidenceError, "dynamic HDR field binding differs"
        ):
            media.validate_hdr_transfer_profile(
                "pq-test",
                oracle,
                source,
                forged,
                input_samples,
                output_samples,
            )

    def testPQRejectsUnsupportedOnDiskPostDecodeMetadata(self) -> None:
        oracle = media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
            "combined-p010-hdr-interlaced"
        ]
        source_dynamic = [{
            "sampleOrdinal": 0,
            "pts": "0/1",
            "hdr10PlusSHA256": identity("hdr10-plus"),
            "postDecodeSHA256": identity("unsupported-post-decode"),
        }]
        output_dynamic = [
            {**source_dynamic[0], "sampleOrdinal": 0, "pts": "0/1"},
            {**source_dynamic[0], "sampleOrdinal": 1, "pts": "1/60"},
        ]
        with self.assertRaisesRegex(
            media.EvidenceError,
            "unsupported on-disk post-decode metadata",
        ):
            media.validate_hdr_transfer_profile(
                "pq-test",
                oracle,
                hdr_attachment("SMPTE_ST_2084_PQ", source_dynamic),
                hdr_attachment("SMPTE_ST_2084_PQ", output_dynamic),
                [{"pts": "0/1"}],
                [{"pts": "0/1"}, {"pts": "1/60"}],
            )

    def testPQDynamicMetadataBindsByPresentationTimeNotDecodeOrder(self) -> None:
        oracle = media.LOCKED_P010_ABSOLUTE_ORACLE["fixtures"][
            "combined-p010-hdr-interlaced"
        ]
        input_times = ["0/1", "1/30", "1/15"]
        input_dynamic = [{
            "sampleOrdinal": index,
            "pts": pts,
            "hdr10PlusSHA256": identity(f"hdr10-plus-{index}"),
            "postDecodeSHA256": None,
        } for index, pts in enumerate(input_times)]
        output_times = ["0/1", "1/60", "1/30", "1/20", "1/15", "1/12"]
        output_dynamic = []
        for index, pts in enumerate(output_times):
            output_dynamic.append({
                "sampleOrdinal": index,
                "pts": pts,
                "hdr10PlusSHA256": input_dynamic[index // 2][
                    "hdr10PlusSHA256"
                ],
                "postDecodeSHA256": None,
            })
        source = hdr_attachment("SMPTE_ST_2084_PQ", input_dynamic)
        target = hdr_attachment("SMPTE_ST_2084_PQ", output_dynamic)
        input_samples = [
            {"pts": "0/1"}, {"pts": "1/15"}, {"pts": "1/30"}
        ]
        output_samples = [
            {"pts": "0/1"}, {"pts": "1/30"}, {"pts": "1/60"},
            {"pts": "1/15"}, {"pts": "1/20"}, {"pts": "1/12"},
        ]
        media.validate_hdr_transfer_profile(
            "pq-test",
            oracle,
            source,
            target,
            input_samples,
            output_samples,
        )
        forged = copy.deepcopy(target)
        forged["dynamicHDRSamples"][4]["hdr10PlusSHA256"] = identity(
            "wrong-source-frame"
        )
        with self.assertRaisesRegex(
            media.EvidenceError,
            "dynamic HDR field binding differs",
        ):
            media.validate_hdr_transfer_profile(
                "pq-test",
                oracle,
                source,
                forged,
                input_samples,
                output_samples,
            )

    def testWeakenedP010ThresholdFailsAfterContractIsRehashed(self) -> None:
        weakened = copy.deepcopy(media.LOCKED_P010_ABSOLUTE_ORACLE)
        weakened["fixtures"]["combined-p010-hdr-interlaced"][
            "lumaMaximumP99AbsoluteCodeError"
        ] += 1
        with self.assertRaisesRegex(
            media.EvidenceError, "thresholds or algorithm differ"
        ):
            media.validate_p010_oracle_contract(weakened)


if __name__ == "__main__":
    unittest.main()
