// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as V from "../src/semantic_values.js";
import { profile } from "./semantic-fixture.js";
import { acceptedValue, valueFailure } from "./validation-support.js";

it("counts empty, scalar and combining grapheme sequences", () => {
  const rules = profile.grapheme_rules! as V.GraphemeRules;
  expect(V.graphemeLength(rules, "")).toBe(0n);
  expect(V.graphemeLength(rules, "a\u0301")).toBe(1n);
});

it("applies grapheme length bounds in value validation", () => {
  const source: V.SourceRef = { repository: "grapheme", revision: "4", path: "types", content_digest: "b".repeat(64), document_id: "" };
  const reference: V.TypeRef = { source, definition_name: "two", pointer: [] };
  const context = new V.ValueContext({ profile, nodes: [{ reference, shape: { tag: "String", value: { format: null, lengths: [{ unit: { tag: "Graphemes" }, minimum: "2", maximum: "2" }], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null } }, description: null, attributes: [], extensions: [] }] });
  expect(valueFailure(context, reference, { tag: "String", value: "a\u0301" })).toMatchObject({ condition: { tag: "StringLength" } });
  expect(acceptedValue(context, reference, { tag: "String", value: "a\u0301b" })).toEqual({ tag: "String", value: "a\u0301b" });
});

it("takes the first property row that contains a codepoint when the table is not sorted", () => {
  const rules = profile.grapheme_rules! as V.GraphemeRules;
  const rowsWith = (rows: readonly V.GraphemeRange[]): V.GraphemeRules => ({ ...rules, properties: rows });
  const extendFirst = rowsWith([{ first: "65", last: "90", property: { tag: "Extend" } }, { first: "65", last: "65", property: { tag: "Other" } }]);
  expect(V.graphemeLength(extendFirst, "AA")).toBe(1n);
  const otherFirst = rowsWith([{ first: "65", last: "65", property: { tag: "Other" } }, { first: "65", last: "90", property: { tag: "Extend" } }]);
  expect(V.graphemeLength(otherFirst, "AA")).toBe(2n);
});
