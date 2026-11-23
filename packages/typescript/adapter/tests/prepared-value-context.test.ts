// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import { runInNewContext } from "node:vm";
import { setFlagsFromString } from "node:v8";
import * as V from "../src/semantic_values.js";
import { profile as fixtureProfile, source } from "./semantic-fixture.js";

const ref = (name: string): V.TypeRef => ({ source, definition_name: name, pointer: [] });
const node = (name: string, shape: V.TypeShape): V.TypeNode => ({ reference: ref(name), shape, description: null, attributes: [], extensions: [] });
const stringSpec = (overrides: Partial<V.StringSpec> = {}): V.StringSpec => ({ format: null, lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null, ...overrides });
const integerSpec = (overrides: Partial<V.IntegerSpec> = {}): V.IntegerSpec => ({ domain: "small", minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null, ...overrides });
const dfa: V.FormatRule = { tag: "AsciiDfa", value: { state_count: "2", initial_state: "0", accepting_states: ["1"], transitions: [
  { from_state: "0", first: "97", last: "122", to_state: "1" }, { from_state: "1", first: "97", last: "122", to_state: "1" }] } };
const profile: V.VersionedSemanticProfile = {
  ...fixtureProfile,
  integer_domains: [{ name: "small", reference: fixtureProfile.reference, range: { tag: "Inclusive", fields: { minimum: "0", maximum: "100" } }, forms: [{ tag: "Number" }] }],
  default_integer_domain: "small",
  format_bindings: [...fixtureProfile.format_bindings, { name: "letters", reference: fixtureProfile.reference, rule: dfa }],
  tag: { key: "kind", format: null, sealed: [{ tag: "sealed", fields: [{ key: "name", required: true, leaf: { tag: "String", value: stringSpec({ format: { tag: "Named", value: "letters" } }) } }, { key: "n", required: false, leaf: { tag: "Integer", value: integerSpec({ maximum: "90" }) } }], extras: { tag: "Reject" } }] },
};
const slot = (name: string, required = true) => ({ type_ref: ref(name), required, nullable: false });
const field = (name: string, type: string, required = true): V.FieldSpec => ({ wire_name: name, slot: slot(type, required), origin: { source, pointer: [] } });
const bounded: V.FormatRule = { tag: "Bounded", fields: { unit: { tag: "Graphemes" }, maximum: "3", rule: dfa } };
function nodesOf(filler: number): readonly V.TypeNode[] {
  return [
    node("letters", { tag: "String", value: stringSpec({ format: { tag: "Named", value: "letters" }, lengths: [{ unit: { tag: "Graphemes" }, minimum: null, maximum: "5" }] }) }),
    node("inline", { tag: "String", value: stringSpec({ format: { tag: "Inline", value: bounded } }) }),
    node("label", { tag: "String", value: stringSpec({ enum_values: ["a", "b"] }) }),
    node("count", { tag: "Integer", value: integerSpec({ minimum: "1", maximum: "50", enum_values: ["1", "5", "50"] }) }),
    node("list", { tag: "Array", value: { item: { type_ref: ref("letters"), nullable: false }, min_length: null, max_length: "4" } }),
    node("alias", { tag: "Alias", fields: { target: ref("list"), reference_text: "list" } }),
    node("kind", { tag: "Sealed", fields: { tag: "sealed", refinements: [{ key: "n", leaf: { tag: "Integer", value: integerSpec({ maximum: "60" }) } }] } }),
    node("choice", { tag: "TaggedUnion", value: { branches: [{ target: ref("kind"), wire_tag: "sealed", selector: { tag: "InternalTag" }, origin: { source, pointer: [] } }] } }),
    node("record", { tag: "Product", value: {
      fields: [field("name", "letters"), field("inline", "inline"), field("label", "label", false), field("count", "count"), field("items", "alias", false), field("choice", "choice", false)],
      extras: { tag: "Allow", fields: { key_format: { tag: "Named", value: "letters" }, value: { type_ref: ref("count"), nullable: false } } } } }),
    ...Array.from({ length: filler }, (_, index) => node(`filler-${index}`, { tag: "String", value: stringSpec({ format: { tag: "Named", value: "letters" } }) })),
  ];
}
const accepted = V.parseExact(JSON.stringify({ name: "ab", inline: "abc", label: "a", count: 5, items: ["ab", "cd"], choice: { kind: "sealed", name: "xy", n: 4 }, extra: 5 }));

function graphOf(filler: number, freeze: boolean): V.ValueGraph {
  const graph = { profile, nodes: nodesOf(filler) };
  return freeze ? V.deepFreeze(structuredClone(graph)) : graph;
}
it("holds the graph tables when the context is built", () => {
  const context = new V.ValueContext(graphOf(40, false));
  expect(context.graphEdges).toBeGreaterThan(0);
  expect(context.meaningBlocked.length).toBe(context.nodes.length);
});

it("returns the same unresolved failure from the table as from the obligation list", () => {
  const nodes = [...nodesOf(0), node("holder", { tag: "Product", value: { fields: [field("gone", "gone")], extras: { tag: "Reject" } } }), node("outer", { tag: "Alias", fields: { target: ref("holder"), reference_text: "holder" } })];
  const context = new V.ValueContext({ profile, nodes });
  const unresolved = { type_ref: ref("gone"), origin: { source, pointer: [] }, value_path: [], profile: profile.reference, reason: { tag: "UnresolvedType" } };
  expect(V.validateValue(context, ref("outer"), V.parseExact("{}"))).toEqual({ tag: "Failed", failure: { tag: "Unresolved", obligations: [unresolved] } });
  expect(V.acceptsValue(context, ref("outer"), V.parseExact("{}"))).toEqual({ tag: "Unresolved", obligations: [unresolved] });
  expect(V.acceptsValue(context, ref("record"), accepted)).toEqual({ tag: "Accepted" });
  expect(context.meaningBlocked[context.typeIndexes.get(V.typeIdentity(ref("holder")))!]).toBe(true);
  expect(context.meaningBlocked[context.typeIndexes.get(V.typeIdentity(ref("record")))!]).toBe(false);
});

function collector(): () => void {
  const flagged = (globalThis as { gc?: () => void }).gc;
  if (flagged !== undefined) return flagged;
  setFlagsFromString("--expose-gc");
  return runInNewContext("gc") as () => void;
}
async function released(refs: readonly WeakRef<object>[]): Promise<boolean> {
  const gc = collector();
  for (let attempt = 0; attempt < 20; attempt += 1) {
    await new Promise(resolve => setTimeout(resolve, 5));
    gc();
    if (refs.every(held => held.deref() === undefined)) return true;
  }
  return false;
}
function validatedAndDropped(freeze: boolean, keep: V.ValueContext | null): { readonly inputs: WeakRef<object>[]; readonly graph: WeakRef<object> } {
  const graph = graphOf(5, freeze);
  const context = keep ?? new V.ValueContext(graph);
  const value = V.parseExact(JSON.stringify({ name: "ab", inline: "abc", count: 5 }));
  const reference = ref("record");
  const contract = { type_ref: ref("record"), required: true, nullable: false };
  const present: V.ExactSlot = { tag: "Present", value };
  expect(V.validateValue(context, reference, value).tag).toBe("Ok");
  expect(V.acceptsSlot(context, contract, present)).toEqual({ tag: "Accepted" });
  expect(V.validateSlot(context, contract, present).tag).toBe("Ok");
  return { inputs: [new WeakRef(value), new WeakRef(reference), new WeakRef(contract), new WeakRef(present)], graph: new WeakRef(graph) };
}

for (const freeze of [true, false]) {
  it(`releases a ${freeze ? "frozen" : "unfrozen"} graph, value and reference after validation once the references are dropped`, async () => {
    const dropped = validatedAndDropped(freeze, null);
    expect(await released([...dropped.inputs, dropped.graph])).toBe(true);
  });
  it(`releases the input values of a ${freeze ? "frozen" : "unfrozen"} graph while its context stays alive`, async () => {
    const context = new V.ValueContext(graphOf(5, freeze));
    const dropped = validatedAndDropped(freeze, context);
    expect(await released(dropped.inputs)).toBe(true);
    expect(context.graph.nodes.length).toBeGreaterThan(0);
  });
}
