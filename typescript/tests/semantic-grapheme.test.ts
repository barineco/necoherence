// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as V from "../src/semantic_values.js";
import { profile } from "./semantic-fixture.js";

it("counts empty, scalar and combining grapheme sequences", () => {
  const rules = profile.grapheme_rules! as V.GraphemeRules;
  expect(V.graphemeBoundaries(rules, "")).toEqual([]);
  expect(V.graphemeCount(rules, "")).toBe(0n);
  expect(V.graphemeBoundaries(rules, "a\u0301")).toEqual([0n, 2n]);
  expect(V.graphemeCount(rules, "a\u0301")).toBe(1n);
});

it("applies grapheme length bounds in value validation", () => {
  const source: V.SourceRef = { repository: "grapheme", revision: "4", path: "types", content_digest: "b".repeat(64), document_id: "" };
  const reference: V.TypeRef = { source, definition_name: "two", pointer: [] };
  const context = new V.ValueContext({ profile, nodes: [{ reference, shape: { tag: "String", value: { format: null, lengths: [{ unit: { tag: "Graphemes" }, minimum: "2", maximum: "2" }], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null } }, description: null, attributes: [], extensions: [] }] });
  expect(() => context.validate(reference, { tag: "String", value: "a\u0301" })).toThrow(/StringLength/);
  expect(context.validate(reference, { tag: "String", value: "a\u0301b" })).toEqual({ tag: "String", value: "a\u0301b" });
});
