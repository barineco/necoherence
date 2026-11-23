// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { generation, library, sourceIdentity } from "./semantic-fixture.js";

it("admits @4 and preserves exact codec roundtrips", () => {
  const input = generation(), admitted = S.admitSignatureGeneration(S.expectedSignatureBasis(input), JSON.stringify(input));
  expect(admitted.tag).toBe("Admitted");
  if (admitted.tag !== "Admitted") return;
  const integer: V.ExactJson = { tag: "String", value: "900719925474099312345" };
  const codec = admitted.checked.codec("integer");
  expect(codec.decode(codec.encode(integer))).toEqual(integer);
});

function certificateFailure(result: ReturnType<typeof S.admitSignatureGeneration>) {
  if (result.tag !== "Failed" || result.failure.tag !== "Certificate") throw new Error("certificate failure expected");
  return result.failure.value;
}

it("rejects @3 and altered generation bases", () => {
  const input = generation();
  expect(S.admitSignatureGeneration(S.expectedSignatureBasis(input), JSON.stringify({ ...input, schema: "ncoh-checked-generation@3" }))).toMatchObject({ tag: "Failed", failure: { tag: "Decode", value: { tag: "Wire", value: { tag: "UnsupportedSchema", path: "$.schema", value: "ncoh-checked-generation@3" } } } });
  const basisGraph = certificateFailure(S.admitSignatureGeneration({ basis: { ...input.basis, graph_sha256: "0".repeat(64) }, observations: null }, JSON.stringify(input)));
  expect(basisGraph.statusAt("coordinate")).toEqual({ kind: "mismatched" });
  expect(basisGraph.statusAt("digest")).toEqual({ kind: "matched" });
  const libraryRevision = certificateFailure(S.admitSignatureGeneration(S.expectedSignatureBasis(input), JSON.stringify({ ...input, signatures: { ...input.signatures, revision: "changed" } })));
  expect(libraryRevision.statusAt("coordinate")).toEqual({ kind: "mismatched" });
  expect(libraryRevision.statusAt("digest")).toEqual({ kind: "matched" });
  const forgedGraph = { ...input.basis, graph_sha256: "0".repeat(64) };
  const forgedDigest = certificateFailure(S.admitSignatureGeneration({ basis: forgedGraph, observations: null }, JSON.stringify({ ...input, basis: forgedGraph })));
  expect(forgedDigest.statusAt("coordinate")).toEqual({ kind: "matched" });
  expect(forgedDigest.statusAt("digest")).toEqual({ kind: "mismatched" });
});

it("rejects an empty entrypoint identity before the duplicate check", () => {
  const input = generation(), [entry] = input.entrypoints;
  expect(S.admitSignatureGeneration(S.expectedSignatureBasis(input), JSON.stringify({ ...input, entrypoints: [{ ...entry!, identity: "" }] }))).toMatchObject({ tag: "Failed", failure: { tag: "EntrypointIdentityEmpty" } });
  expect(S.admitSignatureGeneration(S.expectedSignatureBasis(input), JSON.stringify({ ...input, entrypoints: [{ ...entry!, identity: "" }, { ...entry!, identity: "" }] }))).toMatchObject({ tag: "Failed", failure: { tag: "EntrypointIdentityEmpty" } });
});

it("preserves graph and metadata digest invariants", () => {
  const input = library();
  const reordered = { ...input, nodes: [...input.nodes].reverse() };
  const annotated = { ...input, annotations: [{ target: { tag: "Library" as const }, key: "description", value: { tag: "String" as const, value: "changed" } }] };
  expect(S.signatureBasis(reordered, generation(reordered).entrypoints).graph_sha256).toBe(S.signatureBasis(input, generation(input).entrypoints).graph_sha256);
  expect(S.signatureBasis(annotated, generation(annotated).entrypoints).metadata_sha256).not.toBe(S.signatureBasis(input, generation(input).entrypoints).metadata_sha256);
});

it("preserves caller sample length in the composition basis and rejects an incomplete derivation", () => {
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
  const admitted = S.admitSignatureGeneration(S.expectedSignatureBasis(exchange), JSON.stringify(exchange));
  expect(admitted.tag).toBe("Failed");
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

it("orders operation outcomes by id in the provenance projection", () => {
  const subject = definitionTargetLibrary("input");
  const definition = subject.definitions.at(-1)!;
  if (definition.shape.tag !== "Operation") throw new Error("operation fixture");
  const outcomes = [...definition.shape.value.outcomes].reverse();
  const reordered: S.TypeSignatureLibrary = {
    ...subject,
    definitions: [...subject.definitions.slice(0, -1), { ...definition, shape: { ...definition.shape, value: { ...definition.shape.value, outcomes } } }],
  };
  expect(outcomes.map(outcome => outcome.id)).toEqual(["second", "first"]);
  expect(S.signatureBasis(reordered, []).provenance_sha256).toBe(S.signatureBasis(subject, []).provenance_sha256);
  expect(S.signatureCanonicalJson(V.parseLossless("1e-100"))).toBe("0.0000000001e-90");
});

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
  expect(S.admitSignatureGeneration(S.expectedSignatureBasis(input), JSON.stringify({ ...input, signatures: invalid }))).toMatchObject({
    tag: "Failed",
    failure: { tag: "Library", value: { reference: subject.identity, predicate: "LB01", location: ["library"] } },
  });
});

it("rejects duplicate produced resource ids in an outcome as Lean LB01", () => {
  const subject = definitionTargetLibrary("input");
  const definition = subject.definitions.at(-1)!;
  if (definition.shape.tag !== "Operation") throw new Error("operation fixture");
  const [first, ...rest] = definition.shape.value.outcomes;
  const duplicated = { ...first!, produced_resources: [first!.produced_resources[0]!, first!.produced_resources[0]!] };
  const invalid = { ...subject, definitions: [...subject.definitions.slice(0, -1), { ...definition, shape: { ...definition.shape, value: { ...definition.shape.value, outcomes: [duplicated, ...rest] } } }] };
  expect(() => S.checkLibrary(invalid)).toThrow(S.PredicateFailure);
  try {
    S.checkLibrary(invalid);
  } catch (error) {
    expect(error).toMatchObject({ predicate: "LB01", location: ["library"] });
  }
});

it("treats a Symbol definition payload as an identity rather than a TypeId", () => {
  const subject = definitionTargetLibrary("Symbol");
  expect(S.checkLibrary({ ...subject, nodes: subject.nodes.filter(node => node.id !== "detached") }).library.definitions).toEqual(subject.definitions);
});

it("validates typed outcome values through the declared port contracts", () => {
  const subject = generation().signatures;
  const operation: S.OperationContract = {
    effect: { tag: "DataOnly" }, inputs: [],
    outcomes: [{ id: "success", form: { tag: "Success" }, cause: { tag: "ValueContract", fields: { origin: { source: sourceIdentity, locator: [] } } }, value_ports: [{ id: "output", contract: { type_id: "text", required: true, nullable: false } }], produced_resources: [] }],
  };
  const checked = S.checkLibrary({ ...subject, sources: [sourceIdentity], definitions: [...subject.definitions, { id: "operation", wire_identity: "Operation", shape: { tag: "Operation", value: operation } }] });
  const text = (value: string): V.ExactSlot => ({ tag: "Present", value: { tag: "String", value } });
  expect(S.validateTypedOutcome(checked, operation, { outcome: "success", values: { output: text("ok") } })).toEqual({ outcome: "success", values: { output: text("ok") } });
  expect(() => S.validateTypedOutcome(checked, operation, { outcome: "success", values: { output: { tag: "Absent" } } })).toThrow(V.SemanticValueError);
  expect(() => S.validateTypedOutcome(checked, operation, { outcome: "success", values: { output: { tag: "Present", value: { tag: "Null" } } } })).toThrow(V.SemanticValueError);
  expect(() => S.validateTypedOutcome(checked, operation, { outcome: "success", values: {} })).toThrow(V.SemanticEvidenceError);
});

it("admits an opaque library node and leaves its meaning to the value and composition checks", () => {
  const subject = generation().signatures;
  const opaque: S.TypeSignatureLibrary["nodes"][number] = { id: "opaque", shape: { tag: "Opaque", fields: { type_name: "external" } } };
  const checked = S.checkLibrary({ ...subject, nodes: [...subject.nodes, opaque] });
  const reference = checked.refs.get("opaque")!;
  expect(V.acceptsValue(checked.context, reference, { tag: "Null" })).toMatchObject({ tag: "Unresolved" });
});

const decodeStageCases: readonly (readonly [string, (input: Record<string, unknown>) => Record<string, unknown>, "Json" | "Wire", string])[] = [
  ["signatures null", input => ({ ...input, signatures: null }), "Wire", "Syntax"],
  ["signatures number with empty entrypoints", input => ({ ...input, signatures: 5, entrypoints: [] }), "Wire", "Syntax"],
  ["entrypoints empty with nodes missing", input => ({ ...input, entrypoints: [], signatures: { ...(input.signatures as object), nodes: undefined } }), "Wire", "Syntax"],
  ["duplicate entrypoints with nodes missing", input => ({ ...input, entrypoints: [...(input.entrypoints as unknown[]), ...(input.entrypoints as unknown[])], signatures: { ...(input.signatures as object), nodes: undefined } }), "Wire", "Syntax"],
  ["entrypoint identity number", input => ({ ...input, entrypoints: [{ ...(input.entrypoints as object[])[0], identity: 1 }] }), "Wire", "Syntax"],
  ["entrypoint identity null", input => ({ ...input, entrypoints: [{ ...(input.entrypoints as object[])[0], identity: null }] }), "Wire", "Syntax"],
  ["entrypoint definition number", input => ({ ...input, entrypoints: [{ ...(input.entrypoints as object[])[0], definition: 1 }] }), "Wire", "Syntax"],
  ["entrypoint extra key", input => ({ ...input, entrypoints: [{ ...(input.entrypoints as object[])[0], extra: 1 }] }), "Wire", "UnknownField"],
  ["schema mismatch before basis field type", input => ({ ...input, schema: "ncoh-checked-generation@9", basis: { ...(input.basis as object), graph_sha256: 5 } }), "Wire", "UnsupportedSchema"],
  ["schema number", input => ({ ...input, schema: 4 }), "Wire", "Syntax"],
  ["basis field number before signatures", input => ({ ...input, basis: { ...(input.basis as object), graph_sha256: 5 }, signatures: null }), "Wire", "Syntax"],
  ["extra key before schema", input => ({ ...input, schema: "ncoh-checked-generation@9", extra: 1 }), "Wire", "UnknownField"],
];

it.each(decodeStageCases)("decodes every field of the exchange in Lean order: %s", (_name, mutate, side, tag) => {
  const input = generation();
  const admitted = S.admitSignatureGeneration(S.expectedSignatureBasis(input), JSON.stringify(mutate(input as unknown as Record<string, unknown>)));
  expect(admitted).toMatchObject({ tag: "Failed", failure: { tag: "Decode", value: { tag: side, value: { tag } } } });
});

it("classifies a malformed exchange text as a JSON decode failure", () => {
  const input = generation();
  expect(S.admitSignatureGeneration(S.expectedSignatureBasis(input), "{")).toMatchObject({ tag: "Failed", failure: { tag: "Decode", value: { tag: "Json", value: { tag: "Syntax", path: "$" } } } });
  expect(S.admitSignatureGeneration(S.expectedSignatureBasis(input), "\"\\ud800\"")).toMatchObject({ tag: "Failed", failure: { tag: "Decode", value: { tag: "Json", value: { tag: "Syntax", path: "$", value: "unpaired Unicode surrogate" } } } });
});

it("decodes a generation basis with typed wire failures", () => {
  const input = generation();
  expect(() => S.decodeGenerationBasisWire({ ...input.basis, graph_sha256: 5 })).toThrow(V.WireError);
  expect(() => S.decodeGenerationBasisWire({ ...input.basis, extra: 1 })).toThrow(V.WireError);
  try { S.decodeGenerationBasisWire({ ...input.basis, extra: 1 }); } catch (error) {
    expect((error as V.WireError).failure).toEqual({ tag: "UnknownField", path: "$.extra", value: "extra" });
  }
});
