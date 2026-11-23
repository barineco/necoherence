// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { createInterface } from "node:readline";
import { semanticComposition as C, semanticResidualRecord as R, semanticSignatures as S, semanticValues as V } from "../../../packages/typescript/adapter/dist/index.js";

function sortedExact(value) {
  if (value.tag === "Array") return { tag: "Array", items: value.items.map(item => sortedExact(item)) };
  if (value.tag === "Object") {
    return {
      tag: "Object",
      members: [...value.members]
        .sort((left, right) => V.codePointOrder(left.key, right.key))
        .map(member => ({ key: member.key, value: sortedExact(member.value) })),
    };
  }
  return value;
}

function canonicalPath(path) {
  return path.map(step => typeof step === "bigint" ? Number(step) : step);
}

const OUTCOME_STATUS = { resolved: "Resolved", residual: "Residual", stopped: "Stopped" };

function classificationRecord(evaluation, atomsOf, dispositionsOf) {
  const judgment = evaluation.ok ? evaluation.value.value : evaluation.error;
  const residuals = evaluation.ok ? (evaluation.value.kind === "resolved" ? [] : evaluation.value.residuals.values) : evaluation.error.residuals.values;
  const atoms = judgment.obligations.flatMap(obligation => atomsOf(obligation));
  return {
    status: evaluation.ok ? OUTCOME_STATUS[evaluation.value.kind] : "Failed",
    obligations: judgment.obligations,
    residuals,
    stops: atoms.filter(atom => V.classifyDispositions(dispositionsOf(atom)) === "Stopped"),
    failures: atoms.filter(atom => V.classifyDispositions(dispositionsOf(atom)) === "Failed"),
    provenance: judgment.provenance,
  };
}

function classifySemanticObligations(obligations, provenance) {
  return classificationRecord(V.classifySemanticObligations(provenance, obligations), obligation => [obligation], obligation => [V.semanticReasonDisposition(obligation.reason)]);
}

function compositionOutput(provenance, obligations) {
  return classificationRecord(C.classifyUnresolvedObligations(provenance, obligations), C.unresolvedAtoms, C.unresolvedDispositions);
}

function rejection(input, failure) {
  if (failure.tag === "Value") {
    return {
      id: input.id,
      operation: input.operation,
      status: "Rejected",
      type_ref: failure.failure.type,
      condition: failure.failure.condition,
      observed: failure.failure.observed,
      path: canonicalPath(failure.failure.path),
      trace: (failure.failure.referenceTrace ?? []).map(reference => reference.definition_name),
    };
  }
  return { id: input.id, operation: input.operation, status: "Rejected", condition: failure.tag === "Unresolved" ? "unresolved value meaning" : failure.condition };
}

function toHex(bytes) {
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

function residualRecord(input, checked) {
  V.requireEvidence(input.type_id && input.value && input.basis, "residual record input");
  const reference = checked.refs.get(input.type_id) ?? S.signatureTypeRef(input.type_id);
  const value = sortedExact(input.value);
  const validation = V.validateValue(checked.context, reference, value);
  const unresolved = validation.tag === "Failed" && validation.failure.tag === "Unresolved" ? validation.failure.obligations : [];
  const evaluation = V.classifySemanticObligations({ operation: "validate", type_ref: reference, value_path: [] }, unresolved);
  const obligations = unresolved.length === 0 ? [] : evaluation.ok ? (evaluation.value.kind === "resolved" ? [] : evaluation.value.residuals.values) : evaluation.error.residuals.values;
  if (obligations.length === 0) return { id: input.id, operation: input.operation, status: "not-unresolved" };
  const encoded = R.encodeSemanticResidual(input.basis, reference, value, obligations);
  if (!encoded.ok) return { id: input.id, operation: input.operation, status: "Rejected", condition: encoded.error.tag === "Wire" ? encoded.error.message : encoded.error.failure.operation };
  return { id: input.id, operation: input.operation, status: "encoded", bytes: toHex(encoded.value) };
}

export function evaluateSemanticInvariant(input) {
  try {
    if (input.operation === "classification") {
      if (input.domain === "composition") {
        V.requireEvidence(input.obligations && input.provenance, "classification input");
        return { id: input.id, operation: input.operation, domain: input.domain, ...compositionOutput(input.provenance, input.obligations) };
      }
      if (input.entry === "value") {
        V.requireEvidence(input.graph && input.reference, "public validation input");
        V.validated(V.validateValue(new V.ValueContext(input.graph), input.reference, sortedExact(V.toExact(input.value))), input.reference);
        return { id: input.id, operation: input.operation, status: "Accepted" };
      }
      V.requireEvidence(input.obligations && input.provenance, "classification input");
      return { id: input.id, operation: input.operation, domain: input.domain, ...classifySemanticObligations(input.obligations, input.provenance) };
    }
    if (input.operation === "wire") {
      V.requireEvidence(input.value !== null && typeof input.value === "object", "generation wire input");
      const composition = input.value.composition ?? null;
      const expected = S.decodeExpectedBasisWire({ basis: input.value.basis, observations: composition === null ? null : S.goalObservations(composition) });
      const admitted = S.admitSignatureGeneration(expected, S.signatureCanonicalJson(input.value));
      if (admitted.tag === "Failed") {
        const failure = admitted.failure;
        return failure.tag === "Decode"
          ? { id: input.id, operation: input.operation, status: "Rejected", failure_kind: "Wire", classification: failure.value.value.tag, path: failure.value.value.path }
          : { id: input.id, operation: input.operation, status: "Rejected", condition: failure.tag };
      }
      return { id: input.id, operation: input.operation, status: "Accepted", encoded: JSON.parse(S.signatureCanonicalJson(admitted.checked.input)) };
    }
    V.requireEvidence(input.library, "semantic invariant library");
    if (input.operation === "profile") {
      S.checkProfile(input.library.profile);
      return { id: input.id, operation: input.operation, status: "Accepted" };
    }
    const checked = S.checkLibrary(input.library);
    if (input.operation === "library") return { id: input.id, operation: input.operation, status: "Accepted" };
    if (input.operation === "residual_record") return residualRecord(input, checked);
    V.requireEvidence(input.type_id && input.value, "value invariant input");
    const validated = V.validateValue(checked.context, checked.refs.get(input.type_id), sortedExact(input.value));
    return validated.tag === "Ok" ? { id: input.id, operation: input.operation, status: "Accepted" } : rejection(input, validated.failure);
  } catch (error) {
    if (error instanceof V.SemanticUnresolvedError) {
      const classification = classifySemanticObligations(error.obligations, { operation: "validate", type_ref: error.reference, value_path: [] });
      return input.operation === "classification"
        ? { id: input.id, operation: input.operation, ...classification }
        : { id: input.id, operation: input.operation, status: "Unresolved", classification };
    }
    if (error instanceof S.PredicateFailure) return { id: input.id, operation: input.operation, status: "Rejected", predicate: error.predicate, path: error.location };
    return { id: input.id, operation: input.operation, status: "Rejected", condition: error instanceof Error ? error.message : "invalid input" };
  }
}

for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
  if (!line.trim()) continue;
  if (V.admissionFailure(line) === "exponent too large") {
    process.stderr.write(`${new V.WireError({ tag: "Syntax", path: "$", value: "exponent too large" }).message}\n`);
    process.exitCode = 1;
    break;
  }
  process.stdout.write(`${JSON.stringify(evaluateSemanticInvariant(JSON.parse(line)))}\n`);
}
