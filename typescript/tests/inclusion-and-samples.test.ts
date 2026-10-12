// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import * as V from "../src/semantic_values.js";
import { checkAssignable, formatRuleIncluded, formatRuleSamplesFuel, sampleValues } from "../src/signature_verification.js";

const digest = "a".repeat(64);
const source: V.SourceRef = { repository: "synthetic", revision: "1", path: "types", content_digest: digest, document_id: "inclusion-and-samples" };
const reference: V.ProfileRef = { identity: "inclusion-and-samples", revision: "1", content_digest: digest };
const ref = (name: string): V.TypeRef => ({ source, definition_name: name, pointer: [] });
const origin: V.OccurrenceRef = { source, pointer: [] };
const node = (name: string, shape: V.TypeShape): V.TypeNode => ({ reference: ref(name), shape, description: null, attributes: [], extensions: [] });
const contract = (name: string): V.SlotContract => ({ type_ref: ref(name), required: true, nullable: false });
const field = (name: string, target: string, required = true, nullable = false): V.FieldSpec => ({ wire_name: name, slot: { type_ref: ref(target), required, nullable }, origin });
const branch = (target: string, wireTag: string, selector: V.BranchSelector = { tag: "InternalTag" }): V.UnionBranch => ({ target: ref(target), wire_tag: wireTag, selector, origin });
const integer = (minimum: string | null = null, maximum: string | null = null): V.TypeShape => ({ tag: "Integer", value: { domain: "zero-to-ten", minimum, maximum, const_value: null, enum_values: null, default_value: null } });
const string = (format: V.FormatUse | null = null, lengths: readonly V.LengthBound[] = [], constant: string | null = null): V.TypeShape => ({ tag: "String", value: { format, lengths, wrapper: null, const_value: constant, enum_values: null, examples: [], default_value: null } });
const product = (fields: readonly V.FieldSpec[], extras: V.ExtraMembers = { tag: "Reject" }): V.TypeShape => ({ tag: "Product", value: { fields, extras } });
const union = (branches: readonly V.UnionBranch[]): V.TypeShape => ({ tag: "TaggedUnion", value: { branches } });
const extra = (format: V.FormatUse | null, target: string, nullable = false): V.ExtraMembers => ({ tag: "Allow", fields: { key_format: format, value: { type_ref: ref(target), nullable } } });

const profile: V.VersionedSemanticProfile = {
  reference, source_refs: [source],
  integer_domains: [
    { name: "zero-to-ten", reference, range: { tag: "Inclusive", fields: { minimum: "0", maximum: "10" } }, forms: [{ tag: "Number" }] },
    { name: "forms", reference, range: { tag: "Inclusive", fields: { minimum: "0", maximum: "10" } }, forms: [{ tag: "Number" }, { tag: "IntegralDecimal" }, { tag: "DecimalString" }] },
  ],
  default_integer_domain: "zero-to-ten", numbers: { decimals: true }, grapheme_rules: null,
  format_bindings: [
    { name: "all-text", reference, rule: { tag: "Text" } },
    { name: "not-a", reference, rule: { tag: "Not", value: { tag: "Literal", value: "a" } } },
    { name: "key-x", reference, rule: { tag: "Literal", value: "x" } },
  ],
  bytes_policy: { reference, padding_optional: true, alphabet: { tag: "Standard" }, strict_pad_bits: true, wrapper: "bytes" },
  wrappers: [{ name: "bytes", key: "bytes", payload: { tag: "Bytes" } }],
  tag: { key: "tag", format: "all-text", sealed: [{ tag: "sealed", fields: [
    { key: "name", required: true, leaf: { tag: "String", value: { format: null, lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null } } },
    { key: "count", required: false, leaf: { tag: "Integer", value: { domain: "zero-to-ten", minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null } } },
  ], extras: { tag: "Reject" } }] },
};
const graph = (nodes: readonly V.TypeNode[], valueProfile = profile): V.ValueContext => new V.ValueContext({ profile: valueProfile, nodes }, [source]);

function expectCompatible(context: V.ValueContext, sourceName: string, destinationName: string): void {
  const decision = checkAssignable(context, contract(sourceName), contract(destinationName));
  expect(decision.tag).toBe("Compatible");
  for (const value of sampleValues(context, ref(sourceName)).values) {
    expect(context.accepts(contract(destinationName), { tag: "Present", value })).toBe(true);
  }
}
function expectIncompatible(context: V.ValueContext, sourceName: string, destinationName: string, expected: V.ExactSlot): void {
  const decision = checkAssignable(context, contract(sourceName), contract(destinationName));
  expect(decision.tag).toBe("Incompatible");
  if (decision.tag !== "Incompatible") return;
  expect(decision.value).toEqual(expected);
  expect(context.accepts(contract(sourceName), decision.value)).toBe(true);
  expect(context.accepts(contract(destinationName), decision.value)).toBe(false);
}

describe("Lean inclusion C1-C5 and I1-I7", () => {
  it("matches format inclusion and C1/I1", () => {
    const excluded: V.FormatRule = { tag: "Not", value: { tag: "Literal", value: "a" } };
    expect(formatRuleIncluded({ tag: "Literal", value: "a" }, { tag: "Text" })).toBe(true);
    expect(formatRuleIncluded(excluded, { tag: "Choice", value: [{ tag: "Literal", value: "x" }, excluded] })).toBe(true);
    const context = graph([node("text-string", string({ tag: "Named", value: "all-text" })), node("not-a-string", string({ tag: "Named", value: "not-a" }))]);
    expectCompatible(context, "not-a-string", "not-a-string");
    expectIncompatible(context, "text-string", "not-a-string", { tag: "Present", value: { tag: "String", value: "a" } });
  });

  it("matches C2 extras format inclusion", () => {
    const context = graph([
      node("any", { tag: "Unknown", value: { tag: "Any" } }),
      node("source", product([], extra({ tag: "Inline", value: { tag: "Literal", value: "x" } }, "any"))),
      node("destination", product([], extra({ tag: "Inline", value: { tag: "Text" } }, "any"))),
    ]);
    expectCompatible(context, "source", "destination");
  });

  it("matches C3/I3 ordered union images", () => {
    const context = graph([
      node("payload", product([])),
      node("c-source", union([branch("payload", "a")])),
      node("c-destination", union([branch("payload", "a"), branch("payload", "b")])),
      node("i-source", union([branch("payload", "a"), branch("payload", "b")])),
      node("i-destination", union([branch("payload", "a")])),
    ]);
    expectCompatible(context, "c-source", "c-destination");
    expectIncompatible(context, "i-source", "i-destination", { tag: "Present", value: { tag: "Object", members: [{ key: "tag", value: { tag: "String", value: "b" } }] } });
  });

  it("matches C4/I4 integer intersection", () => {
    const context = graph([node("zero-to-nine", integer("0", "9")), node("zero-to-ten", integer("0", "10"))]);
    expectCompatible(context, "zero-to-nine", "zero-to-ten");
    expectIncompatible(context, "zero-to-ten", "zero-to-nine", { tag: "Present", value: { tag: "Integer", value: "10" } });
  });

  it("matches C5/I5 string length inclusion", () => {
    const one: V.LengthBound = { unit: { tag: "UnicodeScalars" }, minimum: null, maximum: "1" };
    const two: V.LengthBound = { unit: { tag: "UnicodeScalars" }, minimum: null, maximum: "2" };
    const context = graph([node("one", string(null, [one])), node("two", string(null, [two]))]);
    expectCompatible(context, "one", "two");
    expectIncompatible(context, "two", "one", { tag: "Present", value: { tag: "String", value: "aa" } });
  });

  it("matches I2 and the effective tag field in both directions", () => {
    const context = graph([
      node("tag-x", string(null, [], "x")), node("tag-text", string({ tag: "Named", value: "all-text" })),
      node("implicit", product([])),
      node("constant-tag", product([field("tag", "tag-x", false)])),
      node("text-tag", product([field("tag", "tag-text", false)])),
    ]);
    expectIncompatible(context, "implicit", "constant-tag", { tag: "Present", value: { tag: "Object", members: [{ key: "tag", value: { tag: "String", value: "y" } }] } });
    expectCompatible(context, "implicit", "text-tag");
    expectCompatible(context, "text-tag", "implicit");
  });

  it("matches I6 rejected extras", () => {
    const context = graph([
      node("any", { tag: "Unknown", value: { tag: "Any" } }),
      node("source", product([], extra({ tag: "Inline", value: { tag: "Literal", value: "x" } }, "any"))),
      node("destination", product([])),
    ]);
    expectIncompatible(context, "source", "destination", { tag: "Present", value: { tag: "Object", members: [{ key: "x", value: { tag: "Object", members: [] } }] } });
  });

  it("matches I7 wrapper versus ordinary object", () => {
    const context = graph([node("bytes", { tag: "Bytes", value: { minimum: null, maximum: null } }), node("ordinary", { tag: "Unknown", value: { tag: "OrdinaryObject" } })]);
    expectIncompatible(context, "bytes", "ordinary", { tag: "Present", value: { tag: "Object", members: [{ key: "bytes", value: { tag: "String", value: "" } }] } });
  });
  it("matches rules L, S and N", () => {
    const nameX: V.SealedRefinement = { key: "name", leaf: { tag: "String", value: { format: null, lengths: [], wrapper: null, const_value: "x", enum_values: null, examples: [], default_value: null } } };
    const countOne: V.SealedRefinement = { key: "count", leaf: { tag: "Integer", value: { domain: "zero-to-ten", minimum: null, maximum: null, const_value: "1", enum_values: null, default_value: null } } };
    const context = graph([
      node("any", { tag: "Unknown", value: { tag: "Any" } }),
      node("boolean", { tag: "Boolean", value: { const_value: null, default_value: null } }),
      node("unit", { tag: "Unit" }),
      node("text", string()),
      node("integer", integer()),
      node("sealed", { tag: "Sealed", fields: { tag: "sealed", refinements: [] } }),
      node("sealed-source", { tag: "Sealed", fields: { tag: "sealed", refinements: [nameX, countOne] } }),
      node("sealed-destination", { tag: "Sealed", fields: { tag: "sealed", refinements: [nameX] } }),
      node("never", { tag: "Never" }),
    ]);
    for (const name of ["boolean", "unit", "text", "integer", "sealed"]) expectCompatible(context, name, "any");
    expectCompatible(context, "sealed-source", "sealed-destination");
    expectCompatible(context, "never", "sealed-destination");
  });

});

describe("Lean product rule P", () => {
  it("matches fields by wire name independently of order", () => {
    const context = graph([
      node("text", string()), node("integer", integer()),
      node("source", product([field("text", "text"), field("integer", "integer")])),
      node("destination", product([field("integer", "integer"), field("text", "text")])),
    ]);
    expectCompatible(context, "source", "destination");
  });

  it("supplies a source field to destination extras", () => {
    const context = graph([node("integer", integer()), node("source", product([field("x", "integer")])), node("destination", product([], extra({ tag: "Inline", value: { tag: "Literal", value: "x" } }, "integer")))]);
    expectCompatible(context, "source", "destination");
  });

  it("checks extras values in both directions", () => {
    const context = graph([
      node("nine", integer("0", "9")), node("ten", integer("0", "10")),
      node("source", product([], extra({ tag: "Inline", value: { tag: "Literal", value: "x" } }, "nine"))),
      node("destination", product([], extra({ tag: "Inline", value: { tag: "Literal", value: "x" } }, "ten"))),
    ]);
    expectCompatible(context, "source", "destination");
    expectIncompatible(context, "destination", "source", { tag: "Present", value: { tag: "Object", members: [{ key: "x", value: { tag: "Integer", value: "10" } }] } });
  });

  it("distinguishes optional and required fields supplied by extras", () => {
    const make = (required: boolean) => graph([
      node("nine", integer("0", "9")), node("ten", integer("0", "10")),
      node("source", product([], extra(null, "nine"))),
      node("destination", product([field("y", "ten", required)], extra(null, "ten"))),
    ]);
    expectCompatible(make(false), "source", "destination");
    expectIncompatible(make(true), "source", "destination", { tag: "Present", value: { tag: "Object", members: [] } });
  });

  it("uses child null acceptance for element inclusion and samples", () => {
    const context = graph([
      node("any", { tag: "Unknown", value: { tag: "Any" } }),
      node("text", string()),
      node("source", product([], extra(null, "any"))),
      node("destination", product([field("x", "any", false)], extra(null, "any"))),
      node("nullable-array", { tag: "Array", value: { item: { type_ref: ref("text"), nullable: true }, min_length: "1", max_length: "1" } }),
      node("nullable-map", product([], extra({ tag: "Inline", value: { tag: "Literal", value: "x" } }, "text", true))),
    ]);
    expectIncompatible(context, "source", "destination", { tag: "Present", value: { tag: "Object", members: [{ key: "x", value: { tag: "Null" } }] } });
    expect(sampleValues(context, ref("nullable-array")).values).toContainEqual({ tag: "Array", items: [{ tag: "Null" }] });
    expect(sampleValues(context, ref("nullable-map")).values).toContainEqual({ tag: "Object", members: [{ key: "x", value: { tag: "Null" } }] });
  });
});

describe("Lean samples and sample bound", () => {
  it("builds accepted Not, Labels and Sequence samples", () => {
    const not: V.FormatRule = { tag: "Not", value: { tag: "Literal", value: "a" } };
    const labels: V.FormatRule = { tag: "Labels", fields: { separator: "::", min_count: "2", max_count: null, total_max: null, rule: { tag: "Literal", value: "x" } } };
    const sequence: V.FormatRule = { tag: "Sequence", value: [{ tag: "Literal", value: "a" }, { tag: "Optional", value: { tag: "Literal", value: "b" } }] };
    for (const rule of [not, labels, sequence]) {
      const values = formatRuleSamplesFuel(32n, 8n, rule);
      expect(values.length).toBeGreaterThan(0);
      expect(values.every(value => V.recognizeFormat(rule, value))).toBe(true);
    }
    expect(formatRuleSamplesFuel(32n, 8n, labels)).toContain("x::x");
  });

  it("builds bytes samples with the profile alphabet", () => {
    const bytes = node("bytes", { tag: "Bytes", value: { minimum: null, maximum: null } });
    const samples = (alphabet: V.BytesAlphabet["tag"]) => {
      const valueProfile: V.VersionedSemanticProfile = {
        ...profile,
        bytes_policy: { ...profile.bytes_policy!, alphabet: { tag: alphabet } },
      };
      const context = graph([bytes], valueProfile);
      const values = sampleValues(context, ref("bytes")).values;
      expect(values.every(value => context.accepts(contract("bytes"), { tag: "Present", value }))).toBe(true);
      return values;
    };
    expect(samples("Standard")).toContainEqual({ tag: "Object", members: [{ key: "bytes", value: { tag: "String", value: "/w==" } }] });
    expect(samples("UrlSafe")).toContainEqual({ tag: "Object", members: [{ key: "bytes", value: { tag: "String", value: "_w==" } }] });
    expect(samples("Either")).toContainEqual({ tag: "Object", members: [{ key: "bytes", value: { tag: "String", value: "/w==" } }] });
  });

  it("reports SampleBound for a long scalar", () => {
    const context = graph([node("long", string(null, [], "aaaa"))]);
    expect(sampleValues(context, ref("long"), "3")).toEqual({ values: [], obligations: [{ tag: "SampleBound" }] });
  });

  it("reports SampleBound for product field combinations", () => {
    const fields = ["a", "b", "c", "d"].map(name => field(name, "flag"));
    const context = graph([node("flag", { tag: "Boolean", value: { const_value: null, default_value: null } }), node("four-fields", product(fields))]);
    const bounded = sampleValues(context, ref("four-fields"), "3"), unbounded = sampleValues(context, ref("four-fields"), "4");
    expect(bounded.values).toEqual([]);
    expect(bounded.obligations).toEqual([{ tag: "SampleBound" }]);
    expect(unbounded.values.length).toBeGreaterThan(0);
    expect(unbounded.obligations).toEqual([]);
  });
});
