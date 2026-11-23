// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { readFileSync } from "node:fs";
import * as E from "../../packages/typescript/adapter/src/semantic_execution.js";
import * as N from "../../packages/typescript/adapter/src/network-effect.js";
import { networkFailureJson } from "./network_failure.js";
import { headerFields } from "./wire_bytes.js";
import * as S from "../../packages/typescript/adapter/src/semantic_signatures.js";
import type * as C from "../../packages/typescript/adapter/src/semantic_composition.js";
import * as V from "../../packages/typescript/adapter/src/semantic_values.js";

type InputCase = Record<string, any>;

function slot(value: any): V.ExactSlot {
  if (value.tag === "absent") return { tag: "Absent" };
  if (value.tag === "null") return { tag: "Null" };
  return { tag: "Present", value: V.toExact(value.value) };
}

function slotJson(value: V.ExactSlot): any {
  if (value.tag === "Absent") return { tag: "absent" };
  if (value.tag === "Null") return { tag: "null" };
  return { tag: "present", value: V.fromExact(value.value) };
}

function attemptInput(description: any): N.AttemptInput {
  return {
    attempt: { logical: { kind: "semantic", provenance: description.provenance ?? "comparison", revision: 1n }, ordinal: BigInt(description.ordinal ?? 0) },
    instruction: { method: description.method, target: description.target, headers: headerFields(description.headers), body: Uint8Array.from(description.body) },
    deadline: null,
    configuration: { requestBodyLimit: 1024n, responseBodyLimit: 1024n, cancellation: null, monotonicClock: null },
  };
}

function callResult(description: any): E.CallResult {
  return { outcome: description.outcome, outputs: description.outputs.map((value: any) => [value.id, slot(value.value)] as const) };
}

function nested(constructor: string, arguments_: any[] = []): any {
  return { constructor, arguments: arguments_ };
}

function typeJson(value: any): any {
  const source = value.source;
  return { source: { repository: source.repository, revision: source.revision, path: source.path,
    contentDigest: source.content_digest, documentId: source.document_id,
    declaredRevision: source.declared_revision ?? null }, definition: value.definition_name, pointer: value.pointer };
}

function pathJson(value: readonly any[]): any[] {
  return value.map(item => typeof item === "bigint" ? { index: Number(item) } : { field: item });
}

function producerJson(value: C.ProducerRef): any {
  return value.tag === "Initial" ? nested("initial", [value.value])
    : nested("invocationOutcome", [value.fields.site, value.fields.outcome, value.fields.port]);
}

function valueRefJson(value: C.ValueRef): any {
  return { producer: producerJson(value.producer), path: value.path.map(step => step.tag === "Field" ? { field: step.value } : step.tag === "Index" ? { index: Number(step.value) } : { variant: step.value }) };
}

function lotJson(value: C.ResourceLotRef): any {
  return value.tag === "Initial" ? nested("initial", [value.value])
    : nested("produced", [value.fields.site, value.fields.outcome, value.fields.production]);
}

function semanticReasonJson(value: any): any {
  const tag = String(value.tag);
  return nested(tag[0]!.toLowerCase() + tag.slice(1), Object.hasOwn(value, "value") ? [value.value] : []);
}

function semanticObligationJson(value: any): any {
  return {
    typeRef: typeJson(value.type_ref),
    valuePath: value.value_path.map((step: any) => step.tag === "Field" ? { field: step.value } : step.tag === "Index" ? { index: Number(step.value) } : { variant: step.value }),
    reason: semanticReasonJson(value.reason),
  };
}

function validationFailureJson(value: V.ValidationFailure): any {
  if (value.tag === "Unresolved") return nested("unresolved", [value.obligations.map(semanticObligationJson)]);
  if (value.tag === "CertificateMismatch") return nested("certificateMismatch", [value.condition]);
  const failure = value.failure;
  const reference = typeJson(failure.type);
  return nested("value", [{
    typeRef: reference,
    definitionRef: { source: reference.source, name: failure.type.definition_name },
    origin: { source: reference.source, pointer: failure.type.pointer },
    valuePath: pathJson(failure.path),
    condition: failure.condition,
    observed: failure.observed,
    referenceTrace: (failure.referenceTrace ?? []).map(typeJson),
  }]);
}

function providers(testCase: InputCase, references: C.FunctionRef[]): E.Provider[] {
  return testCase.providers.map((description: any): E.Provider => {
    const providerReference = description.reference === "declared" ? references[description.signature ?? 0]! : { identity: "other", revision: "1", contentDigest: "0".repeat(64) };
    if (description.effect === "pure") {
      const returned = callResult(description);
      return { reference: providerReference, implementation: { tag: "Pure", callback: () => ({ tag: "Ok", value: returned }) } };
    }
    const prepared = description.prepare[0];
    return { reference: providerReference, implementation: { tag: "PreparedHttp", owner: {
      prepare: () => ({ tag: "Ok", value: prepared.tag === "completed"
        ? { tag: "Completed", result: callResult(prepared) }
        : { tag: "Ready", input: attemptInput(prepared.request) } }),
      decode: response => {
        const decoded = description.decode.find((value: any) => value.status === response.status);
        if (!decoded) throw new Error(`missing decode behavior for status ${response.status}`);
        return decoded.failure
          ? { tag: "Failed", failure: { tag: "Provider", site: "operation", message: decoded.failure.message } }
          : { tag: "Ok", value: { outcome: decoded.outcome, outputs: decoded.outputs.map((value: any) => [value.id, slot(value.value)] as const) } };
      },
    } } };
  });
}

function failureJson(failure: E.ExecutionFailure): any {
  switch (failure.tag) {
    case "MissingArgument": return { tag: failure.tag, input: failure.id };
    case "ArgumentCoverage": case "ProviderCoverage": case "InvalidPlan": return { tag: failure.tag, condition: failure.condition };
    case "MissingProvider": case "ProviderEffect": return { tag: failure.tag, function: failure.function };
    case "Provider": return { tag: failure.tag, site: failure.site, message: failure.message };
    case "InvalidOutcome": return { tag: failure.tag, site: failure.site, outcome: failure.outcome };
    case "Resource": return { tag: failure.tag, lot: lotJson(failure.lot), condition: failure.condition };
    case "NetworkTerminal": return { tag: failure.tag, outcome: failure.terminal.outcome.tag,
      stage: failure.terminal.outcome.tag === "Failed" ? failure.terminal.outcome.failure.stage : null,
      cause: failure.terminal.outcome.tag === "Failed" ? failure.terminal.outcome.failure.cause.tag : null,
      effect: failure.terminal.effect.tag,
      reason: failure.terminal.effect.tag === "Unknown" ? failure.terminal.effect.reason : null };
    case "Network": return { tag: failure.tag, detail: networkFailureJson(failure.failure) };
    case "Value": return { tag: failure.tag, detail: validationFailureJson(failure.failure) };
    case "MissingValue": return { tag: failure.tag, detail: valueRefJson(failure.ref) };
  }
}

function requestFor(testCase: InputCase, index: number): N.AttemptInput {
  const ready = testCase.providers.flatMap((provider: any) => (provider.prepare ?? []).filter((value: any) => value.tag === "ready"));
  return attemptInput(ready.length === 0 ? testCase.providers[0].request : ready[index].request);
}

function run(testCase: InputCase): any {
  const raw = JSON.parse(testCase.exchange);
  const admitted = S.admitSignatureGeneration(S.expectedSignatureBasis(raw), testCase.exchange);
  if (admitted.tag !== "Admitted") throw new Error(`generation admission: ${JSON.stringify(admitted.failure)}`);
  const composition = admitted.checked.composition;
  if (composition === null) throw new Error("generated exchange has no composition");
  const references = composition.prepared.input.signatures.map(value => value.reference);
  if (references.length === 0) references.push({ identity: "unused", revision: "0", contentDigest: "0".repeat(64) });
  let current = E.start(composition, providers(testCase, references), testCase.arguments.map((value: any) => [value.id, slot(value.value)] as const), N.emptyNetworkState());
  const progress: any[] = [];
  let observationIndex = 0;
  while (current.tag === "Ok" && current.value.tag === "Pending") {
    const pending = current.value;
    progress.push({ tag: "pending", instruction: pending.instruction.tag.toLowerCase() });
    const observation = testCase.observations[observationIndex++];
    const request = requestFor(testCase, observation.request ?? 0);
    const handle = { value: observation.handle ?? "handle" };
    let supplied: E.ExecutionObservation;
    if (observation.tag === "start" && observation.kind === "started") {
      supplied = { tag: "Start", observation: { tag: "Started", attempt: request.attempt, handle } };
    } else if (observation.tag === "start") {
      supplied = { tag: "Start", observation: { tag: "StartFailed", failure: { attempt: request.attempt, stage: "Start", configuration: request.configuration, cause: { tag: "ExecutionStartFailed" } }, effect: { tag: "Unknown", reason: "NoResponse" } } };
    } else {
      supplied = { tag: "Host", observation: { tag: "Delivered", delivery: BigInt(observation.delivery ?? 0), observation: {
        tag: "ResponseObservation", attempt: request.attempt, handle, sourceSequence: { tag: "none" },
        response: { status: observation.status, headers: headerFields(observation.headers), body: Uint8Array.from(observation.body) }, provenance: "LibraryNormalized", effect: { tag: "Unknown", reason: "NoResponse" },
      } } };
    }
    current = E.resume(pending.execution, supplied);
  }
  if (current.tag === "Failed") return { case: testCase.case, progress, failure: failureJson(current.failure.cause) };
  progress.push({ tag: "completed" });
  const terminal = current.value.result;
  const result = terminal.tag === "Success"
    ? { tag: "success", outcome: terminal.outputs.map(([name, value]) => [name, slotJson(value)]) }
    : { tag: "failure", embedding: terminal.embedding, value: slotJson(terminal.value) };
  return { case: testCase.case, progress, result };
}

const document = JSON.parse(readFileSync(process.argv[2]!, "utf8"));
console.log(JSON.stringify(document.cases.map((testCase: InputCase) => {
  try { return run(testCase); }
  catch (failure) {
    return {
      case: testCase.case,
      progress: [],
      driverFailure: failure instanceof Error ? `${failure.name}: ${failure.message}` : String(failure),
    };
  }
})));
