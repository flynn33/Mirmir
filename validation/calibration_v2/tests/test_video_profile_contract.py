from __future__ import annotations

import hashlib
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = CALIBRATION_ROOT / "contracts" / "video-profile-contract-v1.json"
SCHEMA_PATH = CALIBRATION_ROOT / "schemas" / "video-profile-contract-v1.schema.json"
CONTRACT_SHA256 = "8c61d53cab158838e559b81a1d0c6b65ecc734a61ade76f84d41c92187214ef3"
INSTANCE_MATRIX_SHA256 = "ccac6db74c9f47438741fc3bd5fd12daf127b1a5bd8debf89455d350cfc0217c"


def canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


class VideoProfileContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract_bytes = CONTRACT_PATH.read_bytes()
        cls.contract = json.loads(cls.contract_bytes)
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    def test_contract_is_exact_canonical_text_and_schema_valid(self) -> None:
        self.assertEqual(self.contract_bytes, canonical_bytes(self.contract) + b"\n")
        self.assertEqual(hashlib.sha256(self.contract_bytes).hexdigest(), CONTRACT_SHA256)
        self.assertEqual(list(Draft202012Validator(self.schema).iter_errors(self.contract)), [])

    def test_schema_rejects_invalid_format_range_pair_and_missing_siting(self) -> None:
        invalid_pair = json.loads(json.dumps(self.contract))
        invalid_pair["valid_pixel_format_range_pairs"][1]["range"] = "full"
        missing_siting = json.loads(json.dumps(self.contract))
        missing_siting["allowed_chroma_sitings"].remove("bottom_left")
        validator = Draft202012Validator(self.schema)
        self.assertTrue(list(validator.iter_errors(invalid_pair)))
        self.assertTrue(list(validator.iter_errors(missing_siting)))

    def test_exact_twelve_instance_matrix_has_frozen_hash(self) -> None:
        instances = []
        for pair in self.contract["valid_pixel_format_range_pairs"]:
            for siting in self.contract["allowed_chroma_sitings"]:
                instances.append(
                    {
                        "bit_depth": self.contract["bit_depth"],
                        "chroma_siting": siting,
                        "color_primaries": self.contract["color"]["color_primaries"],
                        "pixel_format": pair["pixel_format"],
                        "profile_family_id": self.contract["profile_family_id"],
                        "range": pair["range"],
                        "scan_type": self.contract["scan_type"],
                        "subsampling": self.contract["subsampling"],
                        "transfer_function": self.contract["color"]["transfer_function"],
                        "ycbcr_matrix": self.contract["color"]["ycbcr_matrix"],
                    }
                )
        self.assertEqual(len(instances), 12)
        self.assertEqual(len({hashlib.sha256(canonical_bytes(row)).hexdigest() for row in instances}), 12)
        self.assertEqual(hashlib.sha256(canonical_bytes(instances)).hexdigest(), INSTANCE_MATRIX_SHA256)


if __name__ == "__main__":
    unittest.main()
