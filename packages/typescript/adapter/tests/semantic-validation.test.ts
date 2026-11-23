// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import type * as C from "../src/semantic_composition.js";
import * as V from "../src/semantic_values.js";
import { acceptedValue, validationFailure, valueFailure } from "./validation-support.js";

const digest = "c".repeat(64);
const profileReference: V.ProfileRef = { identity: "validation", revision: "1", content_digest: digest };
const source: V.SourceRef = { repository: "validation", revision: "1", path: "validation", content_digest: digest, document_id: "" };
const ref = (name: string): V.TypeRef => ({ source, definition_name: name, pointer: [] });
const stringSpec = (overrides: Partial<V.StringSpec> = {}): V.StringSpec => ({ format: null, lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null, ...overrides });
const integerSpec = (overrides: Partial<V.IntegerSpec> = {}): V.IntegerSpec => ({ domain: "default", minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null, ...overrides });
const profile: V.VersionedSemanticProfile = {
  reference: profileReference,
  source_refs: [],
  integer_domains: [{ name: "default", reference: profileReference, range: { tag: "Inclusive", fields: { minimum: "-100", maximum: "100" } }, forms: [{ tag: "Number" }, { tag: "IntegralDecimal" }, { tag: "DecimalString" }] }],
  default_integer_domain: "default",
  numbers: { decimals: true },
  grapheme_rules: null,
  format_bindings: [{ name: "not-x", reference: profileReference, rule: { tag: "Not", value: { tag: "Literal", value: "x" } } }],
  bytes_policy: { reference: profileReference, padding_optional: true, alphabet: { tag: "Standard" }, strict_pad_bits: true, wrapper: null },
  wrappers: [{ name: "text-wrapper", key: "text", payload: { tag: "Text", value: null } }],
  tag: {
    key: "tag", format: null,
    sealed: [
      { tag: "sealed", fields: [{ key: "label", required: true, leaf: { tag: "String", value: stringSpec() } }, { key: "n", required: false, leaf: { tag: "Integer", value: integerSpec() } }], extras: { tag: "Reject" } },
      { tag: "other", fields: [], extras: { tag: "Any" } },
    ],
  },
};
const node = (name: string, shape: V.TypeShape): V.TypeNode => ({ reference: ref(name), shape, description: null, attributes: [], extensions: [] });
const field = (name: string, type: string, required = true, nullable = false): V.FieldSpec => ({ wire_name: name, slot: { type_ref: ref(type), required, nullable }, origin: { source, pointer: [] } });
const decimalBound = (mantissa: string, exclusive: boolean): V.DecimalBound => ({ mantissa, scale: "0", exclusive });
const nodes: readonly V.TypeNode[] = [
  node("string", { tag: "String", value: stringSpec() }),
  node("boolean-const", { tag: "Boolean", value: { const_value: true, default_value: null } }),
  node("integer", { tag: "Integer", value: integerSpec() }),
  node("integer-const", { tag: "Integer", value: integerSpec({ const_value: "3" }) }),
  node("integer-enum", { tag: "Integer", value: integerSpec({ enum_values: ["1", "2"] }) }),
  node("integer-range", { tag: "Integer", value: integerSpec({ minimum: "0", maximum: "10" }) }),
  node("decimal", { tag: "Decimal", value: { minimum: decimalBound("10", false), maximum: decimalBound("100", true) } }),
  node("decimal-empty", { tag: "Decimal", value: { minimum: decimalBound("10", false), maximum: decimalBound("10", true) } }),
  node("string-const", { tag: "String", value: stringSpec({ const_value: "a" }) }),
  node("string-enum", { tag: "String", value: stringSpec({ enum_values: ["a", "b"] }) }),
  node("string-length", { tag: "String", value: stringSpec({ lengths: [{ unit: { tag: "UnicodeScalars" }, minimum: null, maximum: "1" }] }) }),
  node("string-format", { tag: "String", value: stringSpec({ format: { tag: "Named", value: "not-x" } }) }),
  node("bytes", { tag: "Bytes", value: { minimum: "1", maximum: "2" } }),
  node("raw-body", { tag: "RawBody", fields: { encoding: "bytes" } }),
  node("product", { tag: "Product", value: { fields: [field("a", "string"), field("b", "string", false, false)], extras: { tag: "Reject" } } }),
  node("array", { tag: "Array", value: { item: { type_ref: ref("string"), nullable: false }, min_length: "1", max_length: "2" } }),
  node("alias-a", { tag: "Alias", fields: { target: ref("alias-b"), reference_text: "alias-b" } }),
  node("alias-b", { tag: "Alias", fields: { target: ref("alias-a"), reference_text: "alias-a" } }),
  node("alias-string", { tag: "Alias", fields: { target: ref("string"), reference_text: "string" } }),
  node("union", { tag: "TaggedUnion", value: { branches: [{ target: ref("string"), wire_tag: "text", selector: { tag: "Kind", value: { tag: "String" } }, origin: { source, pointer: [] } }] } }),
  node("sealed", { tag: "Sealed", fields: { tag: "sealed", refinements: [{ key: "n", leaf: { tag: "Integer", value: integerSpec({ maximum: "5" }) } }] } }),
  node("never", { tag: "Never" }),
  node("unit", { tag: "Unit" }),
  node("ordinary", { tag: "Unknown", value: { tag: "OrdinaryObject" } }),
  node("opaque", { tag: "Opaque", fields: { type_name: "external" } }),
];
const context = new V.ValueContext({ profile, nodes });
const text = (value: string): V.ExactJson => ({ tag: "String", value });
const integer = (value: string): V.ExactJson => ({ tag: "Integer", value });
const object = (...members: readonly (readonly [string, V.ExactJson])[]): V.ExactJson => ({ tag: "Object", members: members.map(([key, value]) => ({ key, value })) });
const condition = (type: string, value: V.ExactJson): V.ValueCondition => valueFailure(context, ref(type), value).condition;

it("rejects each shape with the Lean expansion conditions", () => {
  const cases: readonly (readonly [string, V.ExactJson, V.ValueCondition])[] = [
    ["boolean-const", { tag: "Bool", value: false }, { tag: "ConstMismatch" }],
    ["boolean-const", text("x"), { tag: "WrongValueKind", value: "boolean" }],
    ["integer", text("x"), { tag: "WrongValueKind", value: "integer" }],
    ["integer", integer("101"), { tag: "IntegerDomain" }],
    ["integer-const", integer("4"), { tag: "ConstMismatch" }],
    ["integer-enum", integer("3"), { tag: "EnumMismatch" }],
    ["integer-range", integer("-1"), { tag: "BelowMinimum" }],
    ["integer-range", integer("11"), { tag: "AboveMaximum" }],
    ["decimal", text("1"), { tag: "WrongValueKind", value: "decimal" }],
    ["string", integer("1"), { tag: "WrongValueKind", value: "string" }],
    ["string", text("\ud800"), { tag: "InvalidDataModel" }],
    ["string-const", text("b"), { tag: "ConstMismatch" }],
    ["string-enum", text("c"), { tag: "EnumMismatch" }],
    ["string-length", text("ab"), { tag: "StringLength" }],
    ["string-format", text("x"), { tag: "Format", value: "not-x" }],
    ["bytes", text("?"), { tag: "InvalidBytes" }],
    ["bytes", text("AAAAAA=="), { tag: "BytesLength" }],
    ["raw-body", text("?"), { tag: "InvalidBytes" }],
    ["product", text("x"), { tag: "WrongValueKind", value: "object" }],
    ["product", object(["text", text("x")]), { tag: "WrongValueKind", value: "plain data object" }],
    ["product", object(["b", text("x")]), { tag: "MissingRequired" }],
    ["product", object(["a", { tag: "Null" }]), { tag: "NullNotAllowed" }],
    ["product", object(["a", text("x")], ["c", text("y")]), { tag: "UnexpectedField", value: "c" }],
    ["array", text("x"), { tag: "WrongValueKind", value: "array" }],
    ["array", { tag: "Array", items: [] }, { tag: "ArrayLength" }],
    ["union", integer("1"), { tag: "NoBranchSelected" }],
    ["union", object(["tag", integer("1")]), { tag: "InvalidTag" }],
    ["sealed", text("x"), { tag: "WrongValueKind", value: "sealed object" }],
    ["sealed", object(["a", text("x")]), { tag: "WrongValueKind", value: "sealed object" }],
    ["sealed", object(["tag", text("other")]), { tag: "InvalidDataModel" }],
    ["sealed", object(["tag", text("sealed")]), { tag: "MissingRequired" }],
    ["sealed", object(["tag", text("sealed")], ["label", text("x")], ["n", integer("6")]), { tag: "AboveMaximum" }],
    ["never", { tag: "Null" }, { tag: "InvalidDataModel" }],
    ["unit", integer("1"), { tag: "WrongValueKind", value: "unit" }],
    ["ordinary", text("x"), { tag: "WrongValueKind", value: "ordinary object" }],
    ["ordinary", object(["tag", text("other")]), { tag: "WrongValueKind", value: "ordinary object" }],
  ];
  for (const [type, value, expected] of cases) expect(condition(type, value), `${type} ${JSON.stringify(value)}`).toEqual(expected);
});

it("compares decimal bounds by their mathematical value", () => {
  const expected: readonly (readonly [string, string])[] = [
    ["0.001", "BelowMinimum"], ["5", "BelowMinimum"], ["10", "none"], ["50", "none"], ["100", "AboveMaximum"], ["1000", "AboveMaximum"], ["1e3", "AboveMaximum"],
    ["abc", "InvalidDataModel"], ["0", "BelowMinimum"], ["-3", "BelowMinimum"], ["0.5", "BelowMinimum"], ["1", "BelowMinimum"], ["9", "BelowMinimum"], ["11", "none"],
    ["99", "none"], ["0.99", "BelowMinimum"], ["0.1", "BelowMinimum"], ["0.01", "BelowMinimum"], ["1.0e1", "none"], ["99.99", "none"], ["100.0", "AboveMaximum"], ["9.99", "BelowMinimum"],
  ];
  for (const [number, tag] of expected) {
    const result = V.validateValue(context, ref("decimal"), { tag: "Decimal", text: number });
    expect(result.tag === "Ok" ? "none" : result.failure.tag === "Value" ? result.failure.failure.condition.tag : result.failure.tag, number).toBe(tag);
  }
});

it("checks the maximum after an inclusive minimum equal to the value", () => {
  expect(condition("decimal-empty", { tag: "Decimal", text: "10" })).toEqual({ tag: "AboveMaximum" });
});

it("applies the data check of a sealed form to the members of a sealed shape", () => {
  const extra = object(["tag", text("sealed")], ["label", text("x")], ["extra", integer("1")]);
  expect(valueFailure(context, ref("sealed"), extra)).toMatchObject({ condition: { tag: "UnexpectedField", value: "extra" }, path: ["extra"] });
  const open = object(["tag", text("other")]);
  expect(condition("sealed", open)).toEqual({ tag: "InvalidDataModel" });
});

it("reports an unknown sealed tag for a sealed type when the profile declares no tag model", () => {
  const untagged = new V.ValueContext({ profile: { ...profile, tag: null }, nodes });
  expect(validationFailure(untagged, ref("sealed"), object(["label", text("x")]))).toMatchObject({ tag: "Unresolved", obligations: [{ reason: { tag: "UnknownSealedTag", value: "sealed" } }] });
});

it("rejects a sealed object as a wrong kind in the expansion when the profile declares no tag model", () => {
  const untagged = new V.ValueContext({ profile: { ...profile, tag: null }, nodes });
  expect(V.expandValue(untagged, ref("sealed"), [], object(["label", text("x")]))).toMatchObject({ tag: "Rejected", failure: { condition: { tag: "WrongValueKind", value: "sealed object" } } });
});

it("reports the location of each rejection", () => {
  expect(valueFailure(context, ref("product"), object(["a", text("x")], ["c", text("y")]))).toMatchObject({ path: ["c"], observed: { tag: "Present", value: text("y") } });
  expect(valueFailure(context, ref("product"), object(["b", text("x")]))).toMatchObject({ path: ["a"], observed: { tag: "Absent" }, type: ref("string") });
  expect(valueFailure(context, ref("product"), object(["a", integer("1")]))).toMatchObject({ path: ["a"], referenceTrace: [ref("product")] });
  expect(valueFailure(context, ref("array"), { tag: "Array", items: [text("x"), integer("1")] })).toMatchObject({ path: [1n], condition: { tag: "WrongValueKind", value: "string" } });
  expect(valueFailure(context, ref("sealed"), object(["tag", text("sealed")], ["label", text("x")], ["n", integer("6")]))).toMatchObject({ path: ["n"] });
  expect(valueFailure(context, ref("sealed"), object(["tag", text("sealed")], ["label", integer("1")]))).toMatchObject({ path: ["label"], condition: { tag: "WrongValueKind", value: "string" } });
});

it("follows aliases and rejects a reference cycle with its trace", () => {
  expect(acceptedValue(context, ref("alias-string"), text("x"))).toEqual(text("x"));
  expect(valueFailure(context, ref("alias-a"), { tag: "Null" })).toMatchObject({ condition: { tag: "ReferenceCycle" }, type: ref("alias-a"), referenceTrace: [ref("alias-b"), ref("alias-a")] });
});

it("leaves an opaque or undeclared type unresolved", () => {
  expect(V.expandValue(context, ref("opaque"), [], { tag: "Null" })).toMatchObject({ tag: "Unresolved", obligations: [{ reason: { tag: "OpaqueType", value: "external" } }] });
  expect(V.expandValue(context, ref("missing"), [], { tag: "Null" })).toMatchObject({ tag: "Unresolved", obligations: [{ reason: { tag: "UnresolvedType" } }] });
  expect(validationFailure(context, ref("opaque"), { tag: "Null" })).toMatchObject({ tag: "Unresolved", obligations: [{ reason: { tag: "OpaqueType" } }] });
  expect(V.acceptsValue(context, ref("opaque"), { tag: "Null" })).toMatchObject({ tag: "Unresolved" });
});

it("checks a membership proof against the recomputed children", () => {
  const value: V.ExactJson = { tag: "Array", items: [text("a"), text("b")] };
  const checked = V.validateValue(context, ref("array"), value);
  if (checked.tag === "Failed") throw new Error(JSON.stringify(checked.failure));
  expect(checked.value.proof.children).toHaveLength(2);
  expect(V.validateValue(context, ref("array"), value, checked.value.proof)).toEqual(checked);
  const extra: V.MemberProof = { children: [...checked.value.proof.children, { children: [] }] };
  expect(V.validateValue(context, ref("array"), value, extra)).toEqual({ tag: "Failed", failure: { tag: "CertificateMismatch", condition: "extra membership children" } });
  const missing: V.MemberProof = { children: checked.value.proof.children.slice(0, 1) };
  expect(V.validateValue(context, ref("array"), value, missing)).toEqual({ tag: "Failed", failure: { tag: "CertificateMismatch", condition: "missing membership children" } });
  const nested: V.MemberProof = { children: [{ children: [{ children: [] }] }, checked.value.proof.children[1]!] };
  expect(V.validateValue(context, ref("array"), value, nested)).toEqual({ tag: "Failed", failure: { tag: "CertificateMismatch", condition: "extra membership children" } });
});

it("validates slots and decides acceptance from the validation result", () => {
  const required: V.SlotContract = { type_ref: ref("string"), required: true, nullable: false };
  const optional: V.SlotContract = { ...required, required: false, nullable: true };
  expect(V.validateSlot(context, required, { tag: "Absent" })).toMatchObject({ tag: "Failed", failure: { tag: "Value", failure: { condition: { tag: "MissingRequired" }, observed: { tag: "Absent" }, path: [] } } });
  expect(V.validateSlot(context, required, { tag: "Null" })).toMatchObject({ tag: "Failed", failure: { tag: "Value", failure: { condition: { tag: "NullNotAllowed" }, observed: { tag: "Null" } } } });
  expect(V.validateSlot(context, optional, { tag: "Absent" })).toMatchObject({ tag: "Ok", value: { certificate: { proof: null, contract: optional, source_refs: [], profile: profileReference } } });
  expect(V.validateSlot(context, optional, { tag: "Null" })).toMatchObject({ tag: "Ok", value: { certificate: { proof: null } } });
  expect(V.validateSlot(context, required, { tag: "Present", value: text("x") })).toMatchObject({ tag: "Ok", value: { certificate: { proof: { children: [] }, value: { tag: "Present", value: text("x") } } } });
  expect(V.validateSlot(context, { ...required, type_ref: ref("opaque") }, { tag: "Null" })).toMatchObject({ tag: "Failed", failure: { tag: "Unresolved" } });
  expect(V.acceptsSlot(context, required, { tag: "Present", value: text("x") })).toEqual({ tag: "Accepted" });
  expect(V.acceptsSlot(context, required, { tag: "Absent" })).toMatchObject({ tag: "Rejected", failure: { condition: { tag: "MissingRequired" } } });
  expect(V.acceptsValue(context, ref("string"), integer("1"))).toMatchObject({ tag: "Rejected", failure: { condition: { tag: "WrongValueKind", value: "string" } } });
  expect(V.acceptsValue(context, ref("string"), text("x"))).toEqual({ tag: "Accepted" });
});

it("accepts a grandfathered language tag in the spelling of the list, in lower case, and in upper case", () => {
  const rule: V.FormatRule = { tag: "LanguageTag", fields: { grandfathered: ["i-Klingon", "Sgn-BE-FR"] } };
  for (const entry of ["i-Klingon", "i-klingon", "I-KLINGON", "Sgn-BE-FR", "sgn-be-fr", "SGN-BE-FR"]) expect(V.recognizeFormat(rule, entry, null), entry).toBe(true);
  expect(V.recognizeFormat(rule, "i-other", null)).toBe(false);
  expect(V.recognizeFormat({ tag: "LanguageTag", fields: { grandfathered: [] } }, "i-Klingon", null)).toBe(false);
});
