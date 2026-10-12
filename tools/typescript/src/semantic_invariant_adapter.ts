// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { semanticSignatures as S, semanticValues as V } from "necoherence";

export type SemanticInvariantInput = {
  readonly id: string;
  readonly operation: "wire" | "profile" | "library" | "value" | "inclusion" | "samples";
  readonly library?: S.TypeSignatureLibrary;
  readonly type_id?: string;
  readonly destination_type_id?: string;
  readonly value?: unknown;
  readonly max_type_obligations?: string;
  readonly max_sample_length?: string;
};
export type SemanticInvariantOutput = {
  readonly id: string;
  readonly operation: SemanticInvariantInput["operation"];
  readonly status: "Accepted" | "Rejected" | "Compatible" | "Incompatible" | "Unknown";
  readonly condition?: string;
  readonly path?: readonly (string | number)[];
  readonly trace?: readonly string[];
  readonly type_ref?: V.TypeRef;
  readonly predicate?: string;
  readonly sample_count?: string;
  readonly sample_bound?: boolean;
  readonly encoded?: unknown;
};

function canonicalPath(path: readonly (string | bigint)[]): readonly (string | number)[] {
  return path.map(step => typeof step === "bigint" ? Number(step) : step);
}

export function evaluateSemanticInvariant(input: SemanticInvariantInput): SemanticInvariantOutput {
  try {
    if (input.operation === "wire") {
      V.requireEvidence(input.value !== null && typeof input.value === "object", "generation wire input");
      const wire = input.value as S.SignatureGenerationInput;
      const expected = S.decodeGenerationBasisWire(wire.basis);
      const admitted = S.admitSignatureGeneration(expected, S.signatureCanonicalJson(wire));
      V.requireEvidence(admitted.tag === "Admitted", admitted.tag === "Failed" ? admitted.failure.tag : "generation admission");
      return {
        id: input.id,
        operation: input.operation,
        status: "Accepted",
        encoded: JSON.parse(S.signatureCanonicalJson(admitted.checked.input)),
      };
    }
    V.requireEvidence(input.library, "semantic invariant library");
    if (input.operation === "profile") { S.checkProfile(input.library.profile as V.VersionedSemanticProfile); return { id: input.id, operation: input.operation, status: "Accepted" }; }
    const checked = S.checkLibrary(input.library);
    if (input.operation === "library") return { id: input.id, operation: input.operation, status: "Accepted" };
    if (input.operation === "value") {
      V.requireEvidence(input.type_id && input.value, "value invariant input");
      checked.context.validate(checked.refs.get(input.type_id)!, input.value as V.ExactJson);
      return { id: input.id, operation: input.operation, status: "Accepted" };
    }
    if (input.operation === "inclusion") {
      V.requireEvidence(input.type_id && input.destination_type_id, "inclusion invariant input");
      const result = S.checkAssignable(checked.context, { type_ref: checked.refs.get(input.type_id)!, required: true, nullable: false }, { type_ref: checked.refs.get(input.destination_type_id)!, required: true, nullable: false });
      return { id: input.id, operation: input.operation, status: result.tag };
    }
    V.requireEvidence(input.type_id, "sample invariant input");
    const samples = S.sampleValueFuel(
      checked.context,
      {
        max_type_obligations: input.max_type_obligations ?? "10000",
        max_sample_length: input.max_sample_length ?? "32",
      },
      BigInt(input.max_type_obligations ?? String(checked.context.graph.nodes.length + 1)),
      [],
      checked.refs.get(input.type_id)!,
    );
    return {
      id: input.id,
      operation: input.operation,
      status: samples.values.every(value => checked.context.accepts(
        { type_ref: checked.refs.get(input.type_id!)!, required: true, nullable: false },
        { tag: "Present", value },
      )) ? "Accepted" : "Rejected",
      sample_bound: samples.obligations.some(obligation => obligation.tag === "SampleBound"),
      sample_count: String(samples.values.length),
    };
  } catch (error) {
    if (error instanceof S.PredicateFailure) return { id: input.id, operation: input.operation, status: "Rejected", predicate: error.predicate, path: error.location };
    if (error instanceof V.SemanticValueError) return {
      id: input.id,
      operation: input.operation,
      status: "Rejected",
      type_ref: error.failure.type,
      condition: error.failure.condition,
      path: canonicalPath(error.failure.path),
      trace: (error.failure.referenceTrace ?? []).map(reference => reference.definition_name),
    };
    return { id: input.id, operation: input.operation, status: "Rejected", condition: error instanceof Error ? error.message : "invalid input" };
  }
}
