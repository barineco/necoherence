// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import * as X from "./semantic_values.js";
import {
  ValueContext, SemanticEvidenceError, SemanticValueError, requireEvidence as check, same, deepFreeze,
  slotOf, typeChildren, recognizeFormat, formatRuleEqual,
} from "./semantic_values.js";

export function validateSemanticWire(type: string, value: unknown): unknown {
  if (type === "string") check(typeof value === "string", "string");
  else if (type === "boolean") check(typeof value === "boolean", "boolean");
  else if (type === "sha256") check(typeof value === "string" && /^[0-9a-f]{64}$/.test(value), "sha256");
  else if (type === "string[]") check(Array.isArray(value) && value.every(item => typeof item === "string"), "string array");
  else if (type === "ExactJson") check(value !== null && typeof value === "object" && typeof (value as { tag?: unknown }).tag === "string", "exact JSON");
  return value;
}



















export type ProjectionFailure =
  | { readonly tag: "WrongShape"; readonly fields: { readonly ref: X.TypeRef; readonly path: readonly X.PathStep[] } }
  | { readonly tag: "MissingField" | "MissingVariant"; readonly fields: { readonly ref: X.TypeRef; readonly name: string } }
  | { readonly tag: "BranchAssumptionRequired" | "VariantSelectionUndetermined"; readonly fields: { readonly path: readonly X.PathStep[]; readonly tag: string } }
  | { readonly tag: "Unresolved"; readonly value: readonly X.SemanticObligation[] }
  | { readonly tag: "CertificateMismatch"; readonly value: string };

export class ProjectionError extends SemanticEvidenceError {
  constructor(readonly failure: ProjectionFailure) { super(failure.tag); }
}

function projectionFail(failure: ProjectionFailure): never { throw new ProjectionError(failure); }

function strengthenProjection(slot: X.SlotContract, path: readonly X.PathStep[], assumptions: readonly X.ProjectionAssumption[]): X.SlotContract {
  const observed = assumptions.some(assumption => (assumption.tag === "Present" && same(assumption.value, path))
    || (assumption.tag === "Variant" && same(assumption.fields.path, path))
    || (assumption.tag === "IndexPresent" && same(assumption.fields.path, path)));
  if (observed) return { ...slot, required: true, nullable: false };
  return assumptions.some(assumption => assumption.tag === "NonNull" && same(assumption.value, path))
    ? { ...slot, nullable: false } : slot;
}

function selectorPrecedesInternalTag(branch: X.UnionBranch, tag: string): boolean {
  return branch.selector.tag === "InternalTag" ? branch.wire_tag !== tag
    : branch.selector.tag === "Kind" && branch.selector.value.tag !== "Object";
}

function projectableTagBranch(branches: readonly X.UnionBranch[], tag: string): X.UnionBranch | null {
  for (const branch of branches) {
    if (branch.wire_tag === tag) return branch.selector.tag === "InternalTag" ? branch : null;
    if (!selectorPrecedesInternalTag(branch, tag)) return null;
  }
  return null;
}

export function projectSlot(context: ValueContext, source: X.SlotContract, path: readonly X.PathStep[], assumptions: readonly X.ProjectionAssumption[] = []): X.ProjectionCertificate {
  const sourceObligations = X.meaningObligations(context, [source.type_ref]);
  if (sourceObligations.length > 0) return projectionFail({ tag: "Unresolved", value: sourceObligations });
  const projectContract = (fuel: number, slot: X.SlotContract, traversed: readonly X.PathStep[], remaining: readonly X.PathStep[]): X.SlotContract => {
    if (fuel === 0) return projectionFail({ tag: "Unresolved", value: [{
      type_ref: slot.type_ref, origin: { source: slot.type_ref.source, pointer: slot.type_ref.pointer },
      value_path: traversed, profile: context.profile.reference, reason: { tag: "MembershipBound" },
    }] });
    const strengthened = strengthenProjection(slot, traversed, assumptions);
    if (remaining.length === 0) return strengthened;
    const node = X.findType(context, strengthened.type_ref);
    if (node === undefined) return projectionFail({ tag: "Unresolved", value: [{
      type_ref: strengthened.type_ref, origin: { source: strengthened.type_ref.source, pointer: strengthened.type_ref.pointer },
      value_path: traversed, profile: context.profile.reference, reason: { tag: "UnresolvedType" },
    }] });
    if (node.shape.tag === "Alias") return projectContract(fuel - 1, { ...strengthened, type_ref: node.shape.fields.target }, traversed, remaining);
    const step = remaining[0]!, rest = remaining.slice(1), nextPath = [...traversed, step];
    if (node.shape.tag === "Product" && step.tag === "Field") {
      const field = node.shape.value.fields.find(candidate => candidate.wire_name === step.value);
      if (field === undefined) return projectionFail({ tag: "MissingField", fields: { ref: strengthened.type_ref, name: step.value } });
      return projectContract(fuel - 1, { type_ref: field.slot.type_ref, required: strengthened.required && field.slot.required, nullable: strengthened.nullable || field.slot.nullable }, nextPath, rest);
    }
    if (node.shape.tag === "Array" && step.tag === "Index") {
      if (!X.indexText(step.value)) return projectionFail({ tag: "WrongShape", fields: { ref: strengthened.type_ref, path: traversed } });
      const present = BigInt(step.value) < BigInt(node.shape.value.min_length ?? "0")
        || assumptions.some(assumption => assumption.tag === "IndexPresent" && same(assumption.fields.path, traversed) && assumption.fields.index === step.value);
      return projectContract(fuel - 1, { type_ref: node.shape.value.item.type_ref, required: strengthened.required && present, nullable: true }, nextPath, rest);
    }
    if (node.shape.tag === "TaggedUnion" && step.tag === "Variant") {
      if (!assumptions.some(assumption => assumption.tag === "Variant" && same(assumption.fields.path, traversed) && assumption.fields.tag === step.value)) {
        return projectionFail({ tag: "BranchAssumptionRequired", fields: { path: traversed, tag: step.value } });
      }
      const branch = node.shape.value.branches.find(candidate => candidate.wire_tag === step.value);
      if (branch === undefined) return projectionFail({ tag: "MissingVariant", fields: { ref: strengthened.type_ref, name: step.value } });
      const selected = context.profile.tag === null ? null : projectableTagBranch(node.shape.value.branches, step.value);
      if (selected === null || !same(selected, branch)) return projectionFail({ tag: "VariantSelectionUndetermined", fields: { path: traversed, tag: step.value } });
      return projectContract(fuel - 1, { ...strengthened, type_ref: branch.target }, nextPath, rest);
    }
    return projectionFail({ tag: "WrongShape", fields: { ref: strengthened.type_ref, path: traversed } });
  };
  const destination = projectContract((path.length + 1) * (context.graph.nodes.length + 1), source, [], path);
  const destinationObligations = X.meaningObligations(context, [destination.type_ref]);
  if (destinationObligations.length > 0) return projectionFail({ tag: "Unresolved", value: destinationObligations });
  return deepFreeze({ profile: context.profile.reference, source_refs: context.sources, source, path, assumptions, destination });
}

