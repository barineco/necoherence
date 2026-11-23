# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

import sys
import unittest
from pathlib import Path

import default_materialization_compare as materialization
import semantic_invariant_checks as semantic

ROOT = Path(__file__).resolve().parent


def stderr_adapter(text):
    return [sys.executable, "-c", f"import sys; sys.stderr.write({text!r}); sys.exit(1)"]


def typed_adapter(row):
    return [sys.executable, "-c", f"import json, sys\nfor line in sys.stdin:\n    print(json.dumps({row!r}))\n"]


class DefaultMaterializationComparison(unittest.TestCase):
    def compare_wire(self, lean, python):
        inputs = [{"id": "case-1"}]
        outputs = {"lean": [materialization.normalized(lean)], "python": [materialization.normalized(python)]}
        mismatches, _, _ = materialization.compare(inputs, outputs, ["python"])
        return mismatches

    def test_wire_rows_with_different_paths_are_mismatches(self):
        lean = {"id": "case-1", "status": "Wire", "classification": "UnknownField", "path": "$.graph.nodes[3]"}
        python = {"id": "case-1", "status": "Wire", "classification": "UnknownField", "path": "$.graph.nodes[7]"}
        self.assertEqual(len(self.compare_wire(lean, python)), 1)

    def test_wire_rows_without_paths_are_mismatches(self):
        row = {"id": "case-1", "status": "Wire", "classification": "DuplicateField"}
        self.assertEqual(len(self.compare_wire(row, dict(row))), 1)

    def test_equal_typed_wire_rows_match(self):
        row = {"id": "case-1", "status": "Wire", "classification": "Syntax", "path": "$"}
        self.assertEqual(self.compare_wire(row, dict(row)), [])

    def test_stderr_paths_do_not_become_wire_rows(self):
        inputs = [{"id": "case-1"}]
        for text in ("UnknownField at $.graph.nodes[3]", "UnknownField at $.graph.nodes[7]"):
            with self.assertRaises(RuntimeError):
                materialization.observe(stderr_adapter(text), cwd=ROOT, data='{"id":"case-1"}\n', env=None, inputs=inputs)

    def test_typed_rows_are_observed_from_stdout(self):
        row = {"id": "case-1", "status": "Wire", "classification": "Syntax", "path": "$"}
        rows = materialization.observe(typed_adapter(row), cwd=ROOT, data='{"id":"case-1"}\n', env=None, inputs=[{"id": "case-1"}])
        self.assertEqual(rows, [row])


class SemanticInvariantComparison(unittest.TestCase):
    def test_classification_wire_paths_are_compared(self):
        lean = {"id": "case-1", "status": "Rejected", "failure_kind": "Wire", "classification": "UnknownField", "path": "$.graph.nodes[3]"}
        other = {"id": "case-1", "status": "Rejected", "failure_kind": "Wire", "classification": "UnknownField", "path": "$.graph.nodes[7]"}
        self.assertTrue(semantic.differs(semantic.normalized("classification", other), semantic.normalized("classification", lean)))

    def test_classification_wire_rows_without_paths_are_mismatches(self):
        row = {"id": "case-1", "status": "Rejected", "failure_kind": "Wire", "classification": "Syntax"}
        self.assertTrue(semantic.differs(semantic.normalized("classification", row), semantic.normalized("classification", dict(row))))

    def test_message_text_does_not_select_a_classification(self):
        lean = {"id": "case-1", "status": "Rejected", "failure_kind": "Wire", "classification": "UnknownTag", "path": "$.kind"}
        other = {"id": "case-1", "status": "Error", "message": 'UnknownTag at $.kind: tag "UnknownField" is not a known branch'}
        self.assertTrue(semantic.differs(semantic.normalized("classification", other), semantic.normalized("classification", lean)))

    def test_nested_and_top_level_wire_failures_are_read_as_typed_fields(self):
        nested = {"id": "case-1", "status": "Rejected", "failure": {"kind": "Wire", "classification": "UnknownField", "path": "$.a"}}
        top = {"id": "case-1", "status": "Rejected", "failure_kind": "Wire", "classification": "UnknownField", "path": "$.a"}
        self.assertFalse(semantic.differs(semantic.normalized("wire", nested), semantic.normalized("wire", top)))

    def test_samples_compare_count_and_canonical_values(self):
        integer = lambda text: {"tag": "Integer", "value": text}
        lean = {"id": "case-1", "status": "Accepted", "sample_bound": False, "sample_count": 1, "values": [
            {"tag": "Object", "members": [{"key": "b", "value": integer("1")}, {"key": "a", "value": integer("2")}]}]}
        reordered = {"id": "case-1", "status": "Accepted", "sample_bound": False, "sample_count": 1, "values": [
            {"tag": "Object", "members": [{"key": "a", "value": integer("2")}, {"key": "b", "value": integer("1")}]}]}
        longer = {**reordered, "sample_count": 2, "values": reordered["values"] + [integer("3")]}
        self.assertFalse(semantic.differs(semantic.normalized("samples", reordered), semantic.normalized("samples", lean)))
        self.assertTrue(semantic.differs(semantic.normalized("samples", longer), semantic.normalized("samples", lean)))
        self.assertTrue(semantic.differs(semantic.normalized("samples", {**lean, "values": [integer("1")]}), semantic.normalized("samples", lean)))


if __name__ == "__main__":
    unittest.main()
