"""Regression tests for the bounded P06 diagnostic and report artifact."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BOUND_ROOT = ROOT.parent / "Mirmir"
ANALYSIS_ROOT = Path(__file__).resolve().parent
EVIDENCE_PATH = ANALYSIS_ROOT / "evidence/p06-current-source-snapshot-final.json"
EVIDENCE_RELATIVE_PATH = EVIDENCE_PATH.relative_to(ROOT).as_posix()
ARTIFACT_PATH = ANALYSIS_ROOT / "artifact.json"
REPORT_PATH = ANALYSIS_ROOT / "report.html"
RECEIPT_PATH = ANALYSIS_ROOT / "report-delivery-receipt.json"


def _load_module(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load module: {path}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


ANALYZER = _load_module(
    "p06_failure_analyzer",
    ANALYSIS_ROOT / "analyze_p06_failures.py",
)
REPORT = _load_module(
    "p06_failure_report",
    ANALYSIS_ROOT / "build_p06_failure_report.py",
)


class FailureAnalysisTests(unittest.TestCase):
    def test_named_sql_contract_is_complete(self) -> None:
        queries = ANALYZER.load_named_queries(
            ANALYSIS_ROOT / "queries/p06_failure_analysis.sql"
        )
        expected = {
            "bootstrap_best_margin",
            "candidate_metric_matrix",
            "chroma_best_margin",
            "chroma_passing_tradeoff",
            "coordinate_response",
            "failure_frequency",
            "failure_set_frequency",
            "headline_summary",
            "pre_evaluation_error_frequency",
            "route_predicate_failure_frequency",
            "state_coordinate6_risk_response",
            "status_frequency",
            "unique_evaluation_metric_matrix",
        }
        self.assertTrue(expected.issubset(queries))
        self.assertTrue(all(query.endswith(";") for query in queries.values()))

    def test_headline_sql_counts_valid_feasible_evaluations(self) -> None:
        queries = ANALYZER.load_named_queries(
            ANALYSIS_ROOT / "queries/p06_failure_analysis.sql"
        )
        connection = ANALYZER._create_connection()
        connection.execute(
            "INSERT INTO attempts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (0, 1, "test", "coordinate", "1", "feasible", 0, 0, 0, None, "a" * 64),
        )
        row = dict(
            zip(
                (
                    "attempt_count",
                    "evaluated_attempt_count",
                    "feasible_attempt_count",
                    "core_nine_attempt_count",
                    "core_nine_evaluated_fraction",
                    "pre_evaluation_stop_count",
                ),
                connection.execute(queries["headline_summary"]).fetchone(),
            )
        )
        connection.close()
        self.assertEqual(row["attempt_count"], 1)
        self.assertEqual(row["evaluated_attempt_count"], 1)
        self.assertEqual(row["feasible_attempt_count"], 1)

    def test_stable_read_rejects_symbolic_leaf(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target.json"
            target.write_text("{}\n", encoding="utf-8")
            leaf = root / "leaf.json"
            leaf.symlink_to(target)
            with self.assertRaisesRegex(ANALYZER.AnalysisError, "symbolic"):
                ANALYZER.stable_read_regular_file(leaf)

    def test_stable_read_returns_exact_regular_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "source.ndjson"
            payload = b'{"sequence":0}\n'
            path.write_bytes(payload)
            reopened, metadata = ANALYZER.stable_read_regular_file(path)
            self.assertEqual(reopened, payload)
            self.assertEqual(metadata.st_size, len(payload))

    def test_input_bundle_and_consumed_policy_bindings_are_required(self) -> None:
        candidate_source_path = "Artifacts/ASH/test/evidence.json"
        candidate_source_hash = "f" * 64
        plan_document = {
            "status": "preregistered_not_executed",
            "data_separation": {"holdout_may_be_opened_in_p06": False},
            "input_bindings": [
                {
                    "id": "metric_performance_tolerances",
                    "path": ANALYZER.TOLERANCE_SOURCE_PATH,
                },
                {
                    "id": "candidate_evidence_policy",
                    "path": ANALYZER.CANDIDATE_EVIDENCE_POLICY_SOURCE_PATH,
                },
            ],
        }
        candidate_policy = {
            "source_evidence": {
                "test": {
                    "path": candidate_source_path,
                    "file_sha256": candidate_source_hash,
                }
            }
        }
        source_payloads = {
            ANALYZER.PLAN_SOURCE_PATH: ANALYZER._canonical_json_bytes(plan_document),
            ANALYZER.TOLERANCE_SOURCE_PATH: b'{"tolerances":1}\n',
            ANALYZER.CANDIDATE_EVIDENCE_POLICY_SOURCE_PATH: (
                ANALYZER._canonical_json_bytes(candidate_policy)
            ),
        }
        records = [
            {
                "id": identifier,
                "path": path,
                "sha256": hashlib.sha256(source_payloads[path]).hexdigest(),
                "size_bytes": len(source_payloads[path]),
            }
            for identifier, path in (
                ("calibration_plan", ANALYZER.PLAN_SOURCE_PATH),
                (
                    "metric_performance_tolerances",
                    ANALYZER.TOLERANCE_SOURCE_PATH,
                ),
                (
                    "candidate_evidence_policy",
                    ANALYZER.CANDIDATE_EVIDENCE_POLICY_SOURCE_PATH,
                ),
            )
        ]
        records.append(
            {
                "id": "candidate_evidence_source_test",
                "path": candidate_source_path,
                "sha256": candidate_source_hash,
                "size_bytes": 1,
            }
        )
        live_verification = {
            "artifact_kind": "live_holdout_preopen_verification",
            "schema_version": "1.0.0",
            "verification_status": "pass",
            "access_status": "unopened",
            "access_count": 0,
            "open_intent_anchor_present": False,
            "pixel_content_included": False,
            "corpus_binding_sha256": "a" * 64,
            "live_anchor_root_identity_sha256": "b" * 64,
            "live_ledger_root_identity_sha256": "c" * 64,
            "live_ledger_sha256": "d" * 64,
            "live_preopen_receipt_sha256": "e" * 64,
            "repository_attestation_sha256": "1" * 64,
            "repository_sealed_copy_sha256": "2" * 64,
            "verification_receipt_sha256": "3" * 64,
        }
        bindings = {
            "records": records,
            "live_holdout_preopen_verification": live_verification,
        }
        bindings["bundle_sha256"] = hashlib.sha256(
            ANALYZER._canonical_json_bytes(
                {
                    "repository_file_bindings": records,
                    "live_holdout_preopen_verification": live_verification,
                }
            )
        ).hexdigest()
        result = ANALYZER.validate_input_bindings_document(bindings, source_payloads)
        self.assertEqual(result["bundle_sha256"], bindings["bundle_sha256"])

        wrong_bundle = copy.deepcopy(bindings)
        wrong_bundle["bundle_sha256"] = "0" * 64
        with self.assertRaisesRegex(ANALYZER.AnalysisError, "bundle hash differs"):
            ANALYZER.validate_input_bindings_document(wrong_bundle, source_payloads)

        drifted_sources = dict(source_payloads)
        drifted_sources[ANALYZER.TOLERANCE_SOURCE_PATH] = b'{"tolerances":2}\n'
        with self.assertRaisesRegex(ANALYZER.AnalysisError, "policy hash differs"):
            ANALYZER.validate_input_bindings_document(bindings, drifted_sources)

        stripped = copy.deepcopy(bindings)
        stripped["records"] = stripped["records"][:-1]
        stripped["bundle_sha256"] = hashlib.sha256(
            ANALYZER._canonical_json_bytes(
                {
                    "repository_file_bindings": stripped["records"],
                    "live_holdout_preopen_verification": live_verification,
                }
            )
        ).hexdigest()
        with self.assertRaisesRegex(ANALYZER.AnalysisError, "record set differs"):
            ANALYZER.validate_input_bindings_document(stripped, source_payloads)

    def test_checked_snapshot_and_report_are_deterministic(self) -> None:
        evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
        unhashed = dict(evidence)
        declared = unhashed.pop("analysis_sha256")
        self.assertEqual(
            declared,
            hashlib.sha256(ANALYZER._canonical_json_bytes(unhashed)).hexdigest(),
        )
        self.assertEqual(evidence["scope"]["cutoff_sequence"], 240)
        self.assertTrue(evidence["validation"]["record_hash_chain_valid"])
        self.assertFalse(evidence["scope"]["holdout_accessed"])
        self.assertFalse(evidence["scope"]["media_payload_accessed"])

        first = REPORT.build_artifact(
            evidence,
            analysis_path=EVIDENCE_RELATIVE_PATH,
        )
        second = REPORT.build_artifact(
            evidence,
            analysis_path=EVIDENCE_RELATIVE_PATH,
        )
        self.assertEqual(first, second)
        self.assertEqual(first["surface"], "report")
        self.assertEqual(first["manifest"]["title"], REPORT.TITLE)
        self.assertEqual(
            first["manifest"]["blocks"][0]["body"],
            f"# {REPORT.TITLE}",
        )
        self.assertEqual(first["snapshot"]["status"], "partial")
        self.assertGreaterEqual(len(first["manifest"]["charts"]), 4)
        self.assertGreaterEqual(len(first["manifest"]["tables"]), 4)
        self.assertEqual(
            len(first["snapshot"]["datasets"]["candidate_metric_matrix"]),
            evidence["validation"]["unique_evaluation_file_count"],
        )
        tradeoff_text = next(
            block["body"]
            for block in first["manifest"]["blocks"]
            if block["id"] == "tradeoff_text"
        )
        self.assertIn("every unique evaluation artifact", tradeoff_text)

        serialized = json.dumps(first, sort_keys=True)
        self.assertNotIn(str(ROOT), serialized)
        source_ids = {source["id"] for source in first["sources"]}
        for chart in first["manifest"]["charts"]:
            self.assertIn(chart["sourceId"], source_ids)
        for table in first["manifest"]["tables"]:
            self.assertIn(table["sourceId"], source_ids)

    def test_snapshot_source_hashes_match_current_bytes(self) -> None:
        evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
        for source in evidence["source_files"]:
            source_root = (
                BOUND_ROOT
                if source["repository_role"] == "bound_run"
                else ROOT
            )
            payload = (source_root / source["path"]).read_bytes()
            self.assertEqual(len(payload), source["size_bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), source["sha256"])

    def test_report_rejects_invalid_or_misattributed_evidence(self) -> None:
        evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
        mutations = (
            ("holdout", lambda item: item["scope"].__setitem__("holdout_accessed", True)),
            (
                "validation",
                lambda item: item["validation"].__setitem__(
                    "record_hash_chain_valid",
                    False,
                ),
            ),
            (
                "feasible",
                lambda item: item["headline"].__setitem__("feasible_attempt_count", 9),
            ),
        )
        for label, mutation in mutations:
            with self.subTest(label=label):
                changed = copy.deepcopy(evidence)
                mutation(changed)
                changed["analysis_sha256"] = ANALYZER._self_hash(changed)
                with self.assertRaises(REPORT.ReportBuildError):
                    REPORT.build_artifact(
                        changed,
                        analysis_path=EVIDENCE_RELATIVE_PATH,
                    )
        with self.assertRaisesRegex(REPORT.ReportBuildError, "source path"):
            REPORT.build_artifact(
                evidence,
                analysis_path="analysis/ash-failure-patterns/evidence/other.json",
            )

    def test_report_cli_source_is_bound_to_the_repository(self) -> None:
        resolved, relative = REPORT.resolve_analysis_source(EVIDENCE_PATH)
        self.assertEqual(resolved, EVIDENCE_PATH.resolve())
        self.assertEqual(relative, EVIDENCE_RELATIVE_PATH)
        with tempfile.TemporaryDirectory() as temporary:
            copied = Path(temporary) / EVIDENCE_PATH.name
            copied.write_bytes(EVIDENCE_PATH.read_bytes())
            with self.assertRaisesRegex(REPORT.ReportBuildError, "source path"):
                REPORT.resolve_analysis_source(copied)

    def test_singleton_sweeps_are_not_labeled_flat(self) -> None:
        evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
        rows = {
            row["coordinate"]: row
            for row in evidence["datasets"]["coordinate_response"]
        }
        singleton = rows["alias_or_ringing_risk_low_unorm15"]
        self.assertEqual(singleton["qualified_sweep_count"], 0)
        self.assertIsNone(singleton["engine_raw_conventional_ci_span_db"])
        self.assertIsNone(singleton["engine_raw_chroma_span_pixels"])

    def test_risk_state_rows_bind_metrics_and_failure_labels(self) -> None:
        evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
        rows = evidence["datasets"]["state_coordinate6_risk_response"]
        self.assertTrue(rows)
        self.assertTrue(
            all("engine_raw_conventional_ci_low_db" in row for row in rows)
        )
        self.assertTrue(all("state_causality_failed" in row for row in rows))

    def test_delivery_receipt_binds_verified_bytes(self) -> None:
        evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
        receipt = json.loads(RECEIPT_PATH.read_text(encoding="utf-8"))
        self.assertTrue(receipt["ok"])
        self.assertEqual(
            receipt["stages"],
            {"validation": "passed", "package": "passed", "verification": "passed"},
        )
        self.assertEqual(receipt["bindings"]["analysis_self_sha256"], evidence["analysis_sha256"])
        for identifier, path in (
            ("analysis", EVIDENCE_PATH),
            ("artifact", ARTIFACT_PATH),
            ("html", REPORT_PATH),
        ):
            binding = receipt["bindings"][identifier]
            payload = path.read_bytes()
            self.assertEqual(binding["size_bytes"], len(payload))
            self.assertEqual(binding["sha256"], hashlib.sha256(payload).hexdigest())

    def test_correlations_are_bounded_at_both_grains(self) -> None:
        evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
        values = evidence["correlations"]["values"]
        self.assertEqual(set(values), {"attempt_weighted", "unique_evaluation"})
        for grain in values.values():
            for correlation in grain.values():
                self.assertGreaterEqual(correlation, -1.0)
                self.assertLessEqual(correlation, 1.0)


if __name__ == "__main__":
    unittest.main()
