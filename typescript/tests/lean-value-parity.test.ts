// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as V from "../src/semantic_values.js";

const digest = "a".repeat(64);
const profileReference: V.ProfileRef = { identity: "representative-declarations", revision: "4", content_digest: digest };
const source: V.SourceRef = { repository: "representative", revision: "4", path: "representative", content_digest: digest, document_id: "" };
const ref = (name: string): V.TypeRef => ({ source, definition_name: name, pointer: [] });
const stringSpec = (format: V.FormatUse | null = null, wrapper: string | null = null): V.StringSpec => ({
  format, lengths: [], wrapper, const_value: null, enum_values: null, examples: [], default_value: null,
});
const integerSpec: V.IntegerSpec = { domain: "default", minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null };
const profile: V.VersionedSemanticProfile = {
  reference: profileReference,
  source_refs: [],
  integer_domains: [{
    name: "default", reference: profileReference,
    range: { tag: "Inclusive", fields: { minimum: "-100", maximum: "100" } },
    forms: [{ tag: "Number" }, { tag: "IntegralDecimal" }, { tag: "DecimalString" }],
  }],
  default_integer_domain: "default",
  numbers: { decimals: true },
  grapheme_rules: null,
  format_bindings: [
    { name: "text", reference: profileReference, rule: { tag: "Text" } },
    { name: "not-x", reference: profileReference, rule: { tag: "Not", value: { tag: "Literal", value: "x" } } },
  ],
  bytes_policy: { reference: profileReference, padding_optional: true, alphabet: { tag: "Either" }, strict_pad_bits: true, wrapper: "bytes" },
  wrappers: [
    { name: "text-wrapper", key: "text", payload: { tag: "Text", value: null } },
    { name: "bytes", key: "bytes", payload: { tag: "Bytes" } },
  ],
  tag: {
    key: "tag", format: "text",
    sealed: [{ tag: "sealed", fields: [{ key: "label", required: true, leaf: { tag: "String", value: stringSpec() } }], extras: { tag: "Reject" } }],
  },
};
const node = (name: string, shape: V.TypeShape): V.TypeNode => ({ reference: ref(name), shape, description: null, attributes: [], extensions: [] });
const nodes: readonly V.TypeNode[] = [
  node("not-x", { tag: "String", value: stringSpec({ tag: "Named", value: "not-x" }) }),
  node("wrapped-text", { tag: "String", value: { ...stringSpec({ tag: "Named", value: "not-x" }, "text-wrapper"), lengths: [{ unit: { tag: "UnicodeScalars" }, minimum: null, maximum: "1" }] } }),
  node("sealed", { tag: "Sealed", fields: { tag: "sealed", refinements: [] } }),
  node("ordinary", { tag: "Product", value: { fields: [], extras: { tag: "Reject" } } }),
  node("string", { tag: "String", value: stringSpec() }),
  node("unknown-any", { tag: "Unknown", value: { tag: "Any" } }),
  node("string-array-nullable", { tag: "Array", value: { item: { type_ref: ref("string"), nullable: true }, min_length: null, max_length: null } }),
  node("string-array-required", { tag: "Array", value: { item: { type_ref: ref("string"), nullable: false }, min_length: null, max_length: null } }),
  node("unknown-array-required", { tag: "Array", value: { item: { type_ref: ref("unknown-any"), nullable: false }, min_length: null, max_length: null } }),
  node("unknown-map-required", { tag: "Product", value: { fields: [], extras: { tag: "Allow", fields: { key_format: null, value: { type_ref: ref("unknown-any"), nullable: false } } } } }),
  node("integer-map-required", { tag: "Product", value: { fields: [], extras: { tag: "Allow", fields: { key_format: null, value: { type_ref: ref("forms-integer"), nullable: false } } } } }),
  node("never", { tag: "Never" }),
  node("forms-integer", { tag: "Integer", value: integerSpec }),
  node("decimal", { tag: "Decimal", value: { minimum: null, maximum: null } }),
  node("bytes", { tag: "Bytes", value: { minimum: null, maximum: null } }),
];
const context = (valueProfile = profile): V.ValueContext => new V.ValueContext({ profile: valueProfile, nodes });
const rejected = (valueContext: V.ValueContext, type: string, value: V.ExactJson): V.ValueFailure => {
  try {
    valueContext.validate(ref(type), value);
  } catch (error) {
    if (error instanceof V.SemanticValueError) return error.failure;
    throw error;
  }
  throw new Error("expected rejection");
};

it("matches Lean conditions, paths, and payloads for representative rejected values", () => {
  const cases: readonly [string, V.ExactJson, string, readonly (string | bigint)[]][] = [
    ["not-x", { tag: "String", value: "x" }, "Format:not-x", []],
    ["wrapped-text", { tag: "Object", members: [{ key: "text", value: { tag: "String", value: "x" } }] }, "Format:not-x", []],
    ["sealed", { tag: "Object", members: [{ key: "label", value: { tag: "String", value: "x" } }, { key: "tag", value: { tag: "Integer", value: "1" } }] }, "InvalidTag", ["tag"]],
    ["ordinary", { tag: "Object", members: [{ key: "x", value: { tag: "Integer", value: "1" } }] }, "UnexpectedField:x", ["x"]],
    ["never", { tag: "Null" }, "InvalidDataModel", []],
    ["decimal", { tag: "String", value: "1.5" }, "WrongValueKind:decimal", []],
    ["bytes", { tag: "Object", members: [{ key: "bytes", value: { tag: "String", value: "?" } }] }, "InvalidBytes", []],
  ];
  for (const [type, value, condition, path] of cases) {
    expect(rejected(context(), type, value)).toMatchObject({ condition, path });
  }
  const standard = { ...profile, bytes_policy: { ...profile.bytes_policy!, alphabet: { tag: "Standard" } as const } };
  expect(rejected(context(standard), "bytes", { tag: "Object", members: [{ key: "bytes", value: { tag: "String", value: "-_8=" } }] })).toMatchObject({ condition: "InvalidBytes", path: [] });
});

it("decides element contract null from nullable or the child type", () => {
  const nullValue = { tag: "Null" } as const;
  const array = { tag: "Array", items: [nullValue] } as const;
  const map = { tag: "Object", members: [{ key: "x", value: nullValue }] } as const;
  expect(context().validate(ref("string-array-nullable"), array)).toEqual(array);
  expect(rejected(context(), "string-array-required", array)).toMatchObject({
    condition: "WrongValueKind:string",
    path: [0n],
    referenceTrace: [ref("string-array-required")],
  });
  expect(context().validate(ref("unknown-array-required"), array)).toEqual(array);
  expect(context().validate(ref("unknown-map-required"), map)).toEqual(map);
  expect(rejected(context(), "integer-map-required", map)).toMatchObject({
    condition: "WrongValueKind:integer",
    path: ["x"],
    referenceTrace: [ref("integer-map-required")],
  });
});

it("validates bytes with the profile alphabet, padding, and pad-bit policy", () => {
  const wrapped = (text: string): V.ExactJson => ({ tag: "Object", members: [{ key: "bytes", value: { tag: "String", value: text } }] });
  const withBytesPolicy = (alphabet: V.BytesAlphabet["tag"], strict_pad_bits = true, padding_optional = true): V.VersionedSemanticProfile => ({
    ...profile,
    bytes_policy: { ...profile.bytes_policy!, alphabet: { tag: alphabet }, strict_pad_bits, padding_optional },
  });
  const accepts = (alphabet: V.BytesAlphabet["tag"], text: string): void => {
    expect(context(withBytesPolicy(alphabet)).validate(ref("bytes"), wrapped(text))).toEqual(wrapped(text));
  };
  const rejects = (alphabet: V.BytesAlphabet["tag"], text: string): void => {
    expect(rejected(context(withBytesPolicy(alphabet)), "bytes", wrapped(text))).toMatchObject({ condition: "InvalidBytes", path: [] });
  };

  accepts("Standard", "+/8=");
  rejects("Standard", "-_8=");
  accepts("UrlSafe", "-_8=");
  rejects("UrlSafe", "+/8=");
  for (const text of ["+/8=", "-_8=", "+_8=", "-/8="]) accepts("Either", text);
  expect(rejected(context(withBytesPolicy("Standard", true, false)), "bytes", wrapped("+/8"))).toMatchObject({ condition: "InvalidBytes" });
  expect(context(withBytesPolicy("Standard", true, false)).validate(ref("bytes"), wrapped("+/8="))).toEqual(wrapped("+/8="));
  expect(rejected(context(withBytesPolicy("Standard", true)), "bytes", wrapped("AB=="))).toMatchObject({ condition: "InvalidBytes" });
  expect(context(withBytesPolicy("Standard", false)).validate(ref("bytes"), wrapped("AB=="))).toEqual(wrapped("AB=="));
});

it("accepts a wrapped string and applies its length to the payload", () => {
  const wrapped = (value: string): V.ExactJson => ({ tag: "Object", members: [{ key: "text", value: { tag: "String", value } }] });
  expect(context().validate(ref("wrapped-text"), wrapped("y"))).toEqual(wrapped("y"));
  expect(rejected(context(), "wrapped-text", wrapped("yz"))).toMatchObject({ condition: "StringLength", path: [] });
});

it("accepts the representative integral decimal form", () => {
  expect(context().validate(ref("forms-integer"), { tag: "Decimal", text: "10.0" })).toEqual({ tag: "Decimal", text: "10.0" });
});
