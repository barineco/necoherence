// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import * as C from "../src/semantic_composition.js";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import * as W from "../src/signature_composition_wire.js";
import { library } from "./semantic-fixture.js";

const checked = S.checkLibrary(library());
const textRef = checked.refs.get("text")!;
const textContract: V.SlotContract = { type_ref: textRef, required: true, nullable: false };
const bounds: C.SearchBounds = { maxExpandedStates: 10n, maxBindingCandidates: 20n, maxTypeObligations: 30n, maxBranchNodes: 40n, maxSampleLength: 5n, resourceBounds: null };

function validInput(): C.CompositionInput {
  return {
    identity: "composition", revision: "1", basis: V.semanticBasisOf(checked.context), signatures: [],
    initialInputs: [{ id: "argument", contract: textContract, source: { tag: "Argument" }, resource: null }],
    initialResources: [],
    goal: { outputs: [{ id: "result", contract: textContract, sourceConstraint: { tag: "InitialOnly", fields: { input: "argument", path: [] } } }], failures: [], finalResources: [] },
    invocationDomain: { identity: "domain", revision: "1", sites: [], permittedProjections: [], permittedConstructions: [], permittedTransforms: [], guards: [] },
    allowedEffects: [], explicitOrder: [], selectionPolicy: null, bounds,
  };
}

const operationChecker: C.OperationChecker = () => null;
const operationMeaning: C.OperationMeaning = () => [];

function failure(input: C.CompositionInput): C.CompositionInputFailure {
  const result = C.prepareDirectComposition(checked.context, input, operationChecker, operationMeaning);
  expect(result.tag).toBe("Failed");
  if (result.tag === "Ok") throw new Error("expected composition input failure");
  return result.failure;
}

function problemWire(): Record<string, unknown> {
  return {
    identity: "composition",
    revision: "1",
    basis: S.signatureBasis(checked.library, []),
    signatures: [],
    initial_inputs: [{ id: "argument", contract: { type_id: "text", required: true, nullable: false }, source: { tag: "Argument" }, resource: null }],
    initial_resources: [],
    goal: { outputs: [{ id: "result", contract: { type_id: "text", required: true, nullable: false }, source_constraint: { tag: "InitialOnly", fields: { input: "argument", path: [] } } }], failures: [], final_resources: [] },
    invocation_domain: { identity: "domain", revision: "1", sites: [], permitted_projections: [], permitted_constructions: [], permitted_transforms: [], guards: [] },
    allowed_effects: [],
    explicit_order: [],
    selection_policy: null,
    bounds: { max_expanded_states: "10", max_binding_candidates: "20", max_type_obligations: "30", max_branch_nodes: "40", resource_bounds: null, max_sample_length: "5" },
  };
}

describe("composition input wire", () => {
  it("decodes and encodes the exact input JSON", () => {
    const source = problemWire();
    const wire = W.decodeCompositionInput(checked, source);
    expect(W.encodeCompositionInput(wire)).toEqual(source);
    expect(wire.decoded.input.bounds.maxBranchNodes).toBe(40n);
  });

  it("rejects an unknown key", () => {
    expect(() => W.decodeCompositionInput(checked, { ...problemWire(), extra: true })).toThrow(/UnknownField/);
  });

  it("rejects a missing key", () => {
    const { bounds: _, ...missing } = problemWire();
    expect(() => W.decodeCompositionInput(checked, missing)).toThrow(/Syntax:.*missing field/);
  });

  it("rejects an unknown tag", () => {
    expect(() => W.decodeCompositionInput(checked, { ...problemWire(), allowed_effects: [{ tag: "UnknownEffect" }] })).toThrow(/UnknownTag/);
  });
});

describe("validateCompositionInput failure order", () => {
  it("returns BasisMismatch", () => {
    const input = validInput();
    expect(failure({ ...input, basis: { ...input.basis, profile: { ...input.basis.profile, reference: { ...input.basis.profile.reference, identity: "different" } } } }).tag).toBe("BasisMismatch");
  });

  it("returns DuplicateIdentity", () => {
    const input = validInput();
    expect(failure({ ...input, initialInputs: [...input.initialInputs, input.initialInputs[0]!] }).tag).toBe("DuplicateIdentity");
  });

  it("returns UnresolvedType", () => {
    const input = validInput();
    const missing: V.TypeRef = { ...textRef, definition_name: "missing" };
    expect(failure({ ...input, initialInputs: [{ ...input.initialInputs[0]!, contract: { ...textContract, type_ref: missing } }] }).tag).toBe("UnresolvedType");
  });

  it("returns UnresolvedFunction", () => {
    const input = validInput(), reference: C.FunctionRef = { identity: "missing", revision: "1", contentDigest: "a".repeat(64) };
    expect(failure({ ...input, invocationDomain: { ...input.invocationDomain, sites: [{ id: "site", function: reference }] } }).tag).toBe("UnresolvedFunction");
  });

  it("returns InvalidSignature", () => {
    const input = validInput(), signature: C.FunctionSignature = { reference: { identity: "", revision: "1", contentDigest: "a".repeat(64) }, form: { tag: "Pure" }, effect: { tag: "PureFunction" }, inputs: [], outcomes: [], resourceInputs: [], assumptionRef: "assumption", handlesFailure: null };
    expect(failure({ ...input, signatures: [signature] }).tag).toBe("InvalidSignature");
  });

  it("returns InvalidInitialValue", () => {
    const input = validInput();
    expect(failure({ ...input, initialInputs: [{ ...input.initialInputs[0]!, source: { tag: "SuppliedValue", value: { tag: "Present", value: { tag: "Integer", value: "1" } } } }] }).tag).toBe("InvalidInitialValue");
  });

  it("returns EmptyGoal", () => {
    const input = validInput();
    expect(failure({ ...input, goal: { ...input.goal, outputs: [] } }).tag).toBe("EmptyGoal");
  });

  it("returns InvalidResourceDeclaration", () => {
    const input = validInput();
    expect(failure({ ...input, initialInputs: [{ ...input.initialInputs[0]!, resource: "missing" }] }).tag).toBe("InvalidResourceDeclaration");
  });
});

describe("PreparedCompositionInput authority", () => {
  it("is created by preparation", () => {
    const result = C.prepareDirectComposition(checked.context, validInput(), operationChecker, operationMeaning);
    expect(result.tag).toBe("Ok");
    if (result.tag === "Ok") expect(() => C.requirePreparedCompositionInput(result.value)).not.toThrow();
  });

  it("rejects construction without the module token", () => {
    expect(() => Reflect.construct(C.PreparedCompositionInput, [Symbol("outside"), checked.context, validInput(), operationChecker, operationMeaning, []])).toThrow(/admission authority/);
  });
});
