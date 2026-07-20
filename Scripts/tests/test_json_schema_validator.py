from __future__ import annotations

from pathlib import Path
import sys
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402


class JSONSchemaValidatorTests(unittest.TestCase):
    def validate(self, schema: dict[str, object], value: object) -> list[str]:
        return validate_json_schema_instance(schema, value)

    def test_reference_siblings_and_all_of_are_enforced(self) -> None:
        schema = {
            "$defs": {
                "closed": {
                    "type": "object",
                    "required": ["id"],
                    "properties": {"id": {"type": "string"}},
                    "additionalProperties": False,
                }
            },
            "allOf": [
                {"$ref": "#/$defs/closed"},
                {"properties": {"id": {"const": "A01"}}},
            ],
        }

        self.assertEqual(self.validate(schema, {"id": "A01"}), [])
        self.assertTrue(self.validate(schema, {"id": "A02"}))
        self.assertTrue(self.validate(schema, {"id": "A01", "extra": True}))

    def test_one_of_does_not_skip_sibling_closure(self) -> None:
        schema = {
            "type": "object",
            "required": ["kind"],
            "properties": {"kind": {"enum": ["a", "b"]}},
            "oneOf": [
                {"properties": {"kind": {"const": "a"}}},
                {"properties": {"kind": {"const": "b"}}},
            ],
            "additionalProperties": False,
        }

        self.assertEqual(self.validate(schema, {"kind": "a"}), [])
        self.assertTrue(self.validate(schema, {"kind": "a", "extra": 1}))
        self.assertTrue(self.validate(schema, {"kind": "c"}))

    def test_conditionals_and_not_are_enforced(self) -> None:
        schema = {
            "type": "object",
            "required": ["status", "reason"],
            "properties": {
                "status": {"enum": ["passed", "failed"]},
                "reason": {"type": ["string", "null"]},
            },
            "if": {"properties": {"status": {"const": "passed"}}},
            "then": {"properties": {"reason": {"type": "null"}}},
            "else": {
                "properties": {
                    "reason": {"type": "string", "not": {"const": "none"}}
                }
            },
            "additionalProperties": False,
        }

        self.assertEqual(
            self.validate(schema, {"status": "passed", "reason": None}), []
        )
        self.assertEqual(
            self.validate(schema, {"status": "failed", "reason": "timeout"}),
            [],
        )
        self.assertTrue(
            self.validate(schema, {"status": "passed", "reason": "unexpected"})
        )
        self.assertTrue(
            self.validate(schema, {"status": "failed", "reason": "none"})
        )

    def test_prefix_items_items_false_and_contains_are_enforced(self) -> None:
        schema = {
            "type": "array",
            "minItems": 2,
            "maxItems": 2,
            "prefixItems": [{"const": "first"}, {"const": "second"}],
            "items": False,
            "contains": {"const": "second"},
            "minContains": 1,
            "maxContains": 1,
        }

        self.assertEqual(self.validate(schema, ["first", "second"]), [])
        self.assertTrue(self.validate(schema, ["second", "first"]))
        self.assertTrue(self.validate(schema, ["first", "second", "extra"]))

    def test_scalar_bounds_and_boolean_schemas_are_enforced(self) -> None:
        self.assertEqual(
            self.validate(
                {
                    "type": "number",
                    "exclusiveMinimum": 0,
                    "exclusiveMaximum": 2,
                },
                1,
            ),
            [],
        )
        self.assertTrue(self.validate({"exclusiveMinimum": 0}, 0))
        self.assertTrue(self.validate({"maxLength": 3}, "four"))
        self.assertEqual(self.validate(True, {"anything": True}), [])
        self.assertTrue(self.validate(False, None))


if __name__ == "__main__":
    unittest.main()
