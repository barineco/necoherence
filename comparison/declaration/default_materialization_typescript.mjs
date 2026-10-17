// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { createInterface } from "node:readline";
import { semanticValues as V } from "../../typescript/dist/index.js";

function path(steps) { return steps.map(step => ({ tag: typeof step === "bigint" ? "Index" : "Field", value: String(step) })); }
function origin(ref) { return { source: ref.source, pointer: ref.pointer }; }
function evaluate(input) {
  const context = new V.ValueContext(input.graph, input.graph.source_refs), before = structuredClone(input.before);
  try {
    const result = "wire" in input ? context.decodeWithDefaults(input.reference, input.wire) : context.materializeDefaults(input.reference, before);
    const second = context.materializeDefaults(input.reference, result.value);
    const row = { id: input.id, status: "Accepted", value: result.value, applications: result.applications, second_value: second.value, second_applications: second.applications, input: before };
    if (input.tamper) {
      const first = result.applications[0], wrongRef = structuredClone(first.type_ref), wrongOrigin = structuredClone(first.origin);
      wrongRef.source.document_id += "-forged"; wrongOrigin.pointer.push("forged");
      const forged = [{ ...first, type_ref: wrongRef }, { ...first, origin: wrongOrigin }, { ...first, value_path: [...first.value_path, { tag: "Field", value: "forged" }] }, { ...first, value: { tag: "Bool", value: true } }];
      row.certificates = forged.map(item => V.checkDefaultApplications(input.graph, before, result.value, [item, ...result.applications.slice(1)]));
    }
    return row;
  } catch (error) {
    if (error instanceof V.SemanticUnresolvedError) return { id: input.id, status: "Unresolved", obligations: error.obligations };
    if (error instanceof V.SemanticValueError) return { id: input.id, status: "Rejected", type_ref: error.failure.type, origin: origin(error.failure.type), value_path: path(error.failure.path), condition: error.failure.condition, reference_trace: error.failure.referenceTrace ?? [] };
    if (error instanceof V.SemanticEvidenceError && "wire" in input) return { id: input.id, status: "Wire", classification: error.condition === "one member with this name" ? "DuplicateField" : "Syntax" };
    throw error;
  }
}
for await (const line of createInterface({ input: process.stdin })) console.log(JSON.stringify(evaluate(JSON.parse(line))));
