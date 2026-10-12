// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { expect, it } from "vitest";
import { evaluateSemanticInvariant } from "../src/semantic_invariant_adapter.js";
import { library } from "./semantic-fixture.js";

it("judges @4 profile, library and value inputs", () => {
  const subject = library();
  expect(evaluateSemanticInvariant({ id: "profile", operation: "profile", library: subject })).toMatchObject({ status: "Accepted" });
  expect(evaluateSemanticInvariant({ id: "library", operation: "library", library: subject })).toMatchObject({ status: "Accepted" });
  expect(evaluateSemanticInvariant({ id: "value", operation: "value", library: subject, type_id: "text", value: { tag: "String", value: "x" } })).toMatchObject({ status: "Accepted" });
  expect(evaluateSemanticInvariant({ id: "invalid", operation: "value", library: subject, type_id: "truth", value: { tag: "String", value: "x" } })).toMatchObject({ status: "Rejected", condition: "WrongValueKind:boolean" });
});

it("serializes an indexed value failure with a canonical numeric path", () => {
  const base = library();
  const subject = {
    ...base,
    nodes: [
      ...base.nodes,
      { id: "integer", shape: { tag: "Integer" as const, value: { domain: "integer", minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null } } },
      { id: "repeated-integer", shape: { tag: "Array" as const, value: { item: { type_id: "integer", nullable: false }, min_length: null, max_length: null } } },
    ],
  };
  const output = evaluateSemanticInvariant({
    id: "repeated-integer-null",
    operation: "value",
    library: subject,
    type_id: "repeated-integer",
    value: { tag: "Array", items: [{ tag: "Null" }] },
  });
  expect(output).toMatchObject({ status: "Rejected", condition: "WrongValueKind:integer", path: [0], trace: ["repeated-integer"] });
  expect(() => JSON.stringify(output)).not.toThrow();
});

it("returns Lean-shaped inclusion classifications and sample obligations", () => {
  const subject = library();
  expect(evaluateSemanticInvariant({ id: "inclusion", operation: "inclusion", library: subject, type_id: "text", destination_type_id: "truth" })).toMatchObject({ status: "Incompatible" });
  expect(evaluateSemanticInvariant({ id: "samples", operation: "samples", library: subject, type_id: "text", max_type_obligations: "3", max_sample_length: "0" })).toMatchObject({ status: "Accepted", sample_bound: true, sample_count: "1" });
});
