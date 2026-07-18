from __future__ import annotations

import hashlib
import json
from pathlib import Path
import unittest


FIXTURE_ROOT = (
    Path(__file__).resolve().parent
    / "fixtures"
    / "p06-v3-i00-observation-20260717"
)
OBSERVATION_SHA256 = (
    "615f7e6f616b97413dd17fbb6b289e37b40e0ca3a3e6cc9cd0d72c1b516fa385"
)
FIXTURE_FILE_BINDINGS = {
    "candidate-lut-runtime-manifest-v2.json": (
        "0189f51dc644c11075525edd68a5940fd348df6278a7cd84dc6150b092a7fde1",
        2403,
    ),
    "candidate-mapping.json": (
        "8413f14da33fa9725d60c1b8ae08bc7a5a6d580f8a1541a3de8379a871eac070",
        4401,
    ),
    "candidate-operator-bank.json": (
        "680abedc7a7ec01ed20674b8b2609c1834107a7158b5da5c8aa3763629ed9e02",
        4831,
    ),
    "locked-compiler-input-v2.json": (
        "04ae8202586e540490650dd14c0cb7b158be93f42cbf80375ebb5886fb50a3a8",
        4445,
    ),
}


def _canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class P06LegacyObservationFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        observation_path = FIXTURE_ROOT / "observation.json"
        cls.observation_bytes = observation_path.read_bytes()
        cls.observation = json.loads(cls.observation_bytes)
        cls.documents = {
            name: json.loads((FIXTURE_ROOT / name).read_bytes())
            for name in FIXTURE_FILE_BINDINGS
        }

    def test_observation_is_canonical_and_self_hashed(self) -> None:
        self.assertEqual(
            self.observation_bytes,
            _canonical_bytes(self.observation) + b"\n",
        )

        unhashed = dict(self.observation)
        declared = unhashed.pop("observation_sha256")
        self.assertEqual(declared, OBSERVATION_SHA256)
        self.assertEqual(_sha256(_canonical_bytes(unhashed)), declared)
        self.assertEqual(
            self.observation["canonicalization"]["hash_scope"],
            "canonical sorted-key compact UTF-8 JSON excluding "
            "/observation_sha256",
        )

    def test_fixture_contains_only_the_bound_non_media_json_files(self) -> None:
        expected_names = sorted([*FIXTURE_FILE_BINDINGS, "observation.json"])
        actual_names = sorted(path.name for path in FIXTURE_ROOT.iterdir())
        self.assertEqual(actual_names, expected_names)
        self.assertTrue(all(path.suffix == ".json" for path in FIXTURE_ROOT.iterdir()))

        declared = {
            row["path"]: (row["sha256"], row["size_bytes"])
            for row in self.observation["fixture_files"]
        }
        self.assertEqual(declared, FIXTURE_FILE_BINDINGS)

        for name, (expected_hash, expected_size) in FIXTURE_FILE_BINDINGS.items():
            relative = Path(name)
            self.assertFalse(relative.is_absolute())
            self.assertEqual(relative.name, name)
            payload = (FIXTURE_ROOT / relative).read_bytes()
            self.assertEqual(len(payload), expected_size)
            self.assertEqual(_sha256(payload), expected_hash)

    def test_candidate_and_compiler_identities_are_cross_bound(self) -> None:
        mapping = self.documents["candidate-mapping.json"]
        operator = self.documents["candidate-operator-bank.json"]
        compiler = self.documents["locked-compiler-input-v2.json"]
        runtime = self.documents["candidate-lut-runtime-manifest-v2.json"]
        active = self.observation["outer_scheduler"]["active_first_candidate"]

        self.assertEqual(mapping["candidate_identity"], operator["candidate_identity"])
        candidate_identity = mapping["candidate_identity"]
        self.assertEqual(
            candidate_identity["candidate_vector_sha256"],
            active["candidate_vector_sha256"],
        )
        self.assertEqual(
            candidate_identity["shared_bank_configuration_sha256"],
            active["shared_bank_configuration_sha256"],
        )

        configuration_ids = {
            mapping["configuration_id"],
            operator["configuration_id"],
            compiler["configuration_id"],
            runtime["configuration_id"],
            active["configuration_id"],
        }
        self.assertEqual(configuration_ids, {"ash-p06-5ef8b175db2a957509037f5a"})

        self.assertEqual(compiler["hash_bindings"], runtime["hash_bindings"])
        self.assertEqual(
            compiler["hash_bindings"]["compiler_inputs_sha256"],
            active["compiler_inputs_sha256"],
        )
        self.assertEqual(
            compiler["hash_bindings"]["mapping_sha256"],
            FIXTURE_FILE_BINDINGS["candidate-mapping.json"][0],
        )
        self.assertEqual(
            compiler["hash_bindings"]["operator_bank_sha256"],
            FIXTURE_FILE_BINDINGS["candidate-operator-bank.json"][0],
        )
        self.assertEqual(
            runtime["compiler_input"],
            {
                "path": "locked-compiler-input-v2.json",
                "sha256": FIXTURE_FILE_BINDINGS[
                    "locked-compiler-input-v2.json"
                ][0],
                "size_bytes": FIXTURE_FILE_BINDINGS[
                    "locked-compiler-input-v2.json"
                ][1],
            },
        )

    def test_snapshot_counts_and_arithmetic_are_exact(self) -> None:
        inner = self.observation["inner_native_search"]
        outer = self.observation["outer_scheduler"]
        resources = self.observation["resource_snapshot"]

        self.assertEqual(inner["completed_scheduled_attempts"], 614)
        self.assertEqual(inner["unique_non_ash_measurements"], 526)
        self.assertEqual(inner["inferred_cache_hits"], 88)
        self.assertEqual(
            inner["completed_scheduled_attempts"]
            - inner["unique_non_ash_measurements"],
            inner["inferred_cache_hits"],
        )
        self.assertEqual(inner["fixed_and_conventional_reference_measurements"], 19)
        self.assertEqual(inner["total_unique_measurements"], 545)
        self.assertEqual(
            inner["unique_non_ash_measurements"]
            + inner["fixed_and_conventional_reference_measurements"],
            inner["total_unique_measurements"],
        )

        self.assertEqual(inner["earliest_terminal_scheduled_attempt_total"], 946)
        self.assertEqual(inner["maximum_terminal_scheduled_attempt_ceiling"], 3403)
        self.assertEqual(inner["earliest_remaining_scheduled_attempts"], 332)
        self.assertEqual(inner["maximum_remaining_scheduled_attempts"], 2789)
        self.assertEqual(
            inner["earliest_terminal_scheduled_attempt_total"]
            - inner["completed_scheduled_attempts"],
            inner["earliest_remaining_scheduled_attempts"],
        )
        self.assertEqual(
            inner["maximum_terminal_scheduled_attempt_ceiling"]
            - inner["completed_scheduled_attempts"],
            inner["maximum_remaining_scheduled_attempts"],
        )

        self.assertEqual(outer["completed_attempts"], 0)
        self.assertEqual(outer["completed_measurements"], 0)
        self.assertEqual(outer["per_complete_sweep_attempts"], 411)
        self.assertEqual(outer["maximum_attempt_ceiling"], 411 * 8)
        self.assertEqual(outer["terminal_attempt_total"], "unknown")
        self.assertEqual(outer["complete_first_outer_candidate_eta"], "unknown")
        self.assertEqual(outer["overall_p06_eta"], "unknown")

        document_counts = resources["content_addressed_document_type_counts"]
        self.assertEqual(
            document_counts,
            {
                "p06_control_objective_summary": 545,
                "p06_control_output_manifest": 545,
            },
        )
        self.assertEqual(
            sum(document_counts.values()),
            resources["content_addressed_document_count"],
        )
        self.assertEqual(resources["content_addressed_document_count"], 1090)
        self.assertTrue(
            all(
                count == inner["total_unique_measurements"]
                for count in document_counts.values()
            )
        )
        self.assertEqual(resources["total_file_count"], 29494)
        self.assertEqual(resources["total_run_root_kib"], 8751540)
        self.assertEqual(resources["native_cache_support_kib"], 982584)
        self.assertEqual(resources["content_addressed_evidence_kib"], 17440)

    def test_rates_timestamps_and_first_missing_rule_are_exact(self) -> None:
        inner = self.observation["inner_native_search"]
        self.assertEqual(
            self.observation["observation_local"],
            "2026-07-17T16:27:04-0500",
        )
        self.assertEqual(
            inner["first_non_ash_completion_utc"],
            "2026-07-17T13:11:23.013897Z",
        )
        self.assertEqual(
            inner["latest_snapshot_completion_utc"],
            "2026-07-17T21:26:52.098983Z",
        )
        self.assertEqual(inner["unique_measurement_rate_per_hour"], 63.57)
        self.assertEqual(inner["scheduled_attempt_rate_per_hour"], 74.23)
        self.assertEqual(inner["last_60_minutes_unique_measurements"], 63)
        self.assertEqual(inner["earliest_inner_remaining_hours"], 4.47)
        self.assertEqual(inner["maximum_inner_remaining_hours"], 37.57)
        self.assertEqual(
            inner["first_unevidenced_scheduled_rule"],
            {
                "active_execution_proven": False,
                "classification": "first_missing_scheduled_rule",
                "coordinate": "bias_descriptor_06_q8_8",
                "coordinate_ordinal": 6,
                "rule_sha256": (
                    "1d2ae1d3fae11fbc287e4994777454a0fd3d114d9c07cc28e160d1e63cad22e0"
                ),
                "scheduled_attempt_ordinal_zero_based": 614,
                "sweep": 4,
                "value": 128,
            },
        )

    def test_snapshot_is_historical_sealed_and_non_authorizing(self) -> None:
        self.assertEqual(
            self.observation["source_checkpoint"],
            {
                "commit": "89778b103da855fab5470618ba8f0329f7ab38d1",
                "worktree_clean": True,
            },
        )
        self.assertEqual(
            self.observation["run_identity"],
            {
                "run_id": "66baf7bc-5954-43f4-ae87-d9340ab21ae0",
                "run_root_name": (
                    "20260717-p06-v3-705ED5D8-28E7-41BA-9E34-06A8D80B7638"
                ),
            },
        )
        self.assertEqual(
            self.observation["data_access"],
            {
                "fixture_contains_media_payloads": False,
                "holdout_access_count": 0,
                "holdout_accessed": False,
                "holdout_media_open_count": 0,
                "holdout_sealed": True,
                "observer_media_payloads_accessed": False,
            },
        )
        self.assertEqual(
            self.observation["historical_scope"],
            {
                "authorizes_holdout_access": False,
                "authorizes_production_action": False,
                "authorizes_release": False,
                "authorizes_restart": False,
                "authorizes_selection": False,
                "observation_only": True,
                "status": "historical_non_authorizing_observation",
            },
        )
        terminal = self.observation["terminal_publication"]
        self.assertEqual(
            set(terminal),
            {
                "collision_path_present",
                "exact_six_resource_directory_present",
                "failed_or_failure_archive_path_present",
                "immutable_v3_release_bundle_or_manifest_present",
                "quarantine_path_present",
                "terminal_receipt_present",
            },
        )
        self.assertTrue(all(value is False for value in terminal.values()))

        mapping = self.documents["candidate-mapping.json"]
        operator = self.documents["candidate-operator-bank.json"]
        runtime = self.documents["candidate-lut-runtime-manifest-v2.json"]
        self.assertEqual(mapping["status"], "calibration_candidate")
        self.assertEqual(operator["status"], "calibration_candidate")
        self.assertEqual(runtime["status"], "calibration_candidate")
        self.assertFalse(runtime["native_parity_claimed"])
        self.assertEqual(
            mapping["selection_binding"],
            {
                "calibration_selection_sha256": None,
                "selected_evaluation_sha256": None,
            },
        )
        self.assertEqual(operator["selection_binding"], mapping["selection_binding"])


if __name__ == "__main__":
    unittest.main()
