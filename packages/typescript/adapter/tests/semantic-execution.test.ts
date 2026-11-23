// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import * as C from "../src/semantic_composition.js";
import { compositionAdmissionToken } from "../src/composition_admission_token.js";
import * as E from "../src/semantic_execution.js";
import * as N from "../src/network-effect.js";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import * as W from "../src/signature_composition_wire.js";
import { projectSlot } from "../src/signature_verification.js";
import { generation } from "./semantic-fixture.js";

const text: V.ExactSlot = { tag: "Present", value: { tag: "String", value: "accepted" } };
const integer: V.ExactSlot = { tag: "Present", value: { tag: "Integer", value: "1" } };
const functionRef: C.FunctionRef = { identity: "provider", revision: "1", contentDigest: "b".repeat(64) };
const otherFunctionRef: C.FunctionRef = { identity: "other", revision: "1", contentDigest: "c".repeat(64) };
const bounds: C.SearchBounds = {
  maxExpandedStates: 16n, maxBindingCandidates: 64n, maxTypeObligations: 64n, maxBranchNodes: 64n, maxSampleLength: 64n,
  resourceBounds: null,
};

function slotBinding(prepared: C.PreparedCompositionInput, producer: C.ProducerRef): C.BindingExpr {
  const contract = prepared.input.initialInputs[0]!.contract;
  const projection = projectSlot(prepared.context, contract, [], []);
  const shape = prepared.context.node(contract.type_ref).shape;
  const certificate: C.InclusionCertificate = { basis: V.semanticBasisOf(prepared.context), source: contract, destination: contract, emptyTypes: [], pairs: [{ pair: { source: contract, destination: contract, sourceTag: null }, sourceShape: shape, destinationShape: shape, rule: { tag: "SameDefinedType" }, children: [] }], root: 0n };
  return { tag: "Source", fields: { value: { producer, path: [] }, projection, compatibility: { tag: "Inclusion", value: certificate } } };
}

function checkedExecution(effect: C.CompositionEffect, guarded = false): {
  readonly checked: E.AdmittedComposition;
  readonly prepared: C.PreparedCompositionInput;
  readonly input: C.CompositionInput;
  readonly successProvider: E.Provider;
  readonly failureProvider: E.Provider;
} {
  const library = S.checkLibrary(generation().signatures);
  const contract: V.SlotContract = { type_ref: library.refs.get("text")!, required: true, nullable: false };
  const signature: C.FunctionSignature = {
    reference: functionRef,
    form: effect.tag === "HttpRequestResponse" ? { tag: "Operation", value: { source: contract.type_ref.source, name: "provider" } } : { tag: "Pure" },
    effect,
    inputs: [{ id: "input", contract, sourceConstraint: { tag: "InitialOnly", fields: { input: "input", path: [] } }, resourceRequirement: null }],
    outcomes: [
      { id: "ok", form: { tag: "Success" }, valuePorts: [{ id: "output", contract, resourceProduction: null }], producedResources: [] },
      { id: "declined", form: { tag: "DeclaredFailure" }, valuePorts: [{ id: "failure", contract, resourceProduction: null }], producedResources: [] },
    ],
    resourceInputs: [], assumptionRef: "provider semantics", handlesFailure: null,
  };
  const input: C.CompositionInput = {
    identity: "execution", revision: "1", basis: V.semanticBasisOf(library.context), signatures: [signature],
    initialInputs: [{ id: "input", contract, source: { tag: "Argument" }, resource: null }], initialResources: [],
    goal: {
      outputs: [{ id: "result", contract, sourceConstraint: { tag: "ProducedBy", fields: { site: "site", outcome: "ok", port: "output", path: [] } } }],
      failures: [{ id: "declined", origin: { tag: "Function", fields: { function: functionRef, outcome: "declined" } }, contract, finalResources: [] }],
      finalResources: [],
    },
    invocationDomain: {
      identity: "execution", revision: "1", sites: [{ id: "site", function: functionRef }], permittedProjections: [], permittedConstructions: [],
      permittedTransforms: [], guards: guarded ? [{ id: "presence", sourceType: contract.type_ref, path: [], kind: { tag: "Presence" } }] : [],
    },
    allowedEffects: [effect], explicitOrder: [], selectionPolicy: { tag: "AnyFeasible" }, bounds,
  };
  const admitted = C.prepareDirectComposition(library.context, input, () => null, () => []);
  if (admitted.tag === "Failed") throw new Error(JSON.stringify(admitted.failure));
  const prepared = admitted.value;
  const inputBinding = slotBinding(prepared, { tag: "Initial", value: "input" });
  const invocation: C.InvocationPlan = { site: "site", function: functionRef, bindings: [["input", inputBinding]], resources: [] };
  const output = (outcome: string, port: string): C.BindingExpr => slotBinding(prepared, { tag: "InvocationOutcome", fields: { site: "site", outcome, port } });
  const success: C.PlanTree = { tag: "ReturnValue", fields: { rank: 1n, terminal: { tag: "Success", value: [["result", output("ok", "output")]] } } };
  const failure: C.PlanTree = { tag: "ReturnValue", fields: { rank: 1n, terminal: { tag: "Failure", fields: { embedding: "declined", value: output("declined", "failure") } } } };
  const invoke: C.PlanTree = { tag: "Invoke", fields: { rank: 0n, invocation, arms: [["ok", success], ["declined", failure]], emptyOutcomes: [] } };
  const guardedSuccess: C.PlanTree = { tag: "ReturnValue", fields: { ...success.fields, rank: 2n } };
  const guardedFailure: C.PlanTree = { tag: "ReturnValue", fields: { ...failure.fields, rank: 2n } };
  const guardedInvoke: C.PlanTree = { tag: "Invoke", fields: { rank: 1n, invocation, arms: [["ok", guardedSuccess], ["declined", guardedFailure]], emptyOutcomes: [] } };
  const tree: C.PlanTree = guarded ? {
    tag: "Guard", fields: {
      rank: 0n, guard: "presence", inspected: { producer: { tag: "Initial", value: "input" }, path: [] },
      arms: [[{ tag: "Present" }, guardedInvoke]],
    },
  } : invoke;
  const checked = E.AdmittedComposition.admit(compositionAdmissionToken, prepared, { inputIdentity: input.identity, inputRevision: input.revision, root: tree });
  return {
    checked, prepared, input,
    successProvider: { reference: functionRef, implementation: { tag: "Pure", callback: () => ({ tag: "Ok", value: { outcome: "ok", outputs: [["output", text]] } }) } },
    failureProvider: { reference: functionRef, implementation: { tag: "Pure", callback: () => ({ tag: "Ok", value: { outcome: "declined", outputs: [["failure", text]] } }) } },
  };
}

function attemptInput(): N.AttemptInput {
  return {
    attempt: { logical: { kind: "semantic-execution", provenance: "test", revision: 0n }, ordinal: 0n },
    instruction: { method: "GET", target: "https://example.test/", headers: [], body: new Uint8Array() }, deadline: null,
    configuration: { requestBodyLimit: 1024n, responseBodyLimit: 1024n, cancellation: null, monotonicClock: null },
  };
}

function httpProvider(completed = false): E.Provider {
  return {
    reference: functionRef,
    implementation: { tag: "PreparedHttp", owner: {
      prepare: () => ({ tag: "Ok", value: completed ? { tag: "Completed", result: { outcome: "ok", outputs: [["output", text]] } } : { tag: "Ready", input: attemptInput() } }),
      decode: () => ({ tag: "Ok", value: { outcome: "ok", outputs: [["output", text]] } }),
    } },
  };
}

function pendingHttp(provider = httpProvider()): {
  readonly sent: Extract<E.Progress, { readonly tag: "Pending" }>;
  readonly observing: Extract<E.Progress, { readonly tag: "Pending" }>;
} {
  const fixture = checkedExecution({ tag: "HttpRequestResponse" });
  const started = E.start(fixture.checked, [provider], [["input", text]], N.emptyNetworkState());
  if (started.tag !== "Ok" || started.value.tag !== "Pending" || started.value.instruction.tag !== "Send") throw new Error("expected send instruction");
  const startObservation: N.StartObservation = { tag: "Started", attempt: attemptInput().attempt, handle: { value: "handle" } };
  const resumed = E.resume(started.value.execution, { tag: "Start", observation: startObservation });
  if (resumed.tag !== "Ok" || resumed.value.tag !== "Pending" || resumed.value.instruction.tag !== "Observe") throw new Error("expected observe instruction");
  return { sent: started.value, observing: resumed.value };
}

function responseObservation(delivery = 0n): E.ExecutionObservation {
  const input = attemptInput(), handle = { value: "handle" }, response: N.RawHttpResponse = { status: 200, headers: [], body: new Uint8Array() };
  return { tag: "Host", observation: { tag: "Delivered", delivery, observation: {
    tag: "ResponseObservation", attempt: input.attempt, handle, sourceSequence: { tag: "some", value: delivery }, response,
    provenance: "WireObserved", effect: { tag: "EffectOccurred", witness: { attempt: input.attempt, source: "Adapter", evidence: { value: "response" } } },
  } } };
}

describe("semantic execution", () => {
  it("starts from the owned prepared input after the caller input is changed", () => {
    const fixture = checkedExecution({ tag: "PureFunction" });
    (fixture.input.goal.outputs[0]!.contract as { required: boolean }).required = false;
    expect(E.start(fixture.checked, [fixture.successProvider], [["input", text]], N.emptyNetworkState())).toMatchObject({
      tag: "Ok", value: { tag: "Completed", result: { tag: "Success", outputs: [["result", text]] } },
    });
  });

  it("completes a pure provider synchronously", () => {
    const fixture = checkedExecution({ tag: "PureFunction" });
    expect(E.start(fixture.checked, [fixture.successProvider], [["input", text]], N.emptyNetworkState())).toMatchObject({
      tag: "Ok", value: { tag: "Completed", result: { tag: "Success", outputs: [["result", text]] } },
    });
  });

  it("returns send and observe instructions and completes after the HTTP response", () => {
    const pending = pendingHttp();
    expect(pending.sent.instruction.tag).toBe("Send");
    expect(pending.observing.instruction.tag).toBe("Observe");
    expect(E.resume(pending.observing.execution, responseObservation())).toMatchObject({
      tag: "Ok", value: { tag: "Completed", result: { tag: "Success", outputs: [["result", text]] } },
    });
  });

  it("continues a completed prepared HTTP call without a network instruction", () => {
    const fixture = checkedExecution({ tag: "HttpRequestResponse" });
    const run = E.start(fixture.checked, [httpProvider(true)], [["input", text]], N.emptyNetworkState());
    expect(run).toMatchObject({ tag: "Ok", value: { tag: "Completed", result: { tag: "Success" } } });
    if (run.tag === "Ok" && run.value.tag === "Completed") expect(N.networkAttempts(run.value.network)).toEqual([]);
  });

  it("takes the declared failure outcome and the guard arm selected by the argument", () => {
    const fixture = checkedExecution({ tag: "PureFunction" }, true);
    expect(E.start(fixture.checked, [fixture.failureProvider], [["input", text]], N.emptyNetworkState())).toMatchObject({
      tag: "Ok", value: { tag: "Completed", result: { tag: "Failure", embedding: "declined", value: text } },
    });
  });

  it("reports provider coverage, effect, missing arguments, and output validation with ExecutionFailure constructors", () => {
    const pure = checkedExecution({ tag: "PureFunction" });
    expect(E.start(pure.checked, [{ ...pure.successProvider, reference: otherFunctionRef }], [["input", text]], N.emptyNetworkState())).toMatchObject({ tag: "Failed", failure: { cause: { tag: "MissingProvider" } } });
    const wrongEffect: E.Provider = { reference: functionRef, implementation: { tag: "PreparedHttp", owner: { prepare: () => ({ tag: "Ok", value: { tag: "Ready", input: attemptInput() } }), decode: () => ({ tag: "Ok", value: { outcome: "ok", outputs: [["output", text]] } }) } } };
    expect(E.start(pure.checked, [wrongEffect], [["input", text]], N.emptyNetworkState())).toMatchObject({ tag: "Failed", failure: { cause: { tag: "ProviderEffect" } } });
    expect(E.start(pure.checked, [pure.successProvider], [], N.emptyNetworkState())).toMatchObject({ tag: "Failed", failure: { cause: { tag: "MissingArgument", id: "input" } } });
    const wrongOutput: E.Provider = { reference: functionRef, implementation: { tag: "Pure", callback: () => ({ tag: "Ok", value: { outcome: "ok", outputs: [["output", integer]] } }) } };
    expect(E.start(pure.checked, [wrongOutput], [["input", text]], N.emptyNetworkState())).toMatchObject({ tag: "Failed", failure: { cause: { tag: "Value" } } });
  });

  it("rejects resume without pending state and an observation of the wrong kind", () => {
    const pending = pendingHttp().sent;
    const copied = { ...pending.execution, pending: null } as E.Execution;
    expect(() => E.resume(copied, { tag: "Host", observation: { tag: "Pending", attempt: attemptInput().attempt, handle: { value: "handle" } } })).toThrow(/execution authority/);
    expect(E.resume(pending.execution, responseObservation())).toMatchObject({ tag: "Failed", failure: { cause: { tag: "InvalidPlan", condition: "network observation kind mismatch" } } });
  });

  it("does not admit a copied execution with a substituted network state", () => {
    const pending = pendingHttp().observing, first = E.resume(pending.execution, responseObservation());
    if (first.tag !== "Ok" || first.value.tag !== "Completed") throw new Error("expected terminal response");
    const copied = { ...pending.execution, network: first.value.network } as E.Execution;
    expect(() => E.resume(copied, responseObservation())).toThrow(/execution authority/);
  });
});
