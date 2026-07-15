from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator

from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
SCHEMA_ROOT = CALIBRATION_ROOT / "schemas"

SCHEMA_PATHS = {
    "failure": SCHEMA_ROOT / "non-ash-selector-attempt-failure-v2.schema.json",
    "ledger": SCHEMA_ROOT / "non-ash-selector-attempt-ledger-v2.schema.json",
    "selection": SCHEMA_ROOT / "non-ash-selector-selection-v2.schema.json",
    "neighbors": SCHEMA_ROOT / "non-ash-validation-neighbor-manifest-v2.schema.json",
}

SELECTOR_ID = "continuous-linear-bank-selector-q15-v2"
VALUE_ORDER = (-384, -256, -128, 0, 128, 256, 384)
COORDINATE_ORDER = (
    "bias_descriptor_00_q8_8",
    "bias_descriptor_01_q8_8",
    "bias_descriptor_02_q8_8",
    "bias_descriptor_03_q8_8",
    "bias_descriptor_04_q8_8",
    "bias_descriptor_05_q8_8",
    "bias_descriptor_06_q8_8",
    "bias_descriptor_07_q8_8",
    "bias_descriptor_08_q8_8",
    "bias_descriptor_09_q8_8",
    "bias_descriptor_10_q8_8",
    "bias_descriptor_11_q8_8",
    "bias_descriptor_12_q8_8",
    "bias_descriptor_13_q8_8",
    "bias_descriptor_14_q8_8",
    "bias_descriptor_15_q8_8",
    "weight_magnitude_q8_8",
    "weight_coherence_q8_8",
    "weight_texture_q8_8",
    "weight_risk_q8_8",
    "weight_chroma_alignment_q8_8",
    "weight_orientation_cos_q8_8",
    "weight_orientation_sin_q8_8",
    "weight_noise_q8_8",
    "weight_horizontal_phase_q8_8",
    "weight_vertical_phase_q8_8",
    "weight_route_q8_8",
)

AUTHORITY_BINDINGS = {
    "baseline_ablation_budget_v2": {
        "file_sha256": "1885aa30b46f72ed1de0570a3de5f615cf788ec0d494ed5396731279763da4c8",
        "self_sha256": "405d9ca4413e7e291315257682f206d951a081f052d5ecee6f3a36ac72cd22be",
        "schema_file_sha256": "080cc48a86569d68aecb0ca9384c89300df57dbeaa995e0651cf6082c969416b",
    },
    "candidate_evidence_policy_v2": {
        "file_sha256": "2e7d281ca1959d0eafe42aa6bbf57e34cf48d7dde39c4767a1b83f413fb5fb9c",
        "self_sha256": "aa1770aa05761ef22e2bc174c43bcefa23a9743d2ccbfe9c6dc7876229a3798d",
        "schema_file_sha256": "1bbe2402851fe584eb86b589553b9fb2f3ddb3c809a5ef37ba18a5ce34cf2129",
    },
    "calibration_plan_v2": {
        "file_sha256": "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef",
        "self_sha256": "e6070a7cdd8f3b53231635027055669c8319d311af1790d672723d6e7e048d0f",
        "schema_file_sha256": "09a21861104bd1b03667d1207a79d523386ad4431e710ba44e4d298180753c09",
    },
    "shared_bank_configuration_identity_v2": {
        "file_sha256": "48f5eef7cf9f7c513cf8e6568b3eeb4d607845c1e70e6c39b6ca0192a4c297de",
        "self_sha256": "e522afa73e8dc01c51303d1d1d99a95fe2ea78f968a2696dc0583f695fce7c37",
        "schema_file_sha256": "0cee4c9ed9083d734491d90eaa3f02265b07295d7873733c006cce9df317147c",
    },
}

AUTHORITY_FILES = {
    "baseline_ablation_budget_v2": (
        CALIBRATION_ROOT / "contracts/baseline-ablation-budget-v2.json",
        SCHEMA_ROOT / "baseline-ablation-budget-v2.schema.json",
        "artifact_sha256",
    ),
    "candidate_evidence_policy_v2": (
        CALIBRATION_ROOT / "contracts/candidate-evidence-policy-v2.json",
        SCHEMA_ROOT / "candidate-evidence-policy-v2.schema.json",
        "artifact_sha256",
    ),
    "calibration_plan_v2": (
        CALIBRATION_ROOT / "contracts/calibration-plan-v2.json",
        SCHEMA_ROOT / "calibration-plan-v2.schema.json",
        "plan_sha256",
    ),
    "shared_bank_configuration_identity_v2": (
        CALIBRATION_ROOT / "contracts/shared-bank-configuration-identity-v2.json",
        SCHEMA_ROOT / "shared-bank-configuration-identity-v2.schema.json",
        "artifact_sha256",
    ),
}

V1_BYTE_IDENTITIES = {
    SCHEMA_ROOT / "non-ash-selector-selection-v1.schema.json":
        "a5b41ddcd39d26a257f88f752b873d5264ae491fd35275d1f19f1297e4af49ac",
    SCHEMA_ROOT / "baseline-ablation-contract-v1.schema.json":
        "7da980490d90cab2bfdc9933fffa56cddc2327f8703014c896aa9e9b712c79d5",
    SCHEMA_ROOT / "candidate-evidence-policy-v1.schema.json":
        "2e59187816340fe9d7c88495a5bdd6e26fd33258df6ed521814900464cca024a",
    SCHEMA_ROOT / "calibration-plan-v1.schema.json":
        "051a804b32121a99241270c0199e5f3a90034f717ab05e67019b3d8384a7854a",
}

RULE_HASH_INPUT = (
    "canonical sorted-key compact UTF-8 JSON object with exactly the 27 "
    "coordinate_order names as keys and their signed integer values; no BOM "
    "and no trailing newline"
)


def _load(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected object: {path}")
    return value


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _sha(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _rule_mapping(values: tuple[int, ...] | list[int]) -> dict[str, int]:
    if len(values) != len(COORDINATE_ORDER):
        raise AssertionError("rule value count differs")
    return dict(zip(COORDINATE_ORDER, values))


def _rule_sha256(values: tuple[int, ...] | list[int]) -> str:
    return hashlib.sha256(canonical_json_bytes(_rule_mapping(values))).hexdigest()


def _serialization() -> dict[str, object]:
    return {
        "coordinate_order": list(COORDINATE_ORDER),
        "encoding": "UTF-8",
        "hash_algorithm": "SHA-256",
        "hash_input": RULE_HASH_INPUT,
        "value_order": list(VALUE_ORDER),
    }


def _objective() -> dict[str, object]:
    return {
        "comparison_domain": "engine_raw",
        "row_scope": "natural corpus asset rows only",
        "per_source_aggregation": (
            "unweighted arithmetic mean across that source's locked "
            "degradation-profile rows"
        ),
        "across_source_aggregation": (
            "unweighted arithmetic mean across source assets"
        ),
        "direction": "lexicographically maximize",
        "metric_order": [
            "y_psnr_db",
            "y_ms_ssim",
            "y_ssim",
            "cb_psnr_db",
            "cr_psnr_db",
        ],
    }


def _data_access(*, validation: bool, development: bool = True) -> dict[str, bool]:
    return {
        "development_metrics_accessed": development,
        "validation_accessed": validation,
        "holdout_accessed": False,
        "media_payloads_accessed": False,
        "release_locks_written": False,
        "winner_claim_made": False,
    }


class NonAshSelectorV2SchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schemas = {name: _load(path) for name, path in SCHEMA_PATHS.items()}
        cls.validators = {
            name: Draft202012Validator(schema)
            for name, schema in cls.schemas.items()
        }
        cls.zero_values = tuple(0 for _ in COORDINATE_ORDER)
        cls.ledger = cls._make_ledger()
        cls.neighbors = cls._make_neighbors(cls.ledger)
        cls.development_selection = cls._make_development_selection(cls.ledger)
        cls.validation_selection = cls._make_validation_selection(
            cls.development_selection,
            cls.neighbors,
        )

    @classmethod
    def _base(cls, artifact_kind: str) -> dict[str, object]:
        return {
            "schema_version": "2.0.0",
            "artifact_kind": artifact_kind,
            "selector_id": SELECTOR_ID,
            "authority_bindings": deepcopy(AUTHORITY_BINDINGS),
            "canonical_rule_serialization": _serialization(),
            "shared_bank_configuration_sha256": _sha("shared-bank"),
            "degradation_policy_sha256": _sha("degradation-policy"),
            "cached_16_operator_output_manifest_sha256": _sha(
                "cached-16-operator-output-manifest"
            ),
        }

    @classmethod
    def _make_ledger(cls) -> dict[str, object]:
        document = cls._base("p06_non_ash_selector_attempt_ledger_v2")
        schedule = {
            "initial_attempt_ordinal": 0,
            "maximum_sweeps": 18,
            "coordinate_count": 27,
            "values_per_coordinate": 7,
            "attempts_per_complete_sweep": 189,
            "maximum_attempt_count": 3403,
            "coordinate_order": list(COORDINATE_ORDER),
            "value_order": list(VALUE_ORDER),
            "coordinate_scan_attempt_ordinal_formula": (
                "1 + (sweep - 1) * 189 + coordinate_ordinal * 7 + value_ordinal"
            ),
            "cache_hits_must_be_recorded": True,
        }
        records: list[dict[str, object]] = []
        seen_evaluations: dict[str, str] = {}
        previous: str | None = None

        def append_record(
            *,
            phase: str,
            sweep: int,
            coordinate_ordinal: int | None,
            coordinate_name: str | None,
            coordinate_value: int | None,
            values: tuple[int, ...],
        ) -> None:
            nonlocal previous
            ordinal = len(records)
            rule_sha256 = _rule_sha256(values)
            cache_hit = rule_sha256 in seen_evaluations
            evaluation_sha256 = seen_evaluations.setdefault(
                rule_sha256,
                _sha(f"evaluation:{rule_sha256}"),
            )
            outcome: dict[str, object] = {
                "outcome_type": "evaluated",
                "evaluation_sha256": evaluation_sha256,
                "objective_summary_sha256": _sha(f"objective:{rule_sha256}"),
                "engine_raw_corpus_mean_tuple": [1, 2, 3, 4, 5],
                "output_manifest_sha256": _sha(f"output:{rule_sha256}"),
            }
            record = {
                "attempt_ordinal": ordinal,
                "phase": phase,
                "sweep": sweep,
                "coordinate_ordinal": coordinate_ordinal,
                "coordinate_name": coordinate_name,
                "coordinate_value": coordinate_value,
                "rule_sha256": rule_sha256,
                "canonical_rule_values": list(values),
                "cache_hit": cache_hit,
                "outcome": outcome,
                "previous_record_sha256": previous,
                "record_sha256": _sha(f"record:{ordinal}:{previous}:{rule_sha256}"),
            }
            records.append(record)
            previous = str(record["record_sha256"])

        append_record(
            phase="initial",
            sweep=0,
            coordinate_ordinal=None,
            coordinate_name=None,
            coordinate_value=None,
            values=cls.zero_values,
        )
        for coordinate_ordinal, coordinate_name in enumerate(COORDINATE_ORDER):
            for coordinate_value in VALUE_ORDER:
                values = list(cls.zero_values)
                values[coordinate_ordinal] = coordinate_value
                append_record(
                    phase="coordinate_scan",
                    sweep=1,
                    coordinate_ordinal=coordinate_ordinal,
                    coordinate_name=coordinate_name,
                    coordinate_value=coordinate_value,
                    values=tuple(values),
                )

        document.update(
            {
                "attempt_schedule": schedule,
                "split": "development",
                "run_id": "schema-fixture",
                "maximum_attempt_count": 3403,
                "attempt_count": len(records),
                "unique_evaluation_count": len(seen_evaluations),
                "cache_hit_count": sum(
                    1 for record in records if record["cache_hit"]
                ),
                "first_attempt_ordinal": 0,
                "last_attempt_ordinal": len(records) - 1,
                "records": records,
                "last_record_sha256": previous,
                "completed_sweep_count": 1,
                "terminal_status": "converged",
                "termination_reason": "unchanged_complete_sweep",
                "terminal_attempt_ordinal": 0,
                "terminal_rule_sha256": _rule_sha256(cls.zero_values),
                "terminal_rule_values": list(cls.zero_values),
                "terminal_objective_summary_sha256": _sha("terminal-objective"),
                "terminal_engine_raw_corpus_mean_tuple": [1, 2, 3, 4, 5],
                "data_access": _data_access(validation=False),
                "ledger_sha256": _sha("ledger"),
            }
        )
        return document

    @classmethod
    def _make_neighbors(cls, ledger: dict[str, object]) -> dict[str, object]:
        candidates: list[dict[str, object]] = []
        terminal_sha256 = _rule_sha256(cls.zero_values)
        candidates.append(
            {
                "validation_candidate_ordinal": 0,
                "candidate_kind": "terminal",
                "rule_sha256": terminal_sha256,
                "canonical_rule_values": list(cls.zero_values),
                "development_evidence_sha256": _sha("development-evidence:0"),
                "neighbor_entry_sha256": _sha("neighbor:0"),
            }
        )
        for coordinate_ordinal, coordinate_name in enumerate(COORDINATE_ORDER):
            for replacement_value in VALUE_ORDER:
                if replacement_value == 0:
                    continue
                values = list(cls.zero_values)
                values[coordinate_ordinal] = replacement_value
                ordinal = len(candidates)
                candidates.append(
                    {
                        "validation_candidate_ordinal": ordinal,
                        "candidate_kind": "one_coordinate_neighbor",
                        "coordinate_ordinal": coordinate_ordinal,
                        "coordinate_name": coordinate_name,
                        "terminal_value": 0,
                        "replacement_value": replacement_value,
                        "rule_sha256": _rule_sha256(values),
                        "canonical_rule_values": values,
                        "development_evidence_sha256": _sha(
                            f"development-evidence:{ordinal}"
                        ),
                        "neighbor_entry_sha256": _sha(f"neighbor:{ordinal}"),
                    }
                )
        document = cls._base("p06_non_ash_validation_neighbor_manifest_v2")
        document.update(
            {
                "neighbor_generation": {
                    "terminal_candidate_count": 1,
                    "coordinate_count": 27,
                    "noncurrent_values_per_coordinate": 6,
                    "validation_candidate_count": 163,
                    "candidate_order": (
                        "terminal rule first, then coordinate_order, then "
                        "ascending noncurrent value_order"
                    ),
                    "neighbor_ordinal_formula": (
                        "1 + coordinate_ordinal * 6 + noncurrent_value_ordinal"
                    ),
                    "adaptive_expansion_allowed": False,
                },
                "source_split": "development",
                "target_split": "validation",
                "development_attempt_count": ledger["attempt_count"],
                "development_last_attempt_ordinal": ledger["last_attempt_ordinal"],
                "development_attempt_ledger_sha256": ledger["ledger_sha256"],
                "development_attempt_ledger_tip_sha256": ledger[
                    "last_record_sha256"
                ],
                "development_selection_sha256": _sha("development-selection"),
                "development_candidate_evidence_manifest_sha256": _sha(
                    "development-candidate-evidence-manifest"
                ),
                "terminal_rule_sha256": terminal_sha256,
                "terminal_rule_values": list(cls.zero_values),
                "maximum_validation_candidate_count": 163,
                "validation_candidate_count": 163,
                "candidate_rule_sha256_values": [
                    candidate["rule_sha256"] for candidate in candidates
                ],
                "candidates": candidates,
                "data_access": _data_access(validation=False),
                "manifest_sha256": _sha("neighbor-manifest"),
            }
        )
        return document

    @classmethod
    def _make_development_selection(
        cls,
        ledger: dict[str, object],
    ) -> dict[str, object]:
        document = cls._base("p06_non_ash_selector_selection_v2")
        document.update(
            {
                "selection_stage": "development_provisional",
                "split": "development",
                "uniform_application": True,
                "candidate_evaluation_budget": 3403,
                "maximum_validation_candidate_count": 163,
                "selection_objective": _objective(),
                "development_attempt_count": ledger["attempt_count"],
                "development_last_attempt_ordinal": ledger["last_attempt_ordinal"],
                "development_attempt_ledger_sha256": ledger["ledger_sha256"],
                "development_attempt_ledger_tip_sha256": ledger[
                    "last_record_sha256"
                ],
                "development_terminal_attempt_ordinal": ledger[
                    "terminal_attempt_ordinal"
                ],
                "development_terminal_rule_sha256": ledger[
                    "terminal_rule_sha256"
                ],
                "development_terminal_rule_values": ledger[
                    "terminal_rule_values"
                ],
                "development_objective_summary_sha256": ledger[
                    "terminal_objective_summary_sha256"
                ],
                "development_engine_raw_corpus_mean_tuple": ledger[
                    "terminal_engine_raw_corpus_mean_tuple"
                ],
                "development_selection_sha256": _sha("development-selection"),
                "cached_16_operator_output_manifest_sha256": _sha(
                    "cached-16-operator-output-manifest"
                ),
                "data_access": _data_access(validation=False),
                "tie_break": (
                    "lexicographically maximize the development engine_raw "
                    "corpus-mean tuple, then choose the lexicographically "
                    "ascending canonical serialized complete 27-member rule object"
                ),
            }
        )
        return document

    @classmethod
    def _make_validation_selection(
        cls,
        development_selection: dict[str, object],
        neighbors: dict[str, object],
    ) -> dict[str, object]:
        results: list[dict[str, object]] = []
        candidates = neighbors["candidates"]
        if not isinstance(candidates, list):
            raise AssertionError("candidate fixture is not an array")
        for candidate in candidates:
            ordinal = candidate["validation_candidate_ordinal"]
            if ordinal == 162:
                outcome: dict[str, object] = {
                    "outcome_type": "failed",
                    "failure_type": "evaluation_failure",
                    "attempt_failure_sha256": _sha("validation-failure:162"),
                }
            else:
                outcome = {
                    "outcome_type": "scored",
                    "objective_summary_sha256": _sha(
                        f"validation-objective:{ordinal}"
                    ),
                    "engine_raw_corpus_mean_tuple": [1, 2, 3, 4, 5],
                    "output_manifest_sha256": _sha(
                        f"validation-output:{ordinal}"
                    ),
                }
            results.append(
                {
                    "validation_candidate_ordinal": ordinal,
                    "neighbor_entry_sha256": candidate["neighbor_entry_sha256"],
                    "rule_sha256": candidate["rule_sha256"],
                    "outcome": outcome,
                }
            )
        document = cls._base("p06_non_ash_selector_selection_v2")
        document.update(
            {
                "selection_stage": "validation_final",
                "split": "validation",
                "uniform_application": True,
                "candidate_evaluation_budget": 3403,
                "maximum_validation_candidate_count": 163,
                "selection_objective": _objective(),
                "development_selection_sha256": development_selection[
                    "development_selection_sha256"
                ],
                "development_terminal_rule_sha256": development_selection[
                    "development_terminal_rule_sha256"
                ],
                "validation_neighbor_manifest_sha256": neighbors["manifest_sha256"],
                "validation_candidate_count": 163,
                "validation_results": results,
                "validation_status": "selected",
                "selected_control_rule_sha256": _rule_sha256(cls.zero_values),
                "selected_control_rule_values": list(cls.zero_values),
                "validation_objective_summary_sha256": _sha(
                    "selected-validation-objective"
                ),
                "validation_selection_sha256": _sha("validation-selection"),
                "cached_16_operator_output_manifest_sha256": development_selection[
                    "cached_16_operator_output_manifest_sha256"
                ],
                "data_access": _data_access(validation=True),
                "tie_break": (
                    "lexicographically maximize the validation engine_raw "
                    "corpus-mean tuple, then choose the lexicographically "
                    "ascending canonical serialized complete 27-member rule object"
                ),
            }
        )
        return document

    def assertValid(self, schema_name: str, document: dict[str, object]) -> None:
        errors = sorted(
            self.validators[schema_name].iter_errors(document),
            key=lambda error: list(error.absolute_path),
        )
        self.assertEqual(errors, [], [error.message for error in errors])

    def assertInvalid(self, schema_name: str, document: dict[str, object]) -> None:
        self.assertNotEqual(
            list(self.validators[schema_name].iter_errors(document)),
            [],
        )

    def test_schemas_are_draft_2020_12_canonical_and_authority_bound(self) -> None:
        for name, schema in self.schemas.items():
            with self.subTest(schema=name):
                Draft202012Validator.check_schema(schema)
                self.assertFalse(schema["additionalProperties"])
                self.assertEqual(
                    schema["$defs"]["authorityBindings"]["const"],
                    AUTHORITY_BINDINGS,
                )
                self.assertEqual(
                    SCHEMA_PATHS[name].read_bytes(),
                    canonical_json_bytes(schema) + b"\n",
                )

        for authority_id, (contract_path, schema_path, self_hash_field) in (
            AUTHORITY_FILES.items()
        ):
            with self.subTest(authority=authority_id):
                binding = AUTHORITY_BINDINGS[authority_id]
                self.assertEqual(_file_sha256(contract_path), binding["file_sha256"])
                self.assertEqual(_file_sha256(schema_path), binding["schema_file_sha256"])
                contract = _load(contract_path)
                self.assertEqual(contract[self_hash_field], binding["self_sha256"])
                self.assertEqual(
                    manifest_sha256(contract, field=self_hash_field),
                    binding["self_sha256"],
                )

    def test_rule_hash_preserves_v1_canonical_object_bytes(self) -> None:
        values = list(self.zero_values)
        values[0] = -384
        values[26] = 384
        mapping = _rule_mapping(values)
        self.assertEqual(list(mapping), list(COORDINATE_ORDER))
        self.assertEqual(
            canonical_json_bytes(mapping),
            json.dumps(
                mapping,
                ensure_ascii=False,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8"),
        )
        self.assertNotEqual(
            _rule_sha256(values),
            hashlib.sha256(canonical_json_bytes(values)).hexdigest(),
        )
        for schema in self.schemas.values():
            rule_serialization = schema["$defs"]["ruleSerialization"]
            if "const" in rule_serialization:
                self.assertEqual(rule_serialization["const"]["hash_input"], RULE_HASH_INPUT)
            else:
                self.assertEqual(
                    rule_serialization["properties"]["hash_input"]["const"],
                    RULE_HASH_INPUT,
                )

    def test_failure_schema_is_split_bounded_and_typed(self) -> None:
        document = self._base("p06_non_ash_selector_attempt_failure_v2")
        document.update(
            {
                "split": "development",
                "attempt_ordinal": 3402,
                "rule_sha256": _rule_sha256(self.zero_values),
                "canonical_rule_values": list(self.zero_values),
                "failure_type": "constraint_failure",
                "failure_code": "selector.constraint",
                "failure_message": "fixture constraint failure",
                "failure_details": {"constraint_codes": ["fixture_constraint"]},
                "evidence_bindings": [],
                "data_access": _data_access(validation=False, development=False),
                "failure_sha256": _sha("failure"),
            }
        )
        self.assertValid("failure", document)

        evaluation_failure = deepcopy(document)
        evaluation_failure.update(
            {
                "split": "validation",
                "attempt_ordinal": 162,
                "failure_type": "evaluation_failure",
                "failure_code": "selector.evaluator",
                "failure_details": {
                    "evaluator_error_type": "FixtureError",
                    "evaluation_request_sha256": _sha("evaluation-request"),
                },
                "data_access": _data_access(validation=True),
            }
        )
        self.assertValid("failure", evaluation_failure)

        integrity_failure = deepcopy(evaluation_failure)
        integrity_failure.update(
            {
                "failure_type": "evidence_integrity_failure",
                "failure_code": "selector.binding_mismatch",
                "failure_details": {
                    "binding_id": "fixture",
                    "expected_sha256": _sha("expected"),
                    "observed_sha256": None,
                },
            }
        )
        self.assertValid("failure", integrity_failure)

        stale_type = deepcopy(document)
        stale_type["failure_type"] = "evaluation_failure"
        self.assertInvalid("failure", stale_type)
        over_validation_budget = deepcopy(evaluation_failure)
        over_validation_budget["attempt_ordinal"] = 163
        self.assertInvalid("failure", over_validation_budget)
        leaked_validation = deepcopy(document)
        leaked_validation["data_access"]["validation_accessed"] = True
        self.assertInvalid("failure", leaked_validation)
        stale_degradation = deepcopy(document)
        stale_degradation["degradation_policy_sha256"] = "0" * 64
        self.assertInvalid("failure", stale_degradation)

    def test_ledger_freezes_schedule_cache_reopen_chain_and_terminal_state(self) -> None:
        self.assertValid("ledger", self.ledger)
        records = self.ledger["records"]
        self.assertIsInstance(records, list)
        self.assertEqual(len(records), 190)
        self.assertEqual(records[0]["attempt_ordinal"], 0)
        self.assertEqual(records[0]["previous_record_sha256"], None)
        self.assertEqual(records[0]["phase"], "initial")

        cache_hit_count = 0
        fresh_evaluations: dict[str, str] = {}
        for record in records:
            if not record["cache_hit"]:
                fresh_evaluations[record["rule_sha256"]] = record["outcome"][
                    "evaluation_sha256"
                ]
        for record in records[1:]:
            ordinal = record["attempt_ordinal"]
            coordinate_ordinal = record["coordinate_ordinal"]
            coordinate_value = record["coordinate_value"]
            value_ordinal = VALUE_ORDER.index(coordinate_value)
            self.assertEqual(
                ordinal,
                1 + coordinate_ordinal * 7 + value_ordinal,
            )
            self.assertEqual(record["sweep"], 1)
            self.assertEqual(
                record["coordinate_name"],
                COORDINATE_ORDER[coordinate_ordinal],
            )
            if record["cache_hit"]:
                cache_hit_count += 1
                self.assertEqual(
                    record["outcome"]["evaluation_sha256"],
                    fresh_evaluations[record["rule_sha256"]],
                )
        self.assertEqual(cache_hit_count, 27)

        missing_cache_field = deepcopy(self.ledger)
        del missing_cache_field["records"][1]["cache_hit"]
        self.assertInvalid("ledger", missing_cache_field)
        cached_failure = deepcopy(self.ledger)
        cached = next(record for record in cached_failure["records"] if record["cache_hit"])
        cached["outcome"] = {
            "outcome_type": "failed",
            "attempt_failure_sha256": _sha("cached-failure"),
        }
        self.assertInvalid("ledger", cached_failure)
        mismatched_coordinate = deepcopy(self.ledger)
        mismatched_coordinate["records"][1]["coordinate_name"] = COORDINATE_ORDER[1]
        self.assertInvalid("ledger", mismatched_coordinate)
        invalid_genesis = deepcopy(self.ledger)
        invalid_genesis["records"][0]["previous_record_sha256"] = _sha("prior")
        self.assertInvalid("ledger", invalid_genesis)

        exhausted = deepcopy(self.ledger)
        exhausted["terminal_status"] = "maximum_sweeps_exhausted"
        exhausted["termination_reason"] = "maximum_sweeps_exhausted"
        exhausted["completed_sweep_count"] = 18
        for field in (
            "terminal_attempt_ordinal",
            "terminal_rule_sha256",
            "terminal_rule_values",
            "terminal_objective_summary_sha256",
            "terminal_engine_raw_corpus_mean_tuple",
        ):
            del exhausted[field]
        exhausted["terminal_failure_type"] = "maximum_sweeps_exhausted"
        exhausted["terminal_failure_sha256"] = _sha("maximum-sweeps-failure")
        self.assertValid("ledger", exhausted)
        leaked_terminal = deepcopy(exhausted)
        leaked_terminal["terminal_rule_sha256"] = _rule_sha256(self.zero_values)
        self.assertInvalid("ledger", leaked_terminal)

        aborted = deepcopy(self.ledger)
        aborted["records"] = [aborted["records"][0]]
        aborted["records"][0]["outcome"] = {
            "outcome_type": "failed",
            "failure_type": "evaluation_failure",
            "attempt_failure_sha256": _sha("initial-evaluation-failure"),
        }
        aborted["attempt_count"] = 1
        aborted["unique_evaluation_count"] = 0
        aborted["cache_hit_count"] = 0
        aborted["last_attempt_ordinal"] = 0
        aborted["last_record_sha256"] = aborted["records"][0]["record_sha256"]
        aborted["completed_sweep_count"] = 0
        aborted["terminal_status"] = "aborted"
        aborted["termination_reason"] = "attempt_failure_abort"
        for field in (
            "terminal_attempt_ordinal",
            "terminal_rule_sha256",
            "terminal_rule_values",
            "terminal_objective_summary_sha256",
            "terminal_engine_raw_corpus_mean_tuple",
        ):
            del aborted[field]
        aborted["terminal_failure_type"] = "attempt_failure_abort"
        aborted["terminal_failure_sha256"] = _sha("aborted-ledger")
        self.assertValid("ledger", aborted)
        untyped_abort = deepcopy(aborted)
        del untyped_abort["records"][0]["outcome"]["failure_type"]
        self.assertInvalid("ledger", untyped_abort)

    def test_neighbor_manifest_is_exact_unique_and_frozen_before_validation(self) -> None:
        self.assertValid("neighbors", self.neighbors)
        candidates = self.neighbors["candidates"]
        self.assertIsInstance(candidates, list)
        self.assertEqual(len(candidates), 1 + 27 * 6)
        hashes = [candidate["rule_sha256"] for candidate in candidates]
        self.assertEqual(len(hashes), len(set(hashes)))
        self.assertEqual(
            hashes,
            self.neighbors["candidate_rule_sha256_values"],
        )
        self.assertEqual(candidates[0]["candidate_kind"], "terminal")
        for ordinal, candidate in enumerate(candidates[1:], start=1):
            self.assertEqual(candidate["validation_candidate_ordinal"], ordinal)
            coordinate_ordinal = (ordinal - 1) // 6
            self.assertEqual(candidate["coordinate_ordinal"], coordinate_ordinal)
            self.assertEqual(
                candidate["coordinate_name"],
                COORDINATE_ORDER[coordinate_ordinal],
            )

        missing_candidate = deepcopy(self.neighbors)
        missing_candidate["candidates"].pop()
        self.assertInvalid("neighbors", missing_candidate)
        duplicate_hash = deepcopy(self.neighbors)
        duplicate_hash["candidate_rule_sha256_values"][1] = (
            duplicate_hash["candidate_rule_sha256_values"][0]
        )
        self.assertInvalid("neighbors", duplicate_hash)
        mismatched_coordinate = deepcopy(self.neighbors)
        mismatched_coordinate["candidates"][1]["coordinate_name"] = COORDINATE_ORDER[1]
        self.assertInvalid("neighbors", mismatched_coordinate)
        missing_development_evidence = deepcopy(self.neighbors)
        del missing_development_evidence["candidates"][1][
            "development_evidence_sha256"
        ]
        self.assertInvalid("neighbors", missing_development_evidence)
        opened_validation = deepcopy(self.neighbors)
        opened_validation["data_access"]["validation_accessed"] = True
        self.assertInvalid("neighbors", opened_validation)

    def test_selection_stages_are_structurally_disjoint_and_typed(self) -> None:
        self.assertValid("selection", self.development_selection)
        self.assertValid("selection", self.validation_selection)

        development_with_validation = deepcopy(self.development_selection)
        development_with_validation["validation_candidate_count"] = 163
        self.assertInvalid("selection", development_with_validation)
        development_opened_validation = deepcopy(self.development_selection)
        development_opened_validation["data_access"]["validation_accessed"] = True
        self.assertInvalid("selection", development_opened_validation)
        validation_with_development_trace = deepcopy(self.validation_selection)
        validation_with_development_trace["development_attempt_count"] = 190
        self.assertInvalid("selection", validation_with_development_trace)
        incomplete_validation = deepcopy(self.validation_selection)
        incomplete_validation["validation_results"].pop()
        self.assertInvalid("selection", incomplete_validation)
        untyped_failure = deepcopy(self.validation_selection)
        untyped_failure["validation_results"][-1]["outcome"][
            "failure_type"
        ] = "untyped"
        self.assertInvalid("selection", untyped_failure)
        integrity_failure = deepcopy(self.validation_selection)
        integrity_failure["validation_results"][-1]["outcome"][
            "failure_type"
        ] = "evidence_integrity_failure"
        self.assertInvalid("selection", integrity_failure)

        failed_all = deepcopy(self.validation_selection)
        failed_all["validation_status"] = "failed_all_candidates"
        for result in failed_all["validation_results"]:
            result["outcome"] = {
                "outcome_type": "failed",
                "failure_type": "evaluation_failure",
                "attempt_failure_sha256": _sha(
                    f"all-failed:{result['validation_candidate_ordinal']}"
                ),
            }
        del failed_all["selected_control_rule_sha256"]
        del failed_all["selected_control_rule_values"]
        del failed_all["validation_objective_summary_sha256"]
        failed_all["validation_terminal_failure_sha256"] = _sha(
            "all-validation-candidates-failed"
        )
        self.assertValid("selection", failed_all)
        selected_with_terminal_failure = deepcopy(self.validation_selection)
        selected_with_terminal_failure["validation_terminal_failure_sha256"] = _sha(
            "forbidden-terminal-failure"
        )
        self.assertInvalid("selection", selected_with_terminal_failure)

    def test_cross_version_and_claim_boundaries_are_closed(self) -> None:
        for path, expected_sha256 in V1_BYTE_IDENTITIES.items():
            with self.subTest(path=path.name):
                self.assertEqual(_file_sha256(path), expected_sha256)

        v1_schema = _load(
            SCHEMA_ROOT / "non-ash-selector-selection-v1.schema.json"
        )
        Draft202012Validator.check_schema(v1_schema)
        v1_rule = {name: 0 for name in COORDINATE_ORDER}
        v1_document = {
            "schema_version": "1.1.0",
            "artifact_kind": "p06_non_ash_selector_selection",
            "selection_stage": "development_provisional",
            "selector_id": "continuous-linear-bank-selector-q15-v1",
            "shared_bank_configuration_sha256": _sha("v1-bank"),
            "uniform_application": True,
            "candidate_evaluation_budget": 1513,
            "full_ash_maximum_candidate_evaluation_budget": 1345,
            "selection_objective": _objective(),
            "development_attempt_count": 1,
            "development_attempt_ledger_sha256": _sha("v1-ledger"),
            "development_terminal_rule_sha256": _sha("v1-rule"),
            "development_terminal_rule_configuration": v1_rule,
            "development_objective_summary_sha256": _sha("v1-objective"),
            "development_engine_raw_corpus_mean_tuple": [1, 2, 3, 4, 5],
            "cached_16_operator_output_manifest_sha256": _sha("v1-cache"),
            "tie_break": (
                "lexicographically maximize the development engine_raw "
                "corpus-mean tuple, then choose the lexicographically ascending "
                "canonical serialized complete rule vector"
            ),
        }
        self.assertEqual(
            list(Draft202012Validator(v1_schema).iter_errors(v1_document)),
            [],
        )
        self.assertInvalid("selection", v1_document)
        self.assertNotEqual(
            list(
                Draft202012Validator(v1_schema).iter_errors(
                    self.validation_selection
                )
            ),
            [],
        )

        for schema_name, document in (
            ("failure", self._base("p06_non_ash_selector_attempt_failure_v2")),
            ("ledger", self.ledger),
            ("neighbors", self.neighbors),
            ("selection", self.validation_selection),
        ):
            if schema_name == "failure":
                continue
            for claim in (
                "holdout_results_sha256",
                "media_manifest_sha256",
                "release_bundle_sha256",
                "selected_winner",
            ):
                with self.subTest(schema=schema_name, claim=claim):
                    mutated = deepcopy(document)
                    mutated[claim] = _sha(claim)
                    self.assertInvalid(schema_name, mutated)


if __name__ == "__main__":
    unittest.main()
