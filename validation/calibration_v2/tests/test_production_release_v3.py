from __future__ import annotations

from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.calibration_persistence_v2 import FileBindingV2
from validation.calibration_v2.production_candidate_provider_v2 import (
    SourceGateEvidenceV2,
)
from validation.calibration_v2 import production_release_v3 as production
from validation.calibration_v2 import release_lock
from validation.calibration_v2 import release_orchestrator
from validation.calibration_v2.tests.native_benchmark_fixture import (
    thaw_and_remove_runtime_fixture,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


class ProductionReleaseV3TransactionTests(unittest.TestCase):
    def _gates(self):
        return tuple(
            SourceGateEvidenceV2(
                gate_id,
                FileBindingV2(
                    f"source-gates/{gate_id}.json",
                    str(index + 1) * 64,
                    index + 1,
                ),
            )
            for index, gate_id in enumerate(("G04", "G05", "G06"))
        )

    def test_v3_wrapper_injects_only_custom_publisher_and_exact_gate_handoff(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            calibration = root / "calibration"
            calibration.mkdir()
            repository = root / "repository"
            repository.mkdir()
            paths = {
                name: root / name
                for name in (
                    "release",
                    "native",
                    "open",
                    "evidence",
                    "writer",
                    "dispatch",
                )
            }
            for path in paths.values():
                path.mkdir()
            captured = {}

            def transaction(**arguments):
                captured.update(arguments)
                return {"schema_version": "3.0.1"}

            legacy = mock.Mock(side_effect=AssertionError("legacy publisher called"))
            with mock.patch.object(
                production,
                "build_p06_release_transaction",
                side_effect=transaction,
            ), mock.patch.object(
                release_orchestrator,
                "_publish_release",
                legacy,
            ):
                result = production.build_p06_release_transaction_v3(
                    repository_root=repository,
                    calibration_run_root=calibration,
                    release_root=paths["release"],
                    native_cache_root=paths["native"],
                    open_split_root=paths["open"],
                    evidence_root=paths["evidence"],
                    writer_root=paths["writer"],
                    dispatch_measurement_root=paths["dispatch"],
                    locked_utc="2026-07-16T12:00:00Z",
                    bound_inputs=object(),
                    assembly=object(),
                    run_result=object(),
                    source_gates=self._gates(),
                    provenance=object(),
                )

            self.assertEqual(result, {"schema_version": "3.0.1"})
            self.assertIs(captured["p04_quality_root"], repository)
            self.assertEqual(tuple(captured["test_evidence_paths"]), (
                "G04", "G05", "G06"
            ))
            self.assertEqual(captured["preserved_failure_paths"], {})
            self.assertTrue(callable(captured["_release_publisher"]))
            self.assertIsNot(captured["_release_publisher"], legacy)
            legacy.assert_not_called()

    def test_injected_v3_publisher_closes_over_exact_composition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            for name in (
                "repository", "calibration", "release", "native", "open",
                "evidence", "writer", "dispatch",
            ):
                (root / name).mkdir()
            sentinels = {
                "assembly": object(),
                "run_result": object(),
                "provenance": object(),
            }
            captured = {}

            def transaction(**arguments):
                publisher = arguments["_release_publisher"]
                return publisher(
                    repository_root=root / "repository",
                    calibration_run_root=root / "calibration",
                    release_root=root / "release",
                    native_cache_root=root / "native",
                    open_split_root=root / "open",
                    evidence_root=root / "evidence",
                    writer_root=root / "writer",
                    dispatch_measurement_root=root / "dispatch",
                    p04_quality_root=root / "repository",
                    transaction_id="f" * 32,
                    locked_utc="2026-07-16T12:00:00Z",
                    bound_inputs="bound",
                    test_evidence_paths={},
                    preserved_failure_paths={},
                )

            def v3(**arguments):
                captured.update(arguments)
                return {"publisher": "v3"}

            with mock.patch.object(
                production,
                "build_p06_release_transaction",
                side_effect=transaction,
            ), mock.patch.object(
                production,
                "_publish_release_v3",
                side_effect=v3,
            ):
                result = production.build_p06_release_transaction_v3(
                    repository_root=root / "repository",
                    calibration_run_root=root / "calibration",
                    release_root=root / "release",
                    native_cache_root=root / "native",
                    open_split_root=root / "open",
                    evidence_root=root / "evidence",
                    writer_root=root / "writer",
                    dispatch_measurement_root=root / "dispatch",
                    locked_utc="2026-07-16T12:00:00Z",
                    bound_inputs="bound",
                    assembly=sentinels["assembly"],
                    run_result=sentinels["run_result"],
                    source_gates=self._gates(),
                    provenance=sentinels["provenance"],
                )

            self.assertEqual(result, {"publisher": "v3"})
            for name, value in sentinels.items():
                self.assertIs(captured[name], value)
            self.assertEqual(
                tuple(gate.gate_id for gate in captured["source_gates"]),
                ("G04", "G05", "G06"),
            )

    def test_v3_wrapper_rejects_noncanonical_or_non_utc_timestamp(self) -> None:
        for value in (
            "2026-07-16T12:00:00+01:00",
            "2026-07-16T12:00:00+00:00",
            1,
        ):
            with self.subTest(value=value), self.assertRaises(
                production.ProductionReleaseV3Error
            ), mock.patch.object(
                production,
                "build_p06_release_transaction",
            ) as transaction:
                production.build_p06_release_transaction_v3(
                    repository_root=Path("/tmp/repository"),
                    calibration_run_root=Path("/tmp/calibration"),
                    release_root=Path("/tmp/release"),
                    native_cache_root=Path("/tmp/native"),
                    open_split_root=Path("/tmp/open"),
                    evidence_root=Path("/tmp/evidence"),
                    writer_root=Path("/tmp/writer"),
                    dispatch_measurement_root=Path("/tmp/dispatch"),
                    locked_utc=value,
                    bound_inputs=object(),
                    assembly=object(),
                    run_result=object(),
                    source_gates=self._gates(),
                    provenance=object(),
                )
            transaction.assert_not_called()

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 release sealing requires macOS user-immutable flags",
    )
    def test_real_shell_uses_v3_publisher_then_recovers_without_republication(
        self,
    ) -> None:
        repository = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-v3-real-shell-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            paths = {
                "calibration": root / "support-calibration" / "run",
                "native": root / "support-native" / "cache",
                "open": root / "support-open",
                "evidence": root / "support-evidence" / "evidence",
                "writer": root / "support-writer" / "writer",
                "dispatch": root / "support-dispatch" / "measurement",
            }
            for path in paths.values():
                path.mkdir(parents=True)
                (path / "fixture.bin").write_bytes(b"support fixture\n")
            release = root / "release"
            expected = {
                "schema_version": "3.0.1",
                "locked_utc": "2026-07-16T12:00:00Z",
            }
            bound = mock.Mock()

            def publish(**arguments: object):
                partial = Path(arguments["release_root"])
                (partial / "p06-release-bundle.json").write_bytes(b"{}\n")
                (partial / "v3-payload.bin").write_bytes(b"exact v3 bytes\n")
                return expected

            arguments = {
                "repository_root": repository,
                "calibration_run_root": paths["calibration"],
                "release_root": release,
                "native_cache_root": paths["native"],
                "open_split_root": paths["open"],
                "evidence_root": paths["evidence"],
                "writer_root": paths["writer"],
                "dispatch_measurement_root": paths["dispatch"],
                "locked_utc": expected["locked_utc"],
                "bound_inputs": bound,
                "assembly": object(),
                "run_result": object(),
                "source_gates": self._gates(),
                "provenance": object(),
            }
            try:
                with mock.patch.object(
                    release_orchestrator,
                    "_repository_state",
                    return_value=({"snapshot": "clean"}, True),
                ), mock.patch.object(
                    release_orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=expected,
                ), mock.patch.object(
                    production,
                    "_publish_release_v3",
                    side_effect=publish,
                ) as v3_publisher, mock.patch.object(
                    release_orchestrator,
                    "_publish_release",
                    side_effect=AssertionError("legacy publisher called"),
                ) as legacy_publisher:
                    first = production.build_p06_release_transaction_v3(
                        **arguments
                    )
                    second = production.build_p06_release_transaction_v3(
                        **arguments
                    )

                self.assertEqual(first, expected)
                self.assertEqual(second, expected)
                v3_publisher.assert_called_once()
                legacy_publisher.assert_not_called()
                self.assertTrue((release / "v3-payload.bin").is_file())
                self.assertFalse(
                    (release / release_orchestrator.P06_TRANSACTION_TOKEN_NAME).exists()
                )
            finally:
                for candidate in (
                    release,
                    root / "release.failed",
                    root / ".release.partial",
                    *root.glob(".release.quarantine-*"),
                ):
                    thaw_and_remove_runtime_fixture(candidate)


class SelectedCandidateAuthorityBoundaryTests(unittest.TestCase):
    def _document(self):
        return {
            "status": "calibration_candidate",
            "selection_binding": {
                "calibration_selection_sha256": None,
                "selected_evaluation_sha256": None,
            },
        }

    def test_exact_candidate_bytes_remain_unmodified(self) -> None:
        mapping = self._document()
        operator = self._document()
        before = (canonical_json_bytes(mapping), canonical_json_bytes(operator))

        release_lock._require_unmodified_selected_candidate_authority_v3(
            mapping,
            operator,
        )

        self.assertEqual(
            before,
            (canonical_json_bytes(mapping), canonical_json_bytes(operator)),
        )

    def test_post_selection_status_or_hash_embedding_is_rejected(self) -> None:
        mutations = (
            ("status", "locked_before_p07"),
            (
                "selection_binding",
                {
                    "calibration_selection_sha256": "a" * 64,
                    "selected_evaluation_sha256": "b" * 64,
                },
            ),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                mapping = self._document()
                operator = self._document()
                mapping[field] = value
                operator[field] = value
                with self.assertRaisesRegex(
                    release_lock.ReleaseLockError,
                    "post-selection mutation",
                ):
                    release_lock._require_unmodified_selected_candidate_authority_v3(
                        mapping,
                        operator,
                    )


class LivePreopenAuthorityTests(unittest.TestCase):
    def test_schema_owned_unopened_receipt_requires_no_invented_holdout_field(self) -> None:
        receipt = {
            "verification_status": "pass",
            "access_status": "unopened",
            "access_count": 0,
            "open_intent_anchor_present": False,
            "pixel_content_included": False,
        }
        self.assertIs(
            production._require_live_holdout_preopen_v3(receipt),
            receipt,
        )
        self.assertNotIn("holdout_accessed", receipt)

    def test_accessed_or_open_intent_receipt_is_rejected(self) -> None:
        for field, value in (
            ("access_status", "opened"),
            ("access_count", 1),
            ("open_intent_anchor_present", True),
            ("pixel_content_included", True),
        ):
            with self.subTest(field=field):
                receipt = {
                    "verification_status": "pass",
                    "access_status": "unopened",
                    "access_count": 0,
                    "open_intent_anchor_present": False,
                    "pixel_content_included": False,
                }
                receipt[field] = value
                with self.assertRaises(production.ProductionReleaseV3Error):
                    production._require_live_holdout_preopen_v3(receipt)


if __name__ == "__main__":
    unittest.main()
