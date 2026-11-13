"""Independent exact replay of the phase2 subsampled coordinate/kernel facts."""
from __future__ import annotations

from fractions import Fraction
from functools import lru_cache
import hashlib
import json
from typing import Any

COORDINATE_ID = "pixel-center-luma-authenticated-subsampled-siting-v2"
KERNEL_ID = "ash-p06-catmull-rom-q14-subsampled-physical-siting-v2"
OFFSETS = {
    "left": (0, 1), "center": (1, 1), "top_left": (0, 0),
    "top": (1, 0), "bottom_left": (0, 2), "bottom": (1, 2),
}
GEOMETRY_KEYS = {
    "schemaVersion", "recipePolicyID", "coordinateProcedureID", "kernelContractID",
    "sourceSiting", "outputSiting", "planSchemaVersion", "sourceLumaWidth",
    "sourceLumaHeight", "targetLumaWidth", "targetLumaHeight",
    "scalePlanSHA256", "kernelIRSHA256",
}

QUALITY_CONTRACT_SCHEMA = "mirmir-ash-v4-quality-gate-contract-v1"
QUALITY_CONTRACT_SCHEMA_PHASE2 = "mirmir-ash-v4-quality-gate-contract-v2"
QUALITY_RECIPE_POLICY_ID = "quality-box-source-reference-center-v1"


def quality_contract_phase2(contract: Any) -> bool:
    if not isinstance(contract, dict):
        raise ValueError("quality contract must be an object")
    schema = contract.get("schemaVersion")
    if schema == QUALITY_CONTRACT_SCHEMA:
        return False
    if schema != QUALITY_CONTRACT_SCHEMA_PHASE2:
        raise ValueError("unsupported quality contract")
    construction = contract.get("corpusConstruction")
    if not isinstance(construction, dict):
        raise ValueError("quality corpus construction must be an object")
    common = {
        "chromaSiting", "declaredDownsampling", "referenceHeight",
        "referenceWidth", "sourceHeight", "sourceWidth", "transferAndMatrix",
        "sourceChromaSiting", "referenceChromaSiting", "chromaRecipePolicyID",
    }
    synthetic = {
        "syntheticDiagnosticClipCountPerCohort",
        "syntheticDiagnosticFramesPerClip", "syntheticDiagnosticReleaseEligible",
    }
    natural = {
        "decodedReferenceProcedure", "minimumDecodedSourceHeight",
        "minimumDecodedSourceWidth", "naturalClipCountPerCohort",
        "naturalFramesPerClip", "rgbToBT709Procedure",
    }
    if set(construction) not in (common | synthetic, common | natural):
        raise ValueError("phase2 quality construction field set differs")
    expected = {
        "chromaSiting": "center", "sourceChromaSiting": "center",
        "referenceChromaSiting": "center",
        "chromaRecipePolicyID": QUALITY_RECIPE_POLICY_ID,
        "declaredDownsampling": "independent visible-plane 2x2 box average with nearest-ties-to-even integer rounding",
    }
    for key, value in expected.items():
        if construction.get(key) != value:
            raise ValueError(f"phase2 quality construction differs: {key}")
    return True


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def rational(value: Fraction) -> dict[str, int]:
    return {"numerator": value.numerator, "denominator": value.denominator}


def coefficients(phase: Fraction) -> list[int]:
    t = phase
    weights = [-t * (1-t)**2 / 2, 1-Fraction(5, 2)*t*t+Fraction(3, 2)*t**3,
               t/2+2*t*t-Fraction(3, 2)*t**3, -t*t*(1-t)/2]
    scaled = [w * 16384 for w in weights]
    result = [w.numerator // w.denominator for w in scaled]
    residual = 16384 - sum(result)
    preference = [1, 2, 0, 3] if t <= Fraction(1, 2) else [2, 1, 3, 0]
    order = sorted(range(4), key=lambda i: (-(scaled[i]-result[i]), preference.index(i)))
    for index in order[:residual]:
        result[index] += 1
    return result


@lru_cache(maxsize=256)
def expected_hashes(sw: int, sh: int, tw: int, th: int,
                    source: str, target: str) -> tuple[str, str]:
    if any(type(x) is not int or not 0 < x <= 65536 for x in (sw, sh, tw, th)):
        raise ValueError("invalid luma extents")
    if tw < sw or th < sh or source not in OFFSETS or target not in OFFSETS:
        raise ValueError("invalid phase2 geometry")
    axes = []
    phase_lists = []
    for axis_index, (name, size, extent) in enumerate((("horizontal", sw, tw), ("vertical", sh, th))):
        # Independent physical luma half-pixel map, in exact half-luma units.
        positions = []
        phases = []
        for j in range((extent + 1)//2):
            source_luma = (2*j + Fraction(OFFSETS[target][axis_index], 2) + Fraction(1, 2))*Fraction(size, extent)-Fraction(1, 2)
            position = (source_luma - Fraction(OFFSETS[source][axis_index], 2))/2
            base = position.numerator // position.denominator
            phase = position - base
            phases.append(phase)
            positions.append({"destinationIndex": j, "sourceBase": base, "phase": rational(phase)})
        unique = sorted(set(phases))
        phase_lists.append((phases, unique))
        axes.append({"schemaVersion": 2, "axis": name,
                     "sourceExtent": (size+1)//2, "targetExtent": (extent+1)//2,
                     "scale": rational(Fraction((extent+1)//2, (size+1)//2)),
                     "borderRule": "reflect101", "positions": positions,
                     "uniquePhases": [rational(p) for p in unique],
                     "subsampledLumaMapping": {"axis": name, "sourceLumaExtent": size,
                         "targetLumaExtent": extent, "geometry": {"source": source, "target": target}}})
    plan = {"schemaVersion": 2, "horizontal": axes[0], "vertical": axes[1]}
    kernel = {"schemaVersion": 1, "coefficientProcedureID": "ash-p06-catmull-rom-q14-largest-remainder-v1", "fractionalBits": 14}
    for name, (phases, unique) in zip(("horizontal", "vertical"), phase_lists):
        kernel[name + "Kernels"] = [{"phase": rational(p), "coefficients": coefficients(p), "fractionalBits": 14, "roundingRule": "nearestTiesToEven"} for p in unique]
        kernel[name + "KernelIndexByDestination"] = [unique.index(p) for p in phases]
    return tuple(hashlib.sha256(canonical_bytes(value)).hexdigest() for value in (plan, kernel))


def validate_geometry(value: Any, dimensions: tuple[int, int, int, int], *,
                      schema: str, policy: str, source: str, target: str,
                      label: str) -> None:
    if not isinstance(value, dict) or set(value) != GEOMETRY_KEYS:
        raise ValueError(f"{label}: geometry field set differs")
    expected = {"schemaVersion": schema, "recipePolicyID": policy,
                "coordinateProcedureID": COORDINATE_ID, "kernelContractID": KERNEL_ID,
                "sourceSiting": source, "outputSiting": target, "planSchemaVersion": 2}
    for key, dimension in zip(("sourceLumaWidth", "sourceLumaHeight", "targetLumaWidth", "targetLumaHeight"), dimensions):
        if type(value[key]) is not int:
            raise ValueError(f"{label}: {key} is not an integer")
        expected[key] = dimension
    for key, observed in expected.items():
        if type(value[key]) is not type(observed) or value[key] != observed:
            raise ValueError(f"{label}: {key} differs")
    plan_sha, kernel_sha = expected_hashes(*dimensions, source, target)
    if value["scalePlanSHA256"] != plan_sha or value["kernelIRSHA256"] != kernel_sha:
        raise ValueError(f"{label}: independently replayed geometry hashes differ")
