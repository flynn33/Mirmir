"""Production composition of exact V2 control-selection authorization.

The service in this module performs no candidate measurement and has no
holdout capability.  It accepts only raw aggregate publications issued by one
``RawControlAuthorizationArtifactPublisherV2`` plus a fully persisted and
reopened V2 non-ASH selector closure.  It deterministically constructs the
ranked fixed and conventional selections, persists and reopens the resulting
documents, builds one exact transitive authorization bundle, and requires a
complete ``ControlAuthorizationVerifierV2`` replay before returning it.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
from pathlib import PurePosixPath
import secrets
import stat
from types import MappingProxyType
from typing import Callable, Dict, Mapping, Optional, Sequence, Tuple

from validation.calibration_v2.authenticated_closure_snapshot_v2 import (
    AuthenticatedClosureSnapshotV2,
    ClosureFileBindingV2,
    ClosureFileSnapshotV2,
)
from validation.calibration_v2.control_authorization_v2 import (
    CONVENTIONAL_ALGORITHM_IDS,
    CONVENTIONAL_SELECTION_KIND,
    CONTROL_AUTHORIZATION_BUNDLE_KIND,
    FIXED_DESCRIPTOR_IDS,
    FIXED_SELECTION_KIND,
    OBJECTIVE_SUMMARY_KIND,
    OUTPUT_MANIFEST_KIND,
    SCHEMA_VERSION_V2,
    SELECTION_METRICS,
    SELECTION_OBJECTIVE,
    ControlAuthorizationScopeV2,
    ControlAuthorizationV2Error,
    ControlAuthorizationVerifierV2,
    TypedArtifactBindingV2,
    VerifiedControlAuthorizationV2,
    authority_bindings_v2,
    canonical_json_bytes_v2,
    canonical_json_file_bytes_v2,
    dependency_set_sha256_v2,
    finalize_artifact_sha256_v2,
    finalize_control_authorization_bundle_v2,
    schema_sha256_for_kind_v2,
)
from validation.calibration_v2.control_evidence_publisher_v2 import (
    RAW_CONTROL_AGGREGATE_PUBLICATION_KIND_V2,
    RawControlAuthorizationArtifactPublisherV2,
)
from validation.calibration_v2.non_ash_selector_v2 import (
    NonAshSelectorEvaluationScopeV2,
    NonAshSelectorExecutionProfileV2,
)
from validation.calibration_v2.non_ash_selector_artifacts_v2 import (
    ATTEMPT_LEDGER_KIND,
    NEIGHBOR_MANIFEST_KIND,
    SELECTION_KIND,
)
from validation.calibration_v2.production_evaluator import (
    conventional_control_configuration_sha256_v2,
    fixed_control_configuration_sha256_v2,
)
from validation.calibration_v2.production_providers import (
    ContentAddressedEvidenceStore,
)


_ZERO_SHA256 = "0" * 64
_FIXED_DEVELOPMENT_TIE = (
    "lexicographically maximize the development engine_raw corpus-mean "
    "tuple, then choose the numerically smallest descriptor ID"
)
_FIXED_VALIDATION_TIE = (
    "lexicographically maximize the validation engine_raw corpus-mean "
    "tuple, then choose the numerically smallest descriptor ID"
)
_CONVENTIONAL_DEVELOPMENT_TIE = (
    "lexicographically maximize the development engine_raw corpus-mean "
    "tuple, then choose the lexicographically ascending stable algorithm ID"
)
_CONVENTIONAL_VALIDATION_TIE = (
    "lexicographically maximize the validation engine_raw corpus-mean "
    "tuple, then choose the lexicographically ascending stable algorithm ID"
)


class ProductionControlSelectionV2Error(ValueError):
    """A publication, predecessor closure, or authorization replay differs."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _is_sha256(value: object) -> bool:
    return (
        type(value) is str
        and value != _ZERO_SHA256
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _binding_sort_key(binding: TypedArtifactBindingV2) -> Tuple[object, ...]:
    return (
        binding.path,
        binding.artifact_kind,
        binding.schema_sha256,
        binding.sha256,
        binding.size_bytes,
    )


def _canonical_object(value: object, *, label: str) -> Dict[str, object]:
    try:
        payload = canonical_json_bytes_v2(value)
        reopened = json.loads(payload)
    except (TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProductionControlSelectionV2Error(
            f"{label} is not canonical JSON"
        ) from error
    if type(reopened) is not dict:
        raise ProductionControlSelectionV2Error(f"{label} is not an object")
    return reopened


def _canonical_file_object(payload: bytes, *, label: str) -> Dict[str, object]:
    if type(payload) is not bytes or not payload.endswith(b"\n"):
        raise ProductionControlSelectionV2Error(
            f"{label} is not canonical JSON file bytes"
        )
    try:
        document = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProductionControlSelectionV2Error(
            f"{label} is not valid JSON"
        ) from error
    if (
        type(document) is not dict
        or canonical_json_file_bytes_v2(document) != payload
    ):
        raise ProductionControlSelectionV2Error(
            f"{label} canonical bytes differ"
        )
    return document


def _ordered_unique_bindings(
    values: Sequence[TypedArtifactBindingV2],
    *,
    label: str,
) -> Tuple[TypedArtifactBindingV2, ...]:
    if type(values) not in {tuple, list} or any(
        type(value) is not TypedArtifactBindingV2 for value in values
    ):
        raise ProductionControlSelectionV2Error(
            f"{label} bindings are invalid"
        )
    ordered = tuple(sorted(values, key=_binding_sort_key))
    paths = [binding.path for binding in ordered]
    digests = [binding.sha256 for binding in ordered]
    if (
        tuple(values) != ordered
        or len(ordered) != len(set(ordered))
        or len(paths) != len(set(paths))
        or len(digests) != len(set(digests))
    ):
        raise ProductionControlSelectionV2Error(
            f"{label} bindings are not sorted and uniquely addressed"
        )
    return ordered


def _snapshot_exactly_matches(
    snapshot: AuthenticatedClosureSnapshotV2,
    bindings: Sequence[TypedArtifactBindingV2],
    *,
    label: str,
) -> None:
    if type(snapshot) is not AuthenticatedClosureSnapshotV2:
        raise ProductionControlSelectionV2Error(
            f"{label} snapshot has the wrong type"
        )
    expected = tuple(
        sorted(
            (binding.closure_binding() for binding in bindings),
            key=lambda binding: binding.path,
        )
    )
    if snapshot.bindings != expected:
        raise ProductionControlSelectionV2Error(
            f"{label} snapshot binding set differs"
        )


@dataclass(frozen=True)
class NonAshControlSelectionInputV2:
    """Exact already-persisted V2 non-ASH selector dependency closure."""

    selection_binding: TypedArtifactBindingV2
    predecessor_bindings: Mapping[str, TypedArtifactBindingV2]
    dependency_bindings: Tuple[TypedArtifactBindingV2, ...]
    evidence_snapshot: AuthenticatedClosureSnapshotV2

    def __post_init__(self) -> None:
        if (
            type(self.selection_binding) is not TypedArtifactBindingV2
            or self.selection_binding.artifact_kind != SELECTION_KIND
            or self.selection_binding.schema_sha256
            != schema_sha256_for_kind_v2(SELECTION_KIND)
            or type(self.predecessor_bindings) is not dict
            or any(
                type(name) is not str
                or not name
                or type(binding) is not TypedArtifactBindingV2
                for name, binding in self.predecessor_bindings.items()
            )
        ):
            raise ProductionControlSelectionV2Error(
                "non-ASH selection input bindings are invalid"
            )
        dependencies = _ordered_unique_bindings(
            self.dependency_bindings,
            label="non-ASH selection input",
        )
        required = {self.selection_binding, *self.predecessor_bindings.values()}
        if not required.issubset(set(dependencies)):
            raise ProductionControlSelectionV2Error(
                "non-ASH selection or predecessor binding is omitted"
            )
        _snapshot_exactly_matches(
            self.evidence_snapshot,
            dependencies,
            label="non-ASH selection input",
        )
        object.__setattr__(self, "dependency_bindings", dependencies)
        object.__setattr__(
            self,
            "predecessor_bindings",
            MappingProxyType(dict(self.predecessor_bindings)),
        )


@dataclass(frozen=True)
class ProductionControlSelectionRequestV2:
    """Split-scoped inputs required to construct one V2 authorization."""

    run_id: str
    split: str
    shared_bank_configuration_sha256: str
    degradation_policy_sha256: str
    source_profile_matrix_sha256: str
    best_fixed_publications: Tuple[Mapping[str, object], ...]
    conventional_publications: Tuple[Mapping[str, object], ...]
    non_ash_selector_publications: Tuple[Mapping[str, object], ...]
    non_ash_profile: NonAshSelectorExecutionProfileV2
    non_ash_evaluation_scope: NonAshSelectorEvaluationScopeV2
    non_ash_selection: NonAshControlSelectionInputV2
    development_source_profile_matrix_sha256: Optional[str] = None
    development_best_fixed_publications: Tuple[
        Mapping[str, object], ...
    ] = ()
    development_conventional_publications: Tuple[
        Mapping[str, object], ...
    ] = ()
    development_non_ash_selector_publications: Tuple[
        Mapping[str, object], ...
    ] = ()
    validation_admission: Optional[TypedArtifactBindingV2] = None
    validation_admission_snapshot: Optional[
        AuthenticatedClosureSnapshotV2
    ] = None
    validation_admission_semantic_verifier: Optional[
        Callable[[TypedArtifactBindingV2, Mapping[str, object]], Mapping[str, object]]
    ] = None

    def __post_init__(self) -> None:
        publication_fields = (
            "best_fixed_publications",
            "conventional_publications",
            "non_ash_selector_publications",
            "development_best_fixed_publications",
            "development_conventional_publications",
            "development_non_ash_selector_publications",
        )
        if (
            type(self.run_id) is not str
            or not self.run_id
            or self.split not in {"development", "validation"}
            or not _is_sha256(self.shared_bank_configuration_sha256)
            or not _is_sha256(self.degradation_policy_sha256)
            or not _is_sha256(self.source_profile_matrix_sha256)
            or type(self.non_ash_profile) is not NonAshSelectorExecutionProfileV2
            or type(self.non_ash_evaluation_scope)
            is not NonAshSelectorEvaluationScopeV2
            or type(self.non_ash_selection) is not NonAshControlSelectionInputV2
            or any(type(getattr(self, field)) is not tuple for field in publication_fields)
        ):
            raise ProductionControlSelectionV2Error(
                "production control-selection request is invalid"
            )
        if (
            self.non_ash_evaluation_scope.shared_bank_configuration_sha256
            != self.shared_bank_configuration_sha256
            or self.non_ash_evaluation_scope.degradation_policy_sha256
            != self.degradation_policy_sha256
        ):
            raise ProductionControlSelectionV2Error(
                "non-ASH evaluation scope differs from the request"
            )
        for field in publication_fields:
            publications = getattr(self, field)
            copies = tuple(
                _canonical_object(publication, label=f"{field} publication")
                for publication in publications
            )
            object.__setattr__(self, field, copies)
        if self.split == "development":
            if (
                self.development_source_profile_matrix_sha256 is not None
                or self.development_best_fixed_publications
                or self.development_conventional_publications
                or self.development_non_ash_selector_publications
                or self.validation_admission is not None
                or self.validation_admission_snapshot is not None
                or self.validation_admission_semantic_verifier is not None
            ):
                raise ProductionControlSelectionV2Error(
                    "development request contains validation predecessors"
                )
            return
        if (
            not _is_sha256(self.development_source_profile_matrix_sha256)
            or self.development_source_profile_matrix_sha256
            == self.source_profile_matrix_sha256
            or not self.development_best_fixed_publications
            or not self.development_conventional_publications
            or not self.development_non_ash_selector_publications
            or type(self.validation_admission) is not TypedArtifactBindingV2
            or self.validation_admission.artifact_kind
            != "p06_validation_candidate_development_evidence_v2"
            or self.validation_admission.schema_sha256
            != schema_sha256_for_kind_v2(
                "p06_validation_candidate_development_evidence_v2"
            )
            or type(self.validation_admission_snapshot)
            is not AuthenticatedClosureSnapshotV2
            or not callable(self.validation_admission_semantic_verifier)
        ):
            raise ProductionControlSelectionV2Error(
                "validation request predecessors are invalid"
            )
        assert self.validation_admission is not None
        assert self.validation_admission_snapshot is not None
        _snapshot_exactly_matches(
            self.validation_admission_snapshot,
            (self.validation_admission,),
            label="validation admission",
        )

    def authorization_scope(self) -> ControlAuthorizationScopeV2:
        return ControlAuthorizationScopeV2(
            run_id=self.run_id,
            split=self.split,
            shared_bank_configuration_sha256=(
                self.shared_bank_configuration_sha256
            ),
            degradation_policy_sha256=self.degradation_policy_sha256,
            source_profile_matrix_sha256=self.source_profile_matrix_sha256,
            development_source_profile_matrix_sha256=(
                self.development_source_profile_matrix_sha256
            ),
            validation_admission=self.validation_admission,
        )


@dataclass(frozen=True)
class ProductionControlSelectionResultV2:
    """Verified detached result and its complete immutable byte closure."""

    bundle_document: Mapping[str, object]
    bundle_binding: TypedArtifactBindingV2
    evidence_snapshot: AuthenticatedClosureSnapshotV2
    dependency_bindings: Tuple[TypedArtifactBindingV2, ...]
    control_selection_bindings: Tuple[TypedArtifactBindingV2, ...]
    verified: VerifiedControlAuthorizationV2


@dataclass(frozen=True)
class _RankedPublicationV2:
    stable_id: object
    control_configuration_sha256: str
    objective: Tuple[float, ...]
    objective_summary: TypedArtifactBindingV2
    output_manifest: TypedArtifactBindingV2

    def result_document(self, *, id_field: str) -> Dict[str, object]:
        return {
            id_field: self.stable_id,
            "control_configuration_sha256": self.control_configuration_sha256,
            "engine_raw_corpus_mean_tuple": list(self.objective),
            "objective_summary": self.objective_summary.as_document(),
            "output_manifest": self.output_manifest.as_document(),
        }


class _ClosureAssemblerV2:
    def __init__(self) -> None:
        self._files: Dict[str, Tuple[TypedArtifactBindingV2, bytes]] = {}
        self._by_digest: Dict[str, TypedArtifactBindingV2] = {}
        self._dependencies: Dict[str, TypedArtifactBindingV2] = {}

    def add_closure(
        self,
        snapshot: AuthenticatedClosureSnapshotV2,
        bindings: Sequence[TypedArtifactBindingV2],
        *,
        label: str,
    ) -> None:
        ordered = _ordered_unique_bindings(bindings, label=label)
        _snapshot_exactly_matches(snapshot, ordered, label=label)
        for binding in ordered:
            self.add_payload(
                binding,
                snapshot.payload(binding.closure_binding()),
                dependency=True,
            )

    def add_payload(
        self,
        binding: TypedArtifactBindingV2,
        payload: bytes,
        *,
        dependency: bool,
    ) -> None:
        if (
            type(binding) is not TypedArtifactBindingV2
            or type(payload) is not bytes
            or not payload
            or len(payload) != binding.size_bytes
            or _sha256(payload) != binding.sha256
        ):
            raise ProductionControlSelectionV2Error(
                "closure payload differs from its typed binding"
            )
        existing = self._files.get(binding.path)
        if existing is not None and existing != (binding, payload):
            raise ProductionControlSelectionV2Error(
                "closure path aliases different bytes or types"
            )
        digest_binding = self._by_digest.get(binding.sha256)
        if digest_binding is not None and digest_binding != binding:
            raise ProductionControlSelectionV2Error(
                "closure digest aliases a different path or type"
            )
        self._files[binding.path] = (binding, payload)
        self._by_digest[binding.sha256] = binding
        if dependency:
            self._dependencies[binding.path] = binding

    def dependencies(self) -> Tuple[TypedArtifactBindingV2, ...]:
        return tuple(
            sorted(self._dependencies.values(), key=_binding_sort_key)
        )

    def snapshot(self) -> AuthenticatedClosureSnapshotV2:
        return AuthenticatedClosureSnapshotV2(
            tuple(
                ClosureFileSnapshotV2(
                    ClosureFileBindingV2(
                        binding.path,
                        binding.sha256,
                        binding.size_bytes,
                    ),
                    payload,
                )
                for binding, payload in self._files.values()
            )
        )

    def entries(self) -> Tuple[Tuple[TypedArtifactBindingV2, bytes], ...]:
        return tuple(
            sorted(
                self._files.values(),
                key=lambda entry: _binding_sort_key(entry[0]),
            )
        )


class _PublishedControlClosureStoreV2:
    """Publish declared closure paths without links, replacement, or aliases."""

    _TEMPORARY_PREFIX = ".mirmir-control-v2-"

    def __init__(self, root: Path) -> None:
        self._root = Path(os.path.abspath(os.fspath(root)))
        if not self._root.is_absolute():
            raise ProductionControlSelectionV2Error(
                "control closure root is not absolute"
            )
        self._root_descriptor = self._open_absolute_root(self._root)

    @staticmethod
    def _directory_flags() -> int:
        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        return flags

    @classmethod
    def _open_absolute_root(cls, root: Path) -> int:
        descriptor = os.open(os.sep, cls._directory_flags())
        try:
            for component in root.parts[1:]:
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                    os.fsync(descriptor)
                except FileExistsError:
                    pass
                before = os.stat(
                    component,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                child = os.open(
                    component,
                    cls._directory_flags(),
                    dir_fd=descriptor,
                )
                opened = os.fstat(child)
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(opened.st_mode)
                    or (before.st_dev, before.st_ino)
                    != (opened.st_dev, opened.st_ino)
                ):
                    os.close(child)
                    raise ProductionControlSelectionV2Error(
                        "control closure root identity changed"
                    )
                os.close(descriptor)
                descriptor = child
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    @staticmethod
    def _relative_parts(path: str) -> Tuple[str, ...]:
        parsed = PurePosixPath(path)
        if (
            parsed.is_absolute()
            or parsed.as_posix() != path
            or any(part in {"", ".", ".."} for part in parsed.parts)
        ):
            raise ProductionControlSelectionV2Error(
                "control closure binding path is unsafe"
            )
        return tuple(parsed.parts)

    def _directory(self, parts: Sequence[str]) -> int:
        descriptor = os.dup(self._root_descriptor)
        try:
            for component in parts:
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                    os.fsync(descriptor)
                except FileExistsError:
                    pass
                before = os.stat(
                    component,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                child = os.open(
                    component,
                    self._directory_flags(),
                    dir_fd=descriptor,
                )
                opened = os.fstat(child)
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(opened.st_mode)
                    or (before.st_dev, before.st_ino)
                    != (opened.st_dev, opened.st_ino)
                ):
                    os.close(child)
                    raise ProductionControlSelectionV2Error(
                        "control closure directory identity changed"
                    )
                os.close(descriptor)
                descriptor = child
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    @staticmethod
    def _read_at(descriptor: int, name: str) -> bytes:
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        file_descriptor = os.open(name, flags, dir_fd=descriptor)
        try:
            if not stat.S_ISREG(os.fstat(file_descriptor).st_mode):
                raise ProductionControlSelectionV2Error(
                    "control closure path is not a regular file"
                )
            chunks = []
            while True:
                chunk = os.read(file_descriptor, 1024 * 1024)
                if not chunk:
                    return b"".join(chunks)
                chunks.append(chunk)
        finally:
            os.close(file_descriptor)

    @classmethod
    def _publish_at(cls, descriptor: int, name: str, payload: bytes) -> None:
        try:
            existing = cls._read_at(descriptor, name)
        except FileNotFoundError:
            existing = None
        if existing is not None:
            if existing != payload:
                raise ProductionControlSelectionV2Error(
                    "published control closure bytes changed"
                )
            return
        temporary = (
            f"{cls._TEMPORARY_PREFIX}{os.getpid()}-"
            f"{secrets.token_hex(16)}.tmp"
        )
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        file_descriptor = os.open(
            temporary,
            flags,
            0o600,
            dir_fd=descriptor,
        )
        try:
            offset = 0
            while offset < len(payload):
                written = os.write(file_descriptor, payload[offset:])
                if written <= 0:
                    raise ProductionControlSelectionV2Error(
                        "control closure publication made no progress"
                    )
                offset += written
            os.fsync(file_descriptor)
            try:
                os.link(
                    temporary,
                    name,
                    src_dir_fd=descriptor,
                    dst_dir_fd=descriptor,
                    follow_symlinks=False,
                )
            except FileExistsError:
                if cls._read_at(descriptor, name) != payload:
                    raise ProductionControlSelectionV2Error(
                        "published control closure bytes changed"
                    )
            os.fsync(descriptor)
        finally:
            os.close(file_descriptor)
            try:
                os.unlink(temporary, dir_fd=descriptor)
            except FileNotFoundError:
                pass
            os.fsync(descriptor)

    def publish(
        self,
        entries: Sequence[Tuple[TypedArtifactBindingV2, bytes]],
        *,
        terminal_binding: TypedArtifactBindingV2,
    ) -> None:
        ordered = [entry for entry in entries if entry[0] != terminal_binding]
        ordered.extend(entry for entry in entries if entry[0] == terminal_binding)
        if len(ordered) != len(entries) or ordered[-1][0] != terminal_binding:
            raise ProductionControlSelectionV2Error(
                "control closure terminal publication is absent"
            )
        for binding, payload in ordered:
            parts = self._relative_parts(binding.path)
            descriptor = self._directory(parts[:-1])
            try:
                self._publish_at(descriptor, parts[-1], payload)
                reopened = self._read_at(descriptor, parts[-1])
            finally:
                os.close(descriptor)
            if (
                reopened != payload
                or len(reopened) != binding.size_bytes
                or _sha256(reopened) != binding.sha256
            ):
                raise ProductionControlSelectionV2Error(
                    "published control closure failed exact reopen"
                )

    def close(self) -> None:
        descriptor = getattr(self, "_root_descriptor", -1)
        if descriptor >= 0:
            os.close(descriptor)
            self._root_descriptor = -1


class ProductionControlSelectionV2:
    """Persist, compose, reopen, and fully verify one V2 control bundle."""

    def __init__(
        self,
        *,
        raw_publisher: RawControlAuthorizationArtifactPublisherV2,
        artifact_root: Path,
        verifier: ControlAuthorizationVerifierV2,
    ) -> None:
        if (
            type(raw_publisher) is not RawControlAuthorizationArtifactPublisherV2
            or type(verifier) is not ControlAuthorizationVerifierV2
        ):
            raise ProductionControlSelectionV2Error(
                "production control-selection capabilities are invalid"
            )
        self.raw_publisher = raw_publisher
        self.verifier = verifier
        self._artifact_root = Path(artifact_root)
        try:
            self._store = ContentAddressedEvidenceStore(Path(artifact_root))
        except Exception as error:
            raise ProductionControlSelectionV2Error(
                "control-selection artifact store is unsafe"
            ) from error

    def _persist_document(
        self,
        document: Mapping[str, object],
        *,
        artifact_kind: str,
        assembler: _ClosureAssemblerV2,
        dependency: bool,
    ) -> Tuple[TypedArtifactBindingV2, Dict[str, object]]:
        exact = _canonical_object(document, label=artifact_kind)
        try:
            stored = self._store.publish(exact)
            reopened = self._store.reopen(str(stored["sha256"]))
        except Exception as error:
            raise ProductionControlSelectionV2Error(
                f"{artifact_kind} persistence or reopening failed"
            ) from error
        if reopened != exact:
            raise ProductionControlSelectionV2Error(
                f"{artifact_kind} changed during persistent reopening"
            )
        payload = canonical_json_file_bytes_v2(reopened)
        digest = _sha256(payload)
        binding = TypedArtifactBindingV2(
            artifact_kind=artifact_kind,
            schema_sha256=schema_sha256_for_kind_v2(artifact_kind),
            path=f"control-selection-v2/{artifact_kind}/{digest}.json",
            sha256=digest,
            size_bytes=len(payload),
        )
        assembler.add_payload(binding, payload, dependency=dependency)
        return binding, _canonical_object(reopened, label=artifact_kind)

    def _publication(
        self,
        publication: Mapping[str, object],
        *,
        split: str,
        family: str,
        matrix_sha256: str,
        assembler: _ClosureAssemblerV2,
    ) -> _RankedPublicationV2:
        exact = _canonical_object(publication, label=f"{family} publication")
        if (
            exact.get("schema_version") != SCHEMA_VERSION_V2
            or exact.get("artifact_kind")
            != RAW_CONTROL_AGGREGATE_PUBLICATION_KIND_V2
            or exact.get("run_id") != self.raw_publisher.run_id
            or exact.get("split") != split
            or exact.get("control_family") != family
            or exact.get("source_profile_matrix_sha256") != matrix_sha256
            or exact.get("comparison_domains") != ["engine_raw"]
        ):
            raise ProductionControlSelectionV2Error(
                f"{family} raw V2 publication scope differs"
            )
        try:
            snapshot = self.raw_publisher.snapshot_for(exact)
            dependencies = self.raw_publisher.dependency_bindings_for(exact)
        except Exception as error:
            raise ProductionControlSelectionV2Error(
                f"{family} publication was not issued by the raw publisher"
            ) from error
        declared = exact.get("dependency_bindings")
        if (
            type(declared) is not list
            or declared != [binding.as_document() for binding in dependencies]
            or exact.get("dependency_set_sha256")
            != dependency_set_sha256_v2(dependencies)
            or exact.get("closure_sha256") != snapshot.closure_sha256
        ):
            raise ProductionControlSelectionV2Error(
                f"{family} publication dependency identity differs"
            )
        assembler.add_closure(
            snapshot,
            dependencies,
            label=f"{family} raw publication",
        )
        try:
            objective_binding = TypedArtifactBindingV2.from_document(
                exact.get("objective_summary")
            )
            output_binding = TypedArtifactBindingV2.from_document(
                exact.get("output_manifest")
            )
        except ControlAuthorizationV2Error as error:
            raise ProductionControlSelectionV2Error(
                f"{family} aggregate bindings are invalid"
            ) from error
        if (
            objective_binding.artifact_kind != OBJECTIVE_SUMMARY_KIND
            or objective_binding.schema_sha256
            != schema_sha256_for_kind_v2(OBJECTIVE_SUMMARY_KIND)
            or output_binding.artifact_kind != OUTPUT_MANIFEST_KIND
            or output_binding.schema_sha256
            != schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND)
            or objective_binding not in dependencies
            or output_binding not in dependencies
        ):
            raise ProductionControlSelectionV2Error(
                f"{family} aggregate binding types differ"
            )
        summary = _canonical_file_object(
            snapshot.payload(objective_binding.closure_binding()),
            label=f"{family} objective summary",
        )
        stable_id = exact.get("stable_id")
        means = summary.get("means")
        if (
            summary.get("artifact_kind") != OBJECTIVE_SUMMARY_KIND
            or summary.get("run_id") != self.raw_publisher.run_id
            or summary.get("split") != split
            or summary.get("control_family") != family
            or summary.get("stable_id") != stable_id
            or summary.get("source_profile_matrix_sha256") != matrix_sha256
            or summary.get("metric_order") != list(SELECTION_METRICS)
            or summary.get("comparison_domain") != "engine_raw"
            or type(means) is not list
            or len(means) != len(SELECTION_METRICS)
            or any(type(value) not in {int, float} or not math.isfinite(value) for value in means)
            or not _is_sha256(summary.get("control_configuration_sha256"))
        ):
            raise ProductionControlSelectionV2Error(
                f"{family} objective summary differs"
            )
        return _RankedPublicationV2(
            stable_id=stable_id,
            control_configuration_sha256=str(
                summary["control_configuration_sha256"]
            ),
            objective=tuple(float(value) for value in means),
            objective_summary=objective_binding,
            output_manifest=output_binding,
        )

    def _ranked_publications(
        self,
        publications: Sequence[Mapping[str, object]],
        *,
        split: str,
        family: str,
        bank_sha256: str,
        matrix_sha256: str,
        assembler: _ClosureAssemblerV2,
    ) -> Tuple[_RankedPublicationV2, ...]:
        expected_ids: Tuple[object, ...]
        if family == "best_fixed":
            expected_ids = tuple(FIXED_DESCRIPTOR_IDS)
        elif family == "conventional":
            expected_ids = tuple(CONVENTIONAL_ALGORITHM_IDS)
        else:
            raise ProductionControlSelectionV2Error(
                "ranked control family is invalid"
            )
        if type(publications) not in {tuple, list}:
            raise ProductionControlSelectionV2Error(
                f"{family} publication set is invalid"
            )
        by_id: Dict[object, _RankedPublicationV2] = {}
        for publication in publications:
            parsed = self._publication(
                publication,
                split=split,
                family=family,
                matrix_sha256=matrix_sha256,
                assembler=assembler,
            )
            if (
                family == "best_fixed"
                and (
                    type(parsed.stable_id) is not int
                    or parsed.stable_id not in expected_ids
                )
            ) or (
                family == "conventional"
                and (
                    type(parsed.stable_id) is not str
                    or parsed.stable_id not in expected_ids
                )
            ):
                raise ProductionControlSelectionV2Error(
                    f"{family} publication stable ID differs"
                )
            if parsed.stable_id in by_id:
                raise ProductionControlSelectionV2Error(
                    f"{family} publication stable ID repeats"
                )
            by_id[parsed.stable_id] = parsed
        if set(by_id) != set(expected_ids):
            raise ProductionControlSelectionV2Error(
                f"{family} publication coverage differs"
            )
        ordered = tuple(by_id[identifier] for identifier in expected_ids)
        for row in ordered:
            expected_configuration = (
                fixed_control_configuration_sha256_v2(
                    row.stable_id,
                    bank_sha256,
                )
                if family == "best_fixed"
                else conventional_control_configuration_sha256_v2(
                    row.stable_id,
                    bank_sha256,
                )
            )
            if row.control_configuration_sha256 != expected_configuration:
                raise ProductionControlSelectionV2Error(
                    f"{family} production configuration identity differs"
                )
        return ordered

    @staticmethod
    def _winner(rows: Sequence[_RankedPublicationV2]) -> object:
        best = max(row.objective for row in rows)
        return min(row.stable_id for row in rows if row.objective == best)

    def _ranked_selection(
        self,
        *,
        request: ProductionControlSelectionRequestV2,
        split: str,
        family: str,
        matrix_sha256: str,
        rows: Sequence[_RankedPublicationV2],
        assembler: _ClosureAssemblerV2,
        development_binding: Optional[TypedArtifactBindingV2] = None,
    ) -> TypedArtifactBindingV2:
        fixed = family == "best_fixed"
        kind = FIXED_SELECTION_KIND if fixed else CONVENTIONAL_SELECTION_KIND
        id_field = "descriptor_id" if fixed else "algorithm_id"
        stage = (
            "development_provisional"
            if split == "development"
            else "validation_final"
        )
        tie_break = (
            _FIXED_DEVELOPMENT_TIE
            if fixed and split == "development"
            else (
                _FIXED_VALIDATION_TIE
                if fixed
                else (
                    _CONVENTIONAL_DEVELOPMENT_TIE
                    if split == "development"
                    else _CONVENTIONAL_VALIDATION_TIE
                )
            )
        )
        document: Dict[str, object] = {
            "schema_version": SCHEMA_VERSION_V2,
            "artifact_kind": kind,
            "authority_bindings": authority_bindings_v2(),
            "run_id": request.run_id,
            "selection_stage": stage,
            "split": split,
            "shared_bank_configuration_sha256": (
                request.shared_bank_configuration_sha256
            ),
            "degradation_policy_sha256": request.degradation_policy_sha256,
            "source_profile_matrix_sha256": matrix_sha256,
            "uniform_application": True,
            "candidate_ids": list(
                FIXED_DESCRIPTOR_IDS if fixed else CONVENTIONAL_ALGORITHM_IDS
            ),
            "selection_objective": dict(SELECTION_OBJECTIVE),
            "tie_break": tie_break,
            "data_access": {
                "development_metrics_accessed": True,
                "validation_accessed": split == "validation",
                "holdout_accessed": False,
                "release_locks_written": False,
            },
            "artifact_sha256": _ZERO_SHA256,
        }
        results = [row.result_document(id_field=id_field) for row in rows]
        winner = self._winner(rows)
        if split == "development":
            document["development_results"] = results
            document[
                "provisional_descriptor_id"
                if fixed
                else "provisional_algorithm_id"
            ] = winner
        else:
            if (
                type(development_binding) is not TypedArtifactBindingV2
                or request.validation_admission is None
            ):
                raise ProductionControlSelectionV2Error(
                    f"{family} validation predecessors are absent"
                )
            document["development_selection"] = (
                development_binding.as_document()
            )
            document["validation_admission"] = (
                request.validation_admission.as_document()
            )
            document["validation_results"] = results
            document[
                "chosen_descriptor_id" if fixed else "chosen_algorithm_id"
            ] = winner
        finalized = finalize_artifact_sha256_v2(document)
        binding, _ = self._persist_document(
            finalized,
            artifact_kind=kind,
            assembler=assembler,
            dependency=True,
        )
        return binding

    def _add_non_ash_publications(
        self,
        publications: Sequence[Mapping[str, object]],
        *,
        split: str,
        matrix_sha256: str,
        assembler: _ClosureAssemblerV2,
    ) -> None:
        if type(publications) not in {tuple, list} or not publications:
            raise ProductionControlSelectionV2Error(
                f"non-ASH {split} raw publication set is empty or invalid"
            )
        stable_ids = []
        for publication in publications:
            parsed = self._publication(
                publication,
                split=split,
                family="non_ash_selector",
                matrix_sha256=matrix_sha256,
                assembler=assembler,
            )
            if not _is_sha256(parsed.stable_id):
                raise ProductionControlSelectionV2Error(
                    f"non-ASH {split} stable rule identity is invalid"
                )
            stable_ids.append(parsed.stable_id)
        if len(stable_ids) != len(set(stable_ids)):
            raise ProductionControlSelectionV2Error(
                f"non-ASH {split} raw publication identity repeats"
            )

    def authorize(
        self,
        request: ProductionControlSelectionRequestV2,
    ) -> ProductionControlSelectionResultV2:
        if type(request) is not ProductionControlSelectionRequestV2:
            raise ProductionControlSelectionV2Error(
                "control-selection request has the wrong type"
            )
        if request.run_id != self.raw_publisher.run_id:
            raise ProductionControlSelectionV2Error(
                "control-selection request run ID differs from the publisher"
            )
        predecessor_names = set(request.non_ash_selection.predecessor_bindings)
        expected_predecessors = (
            {"development_ledger"}
            if request.split == "development"
            else {
                "development_ledger",
                "development_selection",
                "validation_neighbor_manifest",
            }
        )
        if predecessor_names != expected_predecessors:
            raise ProductionControlSelectionV2Error(
                "non-ASH predecessor split set differs"
            )
        predecessor_kinds = {
            "development_ledger": ATTEMPT_LEDGER_KIND,
            "development_selection": SELECTION_KIND,
            "validation_neighbor_manifest": NEIGHBOR_MANIFEST_KIND,
        }
        for name, binding in request.non_ash_selection.predecessor_bindings.items():
            if (
                binding.artifact_kind != predecessor_kinds[name]
                or binding.schema_sha256
                != schema_sha256_for_kind_v2(predecessor_kinds[name])
            ):
                raise ProductionControlSelectionV2Error(
                    f"non-ASH {name} typed binding differs"
                )

        assembler = _ClosureAssemblerV2()
        assembler.add_closure(
            request.non_ash_selection.evidence_snapshot,
            request.non_ash_selection.dependency_bindings,
            label="non-ASH persisted closure",
        )
        if request.split == "validation":
            assert request.validation_admission is not None
            assert request.validation_admission_snapshot is not None
            assembler.add_closure(
                request.validation_admission_snapshot,
                (request.validation_admission,),
                label="validation admission",
            )

        development_fixed_binding = None
        development_conventional_binding = None
        if request.split == "validation":
            assert request.development_source_profile_matrix_sha256 is not None
            development_fixed_rows = self._ranked_publications(
                request.development_best_fixed_publications,
                split="development",
                family="best_fixed",
                bank_sha256=request.shared_bank_configuration_sha256,
                matrix_sha256=(
                    request.development_source_profile_matrix_sha256
                ),
                assembler=assembler,
            )
            development_conventional_rows = self._ranked_publications(
                request.development_conventional_publications,
                split="development",
                family="conventional",
                bank_sha256=request.shared_bank_configuration_sha256,
                matrix_sha256=(
                    request.development_source_profile_matrix_sha256
                ),
                assembler=assembler,
            )
            self._add_non_ash_publications(
                request.development_non_ash_selector_publications,
                split="development",
                matrix_sha256=(
                    request.development_source_profile_matrix_sha256
                ),
                assembler=assembler,
            )
            development_fixed_binding = self._ranked_selection(
                request=request,
                split="development",
                family="best_fixed",
                matrix_sha256=(
                    request.development_source_profile_matrix_sha256
                ),
                rows=development_fixed_rows,
                assembler=assembler,
            )
            development_conventional_binding = self._ranked_selection(
                request=request,
                split="development",
                family="conventional",
                matrix_sha256=(
                    request.development_source_profile_matrix_sha256
                ),
                rows=development_conventional_rows,
                assembler=assembler,
            )

        fixed_rows = self._ranked_publications(
            request.best_fixed_publications,
            split=request.split,
            family="best_fixed",
            bank_sha256=request.shared_bank_configuration_sha256,
            matrix_sha256=request.source_profile_matrix_sha256,
            assembler=assembler,
        )
        conventional_rows = self._ranked_publications(
            request.conventional_publications,
            split=request.split,
            family="conventional",
            bank_sha256=request.shared_bank_configuration_sha256,
            matrix_sha256=request.source_profile_matrix_sha256,
            assembler=assembler,
        )
        self._add_non_ash_publications(
            request.non_ash_selector_publications,
            split=request.split,
            matrix_sha256=request.source_profile_matrix_sha256,
            assembler=assembler,
        )
        fixed_binding = self._ranked_selection(
            request=request,
            split=request.split,
            family="best_fixed",
            matrix_sha256=request.source_profile_matrix_sha256,
            rows=fixed_rows,
            assembler=assembler,
            development_binding=development_fixed_binding,
        )
        conventional_binding = self._ranked_selection(
            request=request,
            split=request.split,
            family="conventional",
            matrix_sha256=request.source_profile_matrix_sha256,
            rows=conventional_rows,
            assembler=assembler,
            development_binding=development_conventional_binding,
        )

        dependencies = assembler.dependencies()
        bundle: Dict[str, object] = {
            "schema_version": "2.0.1",
            "artifact_kind": CONTROL_AUTHORIZATION_BUNDLE_KIND,
            "authority_bindings": authority_bindings_v2(),
            "run_id": request.run_id,
            "split": request.split,
            "shared_bank_configuration_sha256": (
                request.shared_bank_configuration_sha256
            ),
            "degradation_policy_sha256": request.degradation_policy_sha256,
            "source_profile_matrix_sha256": (
                request.source_profile_matrix_sha256
            ),
            "control_selections": [
                {
                    "id": "best_fixed",
                    "selection": fixed_binding.as_document(),
                },
                {
                    "id": "conventional",
                    "selection": conventional_binding.as_document(),
                },
                {
                    "id": "non_ash_selector",
                    "selection": (
                        request.non_ash_selection.selection_binding.as_document()
                    ),
                },
            ],
            "non_ash_predecessors": {
                name: binding.as_document()
                for name, binding in request.non_ash_selection.predecessor_bindings.items()
            },
            "dependency_bindings": [
                binding.as_document() for binding in dependencies
            ],
            "dependency_set_sha256": _ZERO_SHA256,
            "authorization_semantic_sha256": _ZERO_SHA256,
            "data_access": {
                "development_metrics_accessed": True,
                "validation_accessed": request.split == "validation",
                "holdout_accessed": False,
                "media_payloads_accessed": False,
                "release_locks_written": False,
                "winner_claim_made": False,
            },
            "artifact_sha256": _ZERO_SHA256,
        }
        if request.split == "validation":
            assert request.development_source_profile_matrix_sha256 is not None
            assert request.validation_admission is not None
            bundle["development_source_profile_matrix_sha256"] = (
                request.development_source_profile_matrix_sha256
            )
            bundle["validation_admission"] = (
                request.validation_admission.as_document()
            )
        bundle = finalize_control_authorization_bundle_v2(bundle)
        bundle_binding, reopened_bundle = self._persist_document(
            bundle,
            artifact_kind=CONTROL_AUTHORIZATION_BUNDLE_KIND,
            assembler=assembler,
            dependency=False,
        )
        evidence_snapshot = assembler.snapshot()
        try:
            verified = self.verifier.verify_bundle(
                bundle_binding,
                evidence_snapshot=evidence_snapshot,
                expected_scope=request.authorization_scope(),
                non_ash_profile=request.non_ash_profile,
                non_ash_evaluation_scope=request.non_ash_evaluation_scope,
                validation_admission_semantic_verifier=(
                    request.validation_admission_semantic_verifier
                ),
            )
        except Exception as error:
            raise ProductionControlSelectionV2Error(
                "complete V2 control authorization replay failed"
            ) from error
        expected_controls = (
            fixed_binding,
            conventional_binding,
            request.non_ash_selection.selection_binding,
        )
        if (
            verified.document != reopened_bundle
            or verified.bundle_binding != bundle_binding
            or verified.dependency_bindings != dependencies
            or verified.control_selection_bindings != expected_controls
        ):
            raise ProductionControlSelectionV2Error(
                "verified V2 control authorization result differs"
            )
        closure_store = _PublishedControlClosureStoreV2(
            self._artifact_root
        )
        try:
            closure_store.publish(
                assembler.entries(),
                terminal_binding=bundle_binding,
            )
        finally:
            closure_store.close()
        return ProductionControlSelectionResultV2(
            bundle_document=_canonical_object(
                reopened_bundle,
                label="verified control authorization bundle",
            ),
            bundle_binding=bundle_binding,
            evidence_snapshot=evidence_snapshot,
            dependency_bindings=dependencies,
            control_selection_bindings=expected_controls,
            verified=verified,
        )


__all__ = [
    "NonAshControlSelectionInputV2",
    "ProductionControlSelectionRequestV2",
    "ProductionControlSelectionResultV2",
    "ProductionControlSelectionV2",
    "ProductionControlSelectionV2Error",
]
