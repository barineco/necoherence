# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import unittest

from semantic_invariant_checks import adapter_input, exact_json, normalized
from semantic_invariant_inputs import generate, library
from preset_representative_inputs import PUBLIC_FORMATS, generate_preset_cases, sigma_case


class RepresentativeInputProperties(unittest.TestCase):
    def test_inputs_are_deterministic_and_uniquely_identified(self):
        first = generate()
        self.assertEqual(first, generate())
        self.assertEqual(len(first), len({case["id"] for case in first}))

    def test_stage_branches_are_constructed_from_rules(self):
        rules = {case["rule"] for case in generate()}
        self.assertTrue({"Text", "Not", "Sequence", "wrapper", "sealed", "ordinary",
                         "internalTag", "memberShape", "kind", "otherwise", "decimal",
                         "IntegerForm.number", "IntegerForm.integralDecimal",
                         "IntegerForm.decimalString", "length-utf8", "length-scalar",
                         "length-grapheme", "BytesAlphabet.Standard", "BytesAlphabet.UrlSafe",
                         "BytesAlphabet.Either", "extras-reject", "extras-allow",
                         "nullable-array", "nullable-extras", "never"} <= rules)
        self.assertTrue({f"C{index}" for index in range(1, 6)} <= rules)
        self.assertTrue({f"I{index}" for index in range(1, 8)} <= rules)

    def test_library_uses_only_checked_generation_v4_declarations(self):
        subject = library()
        self.assertEqual(subject["schema"], "ncoh-type-signatures@1")
        self.assertNotIn("representation", subject["profile"])
        self.assertEqual(subject["profile"]["bytes_policy"]["alphabet"]["tag"], "Either")

    def test_language_adapters_receive_their_declared_envelopes(self):
        case = next(case for case in generate() if case["operation"] == "inclusion")
        self.assertEqual(adapter_input("lean", case)["kind"], "inclusion_by_id")
        self.assertEqual(adapter_input("typescript", case)["operation"], "inclusion")
        self.assertIn("source", adapter_input("python", case))

    def test_typescript_exact_json_preserves_json_kinds(self):
        self.assertEqual(exact_json({"x": [1, True, None]}), {
            "tag": "Object", "members": [{"key": "x", "value": {"tag": "Array", "items": [
                {"tag": "Integer", "value": "1"}, {"tag": "Bool", "value": True}, {"tag": "Null"}]}}]})

    def test_normalization_uses_semantic_fields(self):
        self.assertEqual(normalized("value", {"status": "Rejected", "failure": {
            "type_ref": "count", "condition": "IntegerDomain", "path": [], "trace": ["integer"]}}),
            {"status": "Rejected", "type_ref": "count", "condition": "IntegerDomain", "path": [],
             "trace": ["integer"]})



class PresetRepresentativeInputProperties(unittest.TestCase):
    def test_three_profiles_and_public_formats_are_covered(self):
        cases = generate_preset_cases()
        self.assertEqual(cases, generate_preset_cases())
        self.assertEqual(len(cases), len({case["id"] for case in cases}))
        self.assertEqual(
            {case["library"]["identity"] for case in cases},
            {
                "atproto-data-model-representatives",
                "json-schema-2020-12-observation",
                "protobuf-proto3-protojson-observation",
            },
        )
        for name in PUBLIC_FORMATS:
            self.assertEqual(
                {case["spec_status"] for case in cases if case["id"].startswith(f"at-format-{name}-")},
                {"Accepted", "Rejected"},
            )

    def test_sigma_renames_profile_library_and_input_together(self):
        original = next(case for case in generate_preset_cases() if case["id"] == "at-sealed-blob")
        renamed, _ = sigma_case(original)
        self.assertEqual(renamed["value"]["$kind"], "binary-blob")
        self.assertIn("reference-field", renamed["value"])
        self.assertNotEqual(
            original["library"]["profile"]["reference"]["content_digest"],
            renamed["library"]["profile"]["reference"]["content_digest"],
        )

if __name__ == "__main__":
    unittest.main()
