from __future__ import annotations

from pathlib import Path

from validation.calibration_v2.native_adapter.factory import (
    make_native_candidate_adapter_factory,
)
from validation.calibration_v2.production_evaluator import (
    _invoke_cached_fixed,
    _prepare_native_output_cache,
)
from validation.calibration_v2.tests.test_native_adapter import (
    _BoundStub,
    _context,
    _fixture,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


def test_two_vectors_same_bank_reopen_fixed_cache_without_preparation(
    tmp_path: Path,
) -> None:
    factory = make_native_candidate_adapter_factory(
        REPOSITORY_ROOT,
        cache_root=tmp_path / "native",
        timeout_seconds=300.0,
        bound_inputs=_BoundStub(),
    )
    first_vector = dict(factory.plan["search"]["initial_vector_values"])
    second_vector = dict(first_vector)
    second_vector["edge_present_low_unorm15"] = 4915
    frame = _fixture()
    context = _context("direct-2x")
    preparations = []
    configurations = []
    banks = []
    manifests = []
    output_hashes = []

    for vector in (first_vector, second_vector):
        adapter = factory(vector, "development")
        try:
            configurations.append(adapter.configuration_sha256)
            bank = str(adapter.configuration["shared_bank_configuration_sha256"])
            banks.append(bank)
            token, manifest, preparation = _prepare_native_output_cache(
                adapter=adapter,
                frame=frame,
                context=context,
                source_asset_id="same-bank-cache-proof",
                degradation_profile_id="profile-0",
                degradation_profile_sha256="a" * 64,
                shared_bank_configuration_sha256=bank,
            )
            preparations.append(preparation)
            manifests.append(manifest)
            current = []
            for descriptor_id in range(16):
                output, _ = _invoke_cached_fixed(
                    adapter=adapter,
                    cache_token=token,
                    cache_manifest=manifest,
                    descriptor_id=descriptor_id,
                    context=context,
                    shared_bank_configuration_sha256=bank,
                )
                current.append(
                    manifest["descriptor_outputs"][descriptor_id][
                        "output_frame_sha256"
                    ]
                )
            output_hashes.append(current)
        finally:
            adapter.callable.close()

    assert configurations[0] != configurations[1]
    assert banks[0] == banks[1]
    assert preparations[0]["cache_reused"] is False
    assert preparations[0]["preparation_analysis_grid_invocation_count"] == 1
    assert preparations[0]["preparation_spatial_operator_evaluation_count"] == 16
    assert preparations[1]["cache_reused"] is True
    assert preparations[1]["preparation_analysis_grid_invocation_count"] == 0
    assert preparations[1]["preparation_spatial_operator_evaluation_count"] == 0
    assert preparations[0]["cache_token"] == preparations[1]["cache_token"]
    assert manifests[0] == manifests[1]
    assert output_hashes[0] == output_hashes[1]
