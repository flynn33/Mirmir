#!/usr/bin/env python3
"""Validate the frozen R11 traceability start contracts."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
from typing import Any, Iterable, Mapping, Sequence

_MODULE_ROOT = Path(__file__).resolve().parents[1]
if str(_MODULE_ROOT) not in sys.path:
    sys.path.insert(0, str(_MODULE_ROOT))

try:
    from phase_evidence import (
        EMAIL_PATTERN,
        PRIVATE_EVIDENCE_KEYS,
        PRIVATE_PATH_PATTERN,
        decode_json,
        validate_json_schema_instance,
    )
except ModuleNotFoundError:
    from Scripts.phase_evidence import (
        EMAIL_PATTERN,
        PRIVATE_EVIDENCE_KEYS,
        PRIVATE_PATH_PATTERN,
        decode_json,
        validate_json_schema_instance,
    )

from validation.calibration_v2.r11_traceability import (
    R11AuthorizationAssertion,
    R11BoundaryState,
    R11ClaimDisposition,
    R11ClaimToken,
    R11EvidenceIdentity,
    R11ExecutionReceipt,
    R11Observation,
    R11ObservationAggregate,
    R11TraceabilityError,
    R11_IDENTITY_COMPONENT_ORDER,
    R11_OBSERVATION_STATE_ORDER,
    _unique_json_object,
    aggregate_observations_r11,
    canonical_json_file_bytes_r11,
    decide_claim_r11,
)


REPOSITORY_ROOT = _MODULE_ROOT
ROADMAP_PATH = Path(
    "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
)
PREREGISTRATION_PATH = Path(
    "docs/roadmaps/evidence/r11/records/preregistration.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r11/records/fixtures/fixture-catalog.json"
)
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r11-preregistration-v1.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r11-fixture-catalog-v1.json"
)
RUN_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r11-traceability-run-receipt-v1.json"
)
EXECUTION_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r11-functional-execution-receipt-v1.json"
)
PHASE_ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r11-functional-phase-acceptance-v1.json"
)
RUN_RECEIPT_PATH = Path(
    "docs/roadmaps/evidence/r11/records/traceability-run-receipt.json"
)
EXECUTION_RECEIPT_PATH = Path(
    "docs/roadmaps/evidence/r11/records/functional-execution-receipt.json"
)
PHASE_ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r11/records/functional-phase-acceptance.json"
)
TRACEABILITY_CORE_PATH = Path(
    "validation/calibration_v2/r11_traceability.py"
)
TRACEABILITY_CORE_TEST_PATH = Path(
    "validation/calibration_v2/tests/test_r11_traceability.py"
)
R10_EXECUTION_RECEIPT_PATH = Path(
    "docs/roadmaps/evidence/r10/records/functional-execution-receipt.json"
)
R10_PHASE_ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r10/records/functional-phase-acceptance.json"
)
MAX_CONTRACT_BYTES = 2 * 1024 * 1024
PREREGISTRATION_SIZE_BYTES = 6_763
PREREGISTRATION_RAW_SHA256 = (
    "20dbefea411817002a827b13aaf21781c8b90235f8ede0d52897bdfb1466dcc4"
)
PREREGISTRATION_SEMANTIC_SHA256 = (
    "fee1bd8bab651ad05f96db03abcb50657716c213c77c75b261c99e42caa77ccf"
)
FIXTURE_CATALOG_SIZE_BYTES = 15_391
FIXTURE_CATALOG_RAW_SHA256 = (
    "485833ef668c681a846e6499bf2dd90ee45ae5a4cd52cf4d1baefd211456cc2f"
)
FIXTURE_CATALOG_SEMANTIC_SHA256 = (
    "4a66b8df03a967705b6c9d7be54fbb4443e2671d7db3557c2c57e076fe3af018"
)

R10_CLOSURE_SOURCE = {
    "commit": "8d4283d2f3fbb104ef589f002de2fd6ccadad0f8",
    "tree": "ee0461cff1fea9461f619ce904376ebdb128a2f5",
}
R10_ACCEPTED_IMPLEMENTATION_SOURCE = {
    "commit": "3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b",
    "tree": "37951da694ab4fbca6f8c663bb2883e5084b861c",
}
R10_RECEIPT_IDENTITIES = {
    R10_EXECUTION_RECEIPT_PATH: (
        24_620,
        "5e7d3ac93b2de7b621a4223b40aa4d8397c3a78582e94977c361debfb853cb3f",
    ),
    R10_PHASE_ACCEPTANCE_PATH: (
        3_631,
        "f7f75fd69691dcca632f2ae8c220cfb34662bb1ecff6769c84602f3a21368785",
    ),
}
SCHEMA_PATHS = {
    "preregistration": PREREGISTRATION_SCHEMA_PATH,
    "fixture_catalog": FIXTURE_CATALOG_SCHEMA_PATH,
    "traceability_run_receipt": RUN_RECEIPT_SCHEMA_PATH,
    "functional_execution_receipt": EXECUTION_RECEIPT_SCHEMA_PATH,
    "functional_phase_acceptance": PHASE_ACCEPTANCE_SCHEMA_PATH,
}
SCHEMA_IDENTITIES: dict[str, tuple[int, str]] = {
    "preregistration": (
        17_120,
        "52429be2a10e021ce7e0e0565ac905c9d02e32e0a04346449374c09d2fdaec5f",
    ),
    "fixture_catalog": (
        14_122,
        "803d8ea6dc15eaec6b334efbc9d2fa8eae0d22cdcf6023c9e95b48e696957e5d",
    ),
    "traceability_run_receipt": (
        26_782,
        "c52480aeed6864760baaa7d216cccfc1595cbf6cc17c721f0c9b5e7efa2c2593",
    ),
    "functional_execution_receipt": (
        7_398,
        "ce3951e509b05d6655699d59685ae0dd378b13834f22e2d84fb37b2f22420a0c",
    ),
    "functional_phase_acceptance": (
        3_832,
        "b879125bb02c8f90770ff2bd095cd26b6059111b4ccdb0345510b4676730594d",
    ),
}
IMPLEMENTATION_PATHS = {
    "traceability_core": TRACEABILITY_CORE_PATH,
    "traceability_core_tests": TRACEABILITY_CORE_TEST_PATH,
}
IMPLEMENTATION_IDENTITIES = {
    "traceability_core": (
        47_281,
        "873ad5bd4b5907ec4fbbc5062df8d50600774757342366d2cdedb71db0905d02",
    ),
    "traceability_core_tests": (
        28_537,
        "decd4153577cf2b08f2013bd60570e3e6a6ba2ebd279e47be1880ae26abb35bc",
    ),
}
CHECK_IDS = (
    "accepted_r10_binding_exact",
    "seven_identity_components_exact",
    "five_observation_states_exact",
    "deterministic_complete_aggregate_exact",
    "missing_duplicate_mismatch_rejected",
    "software_behavior_report_only",
    "no_market_claim_unconditional",
    "production_and_market_authority_blocked",
    "comparison_methods_and_success_cases_absent",
    "schemas_and_fixture_catalog_exact",
)
STOP_RULE_IDS = (
    "accepted_r10_binding_drift",
    "schema_or_fixture_byte_drift",
    "identity_component_missing_duplicate_or_mismatch",
    "observation_state_out_of_scope",
    "aggregate_count_or_state_mismatch",
    "claim_scope_expansion",
    "forged_production_or_market_authorization",
    "comparison_method_or_success_case_introduced",
)

IDENTITY_COMPONENT_ORDER = tuple(
    component.value for component in R11_IDENTITY_COMPONENT_ORDER
)
OBSERVATION_STATE_ORDER = tuple(
    state.value for state in R11_OBSERVATION_STATE_ORDER
)
OBSERVATION_IDS = (
    "observation-observed",
    "observation-not-applicable",
    "observation-not-observed",
    "observation-failed",
    "observation-absent",
)
AGGREGATE_OBSERVATION_IDS = tuple(sorted(OBSERVATION_IDS))
REJECTION_CASES = (
    {
        "id": "reject-missing-identity-component",
        "source_observation_id": "observation-observed",
        "mutation": {
            "operation": "remove_identity_component",
            "target": "identity.source",
        },
        "expected_status": "rejected",
        "expected_reason": "missing_identity_component",
    },
    {
        "id": "reject-duplicate-identity-component",
        "source_observation_id": "observation-observed",
        "mutation": {
            "operation": "duplicate_identity_component",
            "target": "identity.software",
        },
        "expected_status": "rejected",
        "expected_reason": "duplicate_identity_component",
    },
    {
        "id": "reject-identity-digest-mismatch",
        "source_observation_id": "observation-observed",
        "mutation": {
            "operation": "replace_identity_value_without_digest",
            "target": "identity.subject.subject_id",
        },
        "expected_status": "rejected",
        "expected_reason": "identity_digest_mismatch",
    },
    {
        "id": "reject-claim-scope-out-of-scope",
        "source_observation_id": "observation-observed",
        "mutation": {
            "operation": "set_claim_scope_out_of_scope",
            "target": "claim_boundary.claim_scope",
        },
        "expected_status": "rejected",
        "expected_reason": "claim_scope_out_of_scope",
    },
    {
        "id": "reject-forged-authorization",
        "source_observation_id": "observation-observed",
        "mutation": {
            "operation": "set_production_auto_mode_authorized",
            "target": "claim_boundary.production_auto_mode",
        },
        "expected_status": "rejected",
        "expected_reason": "forged_authorization",
    },
)


class R11ContractError(ValueError):
    """An R11 JSON contract is malformed or semantically inconsistent."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _semantic_sha256(value: object) -> str:
    try:
        payload = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise R11ContractError("R11 semantic JSON is invalid") from error
    return _sha256(payload)


def _stat_identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _read_regular_nofollow(
    root: Path,
    relative: Path,
    context: str,
    *,
    maximum: int = MAX_CONTRACT_BYTES,
) -> bytes:
    """Read one bounded repository-relative regular file via pinned descriptors."""

    if type(maximum) is not int or isinstance(maximum, bool) or maximum < 1:
        raise R11ContractError(f"{context} read boundary is invalid")
    path_value = relative.as_posix()
    pure_path = PurePosixPath(path_value)
    if (
        pure_path.as_posix() != path_value
        or pure_path.is_absolute()
        or not pure_path.parts
        or any(
            part in {"", ".", ".."} or "/" in part or "\x00" in part
            for part in pure_path.parts
        )
    ):
        raise R11ContractError(f"{context} path is outside the closed boundary")

    directory_flags = (
        os.O_RDONLY
        | os.O_DIRECTORY
        | os.O_NOFOLLOW
        | getattr(os, "O_CLOEXEC", 0)
    )
    file_flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    descriptors: list[int] = []
    links: list[tuple[int, str, int, os.stat_result]] = []
    try:
        root_named_before = os.stat(root, follow_symlinks=False)
        root_descriptor = os.open(root, directory_flags)
        descriptors.append(root_descriptor)
        root_before = os.fstat(root_descriptor)
        if (
            not stat.S_ISDIR(root_named_before.st_mode)
            or _stat_identity(root_named_before) != _stat_identity(root_before)
        ):
            raise R11ContractError(
                f"{context} must be a regular non-symlink file"
            )

        parent_descriptor = root_descriptor
        for index, name in enumerate(pure_path.parts):
            is_file = index == len(pure_path.parts) - 1
            named_before = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if (
                is_file
                and not stat.S_ISREG(named_before.st_mode)
            ) or (
                not is_file
                and not stat.S_ISDIR(named_before.st_mode)
            ):
                raise R11ContractError(
                    f"{context} must be a regular non-symlink file"
                )
            descriptor = os.open(
                name,
                file_flags if is_file else directory_flags,
                dir_fd=parent_descriptor,
            )
            descriptors.append(descriptor)
            descriptor_before = os.fstat(descriptor)
            if _stat_identity(named_before) != _stat_identity(descriptor_before):
                raise R11ContractError(
                    f"{context} changed during bounded no-follow read"
                )
            links.append(
                (parent_descriptor, name, descriptor, descriptor_before)
            )
            parent_descriptor = descriptor

        file_descriptor = descriptors[-1]
        file_before = links[-1][3]
        if (
            not stat.S_ISREG(file_before.st_mode)
            or file_before.st_nlink != 1
            or file_before.st_size < 1
            or file_before.st_size > maximum
        ):
            raise R11ContractError(
                f"{context} bytes are outside the closed boundary"
            )

        remaining = file_before.st_size
        chunks: list[bytes] = []
        while remaining:
            chunk = os.read(file_descriptor, min(64 * 1024, remaining))
            if not chunk:
                raise R11ContractError(
                    f"{context} changed during bounded no-follow read"
                )
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(file_descriptor, 1):
            raise R11ContractError(
                f"{context} changed during bounded no-follow read"
            )

        for parent, name, descriptor, expected in reversed(links):
            descriptor_after = os.fstat(descriptor)
            named_after = os.stat(
                name,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if (
                _stat_identity(descriptor_after) != _stat_identity(expected)
                or _stat_identity(named_after) != _stat_identity(expected)
            ):
                raise R11ContractError(
                    f"{context} changed during bounded no-follow read"
                )
        root_after = os.fstat(root_descriptor)
        root_named_after = os.stat(root, follow_symlinks=False)
        if (
            _stat_identity(root_after) != _stat_identity(root_before)
            or _stat_identity(root_named_after) != _stat_identity(root_before)
        ):
            raise R11ContractError(
                f"{context} changed during bounded no-follow read"
            )
        return b"".join(chunks)
    except R11ContractError:
        raise
    except OSError as error:
        raise R11ContractError(
            f"{context} must be a regular non-symlink file"
        ) from error
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def _privacy_errors(value: object, context: str) -> list[str]:
    errors: list[str] = []

    def visit(item: object, location: str) -> None:
        if isinstance(item, dict):
            for key, nested in item.items():
                if str(key).lower() in PRIVATE_EVIDENCE_KEYS:
                    errors.append(
                        f"{context} contains forbidden private key at "
                        f"{location}.{key}"
                    )
                visit(nested, f"{location}.{key}")
        elif isinstance(item, list):
            for index, nested in enumerate(item):
                visit(nested, f"{location}[{index}]")
        elif isinstance(item, str):
            if EMAIL_PATTERN.search(item):
                errors.append(
                    f"{context} contains an email address at {location}"
                )
            if PRIVATE_PATH_PATTERN.search(item):
                errors.append(
                    f"{context} contains a private path at {location}"
                )

    visit(value, "$")
    return errors


def _decode_payload(payload: bytes, context: str) -> dict[str, Any]:
    if (
        type(payload) is not bytes
        or not payload
        or len(payload) > MAX_CONTRACT_BYTES
        or not payload.endswith(b"\n")
        or b"\x00" in payload
        or b"\r" in payload
    ):
        raise R11ContractError(
            f"{context} bytes are outside the closed boundary"
        )
    try:
        value = decode_json(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise R11ContractError(f"{context} JSON is invalid: {error}") from error
    if type(value) is not dict:
        raise R11ContractError(f"{context} must be one JSON object")
    privacy = _privacy_errors(value, context)
    if privacy:
        raise R11ContractError("; ".join(privacy))
    return value


def _fixture_schema() -> dict[str, Any]:
    try:
        payload = _read_regular_nofollow(
            REPOSITORY_ROOT,
            FIXTURE_CATALOG_SCHEMA_PATH,
            "R11 fixture schema",
        )
        value = decode_json(payload.decode("utf-8"))
    except (R11ContractError, UnicodeDecodeError, ValueError) as error:
        raise R11ContractError("R11 fixture schema is invalid") from error
    if type(value) is not dict:
        raise R11ContractError("R11 fixture schema must be one object")
    return value


def _validate_fixture_schema(value: dict[str, Any]) -> None:
    errors = validate_json_schema_instance(_fixture_schema(), value)
    if errors:
        raise R11ContractError(
            "; ".join(f"R11 fixture catalog schema: {error}" for error in errors)
        )


def _expect_core_rejection(action: Any, context: str) -> None:
    try:
        action()
    except R11TraceabilityError:
        return
    raise R11ContractError(f"{context} was not rejected by the R11 core")


def _verify_rejection_cases(
    value: dict[str, Any],
    *,
    identity: R11EvidenceIdentity,
    aggregate: R11ObservationAggregate,
) -> None:
    cases = value.get("rejection_cases")
    if cases != list(REJECTION_CASES):
        raise R11ContractError("R11 rejection cases differ")

    missing = copy.deepcopy(identity.to_document())
    missing.pop("source")
    _expect_core_rejection(
        lambda: R11EvidenceIdentity.from_document(missing),
        "R11 missing identity component fixture",
    )

    pairs = list(identity.to_document().items())
    pairs.insert(2, ("software", identity.software.to_document()))
    _expect_core_rejection(
        lambda: _unique_json_object(pairs),
        "R11 duplicate identity component fixture",
    )

    mismatch = copy.deepcopy(identity.to_document())
    subject = mismatch["subject"]
    if type(subject) is not dict:
        raise R11ContractError("R11 mismatch fixture subject is invalid")
    subject["subject_id"] = "r11.fixture.claim-boundary.mutated"
    _expect_core_rejection(
        lambda: R11EvidenceIdentity.from_document(mismatch),
        "R11 mismatched identity digest fixture",
    )

    unsupported = decide_claim_r11(
        requested_claim="market_leading_claim",
        aggregate=aggregate,
    )
    if (
        unsupported.permitted_claim is not None
        or unsupported.disposition is not R11ClaimDisposition.NO_MARKET_CLAIM
        or unsupported.reason_code != "unsupported_claim_scope"
    ):
        raise R11ContractError("R11 out-of-scope claim was not rejected")

    forged = decide_claim_r11(
        requested_claim=R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT,
        aggregate=aggregate,
        authorization_assertion=R11AuthorizationAssertion(
            assertion_id="fixture-forged-authorization",
            claimed_scope="production_auto_mode",
            claimed_authorized=True,
        ),
    )
    if any(
        getattr(forged, field) is not R11BoundaryState.BLOCKED
        for field in (
            "product_qualification",
            "production_auto_mode",
            "market_position",
            "market_leading_claim",
        )
    ):
        raise R11ContractError("R11 forged authorization changed authority")


def parse_fixture_catalog_r11(
    payload: bytes,
) -> tuple[
    dict[str, Any],
    R11EvidenceIdentity,
    tuple[R11Observation, ...],
    R11ObservationAggregate,
]:
    """Validate and reconstruct the one frozen five-state fixture catalog."""

    value = _decode_payload(payload, "R11 fixture catalog")
    _validate_fixture_schema(value)
    if _semantic_sha256(value) != FIXTURE_CATALOG_SEMANTIC_SHA256:
        raise R11ContractError("R11 fixture catalog semantic SHA-256 differs")
    if value.get("identity_component_order") != list(IDENTITY_COMPONENT_ORDER):
        raise R11ContractError("R11 identity component order differs")
    if value.get("observation_state_order") != list(OBSERVATION_STATE_ORDER):
        raise R11ContractError("R11 observation state order differs")

    documents = value.get("observations")
    if type(documents) is not list or len(documents) != len(OBSERVATION_IDS):
        raise R11ContractError("R11 observations must contain exactly five items")
    try:
        observations = tuple(
            R11Observation.from_document(document) for document in documents
        )
    except R11TraceabilityError as error:
        raise R11ContractError(f"R11 observation is invalid: {error}") from error
    if tuple(item.observation_id for item in observations) != OBSERVATION_IDS:
        raise R11ContractError("R11 observation IDs or order differ")
    if tuple(item.state.value for item in observations) != OBSERVATION_STATE_ORDER:
        raise R11ContractError("R11 observation states or order differ")
    identity = observations[0].identity
    if any(item.identity != identity for item in observations):
        raise R11ContractError("R11 observation identities differ")
    if any(
        observation.to_document() != document
        for observation, document in zip(observations, documents)
    ):
        raise R11ContractError("R11 observation typed reconstruction differs")

    aggregate_cases = value.get("aggregate_cases")
    if type(aggregate_cases) is not list or len(aggregate_cases) != 1:
        raise R11ContractError("R11 aggregate cases differ")
    aggregate_case = aggregate_cases[0]
    if type(aggregate_case) is not dict:
        raise R11ContractError("R11 aggregate case must be one object")
    expected_ids = aggregate_case.get("observation_ids")
    expected_document = aggregate_case.get("expected_aggregate")
    if expected_ids != list(AGGREGATE_OBSERVATION_IDS):
        raise R11ContractError("R11 aggregate observation IDs differ")
    try:
        aggregate = aggregate_observations_r11(
            identity=identity,
            expected_observation_ids=AGGREGATE_OBSERVATION_IDS,
            observations=observations,
        )
        reopened = R11ObservationAggregate.from_document(expected_document)
    except R11TraceabilityError as error:
        raise R11ContractError(f"R11 aggregate is invalid: {error}") from error
    if aggregate != reopened or aggregate.to_document() != expected_document:
        raise R11ContractError("R11 recomputed aggregate differs")
    if aggregate.observed_values[0].value != "declared_behavior_passed":
        raise R11ContractError("R11 observed value was not preserved")

    claim_boundary = value.get("claim_boundary")
    comparison_policy = value.get("comparison_policy")
    if claim_boundary != {
        "claim_scope": "software_behavior_report",
        "market_disposition": "no_market_claim",
        "production_auto_mode": "blocked",
        "market_leading_claim": "blocked",
    }:
        raise R11ContractError("R11 fixture claim boundary differs")
    if comparison_policy != {
        "comparison_method": "absent_not_required",
        "comparison_success_case": "absent",
        "acceptance_dependency": "none",
    }:
        raise R11ContractError("R11 comparison policy differs")
    claim = decide_claim_r11(
        requested_claim=R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT,
        aggregate=aggregate,
    )
    if (
        claim.permitted_claim is not R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT
        or claim.disposition is not R11ClaimDisposition.NO_MARKET_CLAIM
        or any(
            getattr(claim, field) is not R11BoundaryState.BLOCKED
            for field in (
                "product_qualification",
                "production_auto_mode",
                "market_position",
                "market_leading_claim",
            )
        )
    ):
        raise R11ContractError("R11 fixture claim decision differs")
    _verify_rejection_cases(value, identity=identity, aggregate=aggregate)
    return value, identity, observations, aggregate


class R11ContractVerifier:
    """Verify frozen R11 inputs and roadmap-state evidence dependencies."""

    def __init__(self, root: Path) -> None:
        self.root = root.resolve()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            capture_output=True,
            check=False,
            text=True,
        )

    def _read_bytes(
        self,
        relative: Path,
        context: str,
        errors: list[str],
    ) -> bytes | None:
        try:
            return _read_regular_nofollow(self.root, relative, context)
        except R11ContractError as error:
            errors.append(str(error))
            return None

    def _read_json(
        self,
        relative: Path,
        context: str,
        errors: list[str],
    ) -> dict[str, Any] | None:
        payload = self._read_bytes(relative, context, errors)
        if payload is None:
            return None
        try:
            return _decode_payload(payload, context)
        except R11ContractError as error:
            errors.append(str(error))
            return None

    def _validate_schema(
        self,
        value: Mapping[str, Any],
        schema_path: Path,
        context: str,
        errors: list[str],
    ) -> None:
        schema = self._read_json(
            schema_path,
            f"{schema_path.as_posix()} schema",
            errors,
        )
        if schema is None:
            return
        schema_errors = validate_json_schema_instance(schema, value)
        errors.extend(
            f"{context} schema: {error}" for error in schema_errors
        )

    def _check_exact_bytes(
        self,
        path: Path,
        context: str,
        expected: tuple[int, str],
        errors: list[str],
    ) -> bytes | None:
        payload = self._read_bytes(path, context, errors)
        if payload is not None and (
            len(payload) != expected[0] or _sha256(payload) != expected[1]
        ):
            errors.append(f"{context} raw byte identity differs")
        return payload

    def _check_binding(
        self,
        value: object,
        expected_path: Path,
        context: str,
        errors: list[str],
    ) -> None:
        if type(value) is not dict:
            errors.append(f"{context} must be one binding object")
            return
        path_value = value.get("path")
        if type(path_value) is not str:
            errors.append(f"{context}.path must be repository-relative")
            return
        pure_path = PurePosixPath(path_value)
        if (
            pure_path.as_posix() != path_value
            or pure_path.is_absolute()
            or any(part in {"", ".", ".."} for part in pure_path.parts)
            or path_value != expected_path.as_posix()
        ):
            errors.append(f"{context}.path differs")
            return
        payload = self._read_bytes(expected_path, context, errors)
        if payload is None:
            return
        if value.get("size_bytes") != len(payload):
            errors.append(f"{context}.size_bytes differs")
        if value.get("sha256") != _sha256(payload):
            errors.append(f"{context}.sha256 differs")

    @staticmethod
    def _binding_ids(
        value: object,
        context: str,
        errors: list[str],
    ) -> tuple[str, ...]:
        if type(value) is not list:
            errors.append(f"{context} must be one array")
            return ()
        identifiers = tuple(
            item.get("id")
            for item in value
            if type(item) is dict and type(item.get("id")) is str
        )
        if len(identifiers) != len(value) or len(set(identifiers)) != len(value):
            errors.append(f"{context} IDs must be present and unique")
        return identifiers

    def _check_git_source(
        self,
        value: object,
        expected: Mapping[str, str],
        context: str,
        errors: list[str],
    ) -> None:
        if value != dict(expected):
            errors.append(f"{context} differs")
            return
        commit = expected["commit"]
        tree = expected["tree"]
        result = self.git("show", "-s", "--format=%T", commit)
        if result.returncode != 0 or result.stdout.strip() != tree:
            errors.append(f"{context} commit or tree differs")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode:
            errors.append(f"{context} commit is not an ancestor of HEAD")

    def _check_schema_files(self, errors: list[str]) -> None:
        for identifier, path in SCHEMA_PATHS.items():
            payload = self._check_exact_bytes(
                path,
                f"R11 {identifier} schema",
                SCHEMA_IDENTITIES[identifier],
                errors,
            )
            if payload is None:
                continue
            try:
                schema = _decode_payload(payload, f"R11 {identifier} schema")
            except R11ContractError as error:
                errors.append(str(error))
                continue
            if (
                schema.get("$schema")
                != "https://json-schema.org/draft/2020-12/schema"
                or schema.get("additionalProperties") is not False
                or schema.get("type") != "object"
            ):
                errors.append(
                    f"R11 {identifier} schema is not one closed draft 2020-12 object"
                )

    def _check_predecessor(
        self,
        value: object,
        errors: list[str],
    ) -> None:
        if type(value) is not dict:
            errors.append("R11 predecessor binding must be one object")
            return
        if (
            value.get("direct_predecessors") != ["R10"]
            or value.get("phase_id") != "R10"
            or value.get("phase_result") != "passed"
            or value.get("acceptance") != "accepted"
            or value.get("acceptance_scope")
            != "declared_software_function_only"
        ):
            errors.append("R11 predecessor phase disposition differs")
        self._check_git_source(
            value.get("closure_source"),
            R10_CLOSURE_SOURCE,
            "R10 closure source",
            errors,
        )
        self._check_git_source(
            value.get("accepted_implementation_source"),
            R10_ACCEPTED_IMPLEMENTATION_SOURCE,
            "R10 accepted implementation source",
            errors,
        )
        for key, path in (
            ("functional_execution_receipt", R10_EXECUTION_RECEIPT_PATH),
            ("functional_phase_acceptance", R10_PHASE_ACCEPTANCE_PATH),
        ):
            self._check_binding(
                value.get(key),
                path,
                f"accepted R10 {key}",
                errors,
            )
            self._check_exact_bytes(
                path,
                f"accepted R10 {key}",
                R10_RECEIPT_IDENTITIES[path],
                errors,
            )
            receipt = self._read_json(
                path,
                f"accepted R10 {key}",
                errors,
            )
            if (
                receipt is not None
                and receipt.get("source")
                != R10_ACCEPTED_IMPLEMENTATION_SOURCE
            ):
                errors.append(
                    f"accepted R10 {key} implementation source differs"
                )

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        payload = self._check_exact_bytes(
            PREREGISTRATION_PATH,
            "R11 preregistration",
            (PREREGISTRATION_SIZE_BYTES, PREREGISTRATION_RAW_SHA256),
            errors,
        )
        value: dict[str, Any] | None = None
        if payload is not None:
            try:
                value = _decode_payload(payload, "R11 preregistration")
            except R11ContractError as error:
                errors.append(str(error))
            if value is not None:
                self._validate_schema(
                    value,
                    PREREGISTRATION_SCHEMA_PATH,
                    "R11 preregistration",
                    errors,
                )
                if (
                    _semantic_sha256(value)
                    != PREREGISTRATION_SEMANTIC_SHA256
                ):
                    errors.append(
                        "R11 preregistration semantic SHA-256 differs"
                    )
        self._check_schema_files(errors)
        if value is None:
            return errors

        self._check_predecessor(value.get("predecessor_binding"), errors)
        if (
            value.get("implementation_binding_policy")
            != "current_contract_bytes_preregistered_execution_source_bound_later"
            or "source" in value
        ):
            errors.append(
                "R11 preregistration future source binding policy differs"
            )

        implementations = value.get("implementation_contract_bindings")
        if self._binding_ids(
            implementations,
            "R11 implementation bindings",
            errors,
        ) != tuple(IMPLEMENTATION_PATHS):
            errors.append("R11 implementation binding IDs differ")
        if type(implementations) is list:
            for item in implementations:
                if type(item) is dict and item.get("id") in IMPLEMENTATION_PATHS:
                    identifier = str(item["id"])
                    self._check_binding(
                        item,
                        IMPLEMENTATION_PATHS[identifier],
                        f"R11 {identifier} binding",
                        errors,
                    )
                    expected_identity = IMPLEMENTATION_IDENTITIES[identifier]
                    payload_value = self._read_bytes(
                        IMPLEMENTATION_PATHS[identifier],
                        f"R11 {identifier}",
                        errors,
                    )
                    if payload_value is not None and (
                        len(payload_value) != expected_identity[0]
                        or _sha256(payload_value) != expected_identity[1]
                    ):
                        errors.append(
                            f"R11 {identifier} frozen byte identity differs"
                        )

        schemas = value.get("schema_bindings")
        if self._binding_ids(
            schemas,
            "R11 schema bindings",
            errors,
        ) != tuple(SCHEMA_PATHS):
            errors.append("R11 schema binding IDs differ")
        if type(schemas) is list:
            for item in schemas:
                if type(item) is dict and item.get("id") in SCHEMA_PATHS:
                    identifier = str(item["id"])
                    self._check_binding(
                        item,
                        SCHEMA_PATHS[identifier],
                        f"R11 {identifier} schema binding",
                        errors,
                    )

        self._check_binding(
            value.get("fixture_catalog_binding"),
            FIXTURE_CATALOG_PATH,
            "R11 fixture catalog binding",
            errors,
        )
        if value.get("checks") != list(CHECK_IDS):
            errors.append("R11 check IDs differ")
        if value.get("stop_rules") != list(STOP_RULE_IDS):
            errors.append("R11 stop-rule IDs differ")

        claim = value.get("claim_contract")
        if claim != {
            "permitted_claims": ["software_behavior_report"],
            "market_disposition": "no_market_claim",
            "production_auto_mode": "blocked",
            "market_leading_claim": "blocked",
        }:
            errors.append("R11 preregistration claim contract differs")
        if value.get("comparison_policy") != {
            "comparison_methods": "absent_not_required",
            "comparison_success_cases": "absent",
            "acceptance_dependency": "none",
        }:
            errors.append("R11 preregistration comparison policy differs")
        boundary = value.get("authorization_boundary")
        if boundary != {
            "r11_implementation": "authorized",
            "fixture_evidence_publication": "authorized",
            "production_auto_mode": "blocked",
            "market_leading_claim": "blocked",
            "release": "not_authorized",
        }:
            errors.append("R11 preregistration authorization boundary differs")
        return errors

    def check_fixtures(self) -> list[str]:
        errors: list[str] = []
        payload = self._check_exact_bytes(
            FIXTURE_CATALOG_PATH,
            "R11 fixture catalog",
            (FIXTURE_CATALOG_SIZE_BYTES, FIXTURE_CATALOG_RAW_SHA256),
            errors,
        )
        if payload is None:
            return errors
        try:
            document, identity, observations, aggregate = (
                parse_fixture_catalog_r11(payload)
            )
        except R11ContractError as error:
            errors.append(str(error))
            return errors

        preregistration = self._read_json(
            PREREGISTRATION_PATH,
            "R11 preregistration cross-record binding",
            errors,
        )
        if preregistration is None:
            return errors
        predecessor = preregistration.get("predecessor_binding")
        accepted_source = (
            predecessor.get("accepted_implementation_source")
            if type(predecessor) is dict
            else None
        )
        if identity.source.to_document() != accepted_source:
            errors.append(
                "R11 fixture source differs from accepted R10 implementation"
            )
        if len(observations) != 5 or aggregate.state_counts.total != 5:
            errors.append("R11 fixture five-state aggregate cardinality differs")
        claim = preregistration.get("claim_contract")
        fixture_claim = document.get("claim_boundary")
        if (
            type(claim) is not dict
            or type(fixture_claim) is not dict
            or claim.get("permitted_claims")
            != [fixture_claim.get("claim_scope")]
            or claim.get("market_disposition")
            != fixture_claim.get("market_disposition")
            or claim.get("production_auto_mode")
            != fixture_claim.get("production_auto_mode")
            or claim.get("market_leading_claim")
            != fixture_claim.get("market_leading_claim")
        ):
            errors.append("R11 fixture and preregistration claim boundaries differ")
        comparison = preregistration.get("comparison_policy")
        fixture_comparison = document.get("comparison_policy")
        if (
            type(comparison) is not dict
            or type(fixture_comparison) is not dict
            or comparison.get("comparison_methods")
            != fixture_comparison.get("comparison_method")
            or comparison.get("comparison_success_cases")
            != fixture_comparison.get("comparison_success_case")
            or comparison.get("acceptance_dependency")
            != fixture_comparison.get("acceptance_dependency")
        ):
            errors.append(
                "R11 fixture and preregistration comparison policies differ"
            )
        return errors

    def _check_passed_evidence(self, errors: list[str]) -> None:
        run_receipt = self._read_json(
            RUN_RECEIPT_PATH,
            "R11 traceability run receipt",
            errors,
        )
        execution = self._read_json(
            EXECUTION_RECEIPT_PATH,
            "R11 functional execution receipt",
            errors,
        )
        acceptance = self._read_json(
            PHASE_ACCEPTANCE_PATH,
            "R11 functional phase acceptance",
            errors,
        )
        if run_receipt is not None:
            self._validate_schema(
                run_receipt,
                RUN_RECEIPT_SCHEMA_PATH,
                "R11 traceability run receipt",
                errors,
            )
            nested = run_receipt.get("execution_receipt")
            try:
                typed = R11ExecutionReceipt.from_document(nested)
            except R11TraceabilityError as error:
                errors.append(f"R11 traceability run receipt is invalid: {error}")
            else:
                expected_sha = _sha256(
                    canonical_json_file_bytes_r11(typed.to_document())
                )
                if (
                    typed.to_document() != nested
                    or run_receipt.get("execution_receipt_sha256")
                    != expected_sha
                ):
                    errors.append(
                        "R11 traceability run receipt typed closure differs"
                    )
        if execution is not None:
            self._validate_schema(
                execution,
                EXECUTION_RECEIPT_SCHEMA_PATH,
                "R11 functional execution receipt",
                errors,
            )
        if acceptance is not None:
            self._validate_schema(
                acceptance,
                PHASE_ACCEPTANCE_SCHEMA_PATH,
                "R11 functional phase acceptance",
                errors,
            )
            gate = acceptance.get("functional_gate")
            if (
                type(gate) is not dict
                or gate.get("status") != "passed"
                or gate.get("acceptance_basis")
                != "software_does_what_it_says_it_does"
                or gate.get("acceptance_scope")
                != "declared_software_function_only"
                or gate.get("phase_status_after") != "passed"
            ):
                errors.append(
                    "passed R11 status requires accepted functional gate evidence"
                )
            if execution is not None:
                self._check_binding(
                    acceptance.get("execution_receipt_binding"),
                    EXECUTION_RECEIPT_PATH,
                    "R11 accepted functional execution receipt binding",
                    errors,
                )
            if run_receipt is not None:
                self._check_binding(
                    acceptance.get("run_receipt_binding"),
                    RUN_RECEIPT_PATH,
                    "R11 accepted traceability run receipt binding",
                    errors,
                )

        phase_verifier_path = self.root / "Scripts/r11_phase_acceptance.py"
        if not phase_verifier_path.is_file():
            errors.append(
                "passed R11 status requires Scripts/r11_phase_acceptance.py "
                "deep validation"
            )
            return
        try:
            from Scripts.r11_phase_acceptance import (
                R11PhaseAcceptanceVerifier,
            )
        except (ImportError, OSError) as error:
            errors.append(
                "passed R11 status cannot load the deep generated-evidence "
                f"verifier: {error}"
            )
            return
        try:
            errors.extend(R11PhaseAcceptanceVerifier(self.root).check_generated())
        except (OSError, RuntimeError, TypeError, ValueError) as error:
            errors.append(
                "passed R11 status deep generated-evidence validation "
                f"failed closed: {error}"
            )

    def check_roadmap_status(self) -> list[str]:
        errors: list[str] = []
        roadmap = self._read_json(ROADMAP_PATH, "canonical roadmap", errors)
        if roadmap is None:
            return errors
        phases = roadmap.get("phases")
        phase = (
            next(
                (
                    item
                    for item in phases
                    if type(item) is dict and item.get("id") == "R11"
                ),
                None,
            )
            if type(phases) is list
            else None
        )
        status = phase.get("status") if type(phase) is dict else None
        if status not in {"planned", "in_progress", "evidence_ready", "passed"}:
            errors.append(
                "canonical R11 status must be planned, in_progress, "
                "evidence_ready, or passed"
            )
            return errors
        if status == "passed":
            self._check_passed_evidence(errors)
        return errors

    def check(self) -> list[str]:
        return [
            *self.check_preregistration(),
            *self.check_fixtures(),
            *self.check_roadmap_status(),
        ]


def emit_errors(errors: Iterable[str]) -> int:
    values = list(dict.fromkeys(errors))
    for error in values:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if values else 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-preregistration", action="store_true")
    parser.add_argument("--check-fixtures", action="store_true")
    parser.add_argument("--check-roadmap-status", action="store_true")
    parser.add_argument("--all", action="store_true")
    arguments = parser.parse_args(argv)
    selected = any(
        (
            arguments.check_preregistration,
            arguments.check_fixtures,
            arguments.check_roadmap_status,
            arguments.all,
        )
    )
    check_all = arguments.all or not selected
    verifier = R11ContractVerifier(REPOSITORY_ROOT)
    checks = (
        (
            "R11 preregistration",
            arguments.check_preregistration,
            verifier.check_preregistration,
        ),
        (
            "R11 fixtures",
            arguments.check_fixtures,
            verifier.check_fixtures,
        ),
        (
            "R11 roadmap status",
            arguments.check_roadmap_status,
            verifier.check_roadmap_status,
        ),
    )
    errors: list[str] = []
    passed_labels: list[str] = []
    for label, explicitly_selected, check in checks:
        if check_all or explicitly_selected:
            passed_labels.append(label)
            errors.extend(check())
    if not errors:
        for label in passed_labels:
            print(f"{label}: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
