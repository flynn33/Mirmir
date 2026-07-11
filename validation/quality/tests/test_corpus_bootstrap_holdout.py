from copy import deepcopy
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

from mirmir_quality.bootstrap import paired_bootstrap
from mirmir_quality.corpus import (
    CorpusValidationError,
    create_corpus_lock,
    seal_corpus_lock,
    validate_corpus_lock,
)
from mirmir_quality.holdout import (
    REQUIRED_HASHES,
    HashBinding,
    HoldoutAccessError,
    HoldoutAccessGuard,
    initialize_holdout_access_ledger,
)
from mirmir_quality.harness_manifest import (
    create_quality_harness_implementation_manifest,
    validate_quality_harness_implementation_manifest,
)
from mirmir_quality.json_tools import (
    manifest_sha256,
    read_json,
    validate_schema,
    write_json,
)


QUALITY_ROOT = Path(__file__).resolve().parents[1]
HARNESS_BINDING_FIELD = "quality_harness_implementation_manifest_sha256"
HARNESS_MEDIA_TYPES_PATH = Path(
    "Mirmir/Modules/MediaPipeline/MediaTypes.swift"
)
HARNESS_WRITER_PATH = Path(
    "validation/quality/tools/production_writer/ProductionWriterMain.swift"
)


@contextmanager
def _temporary_directory():
    with tempfile.TemporaryDirectory() as temporary:
        try:
            yield temporary
        finally:
            for path in Path(temporary).rglob("*"):
                if path.is_symlink() or not path.exists():
                    continue
                flags = os.stat(path, follow_symlinks=False).st_flags
                if flags & stat.UF_IMMUTABLE:
                    os.chflags(
                        path,
                        flags & ~stat.UF_IMMUTABLE,
                        follow_symlinks=False,
                    )


def asset(asset_id: str, source_id: str, family_id: str, split: str, digest_digit: str):
    return {
        "asset_id": asset_id,
        "source_asset_id": source_id,
        "source_family_id": family_id,
        "relative_path": f"corpus/{asset_id}.mov",
        "sha256": digest_digit * 64,
        "size_bytes": 1024,
        "media_type": "video",
        "native_target": True,
        "derived": False,
        "split": split,
        "encoded_dimensions": [3840, 2160],
        "presentation_dimensions": [3840, 2160],
        "frame_range": {"start": 0, "duration": 60, "timescale": 60},
        "frame_count": 60,
        "target_routes": ["direct-2x"],
        "pixel_format": "420v",
        "range": "video",
        "color_primaries": "ITU_R_709_2",
        "transfer_function": "ITU_R_709_2",
        "ycbcr_matrix": "ITU_R_709_2",
        "chroma_location": "left",
        "categories": ["camera/object motion"],
        "provenance": {
            "origin_kind": "test-record",
            "creator": "fixture owner",
            "source_uri": None,
            "original_filename": f"{asset_id}.mov",
            "acquired_utc": "2026-07-11T00:00:00Z",
            "capture_or_creation_metadata": {},
            "evidence_path": "rights/test.txt",
            "evidence_sha256": "e" * 64,
        },
        "rights": {
            "status": "confirmed",
            "basis": "test declaration",
            "license_id": None,
            "license_or_declaration_path": "rights/test.txt",
            "license_or_declaration_sha256": "e" * 64,
            "item_specific_exception_status": "not_applicable_project_owned",
            "item_specific_exception_evidence_path": "rights/test.txt",
            "item_specific_exception_evidence_sha256": "e" * 64,
            "permitted_uses": ["local-project-testing"],
            "derivative_artifacts_permitted": True,
            "redistribution_permitted": False,
            "confirmed_by": "fixture owner",
            "confirmed_utc": "2026-07-11T00:00:00Z",
            "expires_utc": None,
        },
        "sensitive_metadata_present": False,
    }


def corpus(assets):
    return create_corpus_lock(
        corpus_id="test-corpus",
        corpus_version="1",
        created_utc="2026-07-11T00:00:00Z",
        split_policy={
            "unit": "source_asset",
            "group_key": "source_family_id",
            "allocation": {"development": 0.5, "validation": 0.25, "holdout": 0.25},
            "algorithm": "test assignment",
            "seed": 7,
            "rounding_rule": "test fixture",
            "minimum_category_counts": {"camera/object motion": 1},
        },
        assets=assets,
        category_vocabulary_version="test-v1",
    )


def _create_quality_harness_repository(root: Path):
    repository_root = root / "harness-repository"
    sources = {
        HARNESS_MEDIA_TYPES_PATH: b"struct ProductVideoOutputSettings {}\n",
        Path("validation/quality/src/mirmir_quality/holdout.py"): (
            b"REQUIRED_HASHES = ()\n"
        ),
        Path("validation/quality/src/mirmir_quality/nested/check.py"): (
            b"BOUND = True\n"
        ),
        Path("validation/quality/tools/build_fixture.py"): b"raise SystemExit(0)\n",
        HARNESS_WRITER_PATH: b"struct ProductionWriter {}\n",
        Path("validation/quality/schemas/configuration-lock.schema.json"): b"{}\n",
        Path(
            "validation/quality/schemas/quality-harness-implementation-manifest.schema.json"
        ): b"{}\n",
        Path("validation/quality/reference/metric_oracle.py"): b"VALUE = 1\n",
    }
    for relative_path, payload in sources.items():
        path = repository_root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
    manifest = create_quality_harness_implementation_manifest(repository_root)
    manifest_path = (
        repository_root
        / "validation/quality/locks/quality-harness-implementation-manifest.json"
    )
    write_json(manifest_path, manifest)
    return repository_root, manifest_path, manifest


def _rewrite_quality_harness_manifest(configuration, bindings, transform):
    binding = bindings[HARNESS_BINDING_FIELD]
    manifest = read_json(binding.path)
    manifest.pop("manifest_sha256")
    transform(manifest)
    manifest["files"] = sorted(
        manifest["files"],
        key=lambda record: record["relative_path"],
    )
    manifest["file_count"] = len(manifest["files"])
    manifest["manifest_sha256"] = manifest_sha256(manifest)
    write_json(binding.path, manifest)
    configuration[HARNESS_BINDING_FIELD] = manifest["manifest_sha256"]


def holdout_fixture(root: Path):
    binding_root = root / "bindings"
    binding_root.mkdir(parents=True)
    harness_root, harness_manifest_path, harness_manifest = (
        _create_quality_harness_repository(root)
    )
    bindings = {}
    configuration = {
        "schema_version": "1.0.0",
        "locked_utc": "2026-07-11T00:00:00Z",
        "release_fields_complete": True,
        "configuration_files_modified_after_lock": False,
        "holdout_opened_utc": None,
    }
    for index, field in enumerate(REQUIRED_HASHES):
        if field == HARNESS_BINDING_FIELD:
            bindings[field] = HashBinding(
                path=harness_manifest_path,
                root=harness_root,
                digest_mode="quality_harness_manifest",
            )
            configuration[field] = harness_manifest["manifest_sha256"]
            continue
        path = binding_root / f"{field}.bin"
        payload = f"locked-{index}-{field}".encode("utf-8")
        path.write_bytes(payload)
        bindings[field] = HashBinding(path=path, root=binding_root)
        configuration[field] = hashlib.sha256(payload).hexdigest()
    ledger_path = root / "ledger-store" / "holdout-access-ledger.json"
    anchor_path = root / "external-anchor-registry" / "holdout-open-intent.json"
    initialize_holdout_access_ledger(
        ledger_path,
        configuration["corpus_manifest_sha256"],
        created_utc="2026-07-11T00:00:00Z",
        anchor_path=anchor_path,
    )
    return configuration, bindings, ledger_path, anchor_path


class CorpusBootstrapHoldoutTests(unittest.TestCase):
    def test_quality_harness_manifest_builder_is_deterministic(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            harness_root, manifest_path, first = (
                _create_quality_harness_repository(root)
            )
            second = create_quality_harness_implementation_manifest(harness_root)

            self.assertEqual(first, second)
            self.assertEqual(read_json(manifest_path), first)
            self.assertEqual(
                validate_quality_harness_implementation_manifest(
                    first,
                    harness_root,
                ),
                first["manifest_sha256"],
            )
            validate_schema(
                first,
                QUALITY_ROOT
                / "schemas/quality-harness-implementation-manifest.schema.json",
            )

    def test_corpus_schema_and_all_split_validation(self) -> None:
        manifest = corpus(
            [
                asset("d0", "s0", "f0", "development", "0"),
                asset("d1", "s1", "f1", "development", "1"),
                asset("v0", "s2", "f2", "validation", "2"),
                asset("h0", "s3", "f3", "holdout", "3"),
            ]
        )

        validate_corpus_lock(manifest)
        validate_schema(manifest, QUALITY_ROOT / "schemas" / "corpus-lock.schema.json")

    def test_source_family_split_leakage_is_rejected(self) -> None:
        manifest = corpus(
            [
                asset("d0", "shared", "shared-family", "development", "4"),
                asset("h0", "shared", "shared-family", "holdout", "5"),
            ]
        )

        with self.assertRaisesRegex(CorpusValidationError, "leaks across splits"):
            validate_corpus_lock(manifest, require_all_splits=False)

    def test_unconfirmed_rights_are_rejected(self) -> None:
        candidate = asset("d0", "s0", "f0", "development", "6")
        candidate["rights"]["status"] = "unverified"
        manifest = corpus([candidate])

        with self.assertRaisesRegex(CorpusValidationError, "lacks confirmed rights"):
            validate_corpus_lock(manifest, require_all_splits=False)

    def test_item_specific_protected_content_exception_is_rejected(self) -> None:
        candidate = asset("d0", "s0", "f0", "development", "6")
        candidate["rights"]["item_specific_exception_status"] = "protected_content_present"
        manifest = corpus([candidate])

        with self.assertRaisesRegex(CorpusValidationError, "disqualifying rights exception"):
            validate_corpus_lock(manifest, require_all_splits=False)

    def test_declared_route_must_be_exactly_derivable_from_native_dimensions(self) -> None:
        candidate = asset("d0", "s0", "f0", "development", "7")
        candidate["presentation_dimensions"] = [3839, 2160]
        manifest = corpus([candidate])

        with self.assertRaisesRegex(CorpusValidationError, "exact direct-2x"):
            validate_corpus_lock(manifest, require_all_splits=False)

    def test_exact_family_allocation_and_category_minima_are_enforced(self) -> None:
        assets = []
        assignments = ["development"] * 6 + ["validation"] * 3 + ["holdout"] * 3
        for index, split in enumerate(assignments):
            record = asset(
                f"a{index}",
                f"s{index}",
                f"f{index}",
                split,
                f"{index:x}",
            )
            record["categories"] = ["camera/object motion"]
            assets.append(record)
        manifest = corpus(assets)
        manifest["split_policy"]["expected_family_counts"] = {
            "development": 6,
            "validation": 3,
            "holdout": 3,
        }
        manifest["split_policy"]["minimum_category_counts"] = {
            "camera/object motion": 4,
        }
        manifest["split_policy"]["minimum_category_counts_by_split"] = {
            "development": {"camera/object motion": 2},
            "validation": {"camera/object motion": 1},
            "holdout": {"camera/object motion": 1},
        }
        manifest["manifest_sha256"] = manifest_sha256(manifest)

        validate_corpus_lock(
            manifest,
            allowed_categories={"camera/object motion"},
            require_exact_allocation=True,
            require_category_minima=True,
        )

        invalid = deepcopy(manifest)
        invalid["split_policy"]["minimum_category_counts_by_split"]["holdout"] = {
            "camera/object motion": 4,
        }
        invalid["manifest_sha256"] = manifest_sha256(invalid)
        with self.assertRaisesRegex(CorpusValidationError, "holdout minimum"):
            validate_corpus_lock(
                invalid,
                allowed_categories={"camera/object motion"},
                require_exact_allocation=True,
                require_category_minima=True,
            )

        invalid_geometry = deepcopy(manifest)
        invalid_geometry["assets"][0]["encoded_dimensions"] = [1920, 804]
        invalid_geometry["assets"][0]["presentation_dimensions"] = [1920, 804]
        invalid_geometry["assets"][0]["target_routes"] = ["direct-3over2"]
        invalid_geometry["manifest_sha256"] = manifest_sha256(invalid_geometry)
        with self.assertRaisesRegex(CorpusValidationError, "canonical project route"):
            validate_corpus_lock(
                invalid_geometry,
                allowed_categories={"camera/object motion"},
                require_exact_allocation=True,
                require_category_minima=True,
            )

        invalid_metadata = deepcopy(manifest)
        invalid_metadata["assets"][0]["ycbcr_matrix"] = "unspecified"
        invalid_metadata["manifest_sha256"] = manifest_sha256(invalid_metadata)
        with self.assertRaisesRegex(
            CorpusValidationError,
            "unsupported or absent ycbcr_matrix metadata",
        ):
            validate_corpus_lock(
                invalid_metadata,
                allowed_categories={"camera/object motion"},
                require_exact_allocation=True,
                require_category_minima=True,
            )

        for field, value, expected_error in (
            (
                "clean_aperture",
                {
                    "width": 300,
                    "height": 180,
                    "horizontal_offset": 12,
                    "vertical_offset": 6,
                },
                "non-full-frame clean aperture",
            ),
            (
                "pixel_aspect_ratio",
                {"HorizontalSpacing": 2, "VerticalSpacing": 1},
                "non-square pixels",
            ),
            ("orientation", "rotate-90", "non-identity orientation"),
        ):
            with self.subTest(field=field):
                invalid_display = deepcopy(manifest)
                invalid_display["assets"][0][field] = value
                invalid_display["manifest_sha256"] = manifest_sha256(
                    invalid_display
                )
                with self.assertRaisesRegex(
                    CorpusValidationError,
                    expected_error,
                ):
                    validate_corpus_lock(
                        invalid_display,
                        allowed_categories={"camera/object motion"},
                        require_exact_allocation=True,
                        require_category_minima=True,
                    )

    def test_asset_and_rights_records_are_bound_to_regular_file_bytes(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            asset_root = root / "assets"
            evidence_root = root / "evidence"
            (asset_root / "corpus").mkdir(parents=True)
            (evidence_root / "rights").mkdir(parents=True)
            payload = b"native target fixture bytes"
            evidence = b"project-owned fixture rights declaration"
            (asset_root / "corpus" / "d0.mov").write_bytes(payload)
            (evidence_root / "rights" / "test.txt").write_bytes(evidence)
            record = asset("d0", "s0", "f0", "development", "1")
            record["sha256"] = hashlib.sha256(payload).hexdigest()
            record["size_bytes"] = len(payload)
            evidence_digest = hashlib.sha256(evidence).hexdigest()
            record["provenance"]["evidence_sha256"] = evidence_digest
            record["rights"]["license_or_declaration_sha256"] = evidence_digest
            record["rights"]["item_specific_exception_evidence_sha256"] = evidence_digest
            manifest = corpus([record])

            validate_corpus_lock(
                manifest,
                require_all_splits=False,
                asset_root=asset_root,
                evidence_root=evidence_root,
            )

            (evidence_root / "rights" / "test.txt").write_bytes(evidence + b" changed")
            with self.assertRaisesRegex(CorpusValidationError, "rights declaration SHA-256"):
                validate_corpus_lock(
                    manifest,
                    require_all_splits=False,
                    asset_root=asset_root,
                    evidence_root=evidence_root,
                )

    def test_corpus_binding_rejects_a_symlink_even_when_target_hash_matches(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            asset_root = root / "assets"
            evidence_root = root / "evidence"
            (asset_root / "corpus").mkdir(parents=True)
            (evidence_root / "rights").mkdir(parents=True)
            outside = root / "outside.mov"
            payload = b"outside payload"
            evidence = b"fixture rights"
            outside.write_bytes(payload)
            (asset_root / "corpus" / "d0.mov").symlink_to(outside)
            (evidence_root / "rights" / "test.txt").write_bytes(evidence)
            record = asset("d0", "s0", "f0", "development", "1")
            record["sha256"] = hashlib.sha256(payload).hexdigest()
            record["size_bytes"] = len(payload)
            evidence_digest = hashlib.sha256(evidence).hexdigest()
            record["provenance"]["evidence_sha256"] = evidence_digest
            record["rights"]["license_or_declaration_sha256"] = evidence_digest
            record["rights"]["item_specific_exception_evidence_sha256"] = evidence_digest
            manifest = corpus([record])

            with self.assertRaisesRegex(CorpusValidationError, "symbolic link"):
                validate_corpus_lock(
                    manifest,
                    require_all_splits=False,
                    asset_root=asset_root,
                    evidence_root=evidence_root,
                )

    def test_production_corpus_lock_seals_exact_validated_bytes_without_overwrite(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            asset_root = root / "assets"
            evidence_root = root / "evidence"
            (asset_root / "corpus").mkdir(parents=True)
            (evidence_root / "rights").mkdir(parents=True)
            evidence = b"project-owned fixture rights declaration"
            (evidence_root / "rights" / "test.txt").write_bytes(evidence)
            evidence_digest = hashlib.sha256(evidence).hexdigest()
            assignments = ["development"] * 6 + ["validation"] * 3 + ["holdout"] * 3
            records = []
            for index, split in enumerate(assignments):
                payload = f"native-target-{index}".encode("utf-8")
                (asset_root / "corpus" / f"a{index}.mov").write_bytes(payload)
                record = asset(f"a{index}", f"s{index}", f"f{index}", split, "0")
                record["sha256"] = hashlib.sha256(payload).hexdigest()
                record["size_bytes"] = len(payload)
                record["provenance"]["evidence_sha256"] = evidence_digest
                record["rights"]["license_or_declaration_sha256"] = evidence_digest
                record["rights"]["item_specific_exception_evidence_sha256"] = evidence_digest
                records.append(record)
            manifest = corpus(records)
            manifest["split_policy"]["expected_family_counts"] = {
                "development": 6,
                "validation": 3,
                "holdout": 3,
            }
            manifest["split_policy"]["minimum_category_counts"] = {
                "camera/object motion": 4,
            }
            manifest["split_policy"]["minimum_category_counts_by_split"] = {
                "development": {"camera/object motion": 2},
                "validation": {"camera/object motion": 1},
                "holdout": {"camera/object motion": 1},
            }
            manifest["manifest_sha256"] = manifest_sha256(manifest)
            destination = root / "sealed" / "corpus-lock.json"

            sealed_sha256 = seal_corpus_lock(
                manifest,
                destination,
                allowed_categories={"camera/object motion"},
                asset_root=asset_root,
                evidence_root=evidence_root,
                schema_path=QUALITY_ROOT / "schemas" / "corpus-lock.schema.json",
            )
            self.assertEqual(
                sealed_sha256,
                hashlib.sha256(destination.read_bytes()).hexdigest(),
            )
            self.assertEqual(read_json(destination), manifest)
            with self.assertRaises(FileExistsError):
                seal_corpus_lock(
                    manifest,
                    destination,
                    allowed_categories={"camera/object motion"},
                    asset_root=asset_root,
                    evidence_root=evidence_root,
                    schema_path=QUALITY_ROOT / "schemas" / "corpus-lock.schema.json",
                )

    def test_bootstrap_uses_source_assets_not_rows(self) -> None:
        records = [
            {"source_asset_id": "a", "candidate": 3.0, "baseline": 1.0, "categories": ["edge"]},
            {"source_asset_id": "a", "candidate": 5.0, "baseline": 1.0, "categories": ["edge"]},
            {"source_asset_id": "b", "candidate": 2.0, "baseline": 1.0, "categories": ["texture"]},
        ]
        result = paired_bootstrap(records, replicates=1000, seed=20260710)

        self.assertEqual(result["asset_count"], 2)
        self.assertEqual(result["asset_deltas"], [3.0, 1.0])
        self.assertEqual(result["point_delta"], 2.0)
        self.assertEqual(
            result["resample_index_sha256"],
            "718c86cd1dd5477b8b1ca085669732223ab92f6cdfca5a50d4bae0105608cd81",
        )

    def test_holdout_refusal_occurs_before_loader(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(Path(temporary))
            incomplete = dict(configuration)
            incomplete["release_fields_complete"] = False
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )
            calls = []

            with self.assertRaises(HoldoutAccessError):
                guard.read_once(incomplete, lambda: calls.append(True))
            self.assertEqual(calls, [])
            self.assertFalse(guard.intent_path.exists())

    def test_holdout_rejects_schema_invalid_configuration_before_anchor(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )
            invalid = dict(configuration)
            invalid.pop("holdout_opened_utc")
            invalid["locked_utc"] = "not-a-date"
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )
            calls = []

            with self.assertRaisesRegex(
                HoldoutAccessError,
                "configuration lock schema validation failed",
            ):
                guard.read_once(invalid, lambda: calls.append(True))
            self.assertEqual(calls, [])
            self.assertFalse(anchor_path.exists())
            self.assertEqual(read_json(ledger_path)["state"], "sealed")

    def test_holdout_persists_open_before_loader_and_refuses_cross_process_replay(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(root)
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
                clock=lambda: "2026-07-11T00:00:01Z",
            )

            def injected_loader():
                persisted = read_json(ledger_path)
                self.assertEqual(persisted["state"], "opened")
                self.assertEqual(persisted["opened_utc"], "2026-07-11T00:00:01Z")
                return "authorized injected fixture"

            self.assertEqual(
                guard.read_once(configuration, injected_loader),
                "authorized injected fixture",
            )
            validate_schema(
                read_json(ledger_path),
                QUALITY_ROOT / "schemas" / "holdout-access-ledger.schema.json",
            )
            validate_schema(
                read_json(anchor_path),
                QUALITY_ROOT / "schemas" / "holdout-access-anchor.schema.json",
            )
            validate_schema(
                configuration,
                QUALITY_ROOT / "schemas" / "configuration-lock.schema.json",
            )

            configuration_path = root / "configuration.json"
            bindings_path = root / "bindings.json"
            configuration_path.write_text(json.dumps(configuration), encoding="utf-8")
            bindings_path.write_text(
                json.dumps(
                    {
                        field: {
                            "path": str(binding.path),
                            "root": str(binding.root),
                            "digest_mode": binding.digest_mode,
                            "manifest_hash_field": binding.manifest_hash_field,
                        }
                        for field, binding in bindings.items()
                    }
                ),
                encoding="utf-8",
            )
            program = """
import json
from pathlib import Path
import sys
from mirmir_quality.holdout import HashBinding, HoldoutAccessError, HoldoutAccessGuard
configuration = json.loads(Path(sys.argv[1]).read_text())
bindings = {
    field: HashBinding(
        path=Path(value["path"]),
        root=Path(value["root"]),
        digest_mode=value["digest_mode"],
        manifest_hash_field=value["manifest_hash_field"],
    )
    for field, value in json.loads(Path(sys.argv[2]).read_text()).items()
}
guard = HoldoutAccessGuard(
    configuration["corpus_manifest_sha256"],
    ledger_path=Path(sys.argv[3]),
    anchor_path=Path(sys.argv[4]),
    hash_bindings=bindings,
)
try:
    guard.read_once(configuration, lambda: None)
except HoldoutAccessError:
    raise SystemExit(0)
raise SystemExit(3)
"""
            environment = dict(os.environ)
            environment["PYTHONPATH"] = str(QUALITY_ROOT / "src")
            result = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    program,
                    str(configuration_path),
                    str(bindings_path),
                    str(ledger_path),
                    str(anchor_path),
                ],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_holdout_rehashes_bound_files_before_loader(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(Path(temporary))
            bindings["mapping_sha256"].path.write_bytes(b"changed after lock")
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )
            calls = []

            with self.assertRaisesRegex(HoldoutAccessError, "does not match the lock"):
                guard.read_once(configuration, lambda: calls.append(True))
            self.assertEqual(calls, [])
            self.assertFalse(guard.intent_path.exists())

    def test_holdout_rehashes_nested_quality_harness_source_before_loader(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )
            source_path = bindings[HARNESS_BINDING_FIELD].root / HARNESS_MEDIA_TYPES_PATH
            payload = source_path.read_bytes()
            source_path.write_bytes(bytes([payload[0] ^ 1]) + payload[1:])
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )
            calls = []

            with self.assertRaisesRegex(HoldoutAccessError, "hash mismatch"):
                guard.read_once(configuration, lambda: calls.append(True))
            self.assertEqual(calls, [])
            self.assertFalse(anchor_path.exists())

    def test_holdout_refuses_shallow_quality_harness_digest_mode(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )
            recursive = bindings[HARNESS_BINDING_FIELD]
            bindings[HARNESS_BINDING_FIELD] = HashBinding(
                path=recursive.path,
                root=recursive.root,
            )

            with self.assertRaisesRegex(ValueError, "recursive validation"):
                HoldoutAccessGuard(
                    configuration["corpus_manifest_sha256"],
                    ledger_path=ledger_path,
                    anchor_path=anchor_path,
                    hash_bindings=bindings,
                )
            self.assertFalse(anchor_path.exists())

    def test_quality_harness_manifest_rejects_omitted_discovered_path(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )

            def omit_path(manifest):
                manifest["files"].pop()

            _rewrite_quality_harness_manifest(configuration, bindings, omit_path)
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "path set is not exact"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_quality_harness_manifest_rejects_invalid_self_hash(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )
            binding = bindings[HARNESS_BINDING_FIELD]
            manifest = read_json(binding.path)
            manifest["manifest_sha256"] = "0" * 64
            write_json(binding.path, manifest)
            configuration[HARNESS_BINDING_FIELD] = manifest["manifest_sha256"]
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "self-hash is invalid"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_quality_harness_manifest_rejects_declared_size_mismatch(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )

            def change_size(manifest):
                manifest["files"][0]["size_bytes"] += 1

            _rewrite_quality_harness_manifest(configuration, bindings, change_size)
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "size mismatch"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_quality_harness_manifest_rejects_extra_declared_path(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )

            def add_path(manifest):
                manifest["files"].append(
                    {
                        "relative_path": "validation/quality/reference/not-present.py",
                        "size_bytes": 0,
                        "sha256": hashlib.sha256(b"").hexdigest(),
                    }
                )

            _rewrite_quality_harness_manifest(configuration, bindings, add_path)
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "path set is not exact"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_quality_harness_manifest_rejects_duplicate_path(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )

            def duplicate_path(manifest):
                duplicate = dict(manifest["files"][0])
                duplicate["sha256"] = "0" * 64
                manifest["files"].append(duplicate)

            _rewrite_quality_harness_manifest(configuration, bindings, duplicate_path)
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "duplicate paths"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_quality_harness_manifest_rejects_path_escape(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )

            def escape_path(manifest):
                manifest["files"][0]["relative_path"] = "../escape.py"

            _rewrite_quality_harness_manifest(configuration, bindings, escape_path)
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "normalized and relative"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_quality_harness_manifest_rejects_nested_source_symlink(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(root)
            source_path = bindings[HARNESS_BINDING_FIELD].root / HARNESS_MEDIA_TYPES_PATH
            outside = root / "same-source.swift"
            outside.write_bytes(source_path.read_bytes())
            source_path.unlink()
            source_path.symlink_to(outside)
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "symbolic"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_quality_harness_manifest_rejects_intermediate_directory_symlink(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(root)
            harness_root = bindings[HARNESS_BINDING_FIELD].root
            writer_directory = (
                harness_root / "validation/quality/tools/production_writer"
            )
            outside = root / "same-writer-directory"
            writer_directory.rename(outside)
            writer_directory.symlink_to(outside, target_is_directory=True)
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "symbolic"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_quality_harness_manifest_rejects_missing_required_source(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )
            source_path = bindings[HARNESS_BINDING_FIELD].root / HARNESS_MEDIA_TYPES_PATH
            source_path.unlink()
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "is absent"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_quality_harness_manifest_rejects_nonregular_matching_path(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )
            nonregular = (
                bindings[HARNESS_BINDING_FIELD].root
                / "validation/quality/reference/nonregular.py"
            )
            os.mkfifo(nonregular)
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "not a regular file"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_holdout_rehashes_after_loader_and_records_mutation_as_failure(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
                clock=lambda: "2026-07-11T00:00:03Z",
            )

            def mutate_binding():
                payload = b"mutated during loader"
                bindings["mapping_sha256"].path.write_bytes(payload)
                configuration["mapping_sha256"] = hashlib.sha256(payload).hexdigest()
                return "must not be published"

            with self.assertRaisesRegex(HoldoutAccessError, "does not match the lock"):
                guard.read_once(configuration, mutate_binding)
            self.assertEqual(read_json(ledger_path)["state"], "failed")
            self.assertTrue(anchor_path.is_file())

    def test_holdout_rehashes_nested_quality_harness_source_after_loader(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(
                Path(temporary)
            )
            writer_path = bindings[HARNESS_BINDING_FIELD].root / HARNESS_WRITER_PATH
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
                clock=lambda: "2026-07-11T00:00:03Z",
            )

            def mutate_nested_source():
                payload = writer_path.read_bytes()
                writer_path.write_bytes(bytes([payload[0] ^ 1]) + payload[1:])
                return "must not be published"

            with self.assertRaisesRegex(HoldoutAccessError, "hash mismatch"):
                guard.read_once(configuration, mutate_nested_source)
            self.assertEqual(read_json(ledger_path)["state"], "failed")
            self.assertTrue(anchor_path.is_file())

    def test_external_anchor_survives_ledger_loss_and_blocks_reinitialization(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(root)
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )
            guard.read_once(configuration, lambda: "opened")
            ledger_path.unlink()
            self.assertTrue(
                os.stat(anchor_path, follow_symlinks=False).st_flags
                & stat.UF_IMMUTABLE
            )
            with self.assertRaises(PermissionError):
                anchor_path.unlink()

            with self.assertRaisesRegex(HoldoutAccessError, "anchor records prior access"):
                initialize_holdout_access_ledger(
                    ledger_path,
                    configuration["corpus_manifest_sha256"],
                    created_utc="2026-07-11T00:00:04Z",
                    anchor_path=anchor_path,
                )

    def test_holdout_binding_rejects_intermediate_symlink_below_trusted_root(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(root)
            binding_root = bindings["mapping_sha256"].root
            real_directory = binding_root / "real"
            real_directory.mkdir()
            payload = bindings["mapping_sha256"].path.read_bytes()
            (real_directory / "mapping.bin").write_bytes(payload)
            (binding_root / "linked").symlink_to(real_directory, target_is_directory=True)
            bindings["mapping_sha256"] = HashBinding(
                path=binding_root / "linked" / "mapping.bin",
                root=binding_root,
            )
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )

            with self.assertRaisesRegex(HoldoutAccessError, "traverses a symbolic link"):
                guard.read_once(configuration, lambda: None)
            self.assertFalse(anchor_path.exists())

    def test_holdout_loader_failure_is_recorded_for_cooperating_processes(self) -> None:
        with _temporary_directory() as temporary:
            configuration, bindings, ledger_path, anchor_path = holdout_fixture(Path(temporary))
            guard = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
                clock=lambda: "2026-07-11T00:00:02Z",
            )

            def fail_loader():
                raise RuntimeError("injected post-open failure")

            with self.assertRaisesRegex(RuntimeError, "injected post-open failure"):
                guard.read_once(configuration, fail_loader)
            self.assertEqual(read_json(ledger_path)["state"], "failed")
            replay = HoldoutAccessGuard(
                configuration["corpus_manifest_sha256"],
                ledger_path=ledger_path,
                anchor_path=anchor_path,
                hash_bindings=bindings,
            )
            with self.assertRaisesRegex(HoldoutAccessError, "open intent"):
                replay.read_once(configuration, lambda: None)


if __name__ == "__main__":
    unittest.main()
