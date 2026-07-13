from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

import pytest

from validation.calibration_v2.corrective_diagnostics import (
    canonical_artifact_file_bytes,
)
from validation.calibration_v2.corrective_preregistration import (
    CorrectivePreregistrationError,
    build_corrective_preregistration,
    corrective_candidate_binding,
    corrective_dimension_contract_hashes,
    validate_corrective_preregistration,
    verify_attempt_ledger_payload,
)
from validation.calibration_v2.runner import candidate_vector_sha256
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
PLAN = json.loads(
    (ROOT / "validation/calibration_v2/contracts/calibration-plan-v1.json")
    .read_bytes()
)
H = {
    name: hashlib.sha256(name.encode("utf-8")).hexdigest()
    for name in (
        "g04",
        "g05",
        "receipt",
        "report",
        "plan",
        "ledger",
        "tail",
        "guard",
        "runtime",
        "metric",
        "manifest",
        "sample",
        "corpus",
        "status",
        "modified",
    )
}


def directory(path: str, inode: int) -> dict[str, object]:
    return {
        "lexical_path": path,
        "real_path": path,
        "device": 42,
        "inode": inode,
    }


def file_binding(path: str, digest: str, inode: int) -> dict[str, object]:
    return {
        "lexical_path": path,
        "file_sha256": digest,
        "size_bytes": 100 + inode,
        "device": 42,
        "inode": inode,
    }


def bindings(*, tail: str, attempt_count: int) -> dict[str, object]:
    fresh_verification = {
        "schema_version": "1.0.0",
        "artifact_kind": "live_holdout_preopen_verification",
        "verification_status": "pass",
        "access_status": "unopened",
        "access_count": 0,
        "open_intent_anchor_present": False,
        "pixel_content_included": False,
        "live_ledger_sha256": "0" * 64,
        "live_ledger_root_identity_sha256": "1" * 64,
        "live_anchor_root_identity_sha256": "2" * 64,
        "live_preopen_receipt_sha256": "3" * 64,
        "repository_sealed_copy_sha256": "4" * 64,
        "repository_attestation_sha256": "5" * 64,
        "corpus_binding_sha256": "6" * 64,
        "verification_receipt_sha256": "7" * 64,
    }
    return {
        "repository": {
            "root": directory("/repo", 1),
            "git_head_commit": "1" * 40,
            "git_index_tree": "2" * 40,
            "tracked_status_sha256": H["status"],
            "tracked_status_size_bytes": 0,
            "modified_tracked_file_count": 0,
            "modified_tracked_manifest_sha256": H["modified"],
        },
        "g04": {
            "artifact_root": directory("/evidence/g04", 2),
            "manifest": file_binding(
                "/evidence/g04/artifact-manifest.json", "8" * 64, 19
            ),
            "receipt": file_binding("/evidence/g04/receipt.json", H["g04"], 3),
            "report": file_binding("/evidence/g04/report.md", H["report"], 4),
        },
        "g05": {
            "artifact_root": directory("/evidence/g05", 5),
            "manifest": file_binding(
                "/evidence/g05/artifact-manifest.json", "7" * 64, 20
            ),
            "receipt": file_binding("/evidence/g05/receipt.json", H["g05"], 6),
            "report": file_binding("/evidence/g05/report.md", H["receipt"], 7),
        },
        "calibration_plan": {
            "file": file_binding("/repo/plan.json", H["plan"], 8),
            "document_sha256": canonical_sha256(PLAN),
        },
        "failed_run": {
            "archive_root": directory("/evidence/failed", 9),
            "attempt_ledger": file_binding(
                "/evidence/failed/attempts.ndjson", H["ledger"], 10
            ),
            "failure_record": file_binding(
                "/evidence/failed/failure.json", "9" * 64, 16
            ),
            "input_bindings": file_binding(
                "/evidence/failed/input-bindings.json", "a" * 64, 17
            ),
            "transaction_intent": file_binding(
                "/evidence/failed/.calibration-transaction.json", "b" * 64, 18
            ),
            "attempt_count": attempt_count,
            "tail_record_sha256": tail,
            "referenced_binding_count": 10,
            "unique_evaluation_file_count": 2,
            "unique_control_file_count": 4,
            "archive_closure_manifest_sha256": "c" * 64,
        },
        "live_holdout": {
            "live_ledger_path": "/guard/access-ledger.json",
            "live_anchor_path": "/guard/open-intent.json",
            "live_preopen_receipt_path": "/guard/preopen-receipt.json",
            "repository_sealed_copy_path": "/repo/sealed-copy.json",
            "repository_attestation_path": "/repo/attestation.json",
            "expected_live_ledger_root_identity_sha256": "1" * 64,
            "expected_live_anchor_root_identity_sha256": "2" * 64,
            "expected_live_preopen_receipt_sha256": "3" * 64,
            "expected_repository_sealed_copy_sha256": "4" * 64,
            "expected_repository_attestation_sha256": "5" * 64,
            "fresh_verification": fresh_verification,
            "fresh_verification_sha256": canonical_sha256(fresh_verification),
        },
        "development_corpus": {
            "open_split_root": directory("/open/development", 11),
            "corpus_lock_file_sha256": H["corpus"],
            "corpus_lock_manifest_sha256": "6" * 64,
            "development_sample_lock_file_sha256": H["sample"],
            "development_sample_lock_manifest_sha256": "7" * 64,
            "development_sample_count": 6,
            "development_sample_bindings_sha256": "8" * 64,
        },
        "runtime": {
            "native_executable_sha256": "9" * 64,
            "native_source_manifest_sha256": "a" * 64,
            "native_code_identity_sha256": "b" * 64,
            "native_configuration_sha256": "c" * 64,
            "writer_executable_sha256": "d" * 64,
            "writer_product_settings_source_sha256": "e" * 64,
            "writer_settings_sha256": "f" * 64,
            "writer_code_identity_sha256": "0" * 64,
            "coordinate_model_contract_file_sha256": "a" * 64,
            "coordinate_model_contract_sha256": "b" * 64,
            "video_profile_contract_file_sha256": "c" * 64,
            "video_profile_contract_sha256": "d" * 64,
            "quality_harness_implementation_manifest_file_sha256": "1" * 64,
            "quality_harness_implementation_manifest_sha256": "2" * 64,
            "metric_policy_file_sha256": "3" * 64,
            "metric_policy_sha256": "4" * 64,
            "metric_implementation_binding_sha256": H["metric"],
        },
        "execution_roots": {
            "run_id": "corrective-r1",
            "output_root_lexical_path": "/output/corrective-r1",
            "output_parent": directory("/output", 12),
            "work_parent": directory("/work", 13),
            "native_cache_root": directory("/cache/native", 14),
            "writer_root": directory("/cache/writer", 15),
        },
    }


def record(
    sequence: int,
    previous: str,
    **values: object,
) -> dict[str, object]:
    body = {
        "sequence": sequence,
        "previous_record_sha256": previous,
        **values,
    }
    return {**body, "record_sha256": canonical_sha256(body)}


def fixture() -> dict[str, object]:
    vector = deepcopy(PLAN["search"]["initial_vector_values"])
    source_coordinate = "minimum_anisotropic_coherence_unorm15"
    carry_coordinate = "detail_gain_q12"
    source_hash = candidate_vector_sha256(vector, PLAN)
    first = record(
        0,
        "0" * 64,
        split="development",
        phase="initial",
        candidate_vector=vector,
        candidate_vector_sha256=source_hash,
    )
    source = record(
        1,
        str(first["record_sha256"]),
        split="development",
        phase="coordinate_search",
        sweep=1,
        coordinate=source_coordinate,
        value=vector[source_coordinate],
        status="infeasible",
        candidate_vector=vector,
        candidate_vector_sha256=source_hash,
        evaluation={
            "path": "evaluations/source.json",
            "sha256": "a" * 64,
            "size_bytes": 123,
        },
        summary_sha256="b" * 64,
        development_search_rank_sha256="c" * 64,
    )
    carry_vector = deepcopy(vector)
    alternatives = [
        value
        for value in PLAN["ranges"]["operator"][carry_coordinate]
        if value != carry_vector[carry_coordinate]
    ]
    assert alternatives
    carry_vector[carry_coordinate] = alternatives[0]
    carry = record(
        2,
        str(source["record_sha256"]),
        split="development",
        phase="coordinate_search",
        sweep=1,
        coordinate=carry_coordinate,
        value=carry_vector[carry_coordinate],
        status="evaluation_failure",
        candidate_vector=carry_vector,
        candidate_vector_sha256=candidate_vector_sha256(carry_vector, PLAN),
    )
    records = (first, source, carry)
    ledger = b"".join(canonical_json_bytes(row) + b"\n" for row in records)
    expected_bindings = bindings(
        tail=str(carry["record_sha256"]),
        attempt_count=len(records),
    )
    document = build_corrective_preregistration(
        preregistered_utc="2026-07-13T00:00:00Z",
        bindings=expected_bindings,
        candidate_vector=vector,
        plan=PLAN,
        attempt_ledger_payload=ledger,
        expected_source_sequence=1,
        expected_source_record_sha256=str(source["record_sha256"]),
        expected_source_candidate_vector_sha256=source_hash,
        expected_carry_forward_sequence=2,
        expected_carry_forward_record_sha256=str(carry["record_sha256"]),
    )
    payload = canonical_artifact_file_bytes(document)
    return {
        "records": records,
        "ledger": ledger,
        "bindings": expected_bindings,
        "document": document,
        "payload": payload,
        "file_sha256": hashlib.sha256(payload).hexdigest(),
        "source_hash": source_hash,
    }


def validate(data: dict[str, object]) -> Mapping[str, object]:
    records = data["records"]
    assert isinstance(records, tuple)
    source = records[1]
    carry = records[2]
    return validate_corrective_preregistration(
        data["document"],
        artifact_payload=data["payload"],
        expected_artifact_file_sha256=str(data["file_sha256"]),
        expected_bindings=data["bindings"],
        plan=PLAN,
        attempt_ledger_payload=data["ledger"],
        expected_source_sequence=1,
        expected_source_record_sha256=str(source["record_sha256"]),
        expected_source_candidate_vector_sha256=str(data["source_hash"]),
        expected_carry_forward_sequence=2,
        expected_carry_forward_record_sha256=str(carry["record_sha256"]),
        execution_not_before_utc=datetime(2026, 7, 13, 0, 0, 1, tzinfo=timezone.utc),
    )


def test_builder_and_validator_bind_exact_candidate_ledger_and_dimensions() -> None:
    data = fixture()
    reopened = validate(data)
    assert reopened == data["document"]
    assert reopened["candidate"] == corrective_candidate_binding(
        reopened["candidate"]["vector"], PLAN
    )
    assert reopened["dimension_contracts"] == corrective_dimension_contract_hashes()
    assert reopened["incumbent_derivation"]["source_sequence"] == 1
    assert reopened["incumbent_derivation"]["carry_forward_sequence"] == 2
    assert reopened["incumbent_derivation"]["changed_coordinates"] == [
        "detail_gain_q12"
    ]


def test_plan_ordered_hash_is_not_mislabeled_canonical_object_or_file_hash() -> None:
    candidate = fixture()["document"]["candidate"]
    assert len(
        {
            candidate["plan_ordered_vector_sha256"],
            candidate["canonical_vector_object_sha256"],
            candidate["canonical_vector_file_sha256"],
        }
    ) == 3


def test_validator_rejects_post_execution_or_changed_input_binding() -> None:
    data = fixture()
    data["document"] = deepcopy(data["document"])
    data["document"]["preregistered_utc"] = "2026-07-13T00:00:02Z"
    unhashed = dict(data["document"])
    unhashed.pop("artifact_sha256")
    data["document"]["artifact_sha256"] = canonical_sha256(unhashed)
    data["payload"] = canonical_artifact_file_bytes(data["document"])
    data["file_sha256"] = hashlib.sha256(data["payload"]).hexdigest()
    with pytest.raises(CorrectivePreregistrationError, match="after execution"):
        validate(data)

    data = fixture()
    data["bindings"] = deepcopy(data["bindings"])
    data["bindings"]["execution_roots"]["run_id"] = "different"
    with pytest.raises(CorrectivePreregistrationError, match="bindings differ"):
        validate(data)


def test_validator_rejects_bare_vector_or_retargeted_incumbent() -> None:
    data = fixture()
    data["document"] = deepcopy(data["document"])
    data["document"]["candidate"] = data["document"]["candidate"]["vector"]
    data["payload"] = canonical_artifact_file_bytes(data["document"])
    data["file_sha256"] = hashlib.sha256(data["payload"]).hexdigest()
    with pytest.raises(Exception):
        validate(data)

    data = fixture()
    records = data["records"]
    with pytest.raises(CorrectivePreregistrationError, match="anchors differ"):
        validate_corrective_preregistration(
            data["document"],
            artifact_payload=data["payload"],
            expected_artifact_file_sha256=str(data["file_sha256"]),
            expected_bindings=data["bindings"],
            plan=PLAN,
            attempt_ledger_payload=data["ledger"],
            expected_source_sequence=1,
            expected_source_record_sha256="f" * 64,
            expected_source_candidate_vector_sha256=str(data["source_hash"]),
            expected_carry_forward_sequence=2,
            expected_carry_forward_record_sha256=str(records[2]["record_sha256"]),
            execution_not_before_utc=datetime(2026, 7, 13, 0, 0, 1, tzinfo=timezone.utc),
        )


def test_attempt_ledger_rejects_noncanonical_or_broken_chain() -> None:
    data = fixture()
    with pytest.raises(CorrectivePreregistrationError, match="terminal LF"):
        verify_attempt_ledger_payload(data["ledger"].rstrip(b"\n"))

    lines = data["ledger"].splitlines()
    first = json.loads(lines[0])
    noncanonical = json.dumps(first, indent=2).encode("utf-8") + b"\n"
    with pytest.raises(CorrectivePreregistrationError, match="canonical"):
        verify_attempt_ledger_payload(noncanonical)

    broken = bytearray(data["ledger"])
    broken[-66] = ord("0") if broken[-66] != ord("0") else ord("1")
    with pytest.raises(CorrectivePreregistrationError):
        verify_attempt_ledger_payload(bytes(broken))
