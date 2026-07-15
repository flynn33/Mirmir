"""Reference derivation for the plane-aware P06 calibration-plan v2 overlay."""

from __future__ import annotations

from itertools import combinations
from typing import Dict, Mapping, Sequence, Tuple


class CalibrationPlanV2Error(ValueError):
    """Raised when the preregistered structural design is internally invalid."""


GF16_REDUCTION_POLYNOMIAL = 0b1_0011
ADMISSIBLE_POLICY_IDS = tuple(range(8)) + tuple(range(16, 24))
MODE_ORDINALS = tuple(range(6))
COORDINATE_POLICIES = ("half_pixel_center", "source_aligned_rational")
STRUCTURAL_VECTOR_COUNT = 256

STRUCTURAL_FACTOR_ORDER = (
    "direct_2x_route_spatial_policy_id",
    "direct_3_over_2_route_spatial_policy_id",
    "direct_2x_luma_anisotropy_mode_ordinal",
    "direct_2x_chroma_anisotropy_mode_ordinal",
    "direct_3_over_2_luma_anisotropy_mode_ordinal",
    "direct_3_over_2_chroma_anisotropy_mode_ordinal",
    "direct_2x_luma_coordinate_policy",
    "direct_2x_chroma_coordinate_policy",
    "direct_3_over_2_luma_coordinate_policy",
    "direct_3_over_2_chroma_coordinate_policy",
)

MODE_COLUMN_MULTIPLIERS = (1, 2, 3, 4)
MODE_COLUMN_XOR_OFFSETS = (0, 0, 0, 2)
COORDINATE_COLUMN_MULTIPLIERS = (5, 6, 7, 8)

REMOVED_V1_COORDINATES = (
    "direct_2x_luma_coordinate_policy",
    "direct_2x_chroma_coordinate_policy",
    "direct_3_over_2_luma_coordinate_policy",
    "direct_3_over_2_chroma_coordinate_policy",
    "anisotropy_strength_q12",
)
ATOMIC_STRUCTURAL_COORDINATE = "spatial_structural_vector_ordinal"
THRESHOLD_BANDS = (
    "edge_present",
    "coherent_structure",
    "texture_high_frequency",
    "alias_or_ringing_risk",
    "chroma_luma_structure_aligned",
)


def gf16_multiply(lhs: int, rhs: int) -> int:
    """Multiply two four-bit GF(16) elements using x^4 + x + 1."""

    if not isinstance(lhs, int) or isinstance(lhs, bool) or not 0 <= lhs < 16:
        raise CalibrationPlanV2Error("GF(16) left operand is outside 0...15")
    if not isinstance(rhs, int) or isinstance(rhs, bool) or not 0 <= rhs < 16:
        raise CalibrationPlanV2Error("GF(16) right operand is outside 0...15")
    product = 0
    multiplicand = lhs
    multiplier = rhs
    while multiplier:
        if multiplier & 1:
            product ^= multiplicand
        multiplier >>= 1
        multiplicand <<= 1
        if multiplicand & 0b1_0000:
            multiplicand ^= GF16_REDUCTION_POLYNOMIAL
    return product & 0b1111


def _linear_column(x_value: int, y_value: int, multiplier: int) -> int:
    return x_value ^ gf16_multiply(multiplier, y_value)


def structural_vector_for_ordinal(ordinal: int) -> Mapping[str, object]:
    """Materialize one complete ten-factor structural vector."""

    if (
        not isinstance(ordinal, int)
        or isinstance(ordinal, bool)
        or not 0 <= ordinal < STRUCTURAL_VECTOR_COUNT
    ):
        raise CalibrationPlanV2Error("structural vector ordinal is outside 0...255")
    x_value, y_value = divmod(ordinal, 16)
    mode_values = tuple(
        (
            _linear_column(x_value, y_value, multiplier) ^ xor_offset
        )
        % len(MODE_ORDINALS)
        for multiplier, xor_offset in zip(
            MODE_COLUMN_MULTIPLIERS,
            MODE_COLUMN_XOR_OFFSETS,
        )
    )
    coordinate_values = tuple(
        COORDINATE_POLICIES[
            _linear_column(x_value, y_value, multiplier)
            % len(COORDINATE_POLICIES)
        ]
        for multiplier in COORDINATE_COLUMN_MULTIPLIERS
    )
    values: Tuple[object, ...] = (
        ADMISSIBLE_POLICY_IDS[x_value],
        ADMISSIBLE_POLICY_IDS[y_value],
        *mode_values,
        *coordinate_values,
    )
    return dict(zip(STRUCTURAL_FACTOR_ORDER, values))


def structural_vectors() -> Tuple[Mapping[str, object], ...]:
    """Return the complete preregistered screening design in ordinal order."""

    return tuple(
        structural_vector_for_ordinal(ordinal)
        for ordinal in range(STRUCTURAL_VECTOR_COUNT)
    )


def structural_factor_domains() -> Mapping[str, Tuple[object, ...]]:
    return {
        STRUCTURAL_FACTOR_ORDER[0]: ADMISSIBLE_POLICY_IDS,
        STRUCTURAL_FACTOR_ORDER[1]: ADMISSIBLE_POLICY_IDS,
        **{
            name: MODE_ORDINALS
            for name in STRUCTURAL_FACTOR_ORDER[2:6]
        },
        **{
            name: COORDINATE_POLICIES
            for name in STRUCTURAL_FACTOR_ORDER[6:10]
        },
    }


def pairwise_requirement_count() -> int:
    domains = structural_factor_domains()
    return sum(
        len(domains[first]) * len(domains[second])
        for first, second in combinations(STRUCTURAL_FACTOR_ORDER, 2)
    )


def validate_structural_design() -> Mapping[str, int]:
    """Exhaustively verify the frozen strength-two design."""

    vectors = structural_vectors()
    domains = structural_factor_domains()
    serialized = {
        tuple(vector[name] for name in STRUCTURAL_FACTOR_ORDER)
        for vector in vectors
    }
    if len(vectors) != STRUCTURAL_VECTOR_COUNT or len(serialized) != len(vectors):
        raise CalibrationPlanV2Error("structural design rows are missing or duplicated")
    if any(
        all(vector[name] == 0 for name in STRUCTURAL_FACTOR_ORDER[2:6])
        for vector in vectors
    ):
        raise CalibrationPlanV2Error("structural design contains the all-isotropic vector")

    covered_requirement_count = 0
    for first, second in combinations(STRUCTURAL_FACTOR_ORDER, 2):
        observed = {
            (vector[first], vector[second])
            for vector in vectors
        }
        expected = {
            (first_value, second_value)
            for first_value in domains[first]
            for second_value in domains[second]
        }
        if observed != expected:
            raise CalibrationPlanV2Error(
                f"structural design lacks pair coverage: {first}, {second}"
            )
        covered_requirement_count += len(observed)

    required = pairwise_requirement_count()
    if covered_requirement_count != required:
        raise CalibrationPlanV2Error("structural pair-coverage count differs from its domain")
    return {
        "row_count": len(vectors),
        "unique_row_count": len(serialized),
        "pairwise_requirement_count": required,
        "covered_pairwise_requirement_count": covered_requirement_count,
    }


def inherited_scalar_parameter_order(
    base_plan: Mapping[str, object],
) -> Tuple[str, ...]:
    """Remove only the five fields replaced by the atomic structural unit."""

    search = base_plan.get("search")
    if not isinstance(search, dict) or not isinstance(search.get("parameter_order"), list):
        raise CalibrationPlanV2Error("base plan lacks its parameter order")
    order = tuple(search["parameter_order"])
    if any(name not in order for name in REMOVED_V1_COORDINATES):
        raise CalibrationPlanV2Error("base plan lacks a replaced v1 coordinate")
    return tuple(name for name in order if name not in REMOVED_V1_COORDINATES)


def inherited_scalar_initial_values(
    base_plan: Mapping[str, object],
) -> Mapping[str, object]:
    search = base_plan.get("search")
    if not isinstance(search, dict) or not isinstance(
        search.get("initial_vector_values"), dict
    ):
        raise CalibrationPlanV2Error("base plan lacks its initial scalar values")
    initial = search["initial_vector_values"]
    return {
        name: initial[name]
        for name in inherited_scalar_parameter_order(base_plan)
    }


def base_parameter_domains(
    base_plan: Mapping[str, object],
) -> Mapping[str, Tuple[object, ...]]:
    """Derive the v1 domains without importing the production v1 runner."""

    ranges = base_plan.get("ranges")
    search = base_plan.get("search")
    if not isinstance(ranges, dict) or not isinstance(search, dict):
        raise CalibrationPlanV2Error("base plan lacks ranges or search policy")
    mapping = ranges.get("mapping")
    operator = ranges.get("operator")
    compiler = ranges.get("compiler")
    if not all(isinstance(value, dict) for value in (mapping, operator, compiler)):
        raise CalibrationPlanV2Error("base plan range groups are invalid")

    domains: Dict[str, Tuple[object, ...]] = {}
    for band in THRESHOLD_BANDS:
        low_name = (
            "alias_or_ringing_risk_low_unorm15"
            if band == "alias_or_ringing_risk"
            else "low_unorm15"
        )
        high_name = (
            "alias_or_ringing_risk_high_unorm15"
            if band == "alias_or_ringing_risk"
            else "high_unorm15"
        )
        domains[f"{band}_low_unorm15"] = tuple(mapping[low_name])
        domains[f"{band}_high_unorm15"] = tuple(mapping[high_name])
    for name in (
        "analysis_epsilon_q0_30",
        "risk_laplacian_weight_unorm15",
        "chroma_edge_confidence_unorm15",
        "direct_2x_analysis_grid_source_step",
        "direct_3_over_2_analysis_grid_source_step",
    ):
        domains[name] = tuple(mapping[name])
    coordinate_domain = tuple(operator["coordinate_policy_by_route"])
    for route_name in ("direct_2x", "direct_3_over_2"):
        domains[f"{route_name}_luma_coordinate_policy"] = coordinate_domain
        domains[f"{route_name}_chroma_coordinate_policy"] = coordinate_domain
    domains["boundary_mode"] = tuple(operator["boundary_mode"])
    for name, values in operator.items():
        if name not in {"coordinate_policy_by_route", "boundary_mode"}:
            domains[name] = tuple(values)
    for name, values in compiler.items():
        domains[name] = tuple(values)

    order = search.get("parameter_order")
    if (
        not isinstance(order, list)
        or set(order) != set(domains)
        or len(order) != len(domains)
    ):
        raise CalibrationPlanV2Error("base parameter order does not cover its domains")
    return domains


def scalar_domain_cardinality_sum(
    base_domains: Mapping[str, Sequence[object]],
    base_plan: Mapping[str, object],
) -> int:
    order = inherited_scalar_parameter_order(base_plan)
    if set(base_domains) != set(base_plan["search"]["parameter_order"]):
        raise CalibrationPlanV2Error("base domains do not cover the base parameter order")
    return sum(len(base_domains[name]) for name in order)
