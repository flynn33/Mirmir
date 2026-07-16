"""Independent Python oracle for the locked schema-2 / LUT format-1.2 boundary.

Only compiler-contract-v2 paths declared exactly inherited from V1 use the frozen
V1 primitives below. Schema-2 configuration is parsed, compiled, serialized, and
validated by native V2 types; it is never converted into a schema-1 input.
"""

from __future__ import annotations

import binascii
import copy
import hashlib
import json
import math
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

from validation.calibration_v2.reference import lut_oracle as inherited_v1


UINT16_MAX = (1 << 16) - 1
UINT32_MAX = (1 << 32) - 1
UINT64_MAX = (1 << 64) - 1

MAGIC = b"ASHV2LUT"
HEADER_SIZE = 320
ENTRY_STRIDE = 24
PARAMETER_STRIDE = 64
PARAMETER_PREFIX_SIZE = 60
HEADER_FLAGS = 0x000F
PLANE_COUNT = 2
CONTEXT_COUNT = 4
VALID_STATE_COUNT = 256
CHROMA_EDGE_CONFIDENCE_ENCODING = 1

HASH_BINDING_KEYS = (
    "mapping_sha256",
    "operator_bank_sha256",
    "metric_policy_sha256",
    "compiler_inputs_sha256",
    "calibration_plan_sha256",
    "corpus_lock_bundle_sha256",
)

CANONICALIZATION = {
    "encoding": "UTF-8",
    "object_key_order": "ascending Unicode scalar value",
    "array_order": "preserved",
    "whitespace": "none",
    "string_escaping": (
        "JSON quotation, reverse-solidus, and control escapes; "
        "non-ASCII encoded directly as UTF-8"
    ),
    "number_domain": "integers only",
    "duplicate_keys": "reject",
    "trailing_newline_in_hash_input": False,
    "hash_algorithm": "SHA-256",
    "hash_scope": (
        "complete canonical document with only "
        "/hash_bindings/compiler_inputs_sha256 omitted"
    ),
}

TEMPORAL_CONTRACT = {
    "enabled": False,
    "context_count": 4,
    "context_aliases_to_spatial": [1, 2, 3],
    "semantic_state": "clear payload coordinate 7 and recompute coordinate 9 parity",
    "affine_anchor": "original parity-valid source state",
}

SOURCE_ALIGNED_CONTRACT = {
    "exact": True,
    "predicate": (
        "the current plane coordinate policy is source_aligned_rational and "
        "horizontal and vertical phase indices are zero"
    ),
    "primary_message": 0,
    "primary_descriptor": 0,
    "secondary": "inactive",
    "denoising": False,
}

ADMISSIBLE_POLICY_IDS = (
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
)


OracleError = inherited_v1.OracleError
CanonicalPath = inherited_v1.CanonicalPath
Candidate = inherited_v1.Candidate
CandidateSlot = inherited_v1.CandidateSlot
INACTIVE_SLOT = inherited_v1.INACTIVE_SLOT
CANONICAL_PATHS = inherited_v1.CANONICAL_PATHS
VALID_STATES = inherited_v1.VALID_STATES


@dataclass(frozen=True)
class Plane:
    name: str
    plane_id: int


PLANES = (
    Plane("luma", 0),
    Plane("chroma", 1),
)
PLANES_BY_ID = {plane.plane_id: plane for plane in PLANES}


@dataclass(frozen=True)
class Route:
    name: str
    route_id: int
    scale_numerator: int
    scale_denominator: int
    phase_count: int
    entry_count: int
    filename: str

    @property
    def plane_entry_count(self) -> int:
        return self.phase_count * CONTEXT_COUNT * VALID_STATE_COUNT


ROUTES = {
    "direct_2x": Route("direct_2x", 1, 2, 1, 4, 8192, "direct2x.ashlut"),
    "direct_3_over_2": Route(
        "direct_3_over_2",
        2,
        3,
        2,
        9,
        18432,
        "direct3over2.ashlut",
    ),
}
ROUTES_BY_ID = {route.route_id: route for route in ROUTES.values()}


@dataclass(frozen=True)
class AnisotropyMode:
    ordinal: int
    mode_id: str
    anisotropy_strength_q12: int
    use_anisotropy: bool


ANISOTROPY_MODES = (
    AnisotropyMode(0, "q12_0_isotropic_v2", 0, False),
    AnisotropyMode(1, "q12_0_rotated_v1", 0, True),
    AnisotropyMode(2, "q12_1024_rotated_v1", 1024, True),
    AnisotropyMode(3, "q12_2048_rotated_v1", 2048, True),
    AnisotropyMode(4, "q12_3072_rotated_v1", 3072, True),
    AnisotropyMode(5, "q12_4096_rotated_v1", 4096, True),
)
ANISOTROPY_MODES_BY_ORDINAL = {mode.ordinal: mode for mode in ANISOTROPY_MODES}


@dataclass(frozen=True)
class RouteSelectionV2:
    route_spatial_policy_id: int
    luma_anisotropy_mode_ordinal: int
    chroma_anisotropy_mode_ordinal: int
    luma_coordinate_policy: str
    chroma_coordinate_policy: str
    analysis_grid_source_step: int

    def mode_for_plane(self, plane: Plane) -> AnisotropyMode:
        ordinal = (
            self.luma_anisotropy_mode_ordinal
            if plane.plane_id == 0
            else self.chroma_anisotropy_mode_ordinal
        )
        return ANISOTROPY_MODES_BY_ORDINAL[ordinal]

    def coordinate_policy_for_plane(self, plane: Plane) -> str:
        return (
            self.luma_coordinate_policy
            if plane.plane_id == 0
            else self.chroma_coordinate_policy
        )


@dataclass(frozen=True)
class OperatorParametersV2:
    minimum_anisotropic_magnitude_unorm15: int
    minimum_anisotropic_coherence_unorm15: int
    detail_gain_q12: int
    relaxed_limiter_alpha_q12: int
    risk_detail_suppression_unorm15: int
    low_pass_radius_q8_8: int
    weight_epsilon_f32_bits: int


SemanticSteps = inherited_v1.SemanticSteps
CompilerPolicy = inherited_v1.CompilerPolicy


@dataclass(frozen=True)
class LockedCompilerInputV2:
    configuration_id: str
    hash_bindings: Mapping[str, str]
    boundary_mode: str
    operator_parameters: OperatorParametersV2
    semantic_steps: SemanticSteps
    compiler_policy: CompilerPolicy
    routes: Mapping[str, RouteSelectionV2]
    canonical_document: Mapping[str, Any]


@dataclass(frozen=True)
class CompiledEntryV2:
    logical_index: int
    plane: Plane
    source_state: int
    valid_state_ordinal: int
    phase_index: int
    context_id: int
    primary: Candidate
    secondary: Candidate | None
    primary_weight_unorm16: int
    secondary_weight_unorm16: int
    margin_unorm16: int
    source_aligned_exact: bool
    primary_slot: CandidateSlot
    secondary_slot: CandidateSlot


@dataclass(frozen=True)
class CompiledRouteV2:
    route: Route
    configuration: LockedCompilerInputV2
    entries: tuple[CompiledEntryV2, ...]


@dataclass(frozen=True)
class ValidatedLUTV2:
    route: Route
    plane_count: int
    entry_count: int
    parameter_count: int
    route_spatial_policy_id: int
    luma_anisotropy_mode_ordinal: int
    chroma_anisotropy_mode_ordinal: int
    luma_coordinate_policy: str
    chroma_coordinate_policy: str
    payload_sha256: str
    payload_crc32: int
    header_crc32: int
    whole_file_sha256: str
    hash_bindings: Mapping[str, str]

    @property
    def luma_anisotropy_mode(self) -> AnisotropyMode:
        return ANISOTROPY_MODES_BY_ORDINAL[self.luma_anisotropy_mode_ordinal]

    @property
    def chroma_anisotropy_mode(self) -> AnisotropyMode:
        return ANISOTROPY_MODES_BY_ORDINAL[self.chroma_anisotropy_mode_ordinal]


def _strict_keys(value: Mapping[str, Any], expected: Sequence[str], context: str) -> None:
    actual = set(value)
    required = set(expected)
    if actual != required:
        missing = sorted(required - actual)
        extra = sorted(actual - required)
        raise OracleError(
            "invalid_locked_input",
            f"{context} keys differ; missing={missing}, extra={extra}",
        )


def _object(value: Any, context: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise OracleError("invalid_locked_input", f"{context} must be an object")
    return value


def _integer(value: Any, context: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise OracleError("invalid_locked_input", f"{context} must be an integer")
    return value


def _enum_integer(value: Any, allowed: Sequence[int], context: str) -> int:
    result = _integer(value, context)
    if result not in allowed:
        raise OracleError("invalid_locked_input", f"{context} is outside its locked range")
    return result


def _digest(value: Any, context: str) -> str:
    if not isinstance(value, str) or len(value) != 64:
        raise OracleError("invalid_locked_input", f"{context} is not a SHA-256 digest")
    if value == "0" * 64 or any(character not in "0123456789abcdef" for character in value):
        raise OracleError("invalid_locked_input", f"{context} is not a nonzero lowercase digest")
    return value


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise OracleError("invalid_locked_input", f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def canonical_compiler_input_bytes_v2(document: Mapping[str, Any]) -> bytes:
    canonical = copy.deepcopy(dict(document))
    try:
        del canonical["hash_bindings"]["compiler_inputs_sha256"]
    except (KeyError, TypeError) as error:
        raise OracleError("invalid_locked_input", "compiler self-hash field is missing") from error
    try:
        return json.dumps(
            canonical,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise OracleError("invalid_locked_input", "document cannot be canonicalized") from error


def canonical_compiler_input_sha256_v2(document: Mapping[str, Any]) -> str:
    return hashlib.sha256(canonical_compiler_input_bytes_v2(document)).hexdigest()


def load_locked_compiler_input_v2(path: Path) -> LockedCompilerInputV2:
    try:
        document = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda value: (_ for _ in ()).throw(
                OracleError("invalid_locked_input", f"non-finite number {value}")
            ),
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise OracleError("invalid_locked_input", str(error)) from error
    if not isinstance(document, dict):
        raise OracleError("invalid_locked_input", "top level must be an object")
    return parse_locked_compiler_input_v2(document)


def parse_locked_compiler_input_v2(
    document: Mapping[str, Any],
) -> LockedCompilerInputV2:
    if not isinstance(document, dict):
        raise OracleError("invalid_locked_input", "top level must be an object")
    top_keys = (
        "schema_version",
        "status",
        "configuration_id",
        "hash_bindings",
        "canonicalization",
        "boundary_mode",
        "operator_parameters",
        "semantic_steps",
        "compiler_policy",
        "routes",
        "temporal",
        "source_aligned",
        "top_two",
    )
    _strict_keys(document, top_keys, "document")
    if document["schema_version"] != "2.0.0" or document["status"] != "locked":
        raise OracleError("invalid_locked_input", "schema version or status differs")

    configuration_id = document["configuration_id"]
    if not isinstance(configuration_id, str) or not (3 <= len(configuration_id) <= 128):
        raise OracleError("invalid_locked_input", "configuration_id is invalid")
    allowed_identifier = "abcdefghijklmnopqrstuvwxyz0123456789._-"
    if configuration_id[0] not in allowed_identifier[:36] or any(
        character not in allowed_identifier for character in configuration_id
    ):
        raise OracleError("invalid_locked_input", "configuration_id is invalid")

    hashes = _object(document["hash_bindings"], "hash_bindings")
    _strict_keys(hashes, HASH_BINDING_KEYS, "hash_bindings")
    validated_hashes = {
        key: _digest(hashes[key], f"hash_bindings.{key}") for key in HASH_BINDING_KEYS
    }
    if document["canonicalization"] != CANONICALIZATION:
        raise OracleError("invalid_locked_input", "canonicalization contract differs")
    if document["temporal"] != TEMPORAL_CONTRACT:
        raise OracleError("invalid_locked_input", "temporal contract differs")
    if document["source_aligned"] != SOURCE_ALIGNED_CONTRACT:
        raise OracleError("invalid_locked_input", "source-aligned contract differs")
    if document["top_two"] != 2:
        raise OracleError("invalid_locked_input", "top_two must equal two")
    if validated_hashes["compiler_inputs_sha256"] != canonical_compiler_input_sha256_v2(document):
        raise OracleError("invalid_locked_input", "compiler input self-hash mismatch")

    boundary_mode = document["boundary_mode"]
    if boundary_mode not in ("clamp", "mirror_reflect101"):
        raise OracleError("invalid_locked_input", "boundary_mode is invalid")

    operator = _object(document["operator_parameters"], "operator_parameters")
    operator_keys = (
        "minimum_anisotropic_magnitude_unorm15",
        "minimum_anisotropic_coherence_unorm15",
        "detail_gain_q12",
        "relaxed_limiter_alpha_q12",
        "risk_detail_suppression_unorm15",
        "low_pass_radius_q8_8",
        "weight_epsilon_f32_bits",
    )
    _strict_keys(operator, operator_keys, "operator_parameters")
    operator_parameters = OperatorParametersV2(
        _enum_integer(
            operator["minimum_anisotropic_magnitude_unorm15"],
            (819, 1638, 3277, 4915),
            "minimum magnitude",
        ),
        _enum_integer(
            operator["minimum_anisotropic_coherence_unorm15"],
            (3277, 4915, 8192, 12288),
            "minimum coherence",
        ),
        _enum_integer(operator["detail_gain_q12"], (0, 384, 768, 1152, 1536), "detail gain"),
        _enum_integer(operator["relaxed_limiter_alpha_q12"], (0, 128, 256, 384, 512), "relaxed alpha"),
        _enum_integer(operator["risk_detail_suppression_unorm15"], (16384, 21299, 26214), "risk suppression"),
        _enum_integer(operator["low_pass_radius_q8_8"], (384, 512, 640), "low-pass radius"),
        _enum_integer(operator["weight_epsilon_f32_bits"], (730643660,), "weight epsilon bits"),
    )

    steps = _object(document["semantic_steps"], "semantic_steps")
    step_keys = (
        "orientation_sector_step",
        "support_radius_step_q8_8",
        "detail_gain_step_q12",
        "regularization_step_q12",
    )
    _strict_keys(steps, step_keys, "semantic_steps")
    semantic_steps = SemanticSteps(
        _enum_integer(steps["orientation_sector_step"], (1,), "orientation step"),
        _enum_integer(steps["support_radius_step_q8_8"], (32, 64, 96), "support step"),
        _enum_integer(steps["detail_gain_step_q12"], (64, 128, 256), "detail step"),
        _enum_integer(steps["regularization_step_q12"], (32, 64, 128), "regularization step"),
    )

    policy = _object(document["compiler_policy"], "compiler_policy")
    policy_keys = (
        "penalty_decay_denominator",
        "penalty_to_weight_unorm16",
        "penalty_orientation_step",
        "penalty_support_step",
        "penalty_detail_step",
        "penalty_regularization_step",
        "penalty_unsupported_support_expansion",
        "penalty_coherent_support_reduction",
        "penalty_unsupported_detail_increase",
        "penalty_supported_detail_reduction",
        "penalty_relaxation_under_risk",
        "penalty_phase_kernel_mismatch",
        "confidence_threshold_unorm16",
    )
    _strict_keys(policy, policy_keys, "compiler_policy")
    denominator = _enum_integer(
        policy["penalty_decay_denominator"],
        (16, 32, 64, 128),
        "penalty decay denominator",
    )
    supplied_table = policy["penalty_to_weight_unorm16"]
    if not isinstance(supplied_table, list) or len(supplied_table) != 256:
        raise OracleError("invalid_locked_input", "penalty table must contain 256 integers")
    penalty_table = tuple(
        _integer(value, f"penalty table index {index}")
        for index, value in enumerate(supplied_table)
    )
    expected_table = tuple(
        inherited_v1.round_half_up(65535 * denominator, denominator + index)
        for index in range(256)
    )
    if penalty_table != expected_table:
        raise OracleError("invalid_locked_input", "penalty table differs from exact formula")
    compiler_policy = CompilerPolicy(
        denominator,
        penalty_table,
        _enum_integer(policy["penalty_orientation_step"], (0, 2, 4, 8), "orientation penalty"),
        _enum_integer(policy["penalty_support_step"], (0, 4, 8, 16), "support penalty"),
        _enum_integer(policy["penalty_detail_step"], (0, 4, 8, 16), "detail penalty"),
        _enum_integer(policy["penalty_regularization_step"], (0, 4, 8, 16), "regularization penalty"),
        _enum_integer(
            policy["penalty_unsupported_support_expansion"],
            (16, 32, 64, 96),
            "unsupported support penalty",
        ),
        _enum_integer(policy["penalty_coherent_support_reduction"], (8, 16, 32, 64), "coherent support penalty"),
        _enum_integer(policy["penalty_unsupported_detail_increase"], (16, 32, 64, 96), "unsupported detail penalty"),
        _enum_integer(policy["penalty_supported_detail_reduction"], (8, 16, 32, 64), "supported detail penalty"),
        _enum_integer(policy["penalty_relaxation_under_risk"], (32, 64, 96, 128), "risk relaxation penalty"),
        _enum_integer(policy["penalty_phase_kernel_mismatch"], (0, 4, 8, 16), "phase kernel penalty"),
        _enum_integer(
            policy["confidence_threshold_unorm16"],
            (16384, 24576, 32768, 36044, 40959, 49151),
            "confidence threshold",
        ),
    )

    route_values = _object(document["routes"], "routes")
    _strict_keys(route_values, tuple(ROUTES), "routes")
    selections: dict[str, RouteSelectionV2] = {}
    all_mode_ordinals: list[int] = []
    for route_name in ROUTES:
        selection = _object(route_values[route_name], f"routes.{route_name}")
        selection_keys = (
            "route_spatial_policy_id",
            "luma_anisotropy_mode_ordinal",
            "chroma_anisotropy_mode_ordinal",
            "luma_coordinate_policy",
            "chroma_coordinate_policy",
            "analysis_grid_source_step",
        )
        _strict_keys(selection, selection_keys, f"routes.{route_name}")
        luma_coordinate_policy = selection["luma_coordinate_policy"]
        chroma_coordinate_policy = selection["chroma_coordinate_policy"]
        for value, field in (
            (luma_coordinate_policy, "luma_coordinate_policy"),
            (chroma_coordinate_policy, "chroma_coordinate_policy"),
        ):
            if value not in ("half_pixel_center", "source_aligned_rational"):
                raise OracleError(
                    "invalid_locked_input",
                    f"routes.{route_name}.{field} is invalid",
                )
        luma_mode = _enum_integer(
            selection["luma_anisotropy_mode_ordinal"],
            tuple(ANISOTROPY_MODES_BY_ORDINAL),
            f"routes.{route_name}.luma_anisotropy_mode_ordinal",
        )
        chroma_mode = _enum_integer(
            selection["chroma_anisotropy_mode_ordinal"],
            tuple(ANISOTROPY_MODES_BY_ORDINAL),
            f"routes.{route_name}.chroma_anisotropy_mode_ordinal",
        )
        all_mode_ordinals.extend((luma_mode, chroma_mode))
        selections[route_name] = RouteSelectionV2(
            _enum_integer(
                selection["route_spatial_policy_id"],
                ADMISSIBLE_POLICY_IDS,
                f"routes.{route_name}.route_spatial_policy_id",
            ),
            luma_mode,
            chroma_mode,
            str(luma_coordinate_policy),
            str(chroma_coordinate_policy),
            _enum_integer(
                selection["analysis_grid_source_step"],
                (1, 2, 4),
                f"routes.{route_name}.analysis_grid_source_step",
            ),
        )
    if all(ordinal == 0 for ordinal in all_mode_ordinals):
        raise OracleError(
            "invalid_locked_input",
            "all-isotropic four-plane anisotropy vector is forbidden",
        )

    return LockedCompilerInputV2(
        configuration_id,
        validated_hashes,
        str(boundary_mode),
        operator_parameters,
        semantic_steps,
        compiler_policy,
        selections,
        copy.deepcopy(dict(document)),
    )


def phase_components(route: Route, phase_index: int) -> tuple[int, int]:
    if not 0 <= phase_index < route.phase_count:
        raise OracleError("invalid_phase", str(phase_index))
    return phase_index % route.scale_numerator, phase_index // route.scale_numerator


def phase_half_cycle(route: Route, phase_index: int) -> int:
    horizontal, vertical = phase_components(route, phase_index)
    return int(2 * horizontal >= route.scale_numerator) ^ int(
        2 * vertical >= route.scale_numerator
    )


def spatial_policy_descriptor(
    raw_state: int,
    route: Route,
    phase_index: int,
    policy_id: int,
) -> int:
    """Evaluate the preregistered K/S/D/L programs for one route policy."""

    if policy_id not in ADMISSIBLE_POLICY_IDS:
        raise OracleError("invalid_locked_input", "route spatial policy is inadmissible")
    state = inherited_v1.spatial_semantic_state(raw_state)
    b1 = inherited_v1.state_coordinate(state, 1)
    b2 = inherited_v1.state_coordinate(state, 2)
    edge = inherited_v1.state_coordinate(state, 3)
    coherent = inherited_v1.state_coordinate(state, 4)
    texture = inherited_v1.state_coordinate(state, 5)
    risk = inherited_v1.state_coordinate(state, 6)
    chroma_aligned = inherited_v1.state_coordinate(state, 8)
    orientation = b1 ^ b2
    phase = phase_half_cycle(route, phase_index)

    kernel_rule = policy_id // 16
    support_rule = (policy_id % 16) // 4
    detail_rule = (policy_id % 4) // 2
    limiter_rule = policy_id % 2

    if kernel_rule == 0:
        kernel = texture ^ (edge & orientation) ^ phase
    elif kernel_rule == 1:
        kernel = texture ^ (edge & orientation)
    elif kernel_rule == 2:
        kernel = texture | (edge & orientation)
    else:
        raise OracleError("invalid_locked_input", "route spatial kernel rule is invalid")

    support_base = edge & coherent
    if support_rule == 0:
        support = support_base
    elif support_rule == 1:
        support = support_base & (1 - risk)
    elif support_rule == 2:
        support = support_base & (1 - texture)
    elif support_rule == 3:
        support = support_base & (1 - risk) & (1 - texture)
    else:
        raise OracleError("invalid_locked_input", "route spatial support rule is invalid")

    if detail_rule == 0:
        detail = edge & texture & (1 - risk)
    elif detail_rule == 1:
        detail = texture & (1 - risk)
    else:
        raise OracleError("invalid_locked_input", "route spatial detail rule is invalid")

    if limiter_rule == 0:
        limiter = chroma_aligned & (1 - risk)
    elif limiter_rule == 1:
        limiter = chroma_aligned
    else:
        raise OracleError("invalid_locked_input", "route spatial limiter rule is invalid")

    return kernel | (support << 1) | (detail << 2) | (limiter << 3)


def _adjusted(base: int, delta: int, step: int, minimum: int, maximum: int) -> int:
    return min(maximum, max(minimum, base + (delta * step)))


def resolve_path_parameters_v2(
    base: int,
    path: CanonicalPath,
    configuration: LockedCompilerInputV2,
) -> tuple[int, int, int, int]:
    kernel = base & 1
    support = (base >> 1) & 1
    parameters = configuration.operator_parameters
    steps = configuration.semantic_steps
    base_gain = parameters.detail_gain_q12 if base & 0b0100 else 0
    detail_gain = _adjusted(
        base_gain,
        path.detail_delta,
        steps.detail_gain_step_q12,
        0,
        2048,
    )
    base_alpha = parameters.relaxed_limiter_alpha_q12 if base & 0b1000 else 0
    relaxed_alpha = _adjusted(
        base_alpha,
        -path.regularization_delta,
        steps.regularization_step_q12,
        0,
        1024,
    )
    support_base = 768 if kernel else 512
    support_radius = _adjusted(
        support_base,
        path.support_delta,
        steps.support_radius_step_q8_8,
        256,
        768,
    )
    detail = int(detail_gain > 0)
    relaxed = int(relaxed_alpha > 0)
    descriptor = kernel | (support << 1) | (detail << 2) | (relaxed << 3)
    return descriptor, detail_gain, relaxed_alpha, support_radius


def _better_representative(
    candidate: tuple[CanonicalPath, int, int, int, int, int],
    current: tuple[CanonicalPath, int, int, int, int, int],
) -> bool:
    candidate_path, _, candidate_penalty, _, _, _ = candidate
    current_path, _, current_penalty, _, _, _ = current
    return (
        candidate_penalty,
        -candidate_path.branch_mass_numerator,
        candidate_path.ordinal,
    ) < (
        current_penalty,
        -current_path.branch_mass_numerator,
        current_path.ordinal,
    )


def _candidate_slot_v2(
    candidate: Candidate,
    configuration: LockedCompilerInputV2,
    plane_mode: AnisotropyMode,
    source_aligned_exact: bool,
) -> CandidateSlot:
    parameters = configuration.operator_parameters
    flags = 1
    if candidate.descriptor & 0b0100 and candidate.detail_gain_q12 > 0:
        flags |= 1 << 1
    if candidate.descriptor & 0b1000 and candidate.relaxed_limiter_alpha_q12 > 0:
        flags |= 1 << 2
    if source_aligned_exact:
        flags |= 1 << 4
    return CandidateSlot(
        plane_mode.anisotropy_strength_q12,
        parameters.minimum_anisotropic_magnitude_unorm15,
        parameters.minimum_anisotropic_coherence_unorm15,
        candidate.detail_gain_q12,
        candidate.relaxed_limiter_alpha_q12,
        parameters.risk_detail_suppression_unorm15,
        candidate.support_radius_q8_8,
        parameters.weight_epsilon_f32_bits,
        candidate.orientation_delta,
        candidate.support_delta,
        candidate.detail_delta,
        candidate.regularization_delta,
        flags,
    )


def _source_preservation_slot_v2(
    configuration: LockedCompilerInputV2,
    plane_mode: AnisotropyMode,
) -> CandidateSlot:
    parameters = configuration.operator_parameters
    return CandidateSlot(
        plane_mode.anisotropy_strength_q12,
        parameters.minimum_anisotropic_magnitude_unorm15,
        parameters.minimum_anisotropic_coherence_unorm15,
        0,
        0,
        parameters.risk_detail_suppression_unorm15,
        512,
        parameters.weight_epsilon_f32_bits,
        0,
        0,
        0,
        0,
        (1 << 0) | (1 << 4),
    )


def logical_index_v2(
    route: Route,
    plane_id: int,
    phase_index: int,
    context_id: int,
    valid_state_ordinal: int,
) -> int:
    if plane_id not in PLANES_BY_ID:
        raise OracleError("invalid_plane", str(plane_id))
    if not 0 <= phase_index < route.phase_count:
        raise OracleError("invalid_phase", str(phase_index))
    if not 0 <= context_id < CONTEXT_COUNT:
        raise OracleError("invalid_context", str(context_id))
    if not 0 <= valid_state_ordinal < VALID_STATE_COUNT:
        raise OracleError("invalid_state_ordinal", str(valid_state_ordinal))
    return (
        plane_id * (route.phase_count * CONTEXT_COUNT * VALID_STATE_COUNT)
        + (((phase_index * CONTEXT_COUNT) + context_id) * VALID_STATE_COUNT)
        + valid_state_ordinal
    )


def compile_cell_v2(
    route: Route,
    configuration: LockedCompilerInputV2,
    plane: Plane | int,
    phase_index: int,
    context_id: int,
    valid_state_ordinal: int,
) -> CompiledEntryV2:
    if isinstance(plane, int):
        try:
            plane = PLANES_BY_ID[plane]
        except KeyError as error:
            raise OracleError("invalid_plane", str(plane)) from error
    if plane not in PLANES:
        raise OracleError("invalid_plane", str(plane))
    if not 0 <= context_id < CONTEXT_COUNT:
        raise OracleError("invalid_context", str(context_id))
    if not 0 <= valid_state_ordinal < VALID_STATE_COUNT:
        raise OracleError("invalid_state_ordinal", str(valid_state_ordinal))

    horizontal, vertical = phase_components(route, phase_index)
    source_state = VALID_STATES[valid_state_ordinal]
    semantic_state = inherited_v1.spatial_semantic_state(source_state)
    route_selection = configuration.routes[route.name]
    plane_mode = route_selection.mode_for_plane(plane)
    base = spatial_policy_descriptor(
        source_state,
        route,
        phase_index,
        route_selection.route_spatial_policy_id,
    )
    policy = configuration.compiler_policy

    groups: dict[int, list[Any]] = {}
    for path in CANONICAL_PATHS:
        affine_state = source_state ^ inherited_v1.encode_message(path.message)
        status, decoded_message = inherited_v1.strict_affine_decode(
            affine_state,
            source_state,
        )
        if status != "exact":
            raise OracleError("affine_recovery_not_exact")
        if decoded_message != path.message:
            raise OracleError("affine_message_mismatch")
        descriptor, detail_gain, relaxed_alpha, support_radius = (
            resolve_path_parameters_v2(base, path, configuration)
        )
        if not inherited_v1.hard_compatible(
            descriptor,
            detail_gain,
            relaxed_alpha,
            semantic_state,
        ):
            continue
        penalty = inherited_v1.compatibility_penalty(
            path,
            descriptor,
            base,
            semantic_state,
            route,
            phase_index,
            policy,
        )
        penalty_weight = policy.penalty_to_weight_unorm16[min(penalty, 255)]
        contribution = path.branch_mass_numerator * penalty_weight
        if contribution > UINT64_MAX:
            raise OracleError("fixed_point_overflow")
        item = (
            path,
            descriptor,
            penalty,
            detail_gain,
            relaxed_alpha,
            support_radius,
        )
        if path.message not in groups:
            groups[path.message] = [item, contribution]
        else:
            updated = groups[path.message][1] + contribution
            if updated > UINT64_MAX:
                raise OracleError("fixed_point_overflow")
            groups[path.message][1] = updated
            if _better_representative(item, groups[path.message][0]):
                groups[path.message][0] = item

    if len(groups) < 2:
        raise OracleError("fewer_than_two_compatible_messages")

    denominator = 256 * 65535
    ranked: list[Candidate] = []
    for message, (representative, raw_mass) in groups.items():
        path, descriptor, penalty, detail_gain, relaxed_alpha, support_radius = representative
        numerator = raw_mass * 65536
        if numerator > UINT64_MAX:
            raise OracleError("fixed_point_overflow")
        message_weight = inherited_v1.round_half_up(numerator, denominator)
        if message_weight == 0 or message_weight > UINT32_MAX:
            raise OracleError("fixed_point_overflow")
        ranked.append(
            Candidate(
                message,
                source_state ^ inherited_v1.encode_message(message),
                descriptor,
                path.ordinal,
                penalty,
                message_weight,
                path.orientation_delta,
                path.support_delta,
                path.detail_delta,
                path.regularization_delta,
                detail_gain,
                relaxed_alpha,
                support_radius,
            )
        )
    ranked.sort(
        key=lambda candidate: (
            -candidate.message_weight_q16_16,
            candidate.representative_penalty,
            candidate.message,
        )
    )

    source_aligned_exact = (
        route_selection.coordinate_policy_for_plane(plane)
        == "source_aligned_rational"
        and horizontal == 0
        and vertical == 0
    )
    index = logical_index_v2(
        route,
        plane.plane_id,
        phase_index,
        context_id,
        valid_state_ordinal,
    )
    if source_aligned_exact:
        primary = Candidate(
            0,
            source_state,
            0,
            0,
            0,
            65536,
            0,
            0,
            0,
            0,
            0,
            0,
            512,
        )
        return CompiledEntryV2(
            index,
            plane,
            source_state,
            valid_state_ordinal,
            phase_index,
            context_id,
            primary,
            None,
            UINT16_MAX,
            0,
            UINT16_MAX,
            True,
            _source_preservation_slot_v2(configuration, plane_mode),
            INACTIVE_SLOT,
        )

    primary = ranked[0]
    possible_secondary = ranked[1]
    total = primary.message_weight_q16_16 + possible_secondary.message_weight_q16_16
    primary_weight = inherited_v1.round_half_up(
        UINT16_MAX * primary.message_weight_q16_16,
        total,
    )
    secondary_weight = UINT16_MAX - primary_weight
    margin = primary_weight - secondary_weight
    if margin >= policy.confidence_threshold_unorm16:
        return CompiledEntryV2(
            index,
            plane,
            source_state,
            valid_state_ordinal,
            phase_index,
            context_id,
            primary,
            None,
            UINT16_MAX,
            0,
            margin,
            False,
            _candidate_slot_v2(primary, configuration, plane_mode, False),
            INACTIVE_SLOT,
        )
    return CompiledEntryV2(
        index,
        plane,
        source_state,
        valid_state_ordinal,
        phase_index,
        context_id,
        primary,
        possible_secondary,
        primary_weight,
        secondary_weight,
        margin,
        False,
        _candidate_slot_v2(primary, configuration, plane_mode, False),
        _candidate_slot_v2(possible_secondary, configuration, plane_mode, False),
    )


def compile_route_v2(
    route: Route,
    configuration: LockedCompilerInputV2,
) -> CompiledRouteV2:
    entries: list[CompiledEntryV2] = []
    for plane in PLANES:
        for phase_index in range(route.phase_count):
            for context_id in range(CONTEXT_COUNT):
                for state_ordinal in range(VALID_STATE_COUNT):
                    entries.append(
                        compile_cell_v2(
                            route,
                            configuration,
                            plane,
                            phase_index,
                            context_id,
                            state_ordinal,
                        )
                    )
    if len(entries) != route.entry_count or any(
        entry.logical_index != index for index, entry in enumerate(entries)
    ):
        raise OracleError("entry_count_mismatch")
    return CompiledRouteV2(route, configuration, tuple(entries))


def compile_all_routes_v2(
    configuration: LockedCompilerInputV2,
) -> Mapping[str, CompiledRouteV2]:
    return {name: compile_route_v2(route, configuration) for name, route in ROUTES.items()}


def _crc32(data: bytes) -> int:
    return binascii.crc32(data) & UINT32_MAX


def _serialize_slot(slot: CandidateSlot) -> bytes:
    values = (
        slot.anisotropy_strength_q12,
        slot.minimum_anisotropic_magnitude_unorm15,
        slot.minimum_anisotropic_coherence_unorm15,
        slot.detail_gain_q12,
        slot.relaxed_limiter_alpha_q12,
        slot.risk_detail_suppression_unorm15,
        slot.support_radius_q8_8,
        slot.weight_epsilon_f32_bits,
        slot.orientation_delta,
        slot.support_delta,
        slot.detail_delta,
        slot.regularization_delta,
        slot.flags,
    )
    unsigned_values = values[:7] + (values[7], values[12])
    if any(value < 0 for value in unsigned_values):
        raise OracleError("parameter_out_of_range")
    if any(value > UINT16_MAX for value in values[:7]) or values[7] > UINT32_MAX:
        raise OracleError("parameter_out_of_range")
    if any(not -128 <= value <= 127 for value in values[8:12]) or values[12] > UINT16_MAX:
        raise OracleError("parameter_out_of_range")
    return struct.pack("<7HI4bH", *values)


def _coordinate_policy_code(value: str) -> int:
    if value == "half_pixel_center":
        return 0
    if value == "source_aligned_rational":
        return 1
    raise OracleError("invalid_locked_input", "coordinate policy is invalid")


def _coordinate_policy_name(value: int) -> str:
    if value == 0:
        return "half_pixel_center"
    if value == 1:
        return "source_aligned_rational"
    raise OracleError("parameter_out_of_range", "coordinate policy")


def _parameter_prefix_v2(
    entry: CompiledEntryV2,
    configuration: LockedCompilerInputV2,
    route: Route,
) -> bytes:
    route_selection = configuration.routes[route.name]
    luma_coordinate_code = _coordinate_policy_code(
        route_selection.luma_coordinate_policy
    )
    chroma_coordinate_code = _coordinate_policy_code(
        route_selection.chroma_coordinate_policy
    )
    boundary_code = 1 if configuration.boundary_mode == "mirror_reflect101" else 0
    tail = struct.pack(
        "<HBBBBB5s",
        configuration.compiler_policy.confidence_threshold_unorm16,
        luma_coordinate_code,
        boundary_code,
        1,
        0,
        chroma_coordinate_code,
        b"\x00" * 5,
    )
    prefix = _serialize_slot(entry.primary_slot) + _serialize_slot(entry.secondary_slot) + tail
    if len(prefix) != PARAMETER_PREFIX_SIZE:
        raise OracleError("serialization_failure", "parameter prefix size differs")
    return prefix


def _entry_flags_v2(entry: CompiledEntryV2) -> int:
    flags = 1 << 3
    if entry.secondary is not None:
        flags |= (1 << 0) | (1 << 4)
    if entry.source_aligned_exact:
        flags |= 1 << 1
    if entry.context_id != 0:
        flags |= 1 << 2
    return flags


def serialize_compiled_route_v2(compilation: CompiledRouteV2) -> bytes:
    route = compilation.route
    configuration = compilation.configuration
    if len(compilation.entries) != route.entry_count:
        raise OracleError("entry_count_mismatch")
    for index, entry in enumerate(compilation.entries):
        expected_plane_id = index // route.plane_entry_count
        if (
            entry.logical_index != index
            or entry.plane.plane_id != expected_plane_id
            or entry.plane not in PLANES
        ):
            raise OracleError("nondeterministic_order")

    entry_parameter_prefixes = [
        _parameter_prefix_v2(entry, configuration, route)
        for entry in compilation.entries
    ]
    sorted_prefixes = sorted(set(entry_parameter_prefixes))
    if not sorted_prefixes:
        raise OracleError("serialization_failure", "empty parameter table")
    parameter_records = [
        prefix + struct.pack("<I", _crc32(prefix)) for prefix in sorted_prefixes
    ]
    parameter_indices = {prefix: index for index, prefix in enumerate(sorted_prefixes)}

    entry_records: list[bytes] = []
    for entry, parameter_prefix in zip(compilation.entries, entry_parameter_prefixes):
        if entry.logical_index != len(entry_records):
            raise OracleError("nondeterministic_order")
        secondary = entry.secondary
        secondary_affine = secondary.affine_state if secondary is not None else UINT16_MAX
        secondary_descriptor = secondary.descriptor if secondary is not None else 0xFF
        secondary_message = secondary.message if secondary is not None else 0xFF
        parameter_index = parameter_indices[parameter_prefix]
        prefix = struct.pack(
            "<HHBBBBHHHHI",
            entry.primary.affine_state,
            secondary_affine,
            entry.primary.descriptor,
            secondary_descriptor,
            entry.primary.message,
            secondary_message,
            entry.primary_weight_unorm16,
            entry.secondary_weight_unorm16,
            entry.margin_unorm16,
            _entry_flags_v2(entry),
            parameter_index,
        )
        parameter_record = parameter_records[parameter_index]
        provenance = (
            struct.pack("<HI", route.route_id, entry.logical_index)
            + prefix
            + parameter_record
        )
        record = prefix + struct.pack("<I", _crc32(provenance))
        if len(record) != ENTRY_STRIDE:
            raise OracleError("serialization_failure", "entry record size differs")
        entry_records.append(record)

    parameter_data = b"".join(parameter_records)
    entry_data = b"".join(entry_records)
    payload = parameter_data + entry_data
    parameter_count = len(parameter_records)
    parameter_bytes = len(parameter_data)
    entry_bytes = len(entry_data)
    entry_offset = HEADER_SIZE + parameter_bytes
    payload_bytes = len(payload)
    file_size = HEADER_SIZE + payload_bytes
    for value in (
        parameter_count,
        parameter_bytes,
        entry_bytes,
        entry_offset,
        payload_bytes,
        file_size,
    ):
        if not 0 <= value <= UINT32_MAX:
            raise OracleError("serialization_failure", "derived size does not fit UInt32")

    selection = configuration.routes[route.name]
    luma_coordinate_code = _coordinate_policy_code(selection.luma_coordinate_policy)
    chroma_coordinate_code = _coordinate_policy_code(selection.chroma_coordinate_policy)
    header = bytearray(HEADER_SIZE)
    header[0:8] = MAGIC
    struct.pack_into("<HH", header, 8, 1, 2)
    struct.pack_into("<HH", header, 12, HEADER_SIZE, 0x4C45)
    struct.pack_into("<HH", header, 16, route.route_id, HEADER_FLAGS)
    struct.pack_into("<HH", header, 20, route.phase_count, CONTEXT_COUNT)
    struct.pack_into(
        "<HHH",
        header,
        24,
        VALID_STATE_COUNT,
        ENTRY_STRIDE,
        PARAMETER_STRIDE,
    )
    struct.pack_into("<H", header, 30, PLANE_COUNT)
    struct.pack_into("<II", header, 32, route.entry_count, parameter_count)
    struct.pack_into("<II", header, 40, HEADER_SIZE, entry_offset)
    struct.pack_into("<II", header, 48, parameter_bytes, entry_bytes)
    struct.pack_into("<II", header, 56, HEADER_SIZE, payload_bytes)
    for index, key in enumerate(HASH_BINDING_KEYS):
        header[64 + (index * 32) : 96 + (index * 32)] = bytes.fromhex(
            configuration.hash_bindings[key]
        )
    payload_sha256 = hashlib.sha256(payload).digest()
    header[256:288] = payload_sha256
    struct.pack_into("<I", header, 292, _crc32(payload))
    struct.pack_into("<I", header, 296, file_size)
    header[300] = selection.route_spatial_policy_id
    header[301] = selection.luma_anisotropy_mode_ordinal
    header[302] = selection.chroma_anisotropy_mode_ordinal
    header[303] = luma_coordinate_code
    header[304] = chroma_coordinate_code
    header[305] = CHROMA_EDGE_CONFIDENCE_ENCODING
    struct.pack_into("<I", header, 288, _crc32(bytes(header)))
    result = bytes(header) + payload
    if len(result) != file_size:
        raise OracleError("serialization_failure", "final file size differs")
    return result


def compile_route_bytes_v2(
    route: Route,
    configuration: LockedCompilerInputV2,
) -> bytes:
    data = serialize_compiled_route_v2(compile_route_v2(route, configuration))
    validate_lut_v2(
        data,
        expected_configuration=configuration,
        expected_route=route,
    )
    return data


def compile_all_route_bytes_v2(
    configuration: LockedCompilerInputV2,
) -> Mapping[str, bytes]:
    return {
        name: compile_route_bytes_v2(route, configuration)
        for name, route in ROUTES.items()
    }


def _unpack_slot(data: bytes) -> CandidateSlot:
    if len(data) != 24:
        raise OracleError("truncated_file", "candidate slot")
    values = struct.unpack("<7HI4bH", data)
    return CandidateSlot(
        values[0],
        values[1],
        values[2],
        values[3],
        values[4],
        values[5],
        values[6],
        values[7],
        values[8],
        values[9],
        values[10],
        values[11],
        values[12],
    )


def _validate_active_slot(slot: CandidateSlot, context: str) -> None:
    if not slot.flags & 1:
        raise OracleError("invalid_entry_flags", f"{context} is inactive")
    if slot.flags & ~0x0017:
        raise OracleError("reserved_nonzero", f"{context} candidate flags")
    if slot.flags & ((1 << 3) | (1 << 5)):
        raise OracleError("invalid_entry_flags", f"{context} temporal or denoising flag")
    if not 0 <= slot.anisotropy_strength_q12 <= 4096:
        raise OracleError("parameter_out_of_range", f"{context} anisotropy")
    for value in (
        slot.minimum_anisotropic_magnitude_unorm15,
        slot.minimum_anisotropic_coherence_unorm15,
        slot.risk_detail_suppression_unorm15,
    ):
        if not 0 <= value <= 32767:
            raise OracleError("parameter_out_of_range", context)
    if not 0 <= slot.detail_gain_q12 <= 2048:
        raise OracleError("parameter_out_of_range", f"{context} detail")
    if not 0 <= slot.relaxed_limiter_alpha_q12 <= 1024:
        raise OracleError("parameter_out_of_range", f"{context} alpha")
    if not 256 <= slot.support_radius_q8_8 <= 768:
        raise OracleError("parameter_out_of_range", f"{context} support")
    epsilon = struct.unpack("<f", struct.pack("<I", slot.weight_epsilon_f32_bits))[0]
    if not math.isfinite(epsilon) or epsilon <= 0:
        raise OracleError("parameter_out_of_range", f"{context} epsilon")
    for delta in (
        slot.orientation_delta,
        slot.support_delta,
        slot.detail_delta,
        slot.regularization_delta,
    ):
        if delta not in (-1, 0, 1):
            raise OracleError("parameter_out_of_range", f"{context} semantic delta")


def _validate_slot_against_entry(
    slot: CandidateSlot,
    descriptor: int,
    source_aligned_exact: bool,
    context: str,
) -> None:
    _validate_active_slot(slot, context)
    positive_detail = bool(slot.flags & (1 << 1))
    relaxed = bool(slot.flags & (1 << 2))
    preserve = bool(slot.flags & (1 << 4))
    if positive_detail != (bool(descriptor & 0b0100) and slot.detail_gain_q12 > 0):
        raise OracleError("invalid_entry_flags", f"{context} detail flag")
    if relaxed != (
        bool(descriptor & 0b1000) and slot.relaxed_limiter_alpha_q12 > 0
    ):
        raise OracleError("invalid_entry_flags", f"{context} limiter flag")
    if preserve != source_aligned_exact:
        raise OracleError("invalid_entry_flags", f"{context} preservation flag")
    if bool(descriptor & 0b0100) != (slot.detail_gain_q12 > 0):
        raise OracleError("invalid_entry_flags", f"{context} detail descriptor")
    if bool(descriptor & 0b1000) != (slot.relaxed_limiter_alpha_q12 > 0):
        raise OracleError("invalid_entry_flags", f"{context} limiter descriptor")


def _configuration_slot_check_v2(
    slot: CandidateSlot,
    descriptor: int,
    base: int,
    configuration: LockedCompilerInputV2,
    plane_mode: AnisotropyMode,
    source_aligned_exact: bool,
    context: str,
) -> None:
    parameters = configuration.operator_parameters
    steps = configuration.semantic_steps
    for actual, expected, name in (
        (
            slot.anisotropy_strength_q12,
            plane_mode.anisotropy_strength_q12,
            "anisotropy",
        ),
        (
            slot.minimum_anisotropic_magnitude_unorm15,
            parameters.minimum_anisotropic_magnitude_unorm15,
            "minimum magnitude",
        ),
        (
            slot.minimum_anisotropic_coherence_unorm15,
            parameters.minimum_anisotropic_coherence_unorm15,
            "minimum coherence",
        ),
        (
            slot.risk_detail_suppression_unorm15,
            parameters.risk_detail_suppression_unorm15,
            "risk suppression",
        ),
        (slot.weight_epsilon_f32_bits, parameters.weight_epsilon_f32_bits, "epsilon"),
    ):
        if actual != expected:
            raise OracleError("input_hash_mismatch", f"{context} {name}")
    if source_aligned_exact:
        expected_detail = 0
        expected_alpha = 0
        expected_support = 512
    else:
        base_detail = parameters.detail_gain_q12 if base & 0b0100 else 0
        expected_detail = _adjusted(
            base_detail,
            slot.detail_delta,
            steps.detail_gain_step_q12,
            0,
            2048,
        )
        base_alpha = parameters.relaxed_limiter_alpha_q12 if base & 0b1000 else 0
        expected_alpha = _adjusted(
            base_alpha,
            -slot.regularization_delta,
            steps.regularization_step_q12,
            0,
            1024,
        )
        support_base = 768 if descriptor & 1 else 512
        expected_support = _adjusted(
            support_base,
            slot.support_delta,
            steps.support_radius_step_q8_8,
            256,
            768,
        )
    if (
        slot.detail_gain_q12 != expected_detail
        or slot.relaxed_limiter_alpha_q12 != expected_alpha
        or slot.support_radius_q8_8 != expected_support
    ):
        raise OracleError(
            "parameter_out_of_range",
            f"{context} resolved parameter mismatch",
        )


def _expected_route(
    expected_route: Route | str | None,
) -> Route | None:
    if isinstance(expected_route, str):
        try:
            return ROUTES[expected_route]
        except KeyError as error:
            raise OracleError("invalid_route", "unknown expected route") from error
    return expected_route


def validate_lut_v2(
    data: bytes,
    expected_configuration: LockedCompilerInputV2 | None = None,
    expected_route: Route | str | None = None,
) -> ValidatedLUTV2:
    """Validate format-1.2 bytes.

    Passing ``expected_configuration`` authenticates external compiler semantics
    in addition to the self-contained binary structure and integrity scopes.
    """

    if not isinstance(data, bytes):
        raise OracleError("truncated_file", "LUT input must be immutable bytes")
    if len(data) < HEADER_SIZE:
        raise OracleError("truncated_file")
    header = data[:HEADER_SIZE]
    if header[:8] != MAGIC:
        raise OracleError("bad_magic")

    # Version dispatch precedes interpretation of every format-1.2 extension byte.
    major, minor = struct.unpack_from("<HH", header, 8)
    if (major, minor) != (1, 2):
        raise OracleError("unsupported_version")

    header_size, endian_tag = struct.unpack_from("<HH", header, 12)
    if header_size != HEADER_SIZE:
        raise OracleError("dimension_mismatch", "header size")
    if endian_tag != 0x4C45:
        raise OracleError("bad_endianness")
    route_id, header_flags = struct.unpack_from("<HH", header, 16)
    route = ROUTES_BY_ID.get(route_id)
    if route is None:
        raise OracleError("invalid_route")
    expected_route_value = _expected_route(expected_route)
    if expected_route_value is not None and route != expected_route_value:
        raise OracleError("invalid_route", "route differs from expectation")
    if header_flags != HEADER_FLAGS:
        raise OracleError("invalid_entry_flags", "header flags")

    phase_count, context_count = struct.unpack_from("<HH", header, 20)
    valid_state_count, entry_stride, parameter_stride = struct.unpack_from(
        "<HHH",
        header,
        24,
    )
    plane_count = struct.unpack_from("<H", header, 30)[0]
    if (
        phase_count != route.phase_count
        or context_count != CONTEXT_COUNT
        or valid_state_count != VALID_STATE_COUNT
        or entry_stride != ENTRY_STRIDE
        or parameter_stride != PARAMETER_STRIDE
        or plane_count != PLANE_COUNT
    ):
        raise OracleError("dimension_mismatch", "fixed dimensions")

    route_spatial_policy_id = header[300]
    luma_mode_ordinal = header[301]
    chroma_mode_ordinal = header[302]
    luma_coordinate_code = header[303]
    chroma_coordinate_code = header[304]
    if route_spatial_policy_id not in ADMISSIBLE_POLICY_IDS:
        raise OracleError("invalid_locked_input", "route spatial policy is inadmissible")
    if (
        luma_mode_ordinal not in ANISOTROPY_MODES_BY_ORDINAL
        or chroma_mode_ordinal not in ANISOTROPY_MODES_BY_ORDINAL
    ):
        raise OracleError("parameter_out_of_range", "anisotropy mode ordinal")
    luma_coordinate_policy = _coordinate_policy_name(luma_coordinate_code)
    chroma_coordinate_policy = _coordinate_policy_name(chroma_coordinate_code)
    if header[305] != CHROMA_EDGE_CONFIDENCE_ENCODING:
        raise OracleError("invalid_entry_flags", "chroma confidence ABI marker")
    if any(header[306:320]):
        raise OracleError("reserved_nonzero", "header")

    if expected_configuration is not None:
        selection = expected_configuration.routes[route.name]
        if (
            route_spatial_policy_id != selection.route_spatial_policy_id
            or luma_mode_ordinal != selection.luma_anisotropy_mode_ordinal
            or chroma_mode_ordinal != selection.chroma_anisotropy_mode_ordinal
            or luma_coordinate_policy != selection.luma_coordinate_policy
            or chroma_coordinate_policy != selection.chroma_coordinate_policy
        ):
            raise OracleError("input_hash_mismatch", "format-1.2 header extension")

    entry_count, parameter_count = struct.unpack_from("<II", header, 32)
    parameter_offset, entry_offset = struct.unpack_from("<II", header, 40)
    parameter_bytes, entry_bytes = struct.unpack_from("<II", header, 48)
    payload_offset, payload_bytes = struct.unpack_from("<II", header, 56)
    declared_file_size = struct.unpack_from("<I", header, 296)[0]
    expected_parameter_bytes = parameter_count * PARAMETER_STRIDE
    expected_entry_bytes = entry_count * ENTRY_STRIDE
    expected_entry_offset = HEADER_SIZE + expected_parameter_bytes
    expected_payload_bytes = expected_parameter_bytes + expected_entry_bytes
    expected_file_size = HEADER_SIZE + expected_payload_bytes
    if any(
        value > UINT32_MAX
        for value in (
            expected_parameter_bytes,
            expected_entry_bytes,
            expected_entry_offset,
            expected_payload_bytes,
            expected_file_size,
        )
    ):
        raise OracleError("offset_or_size_overflow")
    if (
        entry_count != route.entry_count
        or entry_count
        != plane_count * phase_count * context_count * valid_state_count
        or parameter_count < 1
        or parameter_offset != HEADER_SIZE
        or payload_offset != HEADER_SIZE
        or parameter_bytes != expected_parameter_bytes
        or entry_bytes != expected_entry_bytes
        or entry_offset != expected_entry_offset
        or payload_bytes != expected_payload_bytes
    ):
        raise OracleError("dimension_mismatch", "section dimensions")
    if declared_file_size != expected_file_size or len(data) != expected_file_size:
        raise OracleError("file_size_mismatch")

    declared_header_crc = struct.unpack_from("<I", header, 288)[0]
    header_for_crc = bytearray(header)
    header_for_crc[288:292] = b"\x00" * 4
    if _crc32(bytes(header_for_crc)) != declared_header_crc:
        raise OracleError("header_crc_mismatch")
    payload = data[payload_offset : payload_offset + payload_bytes]
    declared_payload_crc = struct.unpack_from("<I", header, 292)[0]
    if _crc32(payload) != declared_payload_crc:
        raise OracleError("payload_crc_mismatch")
    declared_payload_sha = header[256:288]
    if hashlib.sha256(payload).digest() != declared_payload_sha:
        raise OracleError("payload_sha256_mismatch")

    hash_bindings = {
        key: header[64 + (index * 32) : 96 + (index * 32)].hex()
        for index, key in enumerate(HASH_BINDING_KEYS)
    }
    if any(value == "0" * 64 for value in hash_bindings.values()):
        raise OracleError("input_hash_mismatch", "zero digest")
    if expected_configuration is not None:
        for key in HASH_BINDING_KEYS:
            if hash_bindings[key] != expected_configuration.hash_bindings[key]:
                raise OracleError("input_hash_mismatch", key)

    parameter_records = [
        data[
            parameter_offset + (index * PARAMETER_STRIDE) :
            parameter_offset + ((index + 1) * PARAMETER_STRIDE)
        ]
        for index in range(parameter_count)
    ]
    prefixes: list[bytes] = []
    parameter_slots: list[
        tuple[CandidateSlot, CandidateSlot, int, int, int, int]
    ] = []
    for index, record in enumerate(parameter_records):
        prefix = record[:PARAMETER_PREFIX_SIZE]
        if _crc32(prefix) != struct.unpack_from("<I", record, 60)[0]:
            raise OracleError("parameter_crc_mismatch", str(index))
        if any(record[55:60]):
            raise OracleError("reserved_nonzero", f"parameter {index}")
        primary_slot = _unpack_slot(record[0:24])
        secondary_slot = _unpack_slot(record[24:48])
        confidence = struct.unpack_from("<H", record, 48)[0]
        (
            parameter_luma_coordinate,
            boundary_mode,
            source_policy,
            temporal_mode,
            parameter_chroma_coordinate,
        ) = struct.unpack_from("<BBBBB", record, 50)
        if (
            parameter_luma_coordinate not in (0, 1)
            or parameter_chroma_coordinate not in (0, 1)
            or boundary_mode not in (0, 1)
        ):
            raise OracleError("parameter_out_of_range", f"parameter {index} policy")
        if source_policy != 1 or temporal_mode != 0:
            raise OracleError("invalid_entry_flags", f"parameter {index} mode")
        if (
            parameter_luma_coordinate != luma_coordinate_code
            or parameter_chroma_coordinate != chroma_coordinate_code
        ):
            raise OracleError(
                "input_hash_mismatch",
                f"parameter {index} coordinate/header binding",
            )
        _validate_active_slot(primary_slot, f"parameter {index} primary")
        if secondary_slot != INACTIVE_SLOT:
            _validate_active_slot(secondary_slot, f"parameter {index} secondary")
        if expected_configuration is not None:
            expected_boundary = (
                1 if expected_configuration.boundary_mode == "mirror_reflect101" else 0
            )
            if (
                confidence
                != expected_configuration.compiler_policy.confidence_threshold_unorm16
                or boundary_mode != expected_boundary
            ):
                raise OracleError("input_hash_mismatch", f"parameter {index} tail")
        prefixes.append(prefix)
        parameter_slots.append(
            (
                primary_slot,
                secondary_slot,
                confidence,
                parameter_luma_coordinate,
                parameter_chroma_coordinate,
                boundary_mode,
            )
        )
    if prefixes != sorted(set(prefixes)):
        raise OracleError("nondeterministic_order", "parameter table")

    referenced_parameters: set[int] = set()
    context_zero_signatures: dict[tuple[int, int, int], tuple[Any, ...]] = {}
    plane_entry_count = route.plane_entry_count
    for logical_index in range(entry_count):
        offset = entry_offset + (logical_index * ENTRY_STRIDE)
        record = data[offset : offset + ENTRY_STRIDE]
        (
            primary_affine,
            secondary_affine,
            primary_descriptor,
            secondary_descriptor,
            primary_message,
            secondary_message,
            primary_weight,
            secondary_weight,
            margin,
            flags,
            parameter_index,
        ) = struct.unpack("<HHBBBBHHHHI", record[:20])
        if parameter_index >= parameter_count:
            raise OracleError("parameter_index_out_of_bounds", str(logical_index))
        referenced_parameters.add(parameter_index)
        provenance = (
            struct.pack("<HI", route.route_id, logical_index)
            + record[:20]
            + parameter_records[parameter_index]
        )
        if _crc32(provenance) != struct.unpack_from("<I", record, 20)[0]:
            raise OracleError("entry_crc_mismatch", str(logical_index))
        if flags & ~0x001F or not flags & (1 << 3) or flags & (1 << 5):
            raise OracleError("invalid_entry_flags", str(logical_index))

        has_secondary = bool(flags & 1)
        source_exact = bool(flags & (1 << 1))
        plane_id = logical_index // plane_entry_count
        plane = PLANES_BY_ID.get(plane_id)
        if plane is None:
            raise OracleError("invalid_plane", str(plane_id))
        plane_local_index = logical_index % plane_entry_count
        context_id = (plane_local_index // VALID_STATE_COUNT) % CONTEXT_COUNT
        phase_index = plane_local_index // (CONTEXT_COUNT * VALID_STATE_COUNT)
        valid_state_ordinal = plane_local_index % VALID_STATE_COUNT
        if (
            logical_index_v2(
                route,
                plane_id,
                phase_index,
                context_id,
                valid_state_ordinal,
            )
            != logical_index
        ):
            raise OracleError("nondeterministic_order", str(logical_index))
        source_state = VALID_STATES[valid_state_ordinal]
        semantic_state = inherited_v1.spatial_semantic_state(source_state)
        if bool(flags & (1 << 2)) != (context_id != 0):
            raise OracleError("invalid_entry_flags", f"{logical_index} temporal alias")
        if bool(flags & (1 << 4)) != has_secondary:
            raise OracleError("invalid_entry_flags", f"{logical_index} secondary exact")
        if primary_affine > 511 or primary_descriptor > 15 or primary_message > 15:
            raise OracleError("invalid_affine_state", str(logical_index))
        status, message = inherited_v1.strict_affine_decode(primary_affine, source_state)
        if status != "exact":
            raise OracleError("affine_decode_rejected", str(logical_index))
        if message != primary_message:
            raise OracleError("decoded_message_mismatch", str(logical_index))

        (
            primary_slot,
            secondary_slot,
            confidence,
            _,
            _,
            _,
        ) = parameter_slots[parameter_index]
        if has_secondary:
            if (
                secondary_affine > 511
                or secondary_descriptor > 15
                or secondary_message > 15
                or secondary_slot == INACTIVE_SLOT
            ):
                raise OracleError("invalid_sentinel", str(logical_index))
            secondary_status, decoded_secondary = inherited_v1.strict_affine_decode(
                secondary_affine,
                source_state,
            )
            if secondary_status != "exact":
                raise OracleError("affine_decode_rejected", f"{logical_index} secondary")
            if decoded_secondary != secondary_message:
                raise OracleError(
                    "decoded_message_mismatch",
                    f"{logical_index} secondary",
                )
            if primary_weight + secondary_weight != UINT16_MAX:
                raise OracleError("invalid_sentinel", f"{logical_index} weights")
            if margin != primary_weight - secondary_weight or margin >= confidence:
                raise OracleError("invalid_sentinel", f"{logical_index} margin")
        else:
            if (
                secondary_affine != UINT16_MAX
                or secondary_descriptor != 0xFF
                or secondary_message != 0xFF
                or secondary_slot != INACTIVE_SLOT
                or primary_weight != UINT16_MAX
                or secondary_weight != 0
            ):
                raise OracleError("invalid_sentinel", str(logical_index))

        horizontal, vertical = phase_components(route, phase_index)
        current_coordinate_code = (
            luma_coordinate_code if plane_id == 0 else chroma_coordinate_code
        )
        exact_predicate = (
            current_coordinate_code == 1 and horizontal == 0 and vertical == 0
        )
        if source_exact != exact_predicate:
            raise OracleError("invalid_entry_flags", f"{logical_index} source exact")
        base = spatial_policy_descriptor(
            source_state,
            route,
            phase_index,
            route_spatial_policy_id,
        )
        plane_mode = ANISOTROPY_MODES_BY_ORDINAL[
            luma_mode_ordinal if plane_id == 0 else chroma_mode_ordinal
        ]
        if source_exact:
            if (
                has_secondary
                or primary_affine != source_state
                or primary_descriptor != 0
                or primary_message != 0
                or primary_weight != UINT16_MAX
                or secondary_weight != 0
                or margin != UINT16_MAX
                or primary_slot.detail_gain_q12 != 0
                or primary_slot.relaxed_limiter_alpha_q12 != 0
                or primary_slot.support_radius_q8_8 != 512
                or any(
                    value != 0
                    for value in (
                        primary_slot.orientation_delta,
                        primary_slot.support_delta,
                        primary_slot.detail_delta,
                        primary_slot.regularization_delta,
                    )
                )
            ):
                raise OracleError("invalid_sentinel", f"{logical_index} exact source")
        else:
            if (primary_descriptor & 0b0011) != (base & 0b0011):
                raise OracleError(
                    "invalid_entry_flags",
                    f"{logical_index} primary base axes",
                )
            if not has_secondary and margin < confidence:
                raise OracleError("invalid_sentinel", f"{logical_index} pruned margin")

        _validate_slot_against_entry(
            primary_slot,
            primary_descriptor,
            source_exact,
            f"entry {logical_index} primary",
        )
        if primary_slot.anisotropy_strength_q12 != plane_mode.anisotropy_strength_q12:
            raise OracleError(
                "input_hash_mismatch",
                f"entry {logical_index} primary anisotropy mode",
            )
        if not inherited_v1.hard_compatible(
            primary_descriptor,
            primary_slot.detail_gain_q12,
            primary_slot.relaxed_limiter_alpha_q12,
            semantic_state,
        ):
            raise OracleError(
                "invalid_entry_flags",
                f"{logical_index} primary compatibility",
            )
        if expected_configuration is not None:
            _configuration_slot_check_v2(
                primary_slot,
                primary_descriptor,
                base,
                expected_configuration,
                plane_mode,
                source_exact,
                f"entry {logical_index} primary",
            )

        if has_secondary:
            if (secondary_descriptor & 0b0011) != (base & 0b0011):
                raise OracleError(
                    "invalid_entry_flags",
                    f"{logical_index} secondary base axes",
                )
            _validate_slot_against_entry(
                secondary_slot,
                secondary_descriptor,
                False,
                f"entry {logical_index} secondary",
            )
            if secondary_slot.anisotropy_strength_q12 != plane_mode.anisotropy_strength_q12:
                raise OracleError(
                    "input_hash_mismatch",
                    f"entry {logical_index} secondary anisotropy mode",
                )
            if not inherited_v1.hard_compatible(
                secondary_descriptor,
                secondary_slot.detail_gain_q12,
                secondary_slot.relaxed_limiter_alpha_q12,
                semantic_state,
            ):
                raise OracleError(
                    "invalid_entry_flags",
                    f"{logical_index} secondary compatibility",
                )
            if expected_configuration is not None:
                _configuration_slot_check_v2(
                    secondary_slot,
                    secondary_descriptor,
                    base,
                    expected_configuration,
                    plane_mode,
                    False,
                    f"entry {logical_index} secondary",
                )

        signature = (
            primary_affine,
            secondary_affine,
            primary_descriptor,
            secondary_descriptor,
            primary_message,
            secondary_message,
            primary_weight,
            secondary_weight,
            margin,
            flags & ~(1 << 2),
            parameter_index,
        )
        alias_key = (plane_id, phase_index, valid_state_ordinal)
        if context_id == 0:
            context_zero_signatures[alias_key] = signature
        elif context_zero_signatures.get(alias_key) != signature:
            raise OracleError("invalid_entry_flags", f"{logical_index} context alias")

    if referenced_parameters != set(range(parameter_count)):
        raise OracleError("nondeterministic_order", "unreferenced parameter record")

    return ValidatedLUTV2(
        route,
        plane_count,
        entry_count,
        parameter_count,
        route_spatial_policy_id,
        luma_mode_ordinal,
        chroma_mode_ordinal,
        luma_coordinate_policy,
        chroma_coordinate_policy,
        declared_payload_sha.hex(),
        declared_payload_crc,
        declared_header_crc,
        hashlib.sha256(data).hexdigest(),
        hash_bindings,
    )
