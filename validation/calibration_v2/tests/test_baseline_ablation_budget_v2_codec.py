from __future__ import annotations

from collections.abc import Mapping
import copy
from dataclasses import FrozenInstanceError, replace
import hashlib
import json
from pathlib import Path
from typing import Optional
import unittest

from validation.calibration_v2.baseline_ablation_budget_v2 import (
    AUTHORITY_BINDING_IDS,
    COORDINATE_ORDER_V2,
    EXPECTED_MATERIALIZED_SELECTOR_SHA256,
    EXPECTED_MATERIALIZED_SELECTOR_SIZE_BYTES,
    EXPECTED_OVERLAY_FILE_SHA256,
    EXPECTED_OVERLAY_SCHEMA_SHA256,
    EXPECTED_OVERLAY_SELF_SHA256,
    MAXIMUM_DEVELOPMENT_ATTEMPTS_V2,
    MAXIMUM_SWEEPS_V2,
    MAXIMUM_VALIDATION_CANDIDATES_V2,
    SELECTOR_ID_V2,
    VALUES_V2,
    BaselineAblationBudgetV2Error,
    NonAshSelectorAuthorityIdentityV2,
    NonAshSelectorExecutionProfileV2,
    materialize_non_ash_selector_v2,
    parse_baseline_ablation_budget_v2,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
OVERLAY_PATH = CALIBRATION_ROOT / "contracts/baseline-ablation-budget-v2.json"
SCHEMA_PATH = CALIBRATION_ROOT / "schemas/baseline-ablation-budget-v2.schema.json"


class TaggedInt(int):
    pass


class TaggedStr(str):
    pass


class TaggedBytes(bytes):
    pass


class FlippingMapping(Mapping[str, object]):
    def __init__(
        self,
        source: Mapping[str, object],
        *,
        target: str,
        replacement: object,
    ) -> None:
        self.source = dict(source)
        self.target = target
        self.replacement = replacement
        self.read_counts = {key: 0 for key in self.source}

    def __iter__(self):
        return iter(self.source)

    def __len__(self) -> int:
        return len(self.source)

    def __getitem__(self, key: str) -> object:
        self.read_counts[key] += 1
        if key == self.target and self.read_counts[key] > 1:
            return self.replacement
        return self.source[key]


class FlippingPayloadMapping(Mapping[str, bytes]):
    def __init__(self, source: Mapping[str, bytes]) -> None:
        self.source = dict(source)
        self.read_counts = {key: 0 for key in self.source}

    def __iter__(self):
        return iter(self.source)

    def __len__(self) -> int:
        return len(self.source)

    def __getitem__(self, key: str) -> bytes:
        self.read_counts[key] += 1
        if self.read_counts[key] > 1:
            return self.source[key] + b"\n"
        return self.source[key]


class BaselineAblationBudgetV2CodecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.overlay_payload = OVERLAY_PATH.read_bytes()
        cls.schema_payload = SCHEMA_PATH.read_bytes()
        cls.overlay = json.loads(cls.overlay_payload)
        cls.authority_payloads = {
            binding["id"]: (ROOT / binding["path"]).read_bytes()
            for binding in cls.overlay["authority_bindings"]
        }
        cls.base_contract = json.loads(
            cls.authority_payloads["baseline_ablation_contract_v1"]
        )
        cls.base_selector = cls.base_contract["non_ash_selector"]
        cls.replacements = cls.overlay["selector_materialization"]["replacements"]

    def parse(
        self,
        *,
        overlay_payload: Optional[bytes] = None,
        schema_payload: Optional[bytes] = None,
        authority_payloads: Optional[Mapping[str, bytes]] = None,
    ) -> NonAshSelectorExecutionProfileV2:
        return parse_baseline_ablation_budget_v2(
            self.overlay_payload if overlay_payload is None else overlay_payload,
            schema_payload=(
                self.schema_payload if schema_payload is None else schema_payload
            ),
            authority_payloads=(
                self.authority_payloads
                if authority_payloads is None
                else authority_payloads
            ),
        )

    def test_exact_authority_parses_to_frozen_execution_profile(self) -> None:
        profile = self.parse()
        self.assertEqual(profile.selector_id, SELECTOR_ID_V2)
        self.assertEqual(profile.coordinate_order, COORDINATE_ORDER_V2)
        self.assertEqual(len(profile.coordinate_order), 27)
        self.assertEqual(profile.values, VALUES_V2)
        self.assertEqual(len(profile.values), 7)
        self.assertEqual(profile.maximum_sweeps, MAXIMUM_SWEEPS_V2)
        self.assertEqual(
            profile.maximum_development_attempts,
            MAXIMUM_DEVELOPMENT_ATTEMPTS_V2,
        )
        self.assertEqual(
            profile.maximum_validation_candidates,
            MAXIMUM_VALIDATION_CANDIDATES_V2,
        )
        self.assertEqual(
            profile.authority_identity,
            NonAshSelectorAuthorityIdentityV2(
                overlay_file_sha256=EXPECTED_OVERLAY_FILE_SHA256,
                overlay_self_sha256=EXPECTED_OVERLAY_SELF_SHA256,
                overlay_schema_sha256=EXPECTED_OVERLAY_SCHEMA_SHA256,
            ),
        )
        with self.assertRaises(FrozenInstanceError):
            profile.maximum_sweeps = 19

    def test_overlay_rejects_duplicate_nonfinite_and_altered_bytes(self) -> None:
        duplicate = self.overlay_payload.replace(
            b'{"artifact_kind":',
            (
                b'{"artifact_kind":"p06_baseline_ablation_budget_preregistration",'
                b'"artifact_kind":'
            ),
            1,
        )
        nonfinite = self.overlay_payload.replace(
            b'{"artifact_kind":',
            b'{"nonfinite":NaN,"artifact_kind":',
            1,
        )
        overflow_nonfinite = self.overlay_payload.replace(
            b'{"artifact_kind":',
            b'{"nonfinite":1e999,"artifact_kind":',
            1,
        )
        with self.assertRaisesRegex(
            BaselineAblationBudgetV2Error,
            "duplicate JSON member",
        ):
            self.parse(overlay_payload=duplicate)
        with self.assertRaisesRegex(
            BaselineAblationBudgetV2Error,
            "non-finite JSON value",
        ):
            self.parse(overlay_payload=nonfinite)
        with self.assertRaisesRegex(
            BaselineAblationBudgetV2Error,
            "non-finite JSON value",
        ):
            self.parse(overlay_payload=overflow_nonfinite)
        for payload in (
            self.overlay_payload + b"\n",
            self.overlay_payload[:-1],
            TaggedBytes(self.overlay_payload),
        ):
            with self.subTest(payload=payload[-8:]), self.assertRaises(
                BaselineAblationBudgetV2Error
            ):
                self.parse(overlay_payload=payload)

    def test_schema_rejects_duplicate_nonfinite_and_altered_bytes(self) -> None:
        duplicate = (
            b'{"duplicate":1,"duplicate":1,' + self.schema_payload[1:]
        )
        nonfinite = b'{"nonfinite":Infinity,' + self.schema_payload[1:]
        with self.assertRaisesRegex(
            BaselineAblationBudgetV2Error,
            "duplicate JSON member",
        ):
            self.parse(schema_payload=duplicate)
        with self.assertRaisesRegex(
            BaselineAblationBudgetV2Error,
            "non-finite JSON value",
        ):
            self.parse(schema_payload=nonfinite)
        for payload in (
            self.schema_payload + b"\n",
            self.schema_payload[:-1],
            TaggedBytes(self.schema_payload),
        ):
            with self.subTest(payload=payload[-8:]), self.assertRaises(
                BaselineAblationBudgetV2Error
            ):
                self.parse(schema_payload=payload)

    def test_every_authority_payload_is_verified_as_exact_bytes(self) -> None:
        self.assertEqual(
            tuple(binding["id"] for binding in self.overlay["authority_bindings"]),
            AUTHORITY_BINDING_IDS,
        )
        for identifier in AUTHORITY_BINDING_IDS:
            changed = dict(self.authority_payloads)
            changed[identifier] += b"\n"
            with self.subTest(identifier=identifier), self.assertRaisesRegex(
                BaselineAblationBudgetV2Error,
                "payload (size|SHA-256) mismatch",
            ):
                self.parse(authority_payloads=changed)

        missing = dict(self.authority_payloads)
        missing.pop(AUTHORITY_BINDING_IDS[0])
        extra = dict(self.authority_payloads)
        extra["undeclared"] = b"{}\n"
        aliased_value = dict(self.authority_payloads)
        aliased_value[AUTHORITY_BINDING_IDS[0]] = TaggedBytes(
            aliased_value[AUTHORITY_BINDING_IDS[0]]
        )
        aliased_key = {
            (TaggedStr(key) if index == 0 else key): value
            for index, (key, value) in enumerate(self.authority_payloads.items())
        }
        for index, payloads in enumerate(
            (missing, extra, aliased_value, aliased_key)
        ):
            with self.subTest(case=index), self.assertRaises(
                BaselineAblationBudgetV2Error
            ):
                self.parse(authority_payloads=payloads)

    def test_authority_json_rejects_duplicate_and_nonfinite_members(self) -> None:
        identifier = "quality_gate_policy_v1_seed"
        source = self.authority_payloads[identifier]
        duplicate = b'{"duplicate":1,"duplicate":1,' + source[1:]
        nonfinite = b'{"nonfinite":-Infinity,' + source[1:]
        for payload, expression in (
            (duplicate, "duplicate JSON member"),
            (nonfinite, "non-finite JSON value"),
        ):
            changed = dict(self.authority_payloads)
            changed[identifier] = payload
            with self.subTest(expression=expression), self.assertRaisesRegex(
                BaselineAblationBudgetV2Error,
                expression,
            ):
                self.parse(authority_payloads=changed)

    def test_authority_payload_mapping_is_snapshotted_once(self) -> None:
        payloads = FlippingPayloadMapping(self.authority_payloads)
        profile = self.parse(authority_payloads=payloads)
        self.assertEqual(profile.selector_id, SELECTOR_ID_V2)
        self.assertEqual(
            payloads.read_counts,
            {identifier: 1 for identifier in AUTHORITY_BINDING_IDS},
        )

    def test_materialization_is_exact_and_does_not_mutate_v1(self) -> None:
        original = copy.deepcopy(self.base_selector)
        materialized = materialize_non_ash_selector_v2(
            self.base_selector,
            self.replacements,
        )
        payload = canonical_json_bytes(materialized)
        self.assertEqual(self.base_selector, original)
        self.assertIsNot(materialized, self.base_selector)
        self.assertIsNot(materialized["coordinates"], self.base_selector["coordinates"])
        self.assertEqual(len(payload), EXPECTED_MATERIALIZED_SELECTOR_SIZE_BYTES)
        self.assertEqual(
            hashlib.sha256(payload).hexdigest(),
            EXPECTED_MATERIALIZED_SELECTOR_SHA256,
        )
        self.assertEqual(materialized["selector_id"], SELECTOR_ID_V2)
        self.assertEqual(
            materialized["coordinates"]["maximum_sweeps"],
            MAXIMUM_SWEEPS_V2,
        )

    def test_missing_extra_or_changed_replacement_is_rejected(self) -> None:
        missing = dict(self.replacements)
        missing.pop("/budget_formula")
        extra = dict(self.replacements)
        extra["/coordinates/initial_value"] = 1
        changed = dict(self.replacements)
        changed["/candidate_evaluation_budget"] = 3404
        type_aliased = dict(self.replacements)
        type_aliased["/candidate_evaluation_budget"] = TaggedInt(3403)
        bool_confused = dict(self.replacements)
        bool_confused["/candidate_evaluation_budget"] = True
        for index, replacements in enumerate(
            (missing, extra, changed, type_aliased, bool_confused)
        ):
            with self.subTest(case=index), self.assertRaises(
                BaselineAblationBudgetV2Error
            ):
                materialize_non_ash_selector_v2(
                    self.base_selector,
                    replacements,
                )

    def test_any_v1_selector_mutation_is_rejected(self) -> None:
        mutations = []
        inherited = copy.deepcopy(self.base_selector)
        inherited["inputs"][0] = "changed_input"
        mutations.append(inherited)
        inherited_scalar_subclass = copy.deepcopy(self.base_selector)
        inherited_scalar_subclass["bank_descriptor_ids"][0] = TaggedInt(0)
        mutations.append(inherited_scalar_subclass)
        inherited_string_subclass = copy.deepcopy(self.base_selector)
        inherited_string_subclass["coordinates"]["order"][0] = TaggedStr(
            inherited_string_subclass["coordinates"]["order"][0]
        )
        mutations.append(inherited_string_subclass)
        bool_confused = copy.deepcopy(self.base_selector)
        bool_confused["coordinates"]["initial_value"] = False
        mutations.append(bool_confused)
        for pointer in self.replacements:
            overwritten = copy.deepcopy(self.base_selector)
            if pointer == "/coordinates/maximum_sweeps":
                overwritten["coordinates"]["maximum_sweeps"] = 9
            else:
                overwritten[pointer[1:]] = "mutated"
            mutations.append(overwritten)

        for index, selector in enumerate(mutations):
            with self.subTest(case=index), self.assertRaises(
                BaselineAblationBudgetV2Error
            ):
                materialize_non_ash_selector_v2(selector, self.replacements)

    def test_materializer_snapshots_stateful_mappings_once(self) -> None:
        base = FlippingMapping(
            self.base_selector,
            target="coordinates",
            replacement={},
        )
        replacements = FlippingMapping(
            self.replacements,
            target="/candidate_evaluation_budget",
            replacement=3404,
        )
        materialized = materialize_non_ash_selector_v2(base, replacements)
        self.assertEqual(materialized["selector_id"], SELECTOR_ID_V2)
        self.assertEqual(base.read_counts["coordinates"], 1)
        self.assertEqual(
            replacements.read_counts["/candidate_evaluation_budget"],
            1,
        )
        self.assertTrue(all(count == 1 for count in base.read_counts.values()))
        self.assertTrue(
            all(count == 1 for count in replacements.read_counts.values())
        )

    def test_frozen_models_reject_bool_and_scalar_subclass_confusion(self) -> None:
        profile = self.parse()
        invalid_changes = (
            {"maximum_sweeps": True},
            {"values": (*VALUES_V2[:-1], TaggedInt(384))},
            {
                "coordinate_order": (TaggedStr(COORDINATE_ORDER_V2[0]),)
                + COORDINATE_ORDER_V2[1:]
            },
        )
        for index, changes in enumerate(invalid_changes):
            with self.subTest(case=index), self.assertRaises(
                BaselineAblationBudgetV2Error
            ):
                replace(profile, **changes)

        with self.assertRaises(BaselineAblationBudgetV2Error):
            NonAshSelectorAuthorityIdentityV2(
                overlay_file_sha256=TaggedStr(EXPECTED_OVERLAY_FILE_SHA256),
                overlay_self_sha256=EXPECTED_OVERLAY_SELF_SHA256,
                overlay_schema_sha256=EXPECTED_OVERLAY_SCHEMA_SHA256,
            )


if __name__ == "__main__":
    unittest.main()
