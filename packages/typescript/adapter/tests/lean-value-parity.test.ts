// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as V from "../src/semantic_values.js";
import { acceptedValue, valueFailure } from "./validation-support.js";

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
const rejected = (valueContext: V.ValueContext, type: string, value: V.ExactJson): V.ValueFailure => valueFailure(valueContext, ref(type), value);

it("matches Lean conditions, paths, and payloads for representative rejected values", () => {
  const cases: readonly [string, V.ExactJson, V.ValueCondition, readonly (string | bigint)[]][] = [
    ["not-x", { tag: "String", value: "x" }, { tag: "Format", value: "not-x" }, []],
    ["wrapped-text", { tag: "Object", members: [{ key: "text", value: { tag: "String", value: "x" } }] }, { tag: "Format", value: "not-x" }, []],
    ["sealed", { tag: "Object", members: [{ key: "label", value: { tag: "String", value: "x" } }, { key: "tag", value: { tag: "Integer", value: "1" } }] }, { tag: "InvalidTag" }, ["tag"]],
    ["ordinary", { tag: "Object", members: [{ key: "x", value: { tag: "Integer", value: "1" } }] }, { tag: "UnexpectedField", value: "x" }, ["x"]],
    ["never", { tag: "Null" }, { tag: "InvalidDataModel" }, []],
    ["decimal", { tag: "String", value: "1.5" }, { tag: "WrongValueKind", value: "decimal" }, []],
    ["bytes", { tag: "Object", members: [{ key: "bytes", value: { tag: "String", value: "?" } }] }, { tag: "InvalidBytes" }, []],
  ];
  for (const [type, value, condition, path] of cases) {
    expect(rejected(context(), type, value)).toMatchObject({ condition, path });
  }
  const standard = { ...profile, bytes_policy: { ...profile.bytes_policy!, alphabet: { tag: "Standard" } as const } };
  expect(rejected(context(standard), "bytes", { tag: "Object", members: [{ key: "bytes", value: { tag: "String", value: "-_8=" } }] })).toMatchObject({ condition: { tag: "InvalidBytes" }, path: [] });
});

it("preserves the condition payload and observed slot value", () => {
  const value = { tag: "Bool", value: true } as const;
  expect(rejected(context(), "string", value)).toMatchObject({
    condition: { tag: "WrongValueKind", value: "string" },
    observed: { tag: "Present", value },
  });
});

it("decides element contract null from nullable or the child type", () => {
  const nullValue = { tag: "Null" } as const;
  const array = { tag: "Array", items: [nullValue] } as const;
  const map = { tag: "Object", members: [{ key: "x", value: nullValue }] } as const;
  expect(acceptedValue(context(), ref("string-array-nullable"), array)).toEqual(array);
  expect(rejected(context(), "string-array-required", array)).toMatchObject({
    condition: { tag: "WrongValueKind", value: "string" },
    path: [0n],
    referenceTrace: [ref("string-array-required")],
  });
  expect(acceptedValue(context(), ref("unknown-array-required"), array)).toEqual(array);
  expect(acceptedValue(context(), ref("unknown-map-required"), map)).toEqual(map);
  expect(rejected(context(), "integer-map-required", map)).toMatchObject({
    condition: { tag: "WrongValueKind", value: "integer" },
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
    expect(acceptedValue(context(withBytesPolicy(alphabet)), ref("bytes"), wrapped(text))).toEqual(wrapped(text));
  };
  const rejects = (alphabet: V.BytesAlphabet["tag"], text: string): void => {
    expect(rejected(context(withBytesPolicy(alphabet)), "bytes", wrapped(text))).toMatchObject({ condition: { tag: "InvalidBytes" }, path: [] });
  };

  accepts("Standard", "+/8=");
  rejects("Standard", "-_8=");
  accepts("UrlSafe", "-_8=");
  rejects("UrlSafe", "+/8=");
  for (const text of ["+/8=", "-_8=", "+_8=", "-/8="]) accepts("Either", text);
  expect(rejected(context(withBytesPolicy("Standard", true, false)), "bytes", wrapped("+/8"))).toMatchObject({ condition: { tag: "InvalidBytes" } });
  expect(acceptedValue(context(withBytesPolicy("Standard", true, false)), ref("bytes"), wrapped("+/8="))).toEqual(wrapped("+/8="));
  expect(rejected(context(withBytesPolicy("Standard", true)), "bytes", wrapped("AB=="))).toMatchObject({ condition: { tag: "InvalidBytes" } });
  expect(acceptedValue(context(withBytesPolicy("Standard", false)), ref("bytes"), wrapped("AB=="))).toEqual(wrapped("AB=="));
});

it("accepts a wrapped string and applies its length to the payload", () => {
  const wrapped = (value: string): V.ExactJson => ({ tag: "Object", members: [{ key: "text", value: { tag: "String", value } }] });
  expect(acceptedValue(context(), ref("wrapped-text"), wrapped("y"))).toEqual(wrapped("y"));
  expect(rejected(context(), "wrapped-text", wrapped("yz"))).toMatchObject({ condition: { tag: "StringLength" }, path: [] });
});

it("accepts the representative integral decimal form", () => {
  expect(acceptedValue(context(), ref("forms-integer"), { tag: "Decimal", text: "10.0" })).toEqual({ tag: "Decimal", text: "10.0" });
});
it("prioritizes bounded IntegralDecimal values over general decimal admission", () => {
  const boundedProfile = {
    ...profile,
    integer_domains: [{
      ...profile.integer_domains[0]!,
      range: { tag: "Inclusive" as const, fields: { minimum: "-10", maximum: "10" } },
    }],
  };
  const enabled = context(boundedProfile);
  const disabled = context({ ...boundedProfile, numbers: { decimals: false } });
  expect(acceptedValue(enabled, ref("unknown-any"), { tag: "Decimal", text: "10.0" })).toEqual({ tag: "Decimal", text: "10.0" });
  expect(rejected(enabled, "unknown-any", { tag: "Decimal", text: "11.0" })).toMatchObject({ condition: { tag: "IntegerDomain" } });
  expect(rejected(disabled, "unknown-any", { tag: "Decimal", text: "11.0" })).toMatchObject({ condition: { tag: "IntegerDomain" } });
  expect(acceptedValue(enabled, ref("unknown-any"), { tag: "Decimal", text: "1.5" })).toEqual({ tag: "Decimal", text: "1.5" });
  expect(rejected(disabled, "unknown-any", { tag: "Decimal", text: "1.5" })).toMatchObject({ condition: { tag: "InvalidDataModel" } });
  expect(rejected(enabled, "unknown-any", { tag: "Decimal", text: "1e9999" })).toMatchObject({ condition: { tag: "IntegerDomain" } });
  expect(rejected(enabled, "unknown-any", { tag: "Decimal", text: "1e999999999" })).toMatchObject({ condition: { tag: "InvalidDataModel" } });
  const numberOnly = {
    ...boundedProfile,
    integer_domains: [{ ...boundedProfile.integer_domains[0]!, forms: [{ tag: "Number" as const }] }],
  };
  expect(acceptedValue(context(numberOnly), ref("unknown-any"), { tag: "Decimal", text: "11.0" })).toEqual({ tag: "Decimal", text: "11.0" });
  const decimal = { tag: "Decimal", text: "6.02e23" } as const;
  expect(acceptedValue(context(numberOnly), ref("unknown-array-required"), { tag: "Array", items: [decimal] })).toEqual({ tag: "Array", items: [decimal] });
  expect(acceptedValue(context(numberOnly), ref("unknown-map-required"), {
    tag: "Object",
    members: [{ key: "nested", value: { tag: "Array", items: [decimal] } }],
  })).toEqual({
    tag: "Object",
    members: [{ key: "nested", value: { tag: "Array", items: [decimal] } }],
  });
  expect(rejected(enabled, "unknown-any", { tag: "Decimal", text: "1." })).toMatchObject({ condition: { tag: "InvalidDataModel" } });
});

it("bounds the written exponent of an unbounded integral decimal at the reader limit", () => {
  const unbounded = context({
    ...profile,
    integer_domains: [{ ...profile.integer_domains[0]!, range: { tag: "Unbounded" }, forms: [{ tag: "Number" }, { tag: "IntegralDecimal" }] }],
  });
  expect(acceptedValue(unbounded, ref("unknown-any"), { tag: "Decimal", text: "1e9999" })).toEqual({ tag: "Decimal", text: "1e9999" });
  expect(rejected(unbounded, "unknown-any", { tag: "Decimal", text: "1e10000" })).toMatchObject({ condition: { tag: "InvalidDataModel" } });
  expect(rejected(unbounded, "forms-integer", { tag: "Decimal", text: "1e10000" })).toMatchObject({ condition: { tag: "WrongValueKind", value: "integer" } });
  expect(rejected(unbounded, "forms-integer", { tag: "Decimal", text: "1e1000000000" })).toMatchObject({ condition: { tag: "WrongValueKind", value: "integer" } });
});

it("accepts a zero decimal in a decimal field on the wire path and on the text path", () => {
  for (const text of ["0.0", "0e-100", "0.000e-100", "-0.0"]) {
    expect(acceptedValue(context(), ref("decimal"), { tag: "Decimal", text })).toEqual({ tag: "Decimal", text });
    expect(acceptedValue(context(), ref("decimal"), V.parseExact(text))).toEqual({ tag: "Decimal", text: "0" });
  }
  expect(rejected(context(), "decimal", V.parseExact("0e11"))).toMatchObject({ condition: { tag: "WrongValueKind", value: "decimal" } });
});

it("materializes an integer-valued decimal read from text in the Lean canonical text and writes it with its .0", () => {
  expect(context().decodeWithDefaults(ref("decimal"), "10.0").value).toEqual({ tag: "Decimal", text: "10" });
  expect(context().decodeWithDefaults(ref("decimal"), "-7.0").value).toEqual({ tag: "Decimal", text: "-7" });
  expect(context().decodeWithDefaults(ref("decimal"), "1.0").value).toEqual({ tag: "Decimal", text: "1" });
  expect(V.encodeExact(context().decodeWithDefaults(ref("decimal"), "10.0").value)).toBe("10.0");
  expect(V.encodeExact(context().decodeWithDefaults(ref("decimal"), "-7.0").value)).toBe("-7.0");
  expect(V.encodeExact(context().decodeWithDefaults(ref("decimal"), "1.0").value)).toBe("1.0");
});

it("keeps the spelling of a tagged decimal in the materialized value and compares a wire text with it by numberText", () => {
  expect(context().materializeDefaults(ref("decimal"), { tag: "Decimal", text: "10.0" }).value).toEqual({ tag: "Decimal", text: "10.0" });
  expect(context().materializeDefaults(ref("decimal"), { tag: "Decimal", text: "0e-100" }).value).toEqual({ tag: "Decimal", text: "0e-100" });
  expect(V.encodeExact(V.parseExact("10.0"))).toBe(V.encodeExact({ tag: "Decimal", text: "10.0" }));
  expect(V.encodeExact(V.parseExact("0.0"))).toBe(V.encodeExact({ tag: "Decimal", text: "0" }));
});

it("sorts the members of a wire object by key and reports the first failing extra member of an exact object in document order", () => {
  expect(V.boundedParseExact('{"ten":10.0,"one":1.0,"two":2.5}')).toEqual({ tag: "Object", members: [
    { key: "one", value: { tag: "Decimal", text: "1" } },
    { key: "ten", value: { tag: "Decimal", text: "10" } },
    { key: "two", value: { tag: "Decimal", text: "2.5" } },
  ] });
  const strings = (keys: string[]): V.ExactJson => ({ tag: "Object", members: keys.map(key => ({ key, value: { tag: "String", value: "x" } })) });
  expect(valueFailure(context(), ref("integer-map-required"), strings(["b", "a"])).path).toEqual(["b"]);
  expect(valueFailure(context(), ref("integer-map-required"), V.boundedParseExact('{"b":"x","a":"x"}')).path).toEqual(["a"]);
});

it("rejects an extra member of a sealed object through the shape and the data check", () => {
  const object: V.ExactJson = { tag: "Object", members: [
    { key: "tag", value: { tag: "String", value: "sealed" } }, { key: "label", value: { tag: "String", value: "x" } }, { key: "extra", value: { tag: "Integer", value: "1" } },
  ] };
  expect(rejected(context(), "sealed", object)).toMatchObject({ condition: { tag: "UnexpectedField", value: "extra" }, path: ["extra"] });
  expect(rejected(context(), "unknown-any", object)).toMatchObject({ condition: { tag: "UnexpectedField", value: "extra" }, path: ["extra"] });
});
