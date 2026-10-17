// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { generation, library, sourceIdentity } from "./semantic-fixture.js";

it("admits @4 and preserves exact codec roundtrips", () => {
  const input = generation(), admitted = S.admitSignatureGeneration(input.basis, JSON.stringify(input));
  expect(admitted.tag).toBe("Admitted");
  if (admitted.tag !== "Admitted") return;
  const integer: V.ExactJson = { tag: "String", value: "900719925474099312345" };
  const codec = admitted.checked.codec("integer");
  expect(codec.decode(codec.encode(integer))).toEqual(integer);
});

it("rejects @3 and altered generation bases", () => {
  const input = generation();
  expect(S.admitSignatureGeneration(input.basis, JSON.stringify({ ...input, schema: "ncoh-checked-generation@3" }))).toMatchObject({ tag: "Failed", failure: { tag: "UnsupportedSchema" } });
  expect(S.admitSignatureGeneration({ ...input.basis, graph_sha256: "0".repeat(64) }, JSON.stringify(input))).toMatchObject({ tag: "Failed", failure: { tag: "BasisMismatch" } });
});

it("preserves graph and metadata digest invariants", () => {
  const input = library();
  const reordered = { ...input, nodes: [...input.nodes].reverse() };
  const annotated = { ...input, annotations: [{ target: { tag: "Library" as const }, key: "description", value: { tag: "String" as const, value: "changed" } }] };
  expect(S.signatureBasis(reordered, generation(reordered).entrypoints).graph_sha256).toBe(S.signatureBasis(input, generation(input).entrypoints).graph_sha256);
  expect(S.signatureBasis(annotated, generation(annotated).entrypoints).metadata_sha256).not.toBe(S.signatureBasis(input, generation(input).entrypoints).metadata_sha256);
});

it("preserves caller sample length and its composition basis", () => {
  const input = generation();
  const problem = {
    identity: "finite", revision: "1", basis: S.signatureBasis(input.signatures, []),
    signatures: [], initial_inputs: [], initial_resources: [],
    goal: { outputs: [], failures: [], final_resources: [] },
    invocation_domain: { identity: "finite", revision: "1", sites: [], permitted_projections: [], permitted_constructions: [], permitted_transforms: [], guards: [] },
    allowed_effects: [], explicit_order: [], selection_policy: { tag: "AnyFeasible" },
    bounds: { max_expanded_states: "10000", max_binding_candidates: "100000", max_type_obligations: "10000", max_branch_nodes: "100000", resource_bounds: null, max_sample_length: "59" },
  };
  const composition = { problem, derivation: { witness: { input_snapshot: structuredClone(problem) } } };
  const basis = S.signatureBasis(input.signatures, input.entrypoints, composition);
  const exchange = { ...input, composition, basis };
  const admitted = S.admitSignatureGeneration(basis, JSON.stringify(exchange));
  expect(admitted.tag).toBe("Admitted");
  if (admitted.tag !== "Admitted") return;
  expect(admitted.checked.input.composition).toEqual(composition);
  expect(admitted.checked.input.basis).toEqual(basis);
  const changed = structuredClone(composition);
  changed.problem.bounds.max_sample_length = "58";
  changed.derivation.witness.input_snapshot.bounds.max_sample_length = "58";
  expect(S.signatureBasis(input.signatures, input.entrypoints, changed).problem_sha256).not.toBe(basis.problem_sha256);
});

function definitionTargetLibrary(referenceKind: string): S.TypeSignatureLibrary {
  const value = library();
  const port = (id: string, type_id: string): S.SignaturePort => ({ id, contract: { type_id, required: true, nullable: false } });
  const shape: S.SignatureDefinition["shape"] = referenceKind === "Value" || referenceKind === "Message" || referenceKind === "Symbol"
    ? { tag: referenceKind, value: "detached" }
    : {
      tag: "Operation",
      value: {
        effect: { tag: "DataOnly" },
        inputs: [port("kept", "text"), port("input", referenceKind === "input" ? "detached" : "text")],
        outcomes: ["first", "second"].map(id => ({
          id, form: { tag: "Success" },
          cause: { tag: "ValueContract", fields: { origin: { source: sourceIdentity, locator: [] } } },
          value_ports: [port("kept", "text"), port("output", id === "second" && referenceKind === "output" ? "detached" : "text")],
          produced_resources: [{
            id: "resource", token_type: id === "second" && referenceKind === "resource" ? "detached" : "text",
            revision: "1", quantity: "1", provenance: "declared",
          }],
        })),
      },
    };
  return {
    ...value, sources: [sourceIdentity],
    nodes: [...value.nodes, { id: "detached", shape: { tag: "Unit" } }],
    definitions: [...value.definitions, { id: "secondary", wire_identity: "Secondary", shape }],
  };
}

it.each(["Value", "Message", "input", "output", "resource"])("classifies missing %s definition targets as Lean LB01", referenceKind => {
  const subject = definitionTargetLibrary(referenceKind);
  expect(S.checkLibrary(subject).library).toEqual(subject);
  const entrypoints = [{ identity: "Text", definition: "text" }];
  const input = { ...generation(subject), entrypoints, basis: S.signatureBasis(subject, entrypoints) };
  const invalid = { ...subject, nodes: subject.nodes.filter(node => node.id !== "detached") };
  expect(() => S.checkLibrary(invalid)).toThrow(S.PredicateFailure);
  try {
    S.checkLibrary(invalid);
  } catch (error) {
    expect(error).toMatchObject({ reference: subject.identity, predicate: "LB01", location: ["library"] });
  }
  expect(S.admitSignatureGeneration(input.basis, JSON.stringify({ ...input, signatures: invalid }))).toMatchObject({
    tag: "Failed",
    failure: { tag: "Predicate", value: { reference: subject.identity, predicate: "LB01", location: ["library"] } },
  });
});

it("treats a Symbol definition payload as an identity rather than a TypeId", () => {
  const subject = definitionTargetLibrary("Symbol");
  expect(S.checkLibrary({ ...subject, nodes: subject.nodes.filter(node => node.id !== "detached") }).library.definitions).toEqual(subject.definitions);
});
