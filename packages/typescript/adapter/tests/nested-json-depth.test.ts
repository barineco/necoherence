// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as V from "../src/semantic_values.js";

const SHALLOW = 1000;
const DEEP = 10000;

const digest = "d".repeat(64);
const profileReference: V.ProfileRef = { identity: "depth", revision: "1", content_digest: digest };
const source: V.SourceRef = { repository: "depth", revision: "1", path: "depth", content_digest: digest, document_id: "" };
const ref = (name: string): V.TypeRef => ({ source, definition_name: name, pointer: [] });
const profile: V.VersionedSemanticProfile = {
  reference: profileReference,
  source_refs: [],
  integer_domains: [{ name: "default", reference: profileReference, range: { tag: "Unbounded" }, forms: [{ tag: "Number" }] }],
  default_integer_domain: "default",
  numbers: { decimals: false },
  grapheme_rules: null,
  format_bindings: [],
  bytes_policy: null,
  wrappers: [],
  tag: null,
};
const node = (name: string, shape: V.TypeShape): V.TypeNode => ({ reference: ref(name), shape, description: null, attributes: [], extensions: [] });
const arrayNode = node("list", { tag: "Array", value: { item: { type_ref: ref("list"), nullable: false }, min_length: null, max_length: null } });
const productNode = node("node", {
  tag: "Product",
  value: { fields: [{ wire_name: "child", slot: { type_ref: ref("node"), required: false, nullable: false }, origin: { source, pointer: [] } }], extras: { tag: "Reject" } },
});
const unknownNode = node("any", { tag: "Unknown", value: { tag: "Any" } });

const nestedArrays = (depth: number): string => "[".repeat(depth) + "]".repeat(depth);
const nestedObjects = (depth: number): string => '{"child":'.repeat(depth) + "{}" + "}".repeat(depth);

function accepted(result: V.Validation<V.ValidatedValue>): void {
  if (result.tag !== "Ok") throw new Error(`expected acceptance: ${JSON.stringify(result.tag)}`);
}

it("reads nested arrays with their size at shallow and deep depth", () => {
  for (const depth of [SHALLOW, DEEP]) expect(V.jsonSize(V.boundedParseExact(nestedArrays(depth)))).toBe(depth);
});

it("reads nested objects with their size at shallow and deep depth", () => {
  for (const depth of [SHALLOW, DEEP]) expect(V.jsonSize(V.boundedParseExact(nestedObjects(depth)))).toBe(depth + 1);
});

it("parses nested values through the unbounded parser at shallow and deep depth", () => {
  for (const depth of [SHALLOW, DEEP]) expect(V.jsonSize(V.parseExact(nestedArrays(depth)))).toBe(depth);
});

it("encodes nested values back to their text at shallow and deep depth", () => {
  for (const depth of [SHALLOW, DEEP]) {
    expect(V.encodeExact(V.boundedParseExact(nestedArrays(depth)))).toBe(nestedArrays(depth));
    expect(V.encodeExact(V.boundedParseExact(nestedObjects(depth)))).toBe(nestedObjects(depth));
  }
});

it("accepts nested arrays by a recursive array type at shallow and deep depth", () => {
  const context = new V.ValueContext({ profile, nodes: [arrayNode] });
  for (const depth of [SHALLOW, DEEP]) accepted(V.validateValue(context, ref("list"), V.boundedParseExact(nestedArrays(depth))));
});

it("accepts nested objects by a recursive product type at shallow and deep depth", () => {
  const context = new V.ValueContext({ profile, nodes: [productNode] });
  for (const depth of [SHALLOW, DEEP]) accepted(V.validateValue(context, ref("node"), V.boundedParseExact(nestedObjects(depth))));
});

it("accepts nested values by an unknown type at shallow and deep depth", () => {
  const context = new V.ValueContext({ profile, nodes: [unknownNode] });
  for (const depth of [SHALLOW, DEEP]) {
    accepted(V.validateValue(context, ref("any"), V.boundedParseExact(nestedArrays(depth))));
    accepted(V.validateValue(context, ref("any"), V.boundedParseExact(nestedObjects(depth))));
  }
});

it("keeps the size of nested arrays when defaults are materialized at shallow and deep depth", () => {
  const context = new V.ValueContext({ profile, nodes: [arrayNode] });
  for (const depth of [SHALLOW, DEEP]) {
    const defaulted = context.materializeDefaults(ref("list"), V.boundedParseExact(nestedArrays(depth)));
    expect(defaulted.applications).toEqual([]);
    expect(V.jsonSize(defaulted.value)).toBe(depth);
  }
});
