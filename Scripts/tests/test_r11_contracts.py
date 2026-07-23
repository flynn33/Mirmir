from __future__ import annotations

import copy
from contextlib import redirect_stderr, redirect_stdout
import hashlib
from io import StringIO
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT))
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r11_contracts import (  # noqa: E402
    AGGREGATE_OBSERVATION_IDS,
    CHECK_IDS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_RAW_SHA256,
    FIXTURE_CATALOG_SCHEMA_PATH,
    FIXTURE_CATALOG_SEMANTIC_SHA256,
    FIXTURE_CATALOG_SIZE_BYTES,
    IMPLEMENTATION_IDENTITIES,
    IMPLEMENTATION_PATHS,
    MAX_CONTRACT_BYTES,
    OBSERVATION_IDS,
    OBSERVATION_STATE_ORDER,
    PHASE_ACCEPTANCE_PATH,
    PREREGISTRATION_PATH,
    PREREGISTRATION_RAW_SHA256,
    PREREGISTRATION_SCHEMA_PATH,
    PREREGISTRATION_SEMANTIC_SHA256,
    PREREGISTRATION_SIZE_BYTES,
    R10_ACCEPTED_IMPLEMENTATION_SOURCE,
    R10_CLOSURE_SOURCE,
    R10_EXECUTION_RECEIPT_PATH,
    R10_PHASE_ACCEPTANCE_PATH,
    R10_RECEIPT_IDENTITIES,
    REJECTION_CASES,
    ROADMAP_PATH,
    RUN_RECEIPT_PATH,
    SCHEMA_IDENTITIES,
    SCHEMA_PATHS,
    STOP_RULE_IDS,
    R11ContractError,
    R11ContractVerifier,
    _decode_payload,
    _read_regular_nofollow,
    main,
    parse_fixture_catalog_r11,
)
from validation.calibration_v2.r11_traceability import (  # noqa: E402
    R11BoundaryState,
    R11ClaimDisposition,
    R11ClaimToken,
    R11EvidenceIdentity,
    R11Observation,
    R11TraceabilityError,
    decide_claim_r11,
)


def read_bytes(path: Path) -> bytes:
    return (REPOSITORY_ROOT / path).read_bytes()


def read_json(path: Path) -> dict[str, object]:
    value = json.loads(read_bytes(path))
    assert isinstance(value, dict)
    return value


def encoded(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2)
        + "\n"
    ).encode("utf-8")


def semantic_sha256(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()


class R11ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R11ContractVerifier(REPOSITORY_ROOT)
        self.preregistration = read_json(PREREGISTRATION_PATH)
        self.fixture = read_json(FIXTURE_CATALOG_PATH)

    def temporary_roadmap_root(
        self,
        status: str,
    ) -> tempfile.TemporaryDirectory[str]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        roadmap = read_json(ROADMAP_PATH)
        phases = roadmap["phases"]
        assert isinstance(phases, list)
        phase = next(
            item
            for item in phases
            if isinstance(item, dict) and item.get("id") == "R11"
        )
        phase["status"] = status
        target = root / ROADMAP_PATH
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(encoded(roadmap))
        return temporary

    def test_checked_in_contracts_and_stable_parser_pass(self) -> None:
        self.assertEqual(self.verifier.check_preregistration(), [])
        self.assertEqual(self.verifier.check_fixtures(), [])
        self.assertEqual(self.verifier.check_roadmap_status(), [])
        self.assertEqual(self.verifier.check(), [])
        document, identity, observations, aggregate = (
            parse_fixture_catalog_r11(read_bytes(FIXTURE_CATALOG_PATH))
        )
        self.assertEqual(document, self.fixture)
        self.assertEqual(
            identity.identity_sha256,
            "3876a1d5af2715f42e34fa580ad283815cb9d3537c57e91058de753b7f492168",
        )
        self.assertEqual(tuple(item.observation_id for item in observations), OBSERVATION_IDS)
        self.assertEqual(
            aggregate.aggregate_sha256,
            "0666bbb55d9c20b3671cfd276a4a7b233bade2973b219912510e81b97604679d",
        )

    def test_cli_all_default_and_each_mode(self) -> None:
        modes = (
            ([], ("R11 preregistration", "R11 fixtures", "R11 roadmap status")),
            (["--all"], ("R11 preregistration", "R11 fixtures", "R11 roadmap status")),
            (["--check-preregistration"], ("R11 preregistration",)),
            (["--check-fixtures"], ("R11 fixtures",)),
            (["--check-roadmap-status"], ("R11 roadmap status",)),
        )
        for arguments, labels in modes:
            with self.subTest(arguments=arguments):
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    result = main(arguments)
                self.assertEqual(result, 0)
                self.assertEqual(stderr.getvalue(), "")
                for label in labels:
                    self.assertIn(f"{label}: PASS", stdout.getvalue())

    def test_frozen_record_raw_and_semantic_identities(self) -> None:
        preregistration_payload = read_bytes(PREREGISTRATION_PATH)
        fixture_payload = read_bytes(FIXTURE_CATALOG_PATH)
        self.assertEqual(len(preregistration_payload), PREREGISTRATION_SIZE_BYTES)
        self.assertEqual(
            hashlib.sha256(preregistration_payload).hexdigest(),
            PREREGISTRATION_RAW_SHA256,
        )
        self.assertEqual(
            semantic_sha256(self.preregistration),
            PREREGISTRATION_SEMANTIC_SHA256,
        )
        self.assertEqual(len(fixture_payload), FIXTURE_CATALOG_SIZE_BYTES)
        self.assertEqual(
            hashlib.sha256(fixture_payload).hexdigest(),
            FIXTURE_CATALOG_RAW_SHA256,
        )
        self.assertEqual(
            semantic_sha256(self.fixture),
            FIXTURE_CATALOG_SEMANTIC_SHA256,
        )

    def test_all_five_schemas_are_exact_closed_draft_2020_12(self) -> None:
        self.assertEqual(tuple(SCHEMA_PATHS), tuple(SCHEMA_IDENTITIES))
        self.assertEqual(len(SCHEMA_PATHS), 5)
        for identifier, path in SCHEMA_PATHS.items():
            with self.subTest(identifier=identifier):
                payload = read_bytes(path)
                size, digest = SCHEMA_IDENTITIES[identifier]
                self.assertEqual(len(payload), size)
                self.assertEqual(hashlib.sha256(payload).hexdigest(), digest)
                schema = read_json(path)
                self.assertEqual(
                    schema["$schema"],
                    "https://json-schema.org/draft/2020-12/schema",
                )
                self.assertIs(schema["additionalProperties"], False)
                self.assertEqual(schema["type"], "object")

    def test_checked_in_records_match_closed_schemas(self) -> None:
        for record, schema_path in (
            (self.preregistration, PREREGISTRATION_SCHEMA_PATH),
            (self.fixture, FIXTURE_CATALOG_SCHEMA_PATH),
        ):
            with self.subTest(schema=schema_path):
                self.assertEqual(
                    validate_json_schema_instance(
                        read_json(schema_path),
                        record,
                    ),
                    [],
                )

    def test_predecessor_sources_receipts_and_ancestry_are_exact(self) -> None:
        predecessor = self.preregistration["predecessor_binding"]
        assert isinstance(predecessor, dict)
        self.assertEqual(predecessor["closure_source"], R10_CLOSURE_SOURCE)
        self.assertEqual(
            predecessor["accepted_implementation_source"],
            R10_ACCEPTED_IMPLEMENTATION_SOURCE,
        )
        for source in (R10_CLOSURE_SOURCE, R10_ACCEPTED_IMPLEMENTATION_SOURCE):
            tree = subprocess.run(
                ["git", "show", "-s", "--format=%T", source["commit"]],
                cwd=REPOSITORY_ROOT,
                capture_output=True,
                check=True,
                text=True,
            ).stdout.strip()
            self.assertEqual(tree, source["tree"])
            self.assertEqual(
                subprocess.run(
                    ["git", "merge-base", "--is-ancestor", source["commit"], "HEAD"],
                    cwd=REPOSITORY_ROOT,
                    check=False,
                ).returncode,
                0,
            )
        for path, (size, digest) in R10_RECEIPT_IDENTITIES.items():
            payload = read_bytes(path)
            self.assertEqual(len(payload), size)
            self.assertEqual(hashlib.sha256(payload).hexdigest(), digest)
            self.assertEqual(read_json(path)["source"], R10_ACCEPTED_IMPLEMENTATION_SOURCE)

    def test_every_preregistered_binding_and_frozen_contract_is_exact(self) -> None:
        bindings: list[tuple[dict[str, object], Path]] = []
        predecessor = self.preregistration["predecessor_binding"]
        assert isinstance(predecessor, dict)
        for key, path in (
            ("functional_execution_receipt", R10_EXECUTION_RECEIPT_PATH),
            ("functional_phase_acceptance", R10_PHASE_ACCEPTANCE_PATH),
        ):
            binding = predecessor[key]
            assert isinstance(binding, dict)
            bindings.append((binding, path))
        fixture_binding = self.preregistration["fixture_catalog_binding"]
        assert isinstance(fixture_binding, dict)
        bindings.append((fixture_binding, FIXTURE_CATALOG_PATH))
        schemas = self.preregistration["schema_bindings"]
        assert isinstance(schemas, list)
        self.assertEqual(
            tuple(item["id"] for item in schemas if isinstance(item, dict)),
            tuple(SCHEMA_PATHS),
        )
        for item in schemas:
            assert isinstance(item, dict)
            bindings.append((item, SCHEMA_PATHS[str(item["id"])]))
        implementations = self.preregistration["implementation_contract_bindings"]
        assert isinstance(implementations, list)
        self.assertEqual(
            tuple(item["id"] for item in implementations if isinstance(item, dict)),
            tuple(IMPLEMENTATION_PATHS),
        )
        for item in implementations:
            assert isinstance(item, dict)
            identifier = str(item["id"])
            path = IMPLEMENTATION_PATHS[identifier]
            bindings.append((item, path))
            payload = read_bytes(path)
            self.assertEqual(
                (len(payload), hashlib.sha256(payload).hexdigest()),
                IMPLEMENTATION_IDENTITIES[identifier],
            )
        self.assertEqual(len(bindings), 10)
        for index, (binding, path) in enumerate(bindings):
            baseline_errors: list[str] = []
            self.verifier._check_binding(
                binding,
                path,
                f"binding-{index}",
                baseline_errors,
            )
            self.assertEqual(baseline_errors, [])
            for key, replacement in (
                ("path", "wrong/file.json"),
                ("size_bytes", 1),
                ("sha256", "f" * 64),
            ):
                mutated = dict(binding)
                mutated[key] = replacement
                errors: list[str] = []
                self.verifier._check_binding(
                    mutated,
                    path,
                    f"binding-{index}",
                    errors,
                )
                self.assertTrue(errors, (index, key))

    def test_check_stop_comparison_claim_and_authority_contracts_are_exact(self) -> None:
        self.assertEqual(self.preregistration["checks"], list(CHECK_IDS))
        self.assertEqual(self.preregistration["stop_rules"], list(STOP_RULE_IDS))
        self.assertEqual(
            self.preregistration["comparison_policy"],
            {
                "comparison_methods": "absent_not_required",
                "comparison_success_cases": "absent",
                "acceptance_dependency": "none",
            },
        )
        self.assertEqual(
            self.preregistration["claim_contract"],
            {
                "permitted_claims": ["software_behavior_report"],
                "market_disposition": "no_market_claim",
                "production_auto_mode": "blocked",
                "market_leading_claim": "blocked",
            },
        )

    def test_parser_rejects_duplicate_nonfinite_and_invalid_bytes(self) -> None:
        with self.assertRaisesRegex(R11ContractError, "duplicate JSON key"):
            parse_fixture_catalog_r11(b'{"a":1,"a":2}\n')
        with self.assertRaisesRegex(R11ContractError, "non-finite JSON number"):
            parse_fixture_catalog_r11(b'{"value":NaN}\n')
        payload = read_bytes(FIXTURE_CATALOG_PATH)
        mutations: tuple[object, ...] = (
            b"",
            payload[:-1],
            payload.replace(b"\n", b"\r\n", 1),
            payload[:-1] + b"\x00\n",
            b"\xff\n",
            "not-bytes",
            b"{" + b" " * MAX_CONTRACT_BYTES + b"}\n",
        )
        for mutation in mutations:
            with self.subTest(kind=type(mutation).__name__):
                with self.assertRaises(R11ContractError):
                    parse_fixture_catalog_r11(mutation)  # type: ignore[arg-type]

    def test_each_observation_state_semantic_mutation_is_rejected(self) -> None:
        observations = self.fixture["observations"]
        assert isinstance(observations, list)
        self.assertEqual(
            tuple(item["state"] for item in observations if isinstance(item, dict)),
            OBSERVATION_STATE_ORDER,
        )
        mutations = (
            ("reason_code", "execution_failed"),
            ("reason_code", "source_data_absent"),
            ("reason_code", "declared_not_applicable"),
            ("failure_code", None),
            ("reason_code", "declared_not_applicable"),
        )
        for index, (key, replacement) in enumerate(mutations):
            with self.subTest(state=OBSERVATION_STATE_ORDER[index]):
                mutated_document = copy.deepcopy(observations[index])
                assert isinstance(mutated_document, dict)
                mutated_document[key] = replacement
                with self.assertRaises(R11TraceabilityError):
                    R11Observation.from_document(mutated_document)
                mutated_catalog = copy.deepcopy(self.fixture)
                mutated_observations = mutated_catalog["observations"]
                assert isinstance(mutated_observations, list)
                mutated_observations[index] = mutated_document
                with self.assertRaises(R11ContractError):
                    parse_fixture_catalog_r11(encoded(mutated_catalog))

    def test_identity_digest_and_component_mutations_are_rejected(self) -> None:
        observations = self.fixture["observations"]
        assert isinstance(observations, list)
        first = observations[0]
        assert isinstance(first, dict)
        identity_document = first["identity"]
        assert isinstance(identity_document, dict)
        for component in (
            "source",
            "software",
            "subject",
            "input",
            "preprocessing",
            "toolchain",
            "execution",
        ):
            with self.subTest(component=component):
                missing = copy.deepcopy(identity_document)
                missing.pop(component)
                with self.assertRaises(R11TraceabilityError):
                    R11EvidenceIdentity.from_document(missing)
        mismatched = copy.deepcopy(self.fixture)
        mutated_observations = mismatched["observations"]
        assert isinstance(mutated_observations, list)
        mutated_first = mutated_observations[0]
        assert isinstance(mutated_first, dict)
        identity = mutated_first["identity"]
        assert isinstance(identity, dict)
        identity["derived_digest_sha256"] = "f" * 64
        with self.assertRaises(R11ContractError):
            parse_fixture_catalog_r11(encoded(mismatched))

    def test_duplicate_missing_unexpected_and_mixed_identity_observations_reject(self) -> None:
        variants: list[dict[str, object]] = []
        duplicate = copy.deepcopy(self.fixture)
        observations = duplicate["observations"]
        assert isinstance(observations, list)
        observations[1] = copy.deepcopy(observations[0])
        variants.append(duplicate)
        missing = copy.deepcopy(self.fixture)
        observations = missing["observations"]
        assert isinstance(observations, list)
        observations.pop()
        variants.append(missing)
        unexpected = copy.deepcopy(self.fixture)
        observations = unexpected["observations"]
        assert isinstance(observations, list)
        item = observations[-1]
        assert isinstance(item, dict)
        item["observation_id"] = "observation-unexpected"
        variants.append(unexpected)
        mixed_identity = copy.deepcopy(self.fixture)
        observations = mixed_identity["observations"]
        assert isinstance(observations, list)
        item = observations[-1]
        assert isinstance(item, dict)
        identity = item["identity"]
        assert isinstance(identity, dict)
        identity["derived_digest_sha256"] = "f" * 64
        variants.append(mixed_identity)
        for index, variant in enumerate(variants):
            with self.subTest(index=index):
                with self.assertRaises(R11ContractError):
                    parse_fixture_catalog_r11(encoded(variant))

    def test_aggregate_hash_count_state_and_observed_value_mutations_reject(self) -> None:
        mutations: list[dict[str, object]] = []
        for field, replacement in (
            ("observation_sha256_values", ["f" * 64] * 5),
            (
                "state_counts",
                {
                    "observed": 5,
                    "not_applicable": 0,
                    "not_observed": 0,
                    "failed": 0,
                    "absent": 0,
                },
            ),
            ("aggregate_state", "observed"),
            (
                "observed_values",
                [
                    {
                        "observation_id": "observation-observed",
                        "value": "mutated",
                    }
                ],
            ),
            ("expected_observation_ids", list(reversed(AGGREGATE_OBSERVATION_IDS))),
        ):
            mutated = copy.deepcopy(self.fixture)
            cases = mutated["aggregate_cases"]
            assert isinstance(cases, list)
            case = cases[0]
            assert isinstance(case, dict)
            aggregate = case["expected_aggregate"]
            assert isinstance(aggregate, dict)
            aggregate[field] = replacement
            mutations.append(mutated)
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                with self.assertRaises(R11ContractError):
                    parse_fixture_catalog_r11(encoded(mutation))

    def test_every_declared_rejection_case_mapping_mutation_rejects(self) -> None:
        cases = self.fixture["rejection_cases"]
        self.assertEqual(cases, list(REJECTION_CASES))
        assert isinstance(cases, list)
        for index in range(len(cases)):
            with self.subTest(case=index):
                mutated = copy.deepcopy(self.fixture)
                mutated_cases = mutated["rejection_cases"]
                assert isinstance(mutated_cases, list)
                case = mutated_cases[index]
                assert isinstance(case, dict)
                case["expected_reason"] = "forged_authorization"
                if index == 4:
                    case["expected_reason"] = "missing_identity_component"
                with self.assertRaises(R11ContractError):
                    parse_fixture_catalog_r11(encoded(mutated))

    def test_claim_scope_comparison_and_authority_mutations_reject(self) -> None:
        for section, key, replacement in (
            ("claim_boundary", "claim_scope", "market_leading_claim"),
            ("claim_boundary", "market_disposition", "market_claim"),
            ("claim_boundary", "production_auto_mode", "authorized"),
            ("claim_boundary", "market_leading_claim", "authorized"),
            ("comparison_policy", "comparison_method", "a_b_test"),
            ("comparison_policy", "comparison_success_case", "winner"),
            ("comparison_policy", "acceptance_dependency", "comparison"),
        ):
            with self.subTest(section=section, key=key):
                mutated = copy.deepcopy(self.fixture)
                target = mutated[section]
                assert isinstance(target, dict)
                target[key] = replacement
                with self.assertRaises(R11ContractError):
                    parse_fixture_catalog_r11(encoded(mutated))
        extra = copy.deepcopy(self.fixture)
        extra["baseline_score"] = 1
        with self.assertRaises(R11ContractError):
            parse_fixture_catalog_r11(encoded(extra))

    def test_forged_authorization_cannot_change_typed_claim_decision(self) -> None:
        _, _, _, aggregate = parse_fixture_catalog_r11(
            read_bytes(FIXTURE_CATALOG_PATH)
        )
        decision = decide_claim_r11(
            requested_claim=R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT,
            aggregate=aggregate,
        )
        self.assertIs(
            decision.permitted_claim,
            R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT,
        )
        self.assertIs(decision.disposition, R11ClaimDisposition.NO_MARKET_CLAIM)
        for field in (
            "product_qualification",
            "production_auto_mode",
            "market_position",
            "market_leading_claim",
        ):
            self.assertIs(getattr(decision, field), R11BoundaryState.BLOCKED)

    def test_private_email_path_and_key_are_rejected(self) -> None:
        for key, value in (
            ("note", "operator@example.com"),
            ("note", "/Users/operator/private.json"),
            ("username", "operator"),
        ):
            with self.subTest(key=key, value=value):
                mutated = copy.deepcopy(self.fixture)
                mutated[key] = value
                with self.assertRaises(R11ContractError):
                    parse_fixture_catalog_r11(encoded(mutated))

    def test_nofollow_reader_rejects_symlink_hardlink_oversize_and_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target.json"
            target.write_bytes(b"{}\n")
            link = root / "link.json"
            link.symlink_to(target)
            with self.assertRaisesRegex(R11ContractError, "non-symlink"):
                _read_regular_nofollow(root, Path("link.json"), "record")

            hardlink = root / "hardlink.json"
            os.link(target, hardlink)
            with self.assertRaisesRegex(R11ContractError, "closed boundary"):
                _read_regular_nofollow(root, Path("target.json"), "record")

            oversized = root / "oversized.json"
            oversized.write_bytes(b"x" * (MAX_CONTRACT_BYTES + 1))
            with self.assertRaisesRegex(R11ContractError, "closed boundary"):
                _read_regular_nofollow(root, Path("oversized.json"), "record")

            with self.assertRaisesRegex(R11ContractError, "outside"):
                _read_regular_nofollow(root, Path("../target.json"), "record")

    def test_missing_and_symlinked_fixture_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            errors = R11ContractVerifier(Path(temporary)).check_fixtures()
        self.assertIn(
            "R11 fixture catalog must be a regular non-symlink file",
            errors,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target.json"
            target.write_bytes(b"{}\n")
            fixture = root / FIXTURE_CATALOG_PATH
            fixture.parent.mkdir(parents=True, exist_ok=True)
            fixture.symlink_to(target)
            errors = R11ContractVerifier(root).check_fixtures()
        self.assertIn(
            "R11 fixture catalog must be a regular non-symlink file",
            errors,
        )

    def test_planned_in_progress_and_evidence_ready_do_not_require_acceptance(
        self,
    ) -> None:
        for status in ("planned", "in_progress", "evidence_ready"):
            with self.subTest(status=status):
                with self.temporary_roadmap_root(status) as temporary:
                    errors = R11ContractVerifier(
                        Path(temporary)
                    ).check_roadmap_status()
                self.assertEqual(errors, [])

    def test_passed_requires_all_future_evidence_and_deep_verifier(self) -> None:
        with self.temporary_roadmap_root("passed") as temporary:
            errors = R11ContractVerifier(
                Path(temporary)
            ).check_roadmap_status()
        for label in (
            "R11 traceability run receipt",
            "R11 functional execution receipt",
            "R11 functional phase acceptance",
        ):
            self.assertIn(
                f"{label} must be a regular non-symlink file",
                errors,
            )
        self.assertTrue(
            any("deep validation" in error for error in errors),
            errors,
        )

    def test_invalid_roadmap_status_rejects(self) -> None:
        with self.temporary_roadmap_root("blocked") as temporary:
            errors = R11ContractVerifier(
                Path(temporary)
            ).check_roadmap_status()
        self.assertEqual(
            errors,
            [
                "canonical R11 status must be planned, in_progress, "
                "evidence_ready, or passed"
            ],
        )

    def test_strict_decoder_rejects_non_object_and_privacy(self) -> None:
        with self.assertRaisesRegex(R11ContractError, "one JSON object"):
            _decode_payload(b"[]\n", "record")
        with self.assertRaisesRegex(R11ContractError, "email address"):
            _decode_payload(b'{"note":"operator@example.com"}\n', "record")


if __name__ == "__main__":
    unittest.main()
