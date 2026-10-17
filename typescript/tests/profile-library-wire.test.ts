// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { digest, reference, source, stringSpec } from "./semantic-fixture.js";

const integerBinding: V.IntegerDomainBinding = {
  name: "integer", reference,
  range: { tag: "Inclusive", fields: { minimum: "-1", maximum: "1" } },
  forms: [{ tag: "Number" }, { tag: "IntegralDecimal" }, { tag: "DecimalString" }],
};
const identifier: V.FormatBinding = {
  name: "identifier", reference,
  rule: { tag: "Identifier", fields: { first_alphabet: "ab", rest_alphabet: "ab", exact_length: null, min_length: "1", max_length: "4", forbidden: [] } },
};
const tagFormat: V.FormatBinding = { name: "tag-format", reference, rule: { tag: "Choice", value: [{ tag: "Literal", value: "sealed" }, { tag: "Literal", value: "other" }] } };
const onlyOk: V.FormatBinding = { name: "only-ok", reference, rule: { tag: "Literal", value: "ok" } };
const bytesWrapper: V.Wrapper = { name: "bytes-wrapper", key: "bytes", payload: { tag: "Bytes" } };
const textWrapper: V.Wrapper = { name: "text-wrapper", key: "text", payload: { tag: "Text", value: "identifier" } };
const nameField: V.SealedField = { key: "name", required: true, leaf: { tag: "String", value: { ...stringSpec({ tag: "Named", value: "identifier" }), wrapper: "text-wrapper" } } };
const countField: V.SealedField = { key: "count", required: false, leaf: { tag: "Integer", value: { domain: "integer", minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null } } };
const validProfile: V.VersionedSemanticProfile = {
  reference, source_refs: [], integer_domains: [integerBinding], default_integer_domain: "integer",
  numbers: { decimals: true },
  grapheme_rules: {
    reference, component: { unicode_version: "16.0.0", uax29_revision: "45", cluster_profile: "extended" }, table_sha256: digest, sources: [],
    properties: [{ first: "0", last: "1", property: { tag: "Other" } }], extended_pictographic: [{ first: "2", last: "3" }], indic_conjunct: [{ first: "4", last: "5", property: { tag: "Other" } }],
  },
  format_bindings: [identifier, tagFormat, onlyOk],
  bytes_policy: { reference, padding_optional: true, alphabet: { tag: "Either" }, strict_pad_bits: true, wrapper: "bytes-wrapper" },
  wrappers: [bytesWrapper, textWrapper],
  tag: { key: "tag", format: "tag-format", sealed: [{ tag: "sealed", fields: [nameField, countField], extras: { tag: "Reject" } }] },
};

function predicate(action: () => unknown, expected: string): void {
  try { action(); } catch (error) {
    expect(error).toBeInstanceOf(S.PredicateFailure);
    expect((error as S.PredicateFailure).predicate).toBe(expected);
    return;
  }
  throw new Error(`expected ${expected}`);
}

it("observes every Lean profile predicate and the valid profile", () => {
  expect(S.checkProfile(structuredClone(validProfile))).toEqual(validProfile);
  const cases: readonly [S.ProfilePredicate, V.VersionedSemanticProfile][] = [
    ["PR01", { ...validProfile, reference: { ...reference, identity: "" } }],
    ["PR02", { ...validProfile, integer_domains: [integerBinding, integerBinding] }],
    ["PR03", { ...validProfile, integer_domains: [{ ...integerBinding, range: { tag: "Inclusive", fields: { minimum: "2", maximum: "1" } } }] }],
    ["PR04", { ...validProfile, integer_domains: [{ ...integerBinding, forms: [] }] }],
    ["PR05", { ...validProfile, default_integer_domain: "missing" }],
    ["PR06", { ...validProfile, format_bindings: [...validProfile.format_bindings, identifier] }],
    ["PR07", { ...validProfile, format_bindings: [{ ...identifier, rule: { tag: "Identifier", fields: { first_alphabet: "", rest_alphabet: "ab", exact_length: null, min_length: "1", max_length: "4", forbidden: [] } } }, tagFormat, onlyOk] }],
    ["PR08", { ...validProfile, wrappers: [bytesWrapper, { ...textWrapper, key: "bytes" }] }],
    ["PR09", { ...validProfile, wrappers: [bytesWrapper, { ...textWrapper, payload: { tag: "Text", value: "missing" } }] }],
    ["PR10", { ...validProfile, bytes_policy: { ...validProfile.bytes_policy!, wrapper: "text-wrapper" } }],
    ["PR11", { ...validProfile, tag: { ...validProfile.tag!, key: "text" } }],
    ["PR12", { ...validProfile, tag: { ...validProfile.tag!, format: "missing" } }],
    ["PR13", { ...validProfile, tag: { ...validProfile.tag!, sealed: [...validProfile.tag!.sealed, ...validProfile.tag!.sealed] } }],
    ["PR14", { ...validProfile, tag: { ...validProfile.tag!, sealed: [{ ...validProfile.tag!.sealed[0]!, fields: [nameField, countField, nameField] }] } }],
    ["PR15", { ...validProfile, tag: { ...validProfile.tag!, sealed: [{ ...validProfile.tag!.sealed[0]!, fields: [nameField, { ...countField, leaf: { tag: "Integer", value: { domain: "missing", minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null } } }] }] } }],
    ["PR16", { ...validProfile, grapheme_rules: { ...validProfile.grapheme_rules!, properties: [{ first: "2", last: "1", property: { tag: "Other" } }] } }],
  ];
  for (const [expected, profile] of cases) predicate(() => S.checkProfile(profile), expected);
});

const typeRef = (name: string): V.TypeRef => ({ source, definition_name: name, pointer: [] });
const node = (shape: V.TypeShape): V.TypeNode => ({ reference: typeRef("subject"), shape, description: null, attributes: [], extensions: [] });
const meaning = (profile: V.VersionedSemanticProfile, shape: V.TypeShape, expected: S.MeaningPredicate): void => predicate(() => S.checkMeaningDefined({ profile, nodes: [node(shape)] }, [typeRef("subject")]), expected);
const integerSpec = (domain: string | null = null): V.IntegerSpec => ({ domain, minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null });

it("observes every Lean meaning obligation and a defined unit", () => {
  expect(() => S.checkMeaningDefined({ profile: validProfile, nodes: [node({ tag: "Unit" })] }, [typeRef("subject")])).not.toThrow();
  meaning(validProfile, { tag: "String", value: stringSpec({ tag: "Named", value: "missing" }) }, "MO01");
  meaning({ ...validProfile, grapheme_rules: null }, { tag: "String", value: { ...stringSpec(), lengths: [{ unit: { tag: "Graphemes" }, minimum: "1", maximum: null }] } }, "MO02");
  meaning({ ...validProfile, bytes_policy: null }, { tag: "Bytes", value: { minimum: null, maximum: null } }, "MO03");
  meaning(validProfile, { tag: "Integer", value: integerSpec("missing") }, "MO04");
  meaning(validProfile, { tag: "String", value: { ...stringSpec(), wrapper: "missing" } }, "MO05");
  meaning(validProfile, { tag: "String", value: { ...stringSpec(), wrapper: "bytes-wrapper" } }, "MO06");
  meaning(validProfile, { tag: "Sealed", fields: { tag: "missing", refinements: [] } }, "MO07");
  meaning({ ...validProfile, numbers: { decimals: false } }, { tag: "Decimal", value: { minimum: null, maximum: null } }, "MO08");
  meaning(validProfile, { tag: "Integer", value: { ...integerSpec("integer"), minimum: "-2" } }, "MO09");
  meaning(validProfile, { tag: "Opaque", fields: { type_name: "external" } }, "MO10");
  meaning({ ...validProfile, tag: null }, { tag: "TaggedUnion", value: { branches: [{ target: typeRef("subject"), wire_tag: "other", selector: { tag: "InternalTag" }, origin: { source, pointer: [] } }] } }, "MO11");
});

const unitNode: S.TypeSignatureLibrary["nodes"][number] = { id: "unit", shape: { tag: "Unit" } };
const field = (wire_name: string, type_id: string): { wire_name: string; slot: S.SignatureSlot } => ({ wire_name, slot: { type_id, required: true, nullable: false } });
const branch = (target: string, wire_tag: string, selector: V.BranchSelector) => ({ target, wire_tag, selector });
const product = (id: string, fields: readonly ReturnType<typeof field>[], extras: S.SignatureExtraMembers = { tag: "Reject" }) => ({ id, shape: { tag: "Product", value: { fields, extras } } } as const);
const union = (branches: readonly ReturnType<typeof branch>[]) => ({ id: "union", shape: { tag: "TaggedUnion", value: { branches } } } as const);
const libraryProfile: S.ValueSemanticProfile = { ...validProfile, grapheme_rules: null };
function libraryWith(nodes: S.TypeSignatureLibrary["nodes"]): S.TypeSignatureLibrary {
  return { schema: "ncoh-type-signatures@1", identity: "library", revision: "4", profile: libraryProfile, sources: [], provenance: [], groups: [], annotations: [], nodes, definitions: [{ id: "entry", wire_identity: "entry", shape: { tag: "Value", value: "unit" } }] };
}

it("observes every Lean library predicate and the valid library", () => {
  expect(S.checkLibrary(libraryWith([unitNode])).library.nodes).toEqual([unitNode]);
  const stringNode = (id: string, value: V.StringSpec) => ({ id, shape: { tag: "String", value } } as const);
  const cases: readonly [S.LibraryPredicate, S.TypeSignatureLibrary][] = [
    ["LB01", libraryWith([unitNode, { id: "alias", shape: { tag: "Alias", fields: { target: "missing" } } }])],
    ["LB02", libraryWith([unitNode, product("product", [field("value", "unit"), field("value", "unit")])])],
    ["LB03", libraryWith([unitNode, product("product", [field("text", "unit")])])],
    ["LB04", libraryWith([unitNode, union([branch("unit", "same", { tag: "Kind", value: { tag: "Null" } }), branch("unit", "same", { tag: "Kind", value: { tag: "Boolean" } })])])],
    ["LB05", libraryWith([unitNode, union([branch("unit", "fallback", { tag: "Otherwise" }), branch("unit", "null", { tag: "Kind", value: { tag: "Null" } })])])],
    ["LB06", libraryWith([unitNode, union([branch("unit", "", { tag: "Kind", value: { tag: "Null" } })])])],
    ["LB07", libraryWith([unitNode, product("target", []), union([branch("target", "outside", { tag: "InternalTag" })])])],
    ["LB08", libraryWith([unitNode, product("target", []), union([branch("target", "sealed", { tag: "InternalTag" })])])],
    ["LB09", libraryWith([unitNode, union([branch("unit", "member", { tag: "MemberShape", value: [["key", { tag: "Format", value: "missing" }]] })])])],
    ["LB10", libraryWith([unitNode, { id: "sealed-node", shape: { tag: "Sealed", fields: { tag: "sealed", refinements: [{ key: "missing", leaf: { tag: "String", value: stringSpec() } }] } } }])],
    ["LB11", libraryWith([unitNode, union([branch("unit", "other", { tag: "InternalTag" })])])],
    ["LB12", libraryWith([unitNode, product("product", [], { tag: "Allow", fields: { key_format: { tag: "Named", value: "missing" }, value: { type_id: "unit", nullable: false } } })])],
    ["LB13", libraryWith([unitNode, stringNode("string", { ...stringSpec(), wrapper: "missing" })])],
    ["LB14", libraryWith([unitNode, { id: "integer", shape: { tag: "Integer", value: { ...integerSpec(), minimum: "2", maximum: "1" } } }])],
    ["LB15", libraryWith([unitNode, { id: "decimal", shape: { tag: "Decimal", value: { minimum: { mantissa: "2", scale: "0", exclusive: false }, maximum: { mantissa: "1", scale: "0", exclusive: false } } } }])],
    ["LB16", libraryWith([unitNode, { id: "array", shape: { tag: "Array", value: { item: { type_id: "unit", nullable: false }, min_length: "2", max_length: "1" } } }])],
    ["LB17", libraryWith([unitNode, stringNode("tag-value", { ...stringSpec(), const_value: "different" }), product("target", [field("tag", "tag-value")]), union([branch("target", "other", { tag: "InternalTag" })])])],
    ["LB18", libraryWith([unitNode, union([branch("unit", "first", { tag: "Kind", value: { tag: "Null" } }), branch("unit", "second", { tag: "Kind", value: { tag: "Null" } })])])],
    ["LB19", libraryWith([unitNode, stringNode("string", { ...stringSpec({ tag: "Named", value: "only-ok" }), const_value: "bad" })])],
  ];
  for (const [expected, library] of cases) predicate(() => S.checkLibrary(library), expected);
});

it("uses wire tags for InternalTag identity and preserves selector duplicates", () => {
  const nodes = [unitNode, { id: "tag-value", shape: { tag: "String", value: stringSpec() } } as const,
    product("a", [field("$type", "tag-value")]), product("b", [field("$type", "tag-value")])];
  const branches = [branch("a", "com.example.a", { tag: "InternalTag" }), branch("b", "com.example.b", { tag: "InternalTag" })];
  const subject = { ...libraryWith([...nodes, union(branches)]), profile: { ...libraryProfile, tag: { key: "$type", format: null, sealed: [] } } };
  expect(S.checkLibrary(subject).library.nodes).toEqual(subject.nodes);
  for (const selector of [{ tag: "Kind", value: { tag: "Null" } }, { tag: "MemberShape", value: [["key", { tag: "Absent" }]] }] as const) {
    predicate(() => S.checkLibrary({ ...subject, nodes: [...nodes, union(branches.map(item => ({ ...item, selector })))] }), "LB18");
  }
});

it("roundtrips every Lean format, shape, and condition declaration", () => {
  const formats: readonly V.FormatRule[] = [
    { tag: "AsciiDfa", value: { state_count: "1", initial_state: "0", accepting_states: ["0"], transitions: [] } },
    { tag: "Timestamp", value: { allow_second_60: false, minimum_year: "0", maximum_year: "9999", rejectUtcYearOutsideRange: true } },
    { tag: "Choice", value: [{ tag: "Text" }] },
    { tag: "Identifier", fields: { first_alphabet: "a", rest_alphabet: "a", exact_length: null, min_length: "1", max_length: "2", forbidden: [] } },
    { tag: "AbsoluteUri", fields: { max_bytes: null } }, { tag: "LanguageTag", fields: { grandfathered: [] } },
    { tag: "Literal", value: "x" }, { tag: "Sequence", value: [{ tag: "Text" }] }, { tag: "Optional", value: { tag: "Text" } },
    { tag: "Labels", fields: { separator: ".", min_count: "1", max_count: null, total_max: null, rule: { tag: "Text" } } },
    { tag: "Bounded", fields: { unit: { tag: "UnicodeScalars" }, maximum: "2", rule: { tag: "Text" } } }, { tag: "Text" }, { tag: "Not", value: { tag: "Literal", value: "x" } },
  ];
  const boolean = { const_value: null, default_value: null };
  const shapes: readonly S.ValueTypeShape[] = [
    { tag: "Unknown", value: { tag: "Any" } }, { tag: "Unknown", value: { tag: "OrdinaryObject" } }, { tag: "Unit" }, { tag: "Boolean", value: boolean },
    { tag: "Integer", value: integerSpec("integer") }, { tag: "Decimal", value: { minimum: null, maximum: null } }, { tag: "String", value: { ...stringSpec(), lengths: [{ unit: { tag: "Graphemes" }, minimum: null, maximum: "2" }] } },
    { tag: "Bytes", value: { minimum: null, maximum: null } }, { tag: "Product", value: { fields: [], extras: { tag: "Reject" } } },
    { tag: "Array", value: { item: { type_id: "unit", nullable: false }, min_length: null, max_length: null } },
    { tag: "TaggedUnion", value: { branches: [branch("unit", "unit", { tag: "Kind", value: { tag: "Null" } })] } },
    { tag: "Sealed", fields: { tag: "sealed", refinements: [] } }, { tag: "Never" }, { tag: "Alias", fields: { target: "unit" } },
    { tag: "RawBody", fields: { encoding: "raw" } }, { tag: "Opaque", fields: { type_name: "opaque" } },
  ];
  const payload = new Map<string, string>([["WrongValueKind", "string"], ["Format", "f"], ["InvalidWrapper", "text"], ["KeyFormat", "key"], ["DuplicateField", "key"], ["UnexpectedField", "key"]]);
  const conditionTags = ["MissingRequired", "NullNotAllowed", "WrongValueKind", "ConstMismatch", "EnumMismatch", "BelowMinimum", "AboveMaximum", "IntegerDomain", "StringLength", "ArrayLength", "BytesLength", "Format", "InvalidBytes", "InvalidWrapper", "InvalidTag", "ReservedForm", "NoBranchSelected", "KeyFormat", "Uninhabited", "DuplicateField", "UnexpectedField", "InvalidDataModel", "ReferenceCycle"];
  const conditions = conditionTags.map(tag => payload.has(tag) ? { tag, value: payload.get(tag)! } : { tag });
  const profileEncoded = S.encodeProfileWire(validProfile), profileDecoded = S.decodeProfileWire(JSON.parse(profileEncoded));
  expect(profileDecoded).toEqual(validProfile);
  expect(S.encodeProfileWire(profileDecoded)).toBe(profileEncoded);
  for (const value of formats) {
    const encoded = S.encodeFormatRuleWire(value), decoded = S.decodeFormatRuleWire(JSON.parse(encoded));
    expect(decoded).toEqual(value);
    expect(S.encodeFormatRuleWire(decoded)).toBe(encoded);
  }
  for (const value of shapes) {
    const encoded = S.encodeShapeWire(value), decoded = S.decodeShapeWire(JSON.parse(encoded));
    expect(decoded).toEqual(value);
    expect(S.encodeShapeWire(decoded)).toBe(encoded);
  }
  for (const value of conditions) {
    const encoded = S.encodeValueConditionWire(value), decoded = S.decodeValueConditionWire(JSON.parse(encoded));
    expect(decoded).toEqual(value);
    expect(S.encodeValueConditionWire(decoded)).toBe(encoded);
  }

  const validLibrary = libraryWith([unitNode]);
  const libraryEncoded = S.encodeLibraryWire(validLibrary), libraryDecoded = S.decodeLibraryWire(JSON.parse(libraryEncoded));
  expect(libraryDecoded).toEqual(validLibrary);
  expect(S.encodeLibraryWire(libraryDecoded)).toBe(libraryEncoded);
  const entries = [{ identity: "entry", definition: "entry" }];
  const basis = S.signatureBasis(validLibrary, entries);
  const basisEncoded = S.encodeGenerationBasisWire(basis), basisDecoded = S.decodeGenerationBasisWire(JSON.parse(basisEncoded));
  expect(basisDecoded).toEqual(basis);
  expect(S.encodeGenerationBasisWire(basisDecoded)).toBe(basisEncoded);
  const diagnostic: S.SignatureValueFailure = {
    type_ref: typeRef("unit"),
    definition_ref: { source, name: "unit" },
    origin: { source, pointer: [] },
    value_path: [{ tag: "Field", value: "value" }],
    condition: { tag: "WrongValueKind", value: "string" },
    observed: { tag: "Present", value: { tag: "Bool", value: false } },
    reference_trace: [typeRef("unit")],
  };
  const diagnosticEncoded = S.encodeDiagnosticWire(diagnostic), diagnosticDecoded = S.decodeDiagnosticWire(JSON.parse(diagnosticEncoded));
  expect(diagnosticDecoded).toEqual(diagnostic);
  expect(S.encodeDiagnosticWire(diagnosticDecoded)).toBe(diagnosticEncoded);
});

it("rejects every obsolete and noncanonical profile wire row", () => {
  expect(() => S.decodeProfileWire({ ...validProfile, representation: null })).toThrow(/UnknownField:representation/);
  expect(() => S.decodeFormatRuleWire({ tag: "Cid" })).toThrow(/UnknownTag:Cid/);
  expect(() => S.decodeFormatRuleWire({ tag: "Text", value: null })).toThrow(/UnknownField:value/);
  expect(() => S.decodeShapeWire({ tag: "Never", fields: {} })).toThrow(/UnknownField:fields/);
  const validLibrary = libraryWith([unitNode]);
  const entrypoints = [{ identity: "entry", definition: "entry" }], basis = S.signatureBasis(validLibrary, entrypoints);
  const input: S.SignatureGenerationInput = { schema: "ncoh-checked-generation@4", basis, signatures: validLibrary, composition: null, entrypoints };
  const oldField = { ...input, signatures: { ...validLibrary, profile: { ...validLibrary.profile, representation: null } } };
  expect(S.admitSignatureGeneration(basis, JSON.stringify(oldField))).toEqual({ tag: "Failed", failure: { tag: "UnknownField", value: "representation" } });
  const oldTag = { ...input, signatures: { ...validLibrary, nodes: [{ id: "unit", shape: { tag: "Cid" } }] } };
  expect(S.admitSignatureGeneration(basis, JSON.stringify(oldTag))).toEqual({ tag: "Failed", failure: { tag: "UnknownTag", value: "Cid" } });
  const productContext = libraryWith([
    unitNode,
    { id: "product", shape: { tag: "Product", value: { context: { tag: "Object" }, fields: [], extras: { tag: "Reject" } } } },
  ] as unknown as S.TypeSignatureLibrary["nodes"]);
  const contextInput = { ...input, signatures: productContext };
  expect(S.admitSignatureGeneration(basis, JSON.stringify(contextInput))).toEqual({ tag: "Failed", failure: { tag: "UnknownField", value: "context" } });
  const nestedField = libraryWith([
    unitNode,
    { id: "product", shape: { tag: "Product", value: { fields: [{ wire_name: "value", slot: { type_id: "unit", required: true, nullable: false, context: null } }], extras: { tag: "Reject" } } } },
  ] as unknown as S.TypeSignatureLibrary["nodes"]);
  const nestedInput = { ...input, signatures: nestedField };
  expect(S.admitSignatureGeneration(basis, JSON.stringify(nestedInput))).toEqual({ tag: "Failed", failure: { tag: "UnknownField", value: "context" } });
});

it("returns PR01 at the JSON, wire, and admission entrances", () => {
  const invalid = { ...validProfile, reference: { ...reference, identity: "" } };
  predicate(() => S.decodeProfileJson(JSON.stringify(invalid)), "PR01");
  const artifact = JSON.stringify({ profile: invalid });
  predicate(() => V.decodeCanonicalProfileArtifact(invalid.reference, [], artifact, artifact), "PR01");
  predicate(() => S.decodeProfileWire(invalid), "PR01");
  const validLibrary = libraryWith([unitNode]);
  const entrypoints = [{ identity: "entry", definition: "entry" }], basis = S.signatureBasis(validLibrary, entrypoints);
  const input: S.SignatureGenerationInput = { schema: "ncoh-checked-generation@4", basis, signatures: { ...validLibrary, profile: { ...libraryProfile, reference: invalid.reference } }, composition: null, entrypoints };
  expect(S.admitSignatureGeneration(basis, JSON.stringify(input))).toMatchObject({ tag: "Failed", failure: { tag: "Predicate", value: { predicate: "PR01" } } });
});
