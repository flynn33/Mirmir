from __future__ import annotations

from copy import deepcopy
from dataclasses import fields
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
from tempfile import TemporaryDirectory
import unittest

from jsonschema import Draft202012Validator

from validation.calibration_v2.calibration_plan_codec import (
    candidate_vector_sha256_v2,
    materialize_candidate_vector_v2,
    parse_calibration_plan_v2,
)
from validation.calibration_v2.control_evidence_publisher_v2 import (
    ControlEvidencePublisherV2Error,
    RawControlAuthorizationArtifactPublisherV2,
)
from validation.calibration_v2.production_evaluator import (
    ControlExecutionProducerIdentityV2,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
CONTRACT_PATH = (
    CALIBRATION_ROOT
    / "contracts/control-execution-producer-identity-v2.json"
)
SCHEMA_PATH = (
    CALIBRATION_ROOT
    / "schemas/control-execution-producer-identity-v2.schema.json"
)
PLAN_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v2.json"

EXPECTED_CONTRACT_SELF_SHA256 = (
    "dc76d231d0b90a663153678b5651da9eead185eee622897c89e30951603f40f5"
)
EXPECTED_CONTRACT_FILE_SHA256 = (
    "9de7970c089e3ef6627a81c5e8a23c29e3ca7567b8d868058de52108b53a5363"
)
EXPECTED_SCHEMA_FILE_SHA256 = (
    "99032fc9490d5b41f2e9793ab99fb8d9cda2b5d6cd0ff7f9b367c6f4b2d96c46"
)
EXPECTED_SOURCE_SET = (
    (
        0,
        "validation/calibration_v2/native_adapter/factory.py",
        "native_adapter_builder_session_replay",
    ),
    (
        1,
        "validation/calibration_v2/production_evaluator.py",
        "control_execution_identity_and_evaluator_interface",
    ),
    (
        2,
        "validation/calibration_v2/production_providers.py",
        "concrete_control_execution_capability_provider",
    ),
)
EXPECTED_ADAPTER_IDENTITY_FIELDS = (
    "adapter_configuration_sha256",
    "native_executable_sha256",
    "native_implementation_source_sha256",
    "native_source_manifest_sha256",
)
EXPECTED_CARRIER_FIELDS = (
    "physical_candidate_items_bytes",
    "candidate_vector_sha256",
    "adapter_configuration_sha256",
    "authenticated_adapter_identity_bytes",
)


def _reject_duplicate_pairs(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _load_strict_object(path: Path) -> dict[str, object]:
    value = json.loads(
        path.read_bytes(),
        object_pairs_hook=_reject_duplicate_pairs,
        parse_constant=lambda value: (_ for _ in ()).throw(
            ValueError(f"nonfinite JSON number: {value}")
        ),
    )
    if type(value) is not dict:
        raise AssertionError(f"expected exact JSON object: {path}")
    return value


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _stable_identity(status: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        status.st_dev,
        status.st_ino,
        stat.S_IFMT(status.st_mode),
        status.st_size,
        status.st_mtime_ns,
        status.st_ctime_ns,
    )


def _read_repository_regular_file(root: Path, relative: PurePosixPath) -> bytes:
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    file_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    root_descriptor = os.open(root, directory_flags)
    parent_descriptor = root_descriptor
    opened_parents: list[int] = []
    descriptor: int | None = None
    try:
        try:
            for component in relative.parts[:-1]:
                child = os.open(
                    component,
                    directory_flags,
                    dir_fd=parent_descriptor,
                )
                opened_parents.append(child)
                parent_descriptor = child
            name = relative.parts[-1]
            before = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            descriptor = os.open(name, file_flags, dir_fd=parent_descriptor)
            opened = os.fstat(descriptor)
        except OSError as error:
            raise ValueError("source path is not a no-follow regular file") from error
        if (
            not stat.S_ISREG(before.st_mode)
            or not stat.S_ISREG(opened.st_mode)
            or _stable_identity(before) != _stable_identity(opened)
        ):
            raise ValueError("source is not an exact regular file")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        payload = b"".join(chunks)
        after_descriptor = os.fstat(descriptor)
        after_path = os.stat(
            name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (
            not payload
            or len(payload) != opened.st_size
            or _stable_identity(opened) != _stable_identity(after_descriptor)
            or _stable_identity(opened) != _stable_identity(after_path)
        ):
            raise ValueError("source changed while read")
        return payload
    finally:
        if descriptor is not None:
            os.close(descriptor)
        for opened_parent in reversed(opened_parents):
            os.close(opened_parent)
        os.close(root_descriptor)


def _validated_source_manifest(
    source_set: object,
    *,
    domain_separator: str,
    schema_version: str,
    implementation_role: str,
    root: Path = ROOT,
) -> tuple[dict[str, object], bytes, str]:
    if type(source_set) is not list or len(source_set) != 3:
        raise ValueError("source set differs")
    observed_paths: list[str] = []
    observed_roles: list[str] = []
    records: list[dict[str, object]] = []
    for index, row in enumerate(source_set):
        if type(row) is not dict or set(row) != {"order", "path", "role"}:
            raise ValueError("source row differs")
        order = row["order"]
        path_value = row["path"]
        role = row["role"]
        if type(order) is not int or order != index:
            raise ValueError("source order differs")
        if type(path_value) is not str or type(role) is not str or not role:
            raise ValueError("source path or role differs")
        if "\\" in path_value:
            raise ValueError("source path uses a Windows separator")
        relative = PurePosixPath(path_value)
        if (
            relative.is_absolute()
            or not relative.parts
            or relative.as_posix() != path_value
            or any(part in {"", ".", ".."} for part in relative.parts)
        ):
            raise ValueError("source path escapes or is not normalized")
        if path_value in observed_paths or path_value.casefold() in {
            prior.casefold() for prior in observed_paths
        }:
            raise ValueError("source path repeats")
        if role in observed_roles:
            raise ValueError("source role repeats")
        payload = _read_repository_regular_file(root, relative)
        observed_paths.append(path_value)
        observed_roles.append(role)
        records.append(
            {
                "order": index,
                "path": path_value,
                "role": role,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
            }
        )
    manifest = {
        "domain_separator": domain_separator,
        "implementation_role": implementation_role,
        "schema_version": schema_version,
        "sources": records,
    }
    payload = canonical_json_bytes(manifest)
    return manifest, payload, hashlib.sha256(payload).hexdigest()


class ControlExecutionProducerIdentityV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.raw_contract = CONTRACT_PATH.read_bytes()
        cls.raw_schema = SCHEMA_PATH.read_bytes()
        cls.contract = _load_strict_object(CONTRACT_PATH)
        cls.schema = _load_strict_object(SCHEMA_PATH)
        cls.validator = Draft202012Validator(cls.schema)
        cls.plan_document = _load_strict_object(PLAN_PATH)
        cls.plan = parse_calibration_plan_v2(
            PLAN_PATH.read_bytes(),
            bound_payloads={
                binding["id"]: (ROOT / binding["path"]).read_bytes()
                for binding in cls.plan_document["input_bindings"]
            },
        )

    def test_contract_schema_hashes_and_authority_bindings_are_exact(self) -> None:
        Draft202012Validator.check_schema(self.schema)
        self.assertEqual(list(self.validator.iter_errors(self.contract)), [])
        self.assertEqual(
            self.raw_contract,
            canonical_json_bytes(self.contract) + b"\n",
        )
        self.assertEqual(
            self.raw_schema,
            canonical_json_bytes(self.schema) + b"\n",
        )
        self.assertEqual(
            self.contract["artifact_sha256"],
            EXPECTED_CONTRACT_SELF_SHA256,
        )
        self.assertEqual(
            manifest_sha256(self.contract, field="artifact_sha256"),
            EXPECTED_CONTRACT_SELF_SHA256,
        )
        self.assertEqual(_file_sha256(CONTRACT_PATH), EXPECTED_CONTRACT_FILE_SHA256)
        self.assertEqual(_file_sha256(SCHEMA_PATH), EXPECTED_SCHEMA_FILE_SHA256)

        ids: list[str] = []
        paths: list[str] = []
        for binding in self.contract["authority_bindings"]:
            ids.append(binding["id"])
            paths.append(binding["path"])
            relative = PurePosixPath(binding["path"])
            self.assertFalse(relative.is_absolute())
            self.assertNotIn("..", relative.parts)
            payload = ROOT.joinpath(*relative.parts).read_bytes()
            self.assertEqual(len(payload), binding["size_bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), binding["sha256"])
            self_hash = binding["self_hash"]
            if self_hash is not None:
                document = json.loads(payload)
                self.assertEqual(
                    document[self_hash["field"]],
                    self_hash["sha256"],
                )
                self.assertEqual(
                    manifest_sha256(document, field=self_hash["field"]),
                    self_hash["sha256"],
                )
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(len(paths), len(set(paths)))

    def test_exact_48_pair_candidate_bytes_and_hash_match_plan_oracle(self) -> None:
        golden = self.contract["candidate_identity"]["serialization_golden_only"]
        logical = {
            "spatial_structural_vector_ordinal": golden["structural_ordinal"],
            **dict(self.plan.scalar_initial_values),
        }
        physical = materialize_candidate_vector_v2(logical, self.plan)
        pairs = [
            [name, physical[name]] for name in self.plan.physical_candidate_order
        ]
        pair_bytes = canonical_json_bytes(pairs)
        value_bytes = canonical_json_bytes([item[1] for item in pairs])

        self.assertEqual(len(pairs), 48)
        self.assertEqual(
            [item[0] for item in pairs],
            list(self.plan.physical_candidate_order),
        )
        self.assertEqual(
            pair_bytes,
            golden["canonical_physical_candidate_items_utf8"].encode("utf-8"),
        )
        self.assertEqual(len(pair_bytes), golden["canonical_physical_candidate_items_size"])
        self.assertEqual(
            hashlib.sha256(pair_bytes).hexdigest(),
            golden["canonical_physical_candidate_items_sha256"],
        )
        self.assertEqual(len(value_bytes), golden["candidate_vector_bytes_size"])
        self.assertEqual(
            hashlib.sha256(value_bytes).hexdigest(),
            golden["candidate_vector_sha256"],
        )
        self.assertEqual(
            candidate_vector_sha256_v2(physical, self.plan),
            golden["candidate_vector_sha256"],
        )
        self.assertFalse(golden["establishes_default_or_winner"])

    def test_exact_four_digest_adapter_identity_matches_existing_consumers(self) -> None:
        carrier = self.contract["control_execution_producer_identity"]
        adapter = carrier["authenticated_adapter_identity"]
        self.assertEqual(tuple(adapter["exact_fields"]), EXPECTED_ADAPTER_IDENTITY_FIELDS)
        self.assertEqual(adapter["exact_fields"], sorted(adapter["exact_fields"]))
        self.assertEqual(tuple(carrier["carrier_exact_fields"]), EXPECTED_CARRIER_FIELDS)
        self.assertEqual(
            tuple(field.name for field in fields(ControlExecutionProducerIdentityV2)),
            EXPECTED_CARRIER_FIELDS,
        )

        golden = self.contract["candidate_identity"]["serialization_golden_only"]
        adapter_identity = {
            "adapter_configuration_sha256": "1" * 64,
            "native_executable_sha256": "2" * 64,
            "native_implementation_source_sha256": "3" * 64,
            "native_source_manifest_sha256": "4" * 64,
        }
        producer_identity = ControlExecutionProducerIdentityV2(
            physical_candidate_items_bytes=golden[
                "canonical_physical_candidate_items_utf8"
            ].encode("utf-8"),
            candidate_vector_sha256=golden["candidate_vector_sha256"],
            adapter_configuration_sha256="1" * 64,
            authenticated_adapter_identity_bytes=canonical_json_bytes(
                adapter_identity
            ),
        )
        RawControlAuthorizationArtifactPublisherV2(
            run_id="contract-test",
            control_execution_producer_identity=producer_identity,
        )

        extra_identity = dict(adapter_identity)
        extra_identity["unregistered_digest"] = "5" * 64
        extra_producer = ControlExecutionProducerIdentityV2(
            physical_candidate_items_bytes=(
                producer_identity.physical_candidate_items_bytes
            ),
            candidate_vector_sha256=producer_identity.candidate_vector_sha256,
            adapter_configuration_sha256=(
                producer_identity.adapter_configuration_sha256
            ),
            authenticated_adapter_identity_bytes=canonical_json_bytes(
                extra_identity
            ),
        )
        with self.assertRaisesRegex(
            ControlEvidencePublisherV2Error,
            "adapter identity field set differs",
        ):
            RawControlAuthorizationArtifactPublisherV2(
                run_id="contract-test",
                control_execution_producer_identity=extra_producer,
            )

    def test_ordered_python_source_manifest_is_complete_and_domain_separated(self) -> None:
        identity = self.contract["implementation_source_identity"]
        observed = tuple(
            (row["order"], row["path"], row["role"])
            for row in identity["source_set"]
        )
        self.assertEqual(observed, EXPECTED_SOURCE_SET)
        self.assertEqual(identity["source_count"], len(EXPECTED_SOURCE_SET))
        manifest, payload, digest = _validated_source_manifest(
            identity["source_set"],
            domain_separator=identity["domain_separator"],
            schema_version=identity["manifest_schema_version"],
            implementation_role=identity["manifest_implementation_role"],
        )
        self.assertEqual(set(manifest), set(identity["manifest_exact_keys"]))
        self.assertEqual(payload, canonical_json_bytes(manifest))
        self.assertFalse(payload.endswith(b"\n"))
        self.assertRegex(digest, r"^(?!0{64}$)[0-9a-f]{64}$")
        self.assertEqual(
            [set(record) for record in manifest["sources"]],
            [set(identity["record_exact_keys"])] * 3,
        )

        reordered = deepcopy(identity["source_set"])
        reordered[0], reordered[1] = reordered[1], reordered[0]
        with self.assertRaisesRegex(ValueError, "source order differs"):
            _validated_source_manifest(
                reordered,
                domain_separator=identity["domain_separator"],
                schema_version=identity["manifest_schema_version"],
                implementation_role=identity["manifest_implementation_role"],
            )
        traversal = deepcopy(identity["source_set"])
        traversal[0]["path"] = "validation/calibration_v2/../factory.py"
        with self.assertRaisesRegex(ValueError, "escapes or is not normalized"):
            _validated_source_manifest(
                traversal,
                domain_separator=identity["domain_separator"],
                schema_version=identity["manifest_schema_version"],
                implementation_role=identity["manifest_implementation_role"],
            )
        duplicate = deepcopy(identity["source_set"])
        duplicate[1]["path"] = duplicate[0]["path"]
        with self.assertRaisesRegex(ValueError, "source path repeats"):
            _validated_source_manifest(
                duplicate,
                domain_separator=identity["domain_separator"],
                schema_version=identity["manifest_schema_version"],
                implementation_role=identity["manifest_implementation_role"],
            )
        casefold_duplicate = deepcopy(identity["source_set"])
        casefold_duplicate[1]["path"] = casefold_duplicate[0]["path"].upper()
        with self.assertRaisesRegex(ValueError, "source path repeats"):
            _validated_source_manifest(
                casefold_duplicate,
                domain_separator=identity["domain_separator"],
                schema_version=identity["manifest_schema_version"],
                implementation_role=identity["manifest_implementation_role"],
            )

        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "real/parent").mkdir(parents=True)
            (root / "real/parent/source.py").write_bytes(b"source\n")
            (root / "second.py").write_bytes(b"second\n")
            (root / "third.py").write_bytes(b"third\n")
            (root / "parent-link").symlink_to(root / "real", target_is_directory=True)
            (root / "final-link.py").symlink_to(root / "second.py")
            base_rows = [
                {"order": 0, "path": "real/parent/source.py", "role": "first"},
                {"order": 1, "path": "second.py", "role": "second"},
                {"order": 2, "path": "third.py", "role": "third"},
            ]
            parent_symlink = deepcopy(base_rows)
            parent_symlink[0]["path"] = "parent-link/parent/source.py"
            with self.assertRaisesRegex(ValueError, "no-follow regular file"):
                _validated_source_manifest(
                    parent_symlink,
                    domain_separator=identity["domain_separator"],
                    schema_version=identity["manifest_schema_version"],
                    implementation_role=identity["manifest_implementation_role"],
                    root=root,
                )
            final_symlink = deepcopy(base_rows)
            final_symlink[0]["path"] = "final-link.py"
            with self.assertRaisesRegex(ValueError, "no-follow regular file"):
                _validated_source_manifest(
                    final_symlink,
                    domain_separator=identity["domain_separator"],
                    schema_version=identity["manifest_schema_version"],
                    implementation_role=identity["manifest_implementation_role"],
                    root=root,
                )

        different_domain = dict(manifest)
        different_domain["domain_separator"] += "/changed"
        self.assertNotEqual(
            hashlib.sha256(canonical_json_bytes(different_domain)).hexdigest(),
            digest,
        )

    def test_dependency_evidence_and_downstream_boundary_are_explicit(self) -> None:
        source_set = self.contract["implementation_source_identity"]["source_set"]
        factory_source = (ROOT / source_set[0]["path"]).read_text(encoding="utf-8")
        evaluator_source = (ROOT / source_set[1]["path"]).read_text(encoding="utf-8")
        provider_source = (ROOT / source_set[2]["path"]).read_text(encoding="utf-8")
        self.assertIn("class NativeExecutable:", factory_source)
        self.assertIn("class NativeCandidateAdapterFactory:", factory_source)
        self.assertIn("source_manifest_sha256: str", factory_source)
        self.assertIn("configuration_sha256=configuration_hash", factory_source)
        self.assertIn("class ControlExecutionProducerIdentityV2:", evaluator_source)
        self.assertIn("class NativeProductionWriterCapability:", provider_source)

        downstream = self.contract["downstream_bindings"]
        consumer_paths = [row["path"] for row in downstream["consumers"]]
        self.assertNotIn(source_set[0]["path"], consumer_paths)
        self.assertNotIn(source_set[1]["path"], consumer_paths)
        self.assertNotIn(source_set[2]["path"], consumer_paths)
        self.assertEqual(len(consumer_paths), len(set(consumer_paths)))
        for path_value in consumer_paths:
            self.assertTrue((ROOT / path_value).is_file())
        self.assertEqual(
            downstream["authority_digest_requirements"],
            [
                "control_execution_producer_identity_contract_file_sha256",
                "control_execution_producer_identity_contract_self_sha256",
                "control_execution_producer_identity_schema_file_sha256",
            ],
        )

        boundary = self.contract["digest_relations"][
            "configuration_artifact_boundary"
        ]
        self.assertIn("route LUT complete bytes", boundary["independently_bound_inputs"])
        self.assertIn("independently complete-byte", boundary["rule"])
        self.assertIn("native_source_manifest_sha256", boundary["swift_boundary"])

    def test_schema_rejects_authority_or_execution_drift(self) -> None:
        mutations = []
        status = deepcopy(self.contract)
        status["status"] = "executed"
        mutations.append(status)
        field_set = deepcopy(self.contract)
        field_set["control_execution_producer_identity"][
            "authenticated_adapter_identity"
        ]["exact_fields"].append("unregistered_digest")
        mutations.append(field_set)
        source_order = deepcopy(self.contract)
        source_order["implementation_source_identity"]["source_set"][0][
            "order"
        ] = 1
        mutations.append(source_order)
        path_escape = deepcopy(self.contract)
        path_escape["implementation_source_identity"]["source_set"][0][
            "path"
        ] = "../factory.py"
        mutations.append(path_escape)
        authorization = deepcopy(self.contract)
        authorization["execution_boundary"][
            "production_execution_authorized_by_this_contract_alone"
        ] = True
        mutations.append(authorization)
        selected = deepcopy(self.contract)
        selected["candidate_identity"]["serialization_golden_only"][
            "establishes_default_or_winner"
        ] = True
        mutations.append(selected)
        zero_hash = deepcopy(self.contract)
        zero_hash["artifact_sha256"] = "0" * 64
        mutations.append(zero_hash)

        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.assertNotEqual(
                    list(self.validator.iter_errors(mutation)),
                    [],
                )

    def test_preregistration_has_no_access_selection_gate_or_execution_claim(self) -> None:
        self.assertEqual(self.contract["status"], "preregistered_not_executed")
        self.assertEqual(
            self.contract["data_access"],
            {
                "development_metrics_accessed": False,
                "holdout_accessed": False,
                "live_p06_ledger_bound": False,
                "media_payloads_accessed": False,
                "validation_accessed": False,
            },
        )
        boundary = self.contract["execution_boundary"]
        self.assertFalse(boundary["producer_implementation_performed"])
        self.assertFalse(boundary["candidate_evaluation_performed"])
        self.assertFalse(boundary["candidate_selection_performed"])
        self.assertFalse(boundary["gate_claim_made"])
        self.assertFalse(boundary["winner_claim_made"])
        self.assertFalse(boundary["release_lock_written"])
        self.assertFalse(boundary["holdout_open_authorized"])
        self.assertFalse(
            boundary["production_execution_authorized_by_this_contract_alone"]
        )


if __name__ == "__main__":
    unittest.main()
