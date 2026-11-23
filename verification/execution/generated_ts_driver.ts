// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { resolve } from "node:path";
import * as C from "../../packages/typescript/adapter/src/semantic_composition.js";
import * as S from "../../packages/typescript/adapter/src/semantic_signatures.js";
import * as N from "../../packages/typescript/adapter/src/network-effect.js";
import { networkFailureJson } from "./network_failure.js";
import { headerFields } from "./wire_bytes.js";
import * as E from "../../packages/typescript/adapter/src/semantic_execution.js";
import * as V from "../../packages/typescript/adapter/src/semantic_values.js";

type Any = Record<string, any>;
const document = JSON.parse(readFileSync(process.argv[2]!, "utf8"));
const outputDirectory = process.argv[3]!;
mkdirSync(outputDirectory, { recursive: true });
const root = fileURLToPath(new URL("../..", import.meta.url));

function attemptInput(value: Any): N.AttemptInput { return {
  attempt: { logical: { kind: "semantic", provenance: value.provenance ?? "comparison", revision: 1n }, ordinal: BigInt(value.ordinal ?? 0) },
  instruction: { method: value.method, target: value.target, headers: headerFields(value.headers), body: Uint8Array.from(value.body) }, deadline: null,
  configuration: { requestBodyLimit: 1024n, responseBodyLimit: 1024n, cancellation: null, monotonicClock: null },
}; }
function carrier(exchange: Any, typeId: string, value: any): any {
  const shape = exchange.signatures.nodes.find((item: Any) => item.id === typeId).shape;
  if (["Boolean", "String", "Unit"].includes(shape.tag)) return value;
  if (shape.tag === "Array") return value.map((item: any) => carrier(exchange, shape.value.item.type_id, item));
  if (shape.tag === "Product") return Object.fromEntries(shape.value.fields.filter((field: Any) => value[field.wire_name] !== undefined).map((field: Any) => [field.wire_name, carrier(exchange, field.slot.type_id, value[field.wire_name])]));
  if (shape.tag === "Sealed") { const result = { ...value }; delete result[exchange.signatures.profile.tag.key]; return result; }
  if (shape.tag === "TaggedUnion") { const tag = value[exchange.signatures.profile.tag.key]; const branch = shape.value.branches.find((item: Any) => item.selector.tag === "InternalTag" && item.wire_tag === tag) ?? shape.value.branches.find((item: Any) => item.selector.tag === "Otherwise"); return { branch: branch.wire_tag, value: carrier(exchange, branch.target, value) }; }
  return V.toExact(value);
}
function uncarrier(exchange: Any, typeId: string, value: any): any {
  const shape = exchange.signatures.nodes.find((item: Any) => item.id === typeId).shape;
  if (["Boolean", "String", "Unit"].includes(shape.tag)) return value;
  if (shape.tag === "Array") return value.map((item: any) => uncarrier(exchange, shape.value.item.type_id, item));
  if (shape.tag === "Product") return Object.fromEntries(shape.value.fields.filter((field: Any) => value[field.wire_name] !== undefined).map((field: Any) => [field.wire_name, uncarrier(exchange, field.slot.type_id, value[field.wire_name])]));
  if (shape.tag === "Sealed") return { [exchange.signatures.profile.tag.key]: shape.fields.tag, ...value };
  if (shape.tag === "TaggedUnion") return uncarrier(exchange, shape.value.branches.find((item: Any) => item.wire_tag === value.branch).target, value.value);
  return V.fromExact(value);
}
function typedSlot(exchange: Any, value: Any, contract: Any): any {
  const present = () => carrier(exchange, contract.type_id, value.value);
  if (contract.required && !contract.nullable) return present();
  if (!contract.required && contract.nullable) return value.tag === "absent" ? { tag: "Absent" } : value.tag === "null" ? { tag: "Null" } : { tag: "Present", value: present() };
  return value.tag === (contract.required ? "null" : "absent") ? { tag: "None" } : { tag: "Some", value: present() };
}
function defaultValue(exchange: Any, typeId: string): any {
  const shape = exchange.signatures.nodes.find((item: Any) => item.id === typeId).shape;
  if (shape.tag === "Boolean") return false;
  if (shape.tag === "String") return "";
  if (shape.tag === "Unit") return null;
  if (shape.tag === "Array") return [];
  if (shape.tag === "Product") return Object.fromEntries(shape.value.fields.filter((field: Any) => field.slot.required).map((field: Any) => [field.wire_name, defaultValue(exchange, field.slot.type_id)]));
  return {};
}
function slotJson(value: any, contract: Any, exchange?: Any): Any {
  const node = exchange?.signatures.nodes.find((item: Any) => item.id === contract.type_id);
  if (contract.required && !contract.nullable) return { tag: "present", value: uncarrier(exchange, contract.type_id, value) };
  if (!contract.required && contract.nullable) return value.tag === "Absent" ? { tag: "absent" } : value.tag === "Null" ? { tag: "null" } : { tag: "present", value: uncarrier(exchange, contract.type_id, value.value) };
  if (value.tag === "None") return { tag: contract.required ? "null" : "absent" };
  return { tag: "present", value: uncarrier(exchange, contract.type_id, value.value) };
}
function outcome(exchange: Any, signature: number, description: Any, fallback = false): any {
  const outcomes = exchange.composition.problem.signatures[signature].outcomes;
  let index = outcomes.findIndex((value: Any) => value.id === description.outcome);
  if (index < 0 && fallback) index = 0;
  if (index < 0) throw new Error(`unrepresentable outcome ${description.outcome}`);
  const ports = outcomes[index].value_ports;
  return { tag: `K${index}`, values: ports.map((port: Any) => {
    const supplied = description.outputs.find((value: Any) => value.id === port.id);
    const value = supplied?.value ?? (port.contract.nullable ? { tag: "null" } : !port.contract.required ? { tag: "absent" } : { tag: "present", value: defaultValue(exchange, port.contract.type_id) });
    return typedSlot(exchange, value, port.contract);
  }) };
}
function provider(G: Any, exchange: Any, description: Any): any {
  const signature = description.signature ?? 0;
  if (description.effect === "pure") return () => ({ tag: "Ok", value: outcome(exchange, signature, description) });
  const prepared = description.prepare[0];
  const request = prepared.tag === "ready" ? attemptInput(prepared.request) : null;
  const contracts = Object.values(G).filter((value: any) => value && typeof value === "object" && Array.isArray(value.outcomes));
  const operation = contracts[signature] as Any;
  return {
    transport: { encode: (value: any) => ({ tag: "Ok", value }), decode: (response: Any) => {
      const selected = description.decode.find((value: Any) => value.status === response.status);
      return selected.failure ? { tag: "Failed", failure: { tag: "Provider", site: selected.failure.site ?? "operation", message: selected.failure.message } }
        : { tag: "Ok", value: outcome(exchange, signature, selected) };
    } },
    prepare: () => prepared.tag === "ready" ? { tag: "Ok", value: { tag: "Ready", value: request } }
      : { tag: "Ok", value: { tag: "Completed", value: {
          outcome: operation.outcomes.find((value: Any) => value.id === prepared.outcome) ?? operation.outcomes[0],
          value: outcome(exchange, signature, prepared, true),
        } } },
    outcomeId: (value: Any) => exchange.composition.problem.signatures[signature].outcomes[Number(value.tag.slice(1))].id === prepared.outcome || prepared.tag !== "completed"
      ? exchange.composition.problem.signatures[signature].outcomes[Number(value.tag.slice(1))].id : prepared.outcome,
  };
}
function requestFor(testCase: Any, index: number): N.AttemptInput {
  const ready = testCase.providers.flatMap((provider: Any) => provider.prepare ?? []).filter((value: Any) => value.tag === "ready");
  return attemptInput(ready[index].request);
}
function observation(testCase: Any, value: Any): E.ExecutionObservation {
  const request = requestFor(testCase, value.request ?? 0), handle = { value: value.handle ?? "handle" };
  if (value.tag === "start" && value.kind === "started") return { tag: "Start", observation: { tag: "Started", attempt: request.attempt, handle } };
  if (value.tag === "start") return { tag: "Start", observation: { tag: "StartFailed", failure: { attempt: request.attempt, stage: "Start", configuration: request.configuration, cause: { tag: "ExecutionStartFailed" } }, effect: { tag: "Unknown", reason: "NoResponse" } } };
  return { tag: "Host", observation: { tag: "Delivered", delivery: BigInt(value.delivery ?? 0), observation: { tag: "ResponseObservation", attempt: request.attempt, handle,
    sourceSequence: { tag: "none" }, response: { status: value.status, headers: headerFields(value.headers), body: Uint8Array.from(value.body) }, provenance: "LibraryNormalized", effect: { tag: "Unknown", reason: "NoResponse" } } } };
}
function failureJson(failure: E.ExecutionFailure): Any {
  if (failure.tag === "InvalidPlan") return { tag: "invalidPlan", condition: failure.condition };
  if (failure.tag === "Provider") return { tag: "provider", site: failure.site, message: failure.message };
  if (failure.tag === "NetworkTerminal") { const failed = failure.terminal.outcome.tag === "Failed" ? failure.terminal.outcome.failure : null; return {
    tag: "networkTerminal", outcome: failure.terminal.outcome.tag, stage: failed?.stage ?? null, cause: failed?.cause.tag ?? null,
    effect: failure.terminal.effect.tag, reason: failure.terminal.effect.tag === "Unknown" ? failure.terminal.effect.reason : null,
  }; }
  if (failure.tag === "Network") return { tag: "network", detail: networkFailureJson(failure.failure) };
  if (failure.tag === "Value") return { tag: "value", detail: validationFailureJson(failure.failure) };
  return { tag: failure.tag[0]!.toLowerCase() + failure.tag.slice(1), detail: JSON.parse(JSON.stringify(failure, (_, value) => typeof value === "bigint" ? value.toString() : value)) };
}
function nestedFailure(constructor: string, arguments_: unknown[] = []): Any { return { constructor, arguments: arguments_ }; }
function sourceRefJson(source: V.SourceRef): Any { return {
  repository: source.repository, revision: source.revision, path: source.path, contentDigest: source.content_digest,
  documentId: source.document_id, declaredRevision: source.declared_revision ?? null,
}; }
function typeRefJson(reference: V.TypeRef): Any { return { source: sourceRefJson(reference.source), definitionName: reference.definition_name, pointer: reference.pointer }; }
function valueTypeRefJson(reference: V.TypeRef): Any { return { source: sourceRefJson(reference.source), definition: reference.definition_name, pointer: reference.pointer }; }
function pathJson(path: readonly V.PathStep[]): Any[] { return path.map(step => nestedFailure(step.tag[0]!.toLowerCase() + step.tag.slice(1), [step.value])); }
function valuePathJson(path: readonly (string | bigint)[]): Any[] { return path.map(step => typeof step === "bigint" ? { index: Number(step) } : { field: step }); }
function producerRefJson(reference: C.ProducerRef): Any {
  return reference.tag === "Initial" ? nestedFailure("initial", [reference.value])
    : nestedFailure("invocationOutcome", [reference.fields.site, reference.fields.outcome, reference.fields.port]);
}
function valueRefJson(reference: C.ValueRef): Any { return { producer: producerRefJson(reference.producer), path: pathJson(reference.path) }; }
function functionRefJson(reference: C.FunctionRef): Any { return { identity: reference.identity, revision: reference.revision, contentDigest: reference.contentDigest }; }
function semanticReasonJson(reason: V.SemanticReason): Any {
  const constructor = reason.tag[0]!.toLowerCase() + reason.tag.slice(1);
  return "value" in reason ? nestedFailure(constructor, [reason.value]) : nestedFailure(constructor);
}
function semanticObligationJson(obligation: V.SemanticObligation): Any { return {
  typeRef: valueTypeRefJson(obligation.type_ref),
  valuePath: obligation.value_path.map(step => step.tag === "Field" ? { field: step.value } : step.tag === "Index" ? { index: Number(step.value) } : { variant: step.value }),
  reason: semanticReasonJson(obligation.reason),
}; }
function slotContractJson(contract: V.SlotContract): Any { return { typeRef: typeRefJson(contract.type_ref), required: contract.required, nullable: contract.nullable }; }
function typeObligationJson(obligation: C.TypeObligation): Any { return {
  pair: { source: slotContractJson(obligation.pair.source), destination: slotContractJson(obligation.pair.destination) },
  path: pathJson(obligation.path), reason: typeObligationReasonJson(obligation.reason),
}; }
function typeObligationReasonJson(reason: C.TypeObligationReason): Any {
  const constructor = reason.tag[0]!.toLowerCase() + reason.tag.slice(1);
  if (reason.tag === "Meaning") return nestedFailure(constructor, [reason.value.map(semanticObligationJson)]);
  if (reason.tag === "ExtraField") return nestedFailure(constructor, [reason.value]);
  return nestedFailure(constructor);
}
function inclusionFailureJson(failure: C.InclusionFailure): Any {
  const constructor = failure.tag[0]!.toLowerCase() + failure.tag.slice(1);
  if (failure.tag === "UndefinedMeaning") return nestedFailure(constructor, [failure.value.map(semanticObligationJson)]);
  if (failure.tag === "PairMismatch" || failure.tag === "RuleMismatch" || failure.tag === "ChildCoverage") return nestedFailure(constructor, [failure.value.toString()]);
  if (failure.tag === "Unresolved") return nestedFailure(constructor, [typeObligationJson(failure.value)]);
  return nestedFailure(constructor);
}
function projectionFailureJson(failure: Any): Any {
  const constructor = failure.tag[0]!.toLowerCase() + failure.tag.slice(1);
  if (failure.tag === "WrongShape") return nestedFailure(constructor, [typeRefJson(failure.fields.ref), pathJson(failure.fields.path)]);
  if (failure.tag === "MissingField" || failure.tag === "MissingVariant") return nestedFailure(constructor, [typeRefJson(failure.fields.ref), failure.fields.name]);
  if (failure.tag === "BranchAssumptionRequired" || failure.tag === "VariantSelectionUndetermined") return nestedFailure(constructor, [pathJson(failure.fields.path), failure.fields.tag]);
  if (failure.tag === "Unresolved") return nestedFailure(constructor, [failure.value.map(semanticObligationJson)]);
  return nestedFailure(constructor, failure.tag === "CertificateMismatch" ? [failure.value] : []);
}
function valueFailureJson(failure: V.ValueFailure): Any { return {
  typeRef: valueTypeRefJson(failure.type),
  definitionRef: { source: sourceRefJson(failure.type.source), name: failure.type.definition_name },
  origin: { source: sourceRefJson(failure.type.source), pointer: failure.type.pointer },
  valuePath: valuePathJson(failure.path),
  condition: failure.condition, observed: failure.observed,
  referenceTrace: (failure.referenceTrace ?? []).map(valueTypeRefJson),
}; }
function validationFailureJson(failure: V.ValidationFailure): Any {
  if (failure.tag === "Unresolved") return nestedFailure("unresolved", [failure.obligations.map(semanticObligationJson)]);
  if (failure.tag === "CertificateMismatch") return nestedFailure("certificateMismatch", [failure.condition]);
  return nestedFailure("value", [valueFailureJson(failure.failure)]);
}
function compositionInputFailureJson(failure: C.CompositionInputFailure): Any {
  if (failure.tag === "BasisMismatch") return nestedFailure("basisMismatch");
  if (failure.tag === "DuplicateIdentity") return nestedFailure("duplicateIdentity", [failure.fields.kind, failure.fields.identity]);
  if (failure.tag === "UnresolvedType") return nestedFailure("unresolvedType", [typeRefJson(failure.value)]);
  if (failure.tag === "UnresolvedFunction") return nestedFailure("unresolvedFunction", [functionRefJson(failure.value)]);
  if (failure.tag === "InvalidSignature") return nestedFailure("invalidSignature", [functionRefJson(failure.fields.function), failure.fields.reason]);
  if (failure.tag === "InvalidInitialValue") return nestedFailure("invalidInitialValue", [failure.fields.input, valueFailureJson(failure.fields.failure)]);
  return nestedFailure(failure.tag[0]!.toLowerCase() + failure.tag.slice(1), [failure.value]);
}
function initializeFailureJson(failure: Any): Any {
  if (failure.tag === "CompositionInput") return { tag: "preparation", detail: compositionInputFailureJson(failure.value) };
  return { tag: "admission", detail: failure };
}
function execute(G: Any, testCase: Any, exchange: Any): Any {
  const providers = Object.fromEntries(testCase.providers.map((value: Any, index: number) => [`call${index}`, provider(G, exchange, value)]));
  const initial = new Map(exchange.composition.problem.initial_inputs.map((value: Any) => [value.id, value.contract]));
  const arguments_ = Object.fromEntries(testCase.arguments.map((value: Any, index: number) => [`argument${index}`, typedSlot(exchange, value.value, initial.get(value.id))]));
  const initialized = G.initialize();
  if (initialized.tag === "Failed") return { case: testCase.case, progress: [], failure: initializeFailureJson(initialized.failure) };
  let current = G.run(initialized.initialized, providers, arguments_, N.emptyNetworkState()), observationIndex = 0; const progress: Any[] = [];
  while (current.tag === "Ok" && current.value.tag === "Pending") { const pending = current.value; progress.push({ tag: "pending", instruction: pending.instruction.tag.toLowerCase() }); current = G.resume(pending.execution, observation(testCase, testCase.observations[observationIndex++])); }
  if (current.tag === "Failed") return { case: testCase.case, progress, failure: failureJson(current.failure.cause) };
  progress.push({ tag: "completed" }); const result = current.value.result;
  if (result.tag === "Success") { const goals = exchange.composition.problem.goal.outputs, values = goals.length === 1 ? [result.values] : result.values; return { case: testCase.case, progress, result: { tag: "success", outcome: goals.map((goal: Any, index: number) => [goal.id, slotJson(values[index], goal.contract, exchange)]) } }; }
  const index = Number(result.tag.slice("Failure".length)), failure = exchange.composition.problem.goal.failures[index];
  return { case: testCase.case, progress, result: { tag: "failure", embedding: failure.id, value: slotJson(result.value, failure.contract, exchange) } };
}

async function main() {
  const modules = new Map<string, Promise<Any>>(), rows: Any[] = [];
  for (const testCase of document.cases) { try {
    const exchange = JSON.parse(testCase.exchange); let loaded = modules.get(testCase.exchange);
    if (!loaded) { const name = `generated_${modules.size}.mts`, path = resolve(outputDirectory, name); const runtime = pathToFileURL(resolve(root, "packages/typescript/adapter/src/index.ts")).href;
      const expectedPath = resolve(outputDirectory, `expected_${modules.size}.json`), inputPath = resolve(outputDirectory, `input_${modules.size}.json`); writeFileSync(expectedPath, S.encodeExpectedBasisWire(S.expectedSignatureBasis(exchange))); writeFileSync(inputPath, testCase.exchange); execFileSync("cargo", ["run", "--quiet", "--locked", "--manifest-path", resolve(root, "generator/rust/Cargo.toml"), "--bin", "necoherence-generate", "--", "--target", "typescript", "--expected", expectedPath, "--input", inputPath, "--output", path, "--runtime", runtime], { stdio: ["ignore", "ignore", "pipe"] }); loaded = import(pathToFileURL(path).href); modules.set(testCase.exchange, loaded); }
    rows.push(execute(await loaded, testCase, exchange));
  } catch (failure) { rows.push({ case: testCase.case, progress: [], driverFailure: failure instanceof Error ? `${failure.name}: ${failure.message}` : String(failure) }); } }
  console.log(JSON.stringify(rows));
}
void main();
