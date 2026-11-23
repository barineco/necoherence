// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import { residual, residualSet, stopped } from "neco-quotient-certificate";
import * as C from "../src/semantic_composition.js";
import * as V from "../src/semantic_values.js";

const reference = { source: { repository: "r", revision: "1", path: "p", content_digest: "d", document_id: "doc", declared_revision: null }, definition_name: "t", pointer: ["t"] };
const provenance = { operation: "validate", type_ref: reference, value_path: [] };
const reason: V.SemanticObligation = { type_ref: reference, origin: { source: reference.source, pointer: ["origin"] }, value_path: [{ tag: "Field", value: "nested" }], profile: { identity: "p", revision: "1", content_digest: "d" }, reason: { tag: "UnknownFormat", value: "format" } };
const reorder = (value: unknown): unknown => Array.isArray(value) ? value.map(reorder) : value !== null && typeof value === "object" ? Object.fromEntries(Object.entries(value).reverse().map(([key, value]) => [key, reorder(value)])) : value;
const pair: C.TypePair = { source: { type_ref: reference, required: true, nullable: false }, destination: { type_ref: reference, required: true, nullable: false }, sourceTag: null };
const typeObligation = (reason: C.TypeObligationReason): C.TypeObligation => ({ pair, path: [], reason });

it("deduplicates residuals independently of object field insertion order", () => {
  const other = reorder(reason) as V.SemanticObligation;
  expect(JSON.stringify(reason)).not.toBe(JSON.stringify(other));
  const composition = C.classifyUnresolvedObligations(provenance, [{ tag: "Meaning", value: [reason] }, { tag: "Meaning", value: [other] }]);
  expect(composition).toEqual({ ok: true, value: residual({ provenance, obligations: [{ tag: "Meaning", value: [reason] }, { tag: "Meaning", value: [other] }] }, [{ tag: "Meaning", value: [reason] }]) });
});

it("classifies an unresolved type as residual", () => {
  const unresolved: V.SemanticObligation = { ...reason, reason: { tag: "UnresolvedType" } };
  const evaluation = C.classifyUnresolvedObligations(provenance, [{ tag: "Meaning", value: [unresolved] }]);
  expect(evaluation.ok && evaluation.value.kind).toBe("residual");
});

it("keeps the classes of a failed evaluation, including the empty list", () => {
  expect(C.classifyUnresolvedObligations(provenance, [{ tag: "Meaning", value: [] }])).toEqual({ ok: false, error: { provenance, obligations: [{ tag: "Meaning", value: [] }], residuals: residualSet([]), classes: ["Failed"] } });
  expect(C.classifyUnresolvedObligations(provenance, [])).toEqual({ ok: false, error: { provenance, obligations: [], residuals: residualSet([]), classes: [] } });
});

it("stops on a bound exhausted obligation", () => {
  const evaluation = C.classifyUnresolvedObligations(provenance, [{ tag: "StateBoundExhausted" }]);
  expect(evaluation).toEqual({ ok: true, value: stopped({ provenance, obligations: [{ tag: "StateBoundExhausted" }] }, [], [{ tag: "StateBoundExhausted" }]) });
});

it("splits a type obligation into atoms that keep the outer type wrapper", () => {
  const empty = typeObligation({ tag: "Meaning", value: [] });
  const presence = typeObligation({ tag: "Presence" });
  const obligation: C.UnresolvedObligation = { tag: "Type", fields: { value: null, obligations: [empty, presence] } };
  expect(C.unresolvedAtoms(obligation)).toEqual([
    { tag: "Type", fields: { value: null, obligations: [empty] } },
    { tag: "Type", fields: { value: null, obligations: [presence] } },
  ]);
});

it("prefers failure, then stop, then residual among semantic obligations", () => {
  const unresolved: V.SemanticObligation = { ...reason, reason: { tag: "UnresolvedType" } };
  const bound: V.SemanticObligation = { ...reason, reason: { tag: "MembershipBound" } };
  const failed: V.SemanticObligation = { ...reason, reason: { tag: "IntegerBound" } };
  expect(V.classifySemanticObligations(provenance, [unresolved, bound, failed]).ok).toBe(false);
  expect(V.classifySemanticObligations(provenance, [])).toEqual({ ok: false, error: { provenance, obligations: [], residuals: residualSet([]), classes: [] } });
  expect(V.classifySemanticObligations(provenance, [unresolved, bound])).toEqual({ ok: true, value: stopped({ provenance, obligations: [unresolved, bound] }, [unresolved], [bound]) });
  expect(V.classifySemanticObligations(provenance, [unresolved, unresolved])).toEqual({ ok: true, value: residual({ provenance, obligations: [unresolved, unresolved] }, [unresolved]) });
});
