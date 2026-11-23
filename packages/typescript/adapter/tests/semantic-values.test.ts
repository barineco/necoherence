// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { execFileSync } from "node:child_process";
import { expect, it } from "vitest";
import * as S from "../src/semantic_values.js";
import { profile, source } from "./semantic-fixture.js";
import { validationFailure } from "./validation-support.js";

it("normalizes a raw decimal as the Lean fromJson does and keeps the spelling of a tagged decimal", () => {
  const wire = '{"10":9007199254740993,"2":-123456789012345678901234567890,"fraction":1.2300e+99}';
  const normalized = `{"10":9007199254740993,"2":-123456789012345678901234567890,"fraction":123${"0".repeat(97)}}`;
  const exact = S.parseExact(wire);
  expect(exact.tag).toBe("Object");
  if (exact.tag !== "Object") throw new Error("object required");
  expect(exact.members.map(m => m.key)).toEqual(["10", "2", "fraction"]);
  expect(S.encodeExact(exact)).toBe(normalized);
  expect(S.encodeExact(S.toExact(S.fromExact(exact)))).toBe(normalized);
  expect(S.parseExact("1.2300e+99")).toEqual({ tag: "Integer", value: `123${"0".repeat(97)}` });
  expect(S.toExact(S.fromExact({ tag: "Decimal", text: "12" }))).toEqual({ tag: "Decimal", text: "12" });
  expect(S.toExact(S.fromExact({ tag: "Decimal", text: "1.2300e+99" }))).toEqual({ tag: "Decimal", text: "1.2300e+99" });
});

it("rejects ambiguous JSON syntax and non-JSON values before semantic validation", () => {
  for (const wire of ['{"a":1,"a":2}', '{"a":1,}', '{/*x*/"a":1}']) expect(() => S.parseExact(wire)).toThrow(S.SemanticEvidenceError);
  type Recursive = { self?: Recursive };
  const cycle: Recursive = {};
  cycle.self = cycle;
  for (const value of [cycle, new Date(), 9007199254740992]) expect(() => S.toExact(value)).toThrow(S.SemanticEvidenceError);
  const standard: S.BytesPolicy = { reference: { identity: "test", revision: "1", content_digest: "a" }, padding_optional: true, alphabet: { tag: "Standard" }, strict_pad_bits: true, wrapper: null };
  expect(S.base64Encode(Uint8Array.from([0, 255, 128]), standard)).toBe("AP+A");
  expect(S.base64Decode("AP+A", standard)).toEqual(Uint8Array.from([0, 255, 128]));
  expect(S.base64Decode("AB", standard)).toBeNull();
});

it("applies the bytes policy to base64 decoding and encoding", () => {
  const reference: S.ProfileRef = { identity: "test", revision: "1", content_digest: "a" };
  const policy = (alphabet: S.BytesAlphabet["tag"], strict_pad_bits = true, padding_optional = true): S.BytesPolicy => ({
    reference, alphabet: { tag: alphabet }, strict_pad_bits, padding_optional, wrapper: null,
  });
  const bytes = Uint8Array.from([251, 255]);
  const standard = policy("Standard"), urlSafe = policy("UrlSafe"), either = policy("Either");

  expect(S.base64Encode(bytes, standard)).toBe("+/8=");
  expect(S.base64Encode(bytes, urlSafe)).toBe("-_8=");
  expect(S.base64Encode(bytes, either)).toBe("+/8=");
  expect(S.base64Decode("+/8=", standard)).toEqual(bytes);
  expect(S.base64Decode("-_8=", standard)).toBeNull();
  expect(S.base64Decode("-_8=", urlSafe)).toEqual(bytes);
  expect(S.base64Decode("+/8=", urlSafe)).toBeNull();
  for (const text of ["+/8=", "-_8=", "+_8=", "-/8="]) expect(S.base64Decode(text, either)).not.toBeNull();

  expect(S.base64Decode("+/8", policy("Standard", true, false))).toBeNull();
  expect(S.base64Decode("+/8=", policy("Standard", true, false))).toEqual(bytes);
  expect(S.base64Decode("AB==", policy("Standard", true))).toBeNull();
  expect(S.base64Decode("AB==", policy("Standard", false))).toEqual(Uint8Array.from([0]));
});

it("executes value-profile format recognizers independently of declaration readers", () => {
  expect(() => execFileSync(process.execPath, ["--input-type=module", "-e", 'import { checkFormats } from "./tests/semantic-formats.mjs"; checkFormats();'], { encoding: "utf8" })).not.toThrow();
});

it("materializes ordered defaults with resolved provenance and immutable idempotence", () => {
  const ref = (name: string): S.TypeRef => ({ source, definition_name: name, pointer: [name] });
  const node = (name: string, shape: S.TypeShape): S.TypeNode => ({ reference: ref(name), shape, description: null, attributes: [], extensions: [] });
  const graph: S.ValueGraph = { profile, nodes: [
    node("flag", { tag: "Boolean", value: { const_value: null, default_value: false } }),
    node("integer", { tag: "Integer", value: { domain: null, minimum: null, maximum: null, const_value: null, enum_values: null, default_value: "9007199254740993123456789" } }),
    node("alias", { tag: "Alias", fields: { target: ref("integer"), reference_text: "integer" } }),
    node("object", { tag: "Product", value: { fields: ["flag", "alias"].map(name => ({ wire_name: name, slot: { type_ref: ref(name), required: true, nullable: false }, origin: { source, pointer: [] } })), extras: { tag: "Reject" } } }),
  ] };
  const context = new S.ValueContext(graph), before = S.parseExact("{}");
  expect(validationFailure(context, ref("object"), before)).toMatchObject({ tag: "Value" });
  const defaulted = context.decodeWithDefaults(ref("object"), "{}");
  expect(S.encodeExact(defaulted.value)).toBe('{"flag":false,"alias":9007199254740993123456789}');
  expect(defaulted.applications.map(application => application.type_ref.definition_name)).toEqual(["flag", "integer"]);
  expect(defaulted.applications[1]!.origin.pointer).toEqual(["integer", "default"]);
  expect(S.encodeExact(before)).toBe("{}");
  expect(Object.isFrozen(before)).toBe(false);
  expect(Object.isFrozen(defaulted.value)).toBe(true);
  const second = context.materializeDefaults(ref("object"), defaulted.value);
  expect(second.value).toEqual(defaulted.value);
  expect(second.applications).toEqual([]);
  const forged = defaulted.applications.map(application => ({ ...application, origin: { source, pointer: [] } }));
  expect(S.checkDefaultApplications(context, before, defaulted.value, forged)).toBe(false);
  const invalid = structuredClone(graph);
  const number = invalid.nodes.find(node => node.shape.tag === "Integer")!;
  if (number.shape.tag !== "Integer") throw new Error("integer");
  Object.assign(number.shape.value, { minimum: "1", default_value: "0" });
  try { new S.ValueContext(invalid).decodeWithDefaults(ref("object"), '{"flag":"invalid"}'); throw new Error("expected failure"); }
  catch (error) { expect(error).toBeInstanceOf(S.SemanticValueError); if (!(error instanceof S.SemanticValueError)) throw error; expect(error.failure.type).toEqual(ref("integer")); expect(error.failure.path).toEqual([]); expect(error.failure.condition).toEqual({ tag: "BelowMinimum" }); }
});

it("admits reachable meaning with unresolved semantic evidence before defaults and final validation", () => {
  const ref = (name: string): S.TypeRef => ({ source, definition_name: name, pointer: [name] });
  const node = (name: string, shape: S.TypeShape): S.TypeNode => ({ reference: ref(name), shape, description: null, attributes: [], extensions: [] });
  const product = (target: string): S.TypeShape => ({ tag: "Product", value: { fields: [{ wire_name: "optional", slot: { type_ref: ref(target), required: false, nullable: false }, origin: { source, pointer: [] } }], extras: { tag: "Reject" } } });
  const context = new S.ValueContext({ profile, nodes: [node("root", product("gone"))] });
  expect(() => context.decodeWithDefaults(ref("root"), "{}")).toThrow(S.SemanticUnresolvedError);
  expect(S.meaningObligations(context, [ref("root")])).toEqual([{ type_ref: ref("gone"), origin: { source, pointer: ["gone"] }, value_path: [], profile: profile.reference, reason: { tag: "UnresolvedType" } }]);
  const text: S.TypeShape = { tag: "String", value: { format: { tag: "Named", value: "missing-format" }, lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: "" } };
  const formatted = new S.ValueContext({ profile, nodes: [node("text", text), node("root", product("text"))] });
  for (const [reference, before] of [[ref("root"), S.parseExact("{}")], [ref("text"), S.parseExact('""')]] as const) {
    try { formatted.materializeDefaults(reference, before); throw new Error("expected unresolved"); }
    catch (error) {
      expect(error).toBeInstanceOf(S.SemanticUnresolvedError);
      if (!(error instanceof S.SemanticUnresolvedError)) throw error;
      expect(error.obligations).toEqual([{ type_ref: ref("text"), origin: { source, pointer: ["text"] }, value_path: [], profile: profile.reference, reason: { tag: "UnknownFormat", value: "missing-format" } }]);
    }
  }
});

it("orders strings by code point so that U+FFFD precedes a supplementary character", () => {
  expect(["\u{10000}", "\uFFFDa"].sort(S.codePointOrder)).toEqual(["\uFFFDa", "\u{10000}"]);
});

it("projects a non-decimal array index as absent without raising a syntax error", () => {
  const array: S.ExactSlot = { tag: "Present", value: { tag: "Array", items: [{ tag: "Null" }] } };
  expect(S.projectedValue(array, [{ tag: "Index", value: "x" }], profile)).toEqual({ tag: "Absent" });
});

it("resolves a repeated type reference to its first node as the Lean findType does", () => {
  const ref: S.TypeRef = { source, definition_name: "repeated", pointer: ["repeated"] };
  const first: S.TypeNode = { reference: ref, shape: { tag: "String", value: { format: null, lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: "" } }, description: null, attributes: [], extensions: [] };
  const second: S.TypeNode = { ...first, shape: { tag: "Integer", value: { domain: null, minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null } } };
  const graph: S.ValueGraph = { profile, nodes: [first, second] };
  const context = new S.ValueContext(graph);
  expect(S.findType(context, ref)).toBe(first);
  expect(context.node(ref)).toBe(first);
});

it("returns no resolved shape for a cyclic or missing alias as the Lean resolvedShape does", () => {
  const ref = (name: string): S.TypeRef => ({ source, definition_name: name, pointer: [name] });
  const node = (name: string, shape: S.TypeShape): S.TypeNode => ({ reference: ref(name), shape, description: null, attributes: [], extensions: [] });
  const alias = (name: string, target: string): S.TypeNode => node(name, { tag: "Alias", fields: { target: ref(target), reference_text: target } });
  const flagShape: S.TypeShape = { tag: "Boolean", value: { const_value: null, default_value: false } };
  const context = new S.ValueContext({ profile, nodes: [alias("left", "right"), alias("right", "left"), alias("flag", "target"), node("target", flagShape)] });
  expect(context.resolve(ref("left"))).toBeUndefined();
  expect(context.resolve(ref("missing"))).toBeUndefined();
  expect(context.resolve(ref("flag"))).toEqual(flagShape);
  expect(S.resolvedShape(context, ref("left"))).toBeUndefined();
});

it("looks up the basis, integer binding and format use as the Lean definitions do", () => {
  const context = new S.ValueContext({ profile, nodes: [] }, [source]);
  expect(S.semanticBasisOf(context)).toEqual({ profile, sources: [source] });
  expect(S.integerBinding(context.prepared, null)?.name).toBe("integer");
  expect(S.integerBinding(context.prepared, "missing")).toBeUndefined();
  expect(S.formatUseRule(context, { tag: "Named", value: "identifier" })).toEqual(profile.format_bindings[0]?.rule);
  expect(S.formatUseRule(context, { tag: "Named", value: "missing" })).toBeUndefined();
  expect(S.formatUseRule(context, { tag: "Inline", value: { tag: "Text" } })).toEqual({ tag: "Text" });
});

it("measures exact JSON values as the Lean jsonSize does", () => {
  expect(S.jsonSize({ tag: "Null" })).toBe(1);
  expect(S.jsonSize({ tag: "Array", items: [] })).toBe(1);
  expect(S.jsonSize(S.parseExact('{"a":[1,null]}'))).toBe(4);
});

it("rejects construction of validated values outside the checking functions", () => {
  expect(() => Reflect.construct(S.ValidatedValue, [Symbol("forged"), { members: [] }])).toThrow(TypeError);
  expect(() => Reflect.construct(S.ValidatedSlot, [Symbol("forged"), {}])).toThrow(TypeError);
});
