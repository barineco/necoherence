// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { createInterface } from "node:readline";
import { semanticValues as V } from "../../packages/typescript/adapter/dist/index.js";

function path(steps) { return steps.map(step => ({ tag: typeof step === "bigint" ? "Index" : "Field", value: String(step) })); }
function origin(ref) { return { source: ref.source, pointer: ref.pointer }; }
function uniqueWire(value) {
  if (value.tag === "Array") return value.items.every(uniqueWire);
  if (value.tag === "Object") return new Set(value.members.map(member => member.key)).size === value.members.length && value.members.every(member => uniqueWire(member.value));
  return true;
}
function sortedExact(value) {
  if (value.tag === "Array") return { tag: "Array", items: value.items.map(sortedExact) };
  if (value.tag === "Object") return { tag: "Object", members: value.members.map(member => ({ key: member.key, value: sortedExact(member.value) })).sort((left, right) => V.codePointOrder(left.key, right.key)) };
  return value;
}
function evaluate(input) {
  const context = new V.ValueContext(input.graph, input.graph.source_refs), before = structuredClone(input.before);
  if ("wire" in input) {
    if (!uniqueWire(before)) return { id: input.id, status: "Wire", classification: "DuplicateField", path: "$" };
    let parsed;
    try { parsed = V.boundedParseExact(input.wire); }
    catch (error) {
      if (error instanceof V.WireError) return { id: input.id, status: "Wire", classification: error.failure.tag, path: error.failure.path };
      throw error;
    }
    if (V.encodeExact(sortedExact(parsed)) !== V.encodeExact(sortedExact(before))) throw new Error("wire and exact input differ");
  }
  try {
  const result = "wire" in input ? context.decodeWithDefaults(input.reference, input.wire) : context.materializeDefaults(input.reference, before);
    const second = context.materializeDefaults(input.reference, result.value);
    const row = { id: input.id, status: "Accepted", value: result.value, applications: result.applications, second_value: second.value, second_applications: second.applications, input: before };
    if (input.tamper) {
      const first = result.applications[0], wrongRef = structuredClone(first.type_ref), wrongOrigin = structuredClone(first.origin);
      wrongRef.source.document_id += "-forged"; wrongOrigin.pointer.push("forged");
      const forged = [{ ...first, type_ref: wrongRef }, { ...first, origin: wrongOrigin }, { ...first, value_path: [...first.value_path, { tag: "Field", value: "forged" }] }, { ...first, value: { tag: "Bool", value: true } }];
      row.certificates = forged.map(item => V.checkDefaultApplications(context, before, result.value, [item, ...result.applications.slice(1)]));
    }
    return row;
  } catch (error) {
    if (error instanceof V.WireError) return { id: input.id, status: "Wire", classification: error.failure.tag, path: error.failure.path };
    if (error instanceof V.SemanticUnresolvedError) return { id: input.id, status: "Unresolved", obligations: error.obligations };
    if (error instanceof V.SemanticValueError) return { id: input.id, status: "Rejected", type_ref: error.failure.type, definition_ref: { source: error.failure.type.source, name: error.failure.type.definition_name }, origin: origin(error.failure.type), value_path: path(error.failure.path), condition: error.failure.condition, observed: error.failure.observed, reference_trace: error.failure.referenceTrace ?? [] };
    throw error;
  }
}
for await (const line of createInterface({ input: process.stdin })) {
  const input = JSON.parse(line);
  let row;
  try { row = evaluate(input); } catch (error) { row = { id: input.id, status: "AdapterFailure", message: String(error) }; }
  console.log(JSON.stringify(row));
}
