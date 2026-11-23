// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import type * as C from "./semantic_composition.js";
import { apply, keyedBlocksOf } from "neco-quotient-application";
import type { KeyedBlocks } from "neco-quotient-application";
import { compositionAdmissionToken } from "./composition_admission_token.js";
import * as N from "./network-effect.js";
import * as V from "./semantic_values.js";
import { failed, ok } from "./semantic_values.js";
import { projectSlot } from "./signature_verification.js";

export type ExecutionFailure =
  | { readonly tag: "Value"; readonly failure: V.ValidationFailure }
  | { readonly tag: "MissingArgument"; readonly id: C.InputId }
  | { readonly tag: "ArgumentCoverage"; readonly condition: string }
  | { readonly tag: "MissingValue"; readonly ref: C.ValueRef }
  | { readonly tag: "MissingProvider"; readonly function: C.FunctionRef }
  | { readonly tag: "ProviderCoverage"; readonly condition: string }
  | { readonly tag: "ProviderEffect"; readonly function: C.FunctionRef }
  | { readonly tag: "Provider"; readonly site: C.SiteId; readonly message: string }
  | { readonly tag: "InvalidOutcome"; readonly site: C.SiteId; readonly outcome: C.OutcomeId }
  | { readonly tag: "Resource"; readonly lot: C.ResourceLotRef; readonly condition: string }
  | { readonly tag: "InvalidPlan"; readonly condition: string }
  | { readonly tag: "Network"; readonly failure: N.NetworkFailure }
  | { readonly tag: "NetworkTerminal"; readonly terminal: N.NetworkTerminal };

export type Result<T> = V.Except<T, ExecutionFailure>;

export interface CallResult {
  readonly outcome: C.OutcomeId;
  readonly outputs: readonly (readonly [C.PortId, V.ExactSlot])[];
}

export interface NetworkOwner {
  readonly encode: (arguments_: readonly (readonly [C.PortId, V.ExactSlot])[]) => Result<N.AttemptInput>;
  readonly decode: (response: N.RawHttpResponse) => Result<CallResult>;
}

export type PreparedCall =
  | { readonly tag: "Ready"; readonly input: N.AttemptInput }
  | { readonly tag: "Completed"; readonly result: CallResult };

export interface PreparedNetworkOwner {
  readonly prepare: (arguments_: readonly (readonly [C.PortId, V.ExactSlot])[]) => Result<PreparedCall>;
  readonly decode: (response: N.RawHttpResponse) => Result<CallResult>;
}

export type ProviderImplementation =
  | { readonly tag: "Pure"; readonly callback: (arguments_: readonly (readonly [C.PortId, V.ExactSlot])[]) => Result<CallResult> }
  | { readonly tag: "PreparedHttp"; readonly owner: PreparedNetworkOwner };

export interface Provider {
  readonly reference: C.FunctionRef;
  readonly implementation: ProviderImplementation;
}

export type ExecutionResult =
  | { readonly tag: "Success"; readonly outputs: readonly (readonly [C.GoalPortId, V.ExactSlot])[] }
  | { readonly tag: "Failure"; readonly embedding: C.FailureEmbeddingId; readonly value: V.ExactSlot };

export interface RuntimeState {
  readonly values: readonly (readonly [C.ProducerRef, V.ExactSlot])[];
  readonly resources: readonly (readonly [C.ResourceLotRef, C.ResourceLot])[];
}

export interface RunFailure {
  readonly cause: ExecutionFailure;
  readonly network: N.NetworkState;
}

export type NetworkInstruction =
  | { readonly tag: "Send"; readonly command: N.SendCommand }
  | { readonly tag: "Observe"; readonly started: N.StartedAttempt };

export type ExecutionObservation =
  | { readonly tag: "Start"; readonly observation: N.StartObservation }
  | { readonly tag: "Host"; readonly observation: N.HostObservation };

type PreparedTree =
  | { readonly tag: "Invoke"; readonly invocation: C.InvocationPlan; readonly arms: OutcomeTable }
  | { readonly tag: "Guard"; readonly guard: C.GuardId; readonly inspected: C.ValueRef; readonly arms: GuardTable }
  | { readonly tag: "ReturnValue"; readonly terminal: C.ReturnPlan };
type OutcomeTable = KeyedBlocks<C.OutcomeId, PreparedTree> | null;
type GuardTable = KeyedBlocks<string, PreparedTree> | null;

function guardArmKey(arm: C.GuardArm): string {
  return arm.tag === "Variant" ? `Variant:${arm.value}` : arm.tag;
}

function prepareTree(tree: C.PlanTree): PreparedTree {
  if (tree.tag === "ReturnValue") return { tag: "ReturnValue", terminal: tree.fields.terminal };
  if (tree.tag === "Invoke") {
    const table = keyedBlocksOf(tree.fields.arms.map(([outcome, child]) => [outcome, prepareTree(child)] as const));
    return { tag: "Invoke", invocation: tree.fields.invocation, arms: table.kind === "built" ? table.blocks : null };
  }
  const table = keyedBlocksOf(tree.fields.arms.map(([arm, child]) => [guardArmKey(arm), prepareTree(child)] as const));
  return { tag: "Guard", guard: tree.fields.guard, inspected: tree.fields.inspected, arms: table.kind === "built" ? table.blocks : null };
}

const preparedRoot: unique symbol = Symbol("prepared root");

export type PendingNetwork =
  | { readonly tag: "Start"; readonly invocation: C.InvocationPlan; readonly arms: OutcomeTable; readonly owner: NetworkOwner; readonly prepared: N.PreparedAttempt }
  | { readonly tag: "Response"; readonly invocation: C.InvocationPlan; readonly arms: OutcomeTable; readonly owner: NetworkOwner; readonly started: N.StartedAttempt };

const executionBrand: unique symbol = Symbol("execution authority");
const executionAuthority = new WeakSet<Execution>();

export interface Execution {
  readonly [executionBrand]: true;
  readonly prepared: C.PreparedCompositionInput;
  readonly providers: readonly Provider[];
  readonly state: RuntimeState;
  readonly tree: PreparedTree;
  readonly network: N.NetworkState;
  readonly pending: PendingNetwork | null;
}

type ExecutionFields = Omit<Execution, typeof executionBrand>;

function execution(fields: ExecutionFields): Execution {
  const value = { ...fields, [executionBrand]: true as const };
  executionAuthority.add(value);
  return Object.freeze(value);
}

function requireExecution(value: Execution): void {
  if (!executionAuthority.has(value)) throw new TypeError("execution authority");
}

function updateExecution(value: Execution, fields: Partial<ExecutionFields>): Execution {
  requireExecution(value);
  return execution({ ...value, ...fields });
}

export type Progress =
  | { readonly tag: "Completed"; readonly result: ExecutionResult; readonly network: N.NetworkState }
  | { readonly tag: "Pending"; readonly execution: Execution; readonly instruction: NetworkInstruction };

export type RunResult =
  | { readonly tag: "Ok"; readonly value: Progress }
  | { readonly tag: "Failed"; readonly failure: RunFailure };

const runFailed = (network: N.NetworkState, cause: ExecutionFailure): RunResult => ({ tag: "Failed", failure: { cause, network } });
const same = V.same;

function project(tagKey: string, value: V.ExactSlot, path: C.ValuePath): Result<V.ExactSlot> {
  if (path.length === 0) return ok(value);
  if (value.tag !== "Present") return failed({ tag: "InvalidPlan", condition: "projection shape mismatch" });
  const [step, ...rest] = path;
  if (step!.tag === "Field" && value.value.tag === "Object") {
    const member = V.memberValue(step!.value, value.value.members);
    return project(tagKey, V.slotOf(member), rest);
  }
  if (step!.tag === "Index" && value.value.tag === "Array") {
    const index = BigInt(step!.value);
    if (index < 0n || index >= BigInt(value.value.items.length)) return failed({ tag: "InvalidPlan", condition: "array projection outside value" });
    return project(tagKey, V.slotOf(value.value.items[Number(index)]), rest);
  }
  if (step!.tag === "Variant" && value.value.tag === "Object") {
    const tag = V.memberValue(tagKey, value.value.members);
    return tag?.tag === "String" && tag.value === step!.value
      ? project(tagKey, value, rest)
      : failed({ tag: "InvalidPlan", condition: "variant projection mismatch" });
  }
  return failed({ tag: "InvalidPlan", condition: "projection shape mismatch" });
}

function lookup(prepared: C.PreparedCompositionInput, state: RuntimeState, ref: C.ValueRef): Result<V.ExactSlot> {
  const found = state.values.find(([producer]) => same(producer, ref.producer));
  if (found === undefined) return failed({ tag: "MissingValue", ref });
  return project(prepared.context.profile.tag?.key ?? "", found[1], ref.path);
}

function evaluateBinding(prepared: C.PreparedCompositionInput, state: RuntimeState, binding: C.BindingExpr): Result<V.ExactSlot> {
  if (binding.tag === "Source") return lookup(prepared, state, binding.fields.value);
  const members: { readonly key: string; readonly value: V.ExactJson }[] = [];
  for (const [name, nested] of binding.fields.fields) {
    const evaluated = evaluateBinding(prepared, state, nested);
    if (evaluated.tag === "Failed") return evaluated;
    if (evaluated.value.tag === "Null") members.push({ key: name, value: { tag: "Null" } });
    else if (evaluated.value.tag === "Present") members.push({ key: name, value: evaluated.value.value });
  }
  return ok({ tag: "Present", value: { tag: "Object", members } });
}

function validate(prepared: C.PreparedCompositionInput, contract: V.SlotContract, value: V.ExactSlot): Result<void> {
  const decision = V.acceptsSlot(prepared.context, contract, value);
  if (decision.tag === "Accepted") return ok(undefined);
  return failed({ tag: "Value", failure: decision.tag === "Rejected" ? { tag: "Value", failure: decision.failure } : { tag: "Unresolved", obligations: decision.obligations } });
}

function initialState(prepared: C.PreparedCompositionInput, arguments_: readonly (readonly [C.InputId, V.ExactSlot])[]): Result<RuntimeState> {
  for (const [id] of arguments_) {
    if (arguments_.filter(([candidate]) => candidate === id).length !== 1
      || !prepared.input.initialInputs.some(initial => initial.id === id && initial.source.tag === "Argument")) {
      return failed({ tag: "ArgumentCoverage", condition: "unique declared argument identifiers required" });
    }
  }
  const values: (readonly [C.ProducerRef, V.ExactSlot])[] = [];
  for (const initial of prepared.input.initialInputs) {
    const value = initial.source.tag === "SuppliedValue"
      ? initial.source.value
      : arguments_.find(([id]) => id === initial.id)?.[1];
    if (value === undefined) return failed({ tag: "MissingArgument", id: initial.id });
    const checked = validate(prepared, initial.contract, value);
    if (checked.tag === "Failed") return checked;
    values.push([{ tag: "Initial", value: initial.id }, value]);
  }
  return ok({ values, resources: prepared.input.initialResources.map(lot => [{ tag: "Initial", value: lot.id }, lot] as const) });
}

function bindResources(signature: C.FunctionSignature, invocation: C.InvocationPlan, state: RuntimeState): Result<RuntimeState> {
  let resources = [...state.resources];
  for (const binding of invocation.resources) {
    const requirement = signature.resourceInputs.find(candidate => candidate.id === binding.requirement);
    if (requirement === undefined) return failed({ tag: "InvalidPlan", condition: "resource requirement mismatch" });
    const found = resources.find(([ref]) => same(ref, binding.lot));
    if (found === undefined) return failed({ tag: "Resource", lot: binding.lot, condition: "missing lot" });
    const lot = found[1];
    if (lot.revision !== requirement.requiredRevision) return failed({ tag: "Resource", lot: binding.lot, condition: "revision mismatch" });
    if (lot.quantity < requirement.multiplicity) return failed({ tag: "Resource", lot: binding.lot, condition: "insufficient quantity" });
    if (requirement.mode.tag === "Consume") {
      resources = resources.map(([ref, existing]) => same(ref, binding.lot)
        ? [ref, { ...existing, quantity: existing.quantity - requirement.multiplicity }] as const
        : [ref, existing] as const);
    }
  }
  return ok({ ...state, resources });
}

function inspectGuard(prepared: C.PreparedCompositionInput, guard: C.DeclaredGuard, value: V.ExactSlot): Result<C.GuardArm> {
  if (guard.kind.tag === "Presence") return ok({ tag: value.tag });
  if (guard.kind.tag === "Validate") {
    const decision = V.acceptsSlot(prepared.context, guard.kind.value, value);
    if (decision.tag === "Unresolved") return failed({ tag: "Value", failure: { tag: "Unresolved", obligations: decision.obligations } });
    return ok({ tag: decision.tag });
  }
  if (value.tag === "Absent" || value.tag === "Null") return ok({ tag: value.tag });
  if (value.value.tag !== "Object") return failed({ tag: "InvalidPlan", condition: "union guard shape" });
  const discriminator = V.memberValue(prepared.context.profile.tag?.key ?? "", value.value.members);
  if (discriminator?.tag !== "String") return failed({ tag: "InvalidPlan", condition: "union guard discriminator" });
  let destination: V.SlotContract;
  try {
    destination = projectSlot(prepared.context, { type_ref: guard.sourceType, required: true, nullable: false }, guard.path, []).destination;
  } catch {
    return failed({ tag: "InvalidPlan", condition: "union guard projection" });
  }
  const shape = prepared.context.resolve(destination.type_ref);
  if (shape === undefined || shape.tag !== "TaggedUnion") return failed({ tag: "InvalidPlan", condition: "union guard declaration" });
  const branch = V.selectBranch(prepared.context, destination.type_ref, value.value);
  if (branch === null) return failed({ tag: "InvalidPlan", condition: "union branch selection" });
  return ok({ tag: "Variant", value: branch.wire_tag });
}

function providerEffectMatches(effect: C.CompositionEffect, implementation: ProviderImplementation): boolean {
  return implementation.tag === "Pure"
    ? effect.tag === "PureFunction" || effect.tag === "DataOnly"
    : effect.tag === "HttpRequestResponse";
}

function validateProviders(prepared: C.PreparedCompositionInput, providers: readonly Provider[]): Result<void> {
  if (providers.length !== prepared.input.signatures.length) return failed({ tag: "ProviderCoverage", condition: "exact provider coverage required" });
  for (const provider of providers) {
    if (providers.filter(candidate => same(candidate.reference, provider.reference)).length !== 1) return failed({ tag: "ProviderCoverage", condition: "unique provider references required" });
  }
  for (const signature of prepared.input.signatures) {
    const provider = providers.find(candidate => same(candidate.reference, signature.reference));
    if (provider === undefined) return failed({ tag: "MissingProvider", function: signature.reference });
    if (!providerEffectMatches(signature.effect, provider.implementation)) return failed({ tag: "ProviderEffect", function: signature.reference });
  }
  return ok(undefined);
}

function invocationCall(execution: Execution, invocation: C.InvocationPlan): Result<readonly [C.FunctionSignature, RuntimeState, readonly (readonly [C.PortId, V.ExactSlot])[]]> {
  const signature = execution.prepared.input.signatures.find(candidate => same(candidate.reference, invocation.function));
  if (signature === undefined) return failed({ tag: "InvalidPlan", condition: "function identity mismatch" });
  const bound = bindResources(signature, invocation, execution.state);
  if (bound.tag === "Failed") return bound;
  const arguments_: (readonly [C.PortId, V.ExactSlot])[] = [];
  for (const [id, binding] of invocation.bindings) {
    const port = signature.inputs.find(candidate => candidate.id === id);
    if (port === undefined) return failed({ tag: "InvalidPlan", condition: "input port mismatch" });
    const value = evaluateBinding(execution.prepared, bound.value, binding);
    if (value.tag === "Failed") return value;
    const checked = validate(execution.prepared, port.contract, value.value);
    if (checked.tag === "Failed") return checked;
    arguments_.push([id, value.value]);
  }
  return ok([signature, bound.value, arguments_]);
}

function acceptOutcome(execution: Execution, signature: C.FunctionSignature, invocation: C.InvocationPlan,
  arms: OutcomeTable, result: CallResult): Result<Execution> {
  const outcome = signature.outcomes.find(candidate => candidate.id === result.outcome);
  if (outcome === undefined) return failed({ tag: "InvalidOutcome", site: invocation.site, outcome: result.outcome });
  if (result.outputs.length !== outcome.valuePorts.length) return failed({ tag: "InvalidPlan", condition: "output port coverage" });
  const values: (readonly [C.ProducerRef, V.ExactSlot])[] = [];
  for (const port of outcome.valuePorts) {
    const found = result.outputs.find(([id]) => id === port.id);
    if (found === undefined) return failed({ tag: "InvalidPlan", condition: "missing output port" });
    const checked = validate(execution.prepared, port.contract, found[1]);
    if (checked.tag === "Failed") return checked;
    values.push([{ tag: "InvocationOutcome", fields: { site: invocation.site, outcome: outcome.id, port: port.id } }, found[1]]);
  }
  const resources = outcome.producedResources.map(production => [{ tag: "Produced", fields: { site: invocation.site, outcome: outcome.id, production: production.id } }, {
    id: production.id, tokenType: production.tokenType, producer: { tag: "InvocationOutcome", fields: { site: invocation.site, outcome: outcome.id } },
    revision: production.revision, quantity: production.quantity, provenance: production.provenance,
  }] as const satisfies readonly [C.ResourceLotRef, C.ResourceLot]);
  if (arms === null) return failed({ tag: "InvalidPlan", condition: "duplicate outcome branch" });
  const applied = apply(arms, outcome.id);
  if (applied.kind === "residual") return failed({ tag: "InvalidPlan", condition: "outcome branch mismatch" });
  const tree = applied.value;
  return ok(updateExecution(execution, { state: { values: [...execution.state.values, ...values], resources: [...execution.state.resources, ...resources] }, tree, pending: null }));
}

function startHttp(execution: Execution, invocation: C.InvocationPlan, arms: OutcomeTable,
  arguments_: readonly (readonly [C.PortId, V.ExactSlot])[], owner: NetworkOwner): RunResult {
  const encoded = owner.encode(arguments_);
  if (encoded.tag === "Failed") return runFailed(execution.network, encoded.failure);
  const preparedStep = N.prepare(execution.network, encoded.value);
  if (preparedStep.tag === "Rejected") return runFailed(preparedStep.state, { tag: "Network", failure: preparedStep.failure });
  const commandStep = N.sendCommand(preparedStep.state, preparedStep.prepared);
  if (commandStep.tag === "Rejected") return runFailed(commandStep.state, { tag: "Network", failure: commandStep.failure });
  const pending: PendingNetwork = { tag: "Start", invocation, arms, owner, prepared: preparedStep.prepared };
  return { tag: "Ok", value: { tag: "Pending", execution: updateExecution(execution, { network: commandStep.state, pending }), instruction: { tag: "Send", command: commandStep.command } } };
}

function advance(execution: Execution): RunResult {
  requireExecution(execution);
  const tree = execution.tree;
  if (tree.tag === "ReturnValue") {
    const terminal = tree.terminal;
    if (terminal.tag === "Success") {
      const outputs: (readonly [C.GoalPortId, V.ExactSlot])[] = [];
      for (const [id, binding] of terminal.value) {
        const port = execution.prepared.input.goal.outputs.find(candidate => candidate.id === id);
        if (port === undefined) return runFailed(execution.network, { tag: "InvalidPlan", condition: "goal port mismatch" });
        const value = evaluateBinding(execution.prepared, execution.state, binding);
        if (value.tag === "Failed") return runFailed(execution.network, value.failure);
        const checked = validate(execution.prepared, port.contract, value.value);
        if (checked.tag === "Failed") return runFailed(execution.network, checked.failure);
        outputs.push([id, value.value]);
      }
      for (const resource of execution.prepared.input.goal.finalResources) {
        const lot = execution.state.resources.find(([ref]) => same(ref, resource.lot))?.[1];
        if (lot === undefined) return runFailed(execution.network, { tag: "Resource", lot: resource.lot, condition: "missing final lot" });
        if (lot.quantity < resource.multiplicity || lot.revision !== resource.revision) return runFailed(execution.network, { tag: "Resource", lot: resource.lot, condition: "final resource mismatch" });
      }
      return { tag: "Ok", value: { tag: "Completed", result: { tag: "Success", outputs }, network: execution.network } };
    }
    const failure = execution.prepared.input.goal.failures.find(candidate => candidate.id === terminal.fields.embedding);
    if (failure === undefined) return runFailed(execution.network, { tag: "InvalidPlan", condition: "failure embedding mismatch" });
    const value = evaluateBinding(execution.prepared, execution.state, terminal.fields.value);
    if (value.tag === "Failed") return runFailed(execution.network, value.failure);
    const checked = validate(execution.prepared, failure.contract, value.value);
    if (checked.tag === "Failed") return runFailed(execution.network, checked.failure);
    return { tag: "Ok", value: { tag: "Completed", result: { tag: "Failure", embedding: terminal.fields.embedding, value: value.value }, network: execution.network } };
  }
  if (tree.tag === "Guard") {
    const guard = execution.prepared.input.invocationDomain.guards.find(candidate => candidate.id === tree.guard);
    if (guard === undefined) return runFailed(execution.network, { tag: "InvalidPlan", condition: "guard identity mismatch" });
    const value = lookup(execution.prepared, execution.state, tree.inspected);
    if (value.tag === "Failed") return runFailed(execution.network, value.failure);
    const arm = inspectGuard(execution.prepared, guard, value.value);
    if (arm.tag === "Failed") return runFailed(execution.network, arm.failure);
    if (tree.arms === null) return runFailed(execution.network, { tag: "InvalidPlan", condition: "duplicate guard branch" });
    const applied = apply(tree.arms, guardArmKey(arm.value));
    if (applied.kind === "residual") return runFailed(execution.network, { tag: "InvalidPlan", condition: "guard branch mismatch" });
    return advance(updateExecution(execution, { tree: applied.value }));
  }
  const call = invocationCall(execution, tree.invocation);
  if (call.tag === "Failed") return runFailed(execution.network, call.failure);
  const [signature, state, arguments_] = call.value;
  const current = updateExecution(execution, { state });
  const provider = current.providers.find(candidate => same(candidate.reference, tree.invocation.function));
  if (provider === undefined) return runFailed(current.network, { tag: "MissingProvider", function: tree.invocation.function });
  if (provider.implementation.tag === "Pure") {
    const result = provider.implementation.callback(arguments_);
    if (result.tag === "Failed") return runFailed(current.network, result.failure);
    const accepted = acceptOutcome(current, signature, tree.invocation, tree.arms, result.value);
    return accepted.tag === "Failed" ? runFailed(current.network, accepted.failure) : advance(accepted.value);
  }
  const prepared = provider.implementation.owner.prepare(arguments_);
  if (prepared.tag === "Failed") return runFailed(current.network, prepared.failure);
  if (prepared.value.tag === "Ready") {
    const input = prepared.value.input;
    return startHttp(current, tree.invocation, tree.arms, arguments_, {
      encode: () => ok(input), decode: provider.implementation.owner.decode,
    });
  }
  const accepted = acceptOutcome(current, signature, tree.invocation, tree.arms, prepared.value.result);
  return accepted.tag === "Failed" ? runFailed(current.network, accepted.failure) : advance(accepted.value);
}

const admittedCompositionAuthority = new WeakSet<AdmittedComposition>();

export class AdmittedComposition {
  readonly [preparedRoot]: PreparedTree;
  private constructor(token: symbol, readonly prepared: C.PreparedCompositionInput, readonly plan: C.CompositionPlan) {
    if (token !== compositionAdmissionToken) throw new TypeError("composition admission authority");
    this[preparedRoot] = prepareTree(plan.root);
    admittedCompositionAuthority.add(this);
    Object.freeze(this);
  }
  static admit(token: symbol, prepared: C.PreparedCompositionInput, plan: C.CompositionPlan): AdmittedComposition {
    return new AdmittedComposition(token, prepared, plan);
  }
}

export function requireAdmittedComposition(value: AdmittedComposition): void {
  if (!admittedCompositionAuthority.has(value)) throw new TypeError("admitted composition authority");
}

export function start(admitted: AdmittedComposition, providers: readonly Provider[],
  arguments_: readonly (readonly [C.InputId, V.ExactSlot])[], network: N.NetworkState): RunResult {
  requireAdmittedComposition(admitted);
  const prepared = admitted.prepared;
  const read = N.readNetworkState(network);
  const providerCheck = validateProviders(prepared, providers);
  if (providerCheck.tag === "Failed") return runFailed(read.state, providerCheck.failure);
  const state = initialState(prepared, arguments_);
  if (state.tag === "Failed") return runFailed(read.state, state.failure);
  return advance(execution({ prepared, providers, state: state.value, tree: admitted[preparedRoot], network: read.state, pending: null }));
}

export function resume(execution: Execution, observation: ExecutionObservation): RunResult {
  requireExecution(execution);
  const pending = execution.pending;
  if (pending === null) return runFailed(execution.network, { tag: "InvalidPlan", condition: "only pending executions may resume" });
  if (pending.tag === "Start" && observation.tag === "Start") {
    const step = N.observeStart(execution.network, pending.prepared, observation.observation);
    if (step.tag === "Started") {
      const next: PendingNetwork = { tag: "Response", invocation: pending.invocation, arms: pending.arms, owner: pending.owner, started: step.started };
      return { tag: "Ok", value: { tag: "Pending", execution: updateExecution(execution, { network: step.state, pending: next }), instruction: { tag: "Observe", started: step.started } } };
    }
    if (step.tag === "Terminal") return runFailed(step.state, { tag: "NetworkTerminal", terminal: step.settled.terminal });
    if (step.tag === "Rejected") return runFailed(step.state, { tag: "Network", failure: step.failure });
    return runFailed(execution.network, { tag: "InvalidPlan", condition: "network start result" });
  }
  if (pending.tag === "Response" && observation.tag === "Host") {
    const step = N.observe(execution.network, observation.observation);
    if (step.tag === "Pending") {
      const next: PendingNetwork = { ...pending, started: step.started };
      return { tag: "Ok", value: { tag: "Pending", execution: updateExecution(execution, { network: step.state, pending: next }), instruction: { tag: "Observe", started: step.started } } };
    }
    if (step.tag === "Duplicate" || step.tag === "Late") {
      return { tag: "Ok", value: { tag: "Pending", execution: updateExecution(execution, { network: step.state }), instruction: { tag: "Observe", started: pending.started } } };
    }
    if (step.tag === "Rejected") return runFailed(step.state, { tag: "Network", failure: step.failure });
    if (step.tag === "Started") return runFailed(execution.network, { tag: "InvalidPlan", condition: "completion delivered a start result" });
    if (step.settled.terminal.outcome.tag !== "Response") return runFailed(step.state, { tag: "NetworkTerminal", terminal: step.settled.terminal });
    const decoded = pending.owner.decode(step.settled.terminal.outcome.response);
    if (decoded.tag === "Failed") return runFailed(step.state, decoded.failure);
    const signature = execution.prepared.input.signatures.find(candidate => same(candidate.reference, pending.invocation.function));
    if (signature === undefined) return runFailed(step.state, { tag: "InvalidPlan", condition: "function identity mismatch" });
    const accepted = acceptOutcome(updateExecution(execution, { network: step.state, pending: null }), signature, pending.invocation, pending.arms, decoded.value);
    return accepted.tag === "Failed" ? runFailed(step.state, accepted.failure) : advance(accepted.value);
  }
  return runFailed(execution.network, { tag: "InvalidPlan", condition: "network observation kind mismatch" });
}
