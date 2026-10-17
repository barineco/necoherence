// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT


import * as Core from "../../typescript/src/core.js";
import * as Call from "../../typescript/src/call.js";
import * as Iteration from "../../typescript/src/iteration.js";
import * as Store from "../../typescript/src/store.js";
import * as Record from "../../typescript/src/record.js";
import * as Reconcile from "../../typescript/src/reconcile.js";
import * as Progression from "../../typescript/src/request-progression.js";
import * as Admission from "../../typescript/src/dynamic-admission.js";
import * as Transition from "../../typescript/src/transition.js";
import * as FileEffect from "../../typescript/src/file-effect.js";
import type { ValueFailure } from "../../typescript/src/value.js";

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

type FailureKind = "json_syntax" | "query_shape" | "unknown_feature" | "unknown_operation" | "input_shape";

class DecodeFailure extends Error {
  constructor(public readonly kind: FailureKind, public readonly detail: string) {
    super(detail);
  }
}

function fail(detail: string): never {
  throw new DecodeFailure("input_shape", detail);
}

function objVal(j: Json, k: string): Json {
  if (j === null || typeof j !== "object" || Array.isArray(j)) fail(`expected object for ${k}`);
  const record = j as { [key: string]: Json };
  if (!(k in record)) fail(`missing field ${k}`);
  return record[k] as Json;
}

function asStr(j: Json): string {
  if (typeof j !== "string") fail("expected string");
  return j;
}

function asBool(j: Json): boolean {
  if (typeof j !== "boolean") fail("expected bool");
  return j;
}

function asArr(j: Json): Json[] {
  if (!Array.isArray(j)) fail("expected array");
  return j;
}

function natOfStr(s: string): bigint {
  if (s.length === 0) fail("empty integer");
  if (!/^[0-9]+$/.test(s)) fail("invalid integer");
  return BigInt(s);
}

function natField(j: Json, k: string): bigint {
  return natOfStr(asStr(objVal(j, k)));
}

function strField(j: Json, k: string): string {
  return asStr(objVal(j, k));
}

function arrField(j: Json, k: string): Json[] {
  return asArr(objVal(j, k));
}

function natToJson(n: bigint): Json {
  return n.toString();
}

function orNull<T>(j: Json, decode: (v: Json) => T): T | null {
  return j === null ? null : decode(j);
}


function decodeResourceId(j: Json): Core.ResourceId {
  return Object.freeze({ kind: strField(j, "kind"), name: strField(j, "name") });
}

function encodeResourceId(r: Core.ResourceId): Json {
  return { kind: r.kind, name: r.name };
}

function decodeRevision(j: Json): Core.Revision {
  return Object.freeze({ value: natOfStr(asStr(j)) });
}

function encodeRevision(r: Core.Revision): Json {
  return natToJson(r.value);
}

function decodeBasis(j: Json): Core.Basis {
  return Object.freeze({
    resource: decodeResourceId(objVal(j, "resource")),
    revision: decodeRevision(objVal(j, "revision")),
  });
}

function encodeBasis(b: Core.Basis): Json {
  return { resource: encodeResourceId(b.resource), revision: encodeRevision(b.revision) };
}

function decodeWorld(j: Json): Core.World {
  const arr = asArr(j);
  return Core.worldOf(
    arr.map((e) => [decodeResourceId(objVal(e, "resource")), decodeRevision(objVal(e, "revision"))] as const)
  );
}

function encodeWorld(w: Core.World): Json {
  return w.entries.map(([resource, revision]) => ({ resource: encodeResourceId(resource), revision: encodeRevision(revision) }));
}

function encodeLookup(l: Core.Lookup): Json {
  if (l.tag === "Found") return { tag: "found", revision: encodeRevision(l.revision) };
  return { tag: "unknown", resource: encodeResourceId(l.resource) };
}

function decodeCommand(j: Json): Core.Command<Json> {
  return Object.freeze({ intent: objVal(j, "intent"), basis: decodeBasis(objVal(j, "basis")) });
}

function encodeCommand(c: Core.Command<Json>): Json {
  return { intent: c.intent, basis: encodeBasis(c.basis) };
}

function encodeApplyOutcome(o: Core.Outcome<readonly [Json, Core.World], Core.UnknownResource, Core.StaleBasis, never>): Json {
  if (o.tag === "Applied") return { tag: "applied", intent: o.value[0], world: encodeWorld(o.value[1]) };
  if (o.tag === "Rejected") return { tag: "rejected", resource: encodeResourceId(o.reason.resource) };
  if (o.tag === "Conflicted") return { tag: "conflicted", expected: encodeRevision(o.conflict.expected), actual: encodeRevision(o.conflict.actual) };
  throw new Error("unreachable boundary failure");
}

function opCoreLookup(input: Json): Json {
  const world = decodeWorld(objVal(input, "world"));
  const resource = decodeResourceId(objVal(input, "resource"));
  return encodeLookup(Core.lookup(world, resource));
}

function opCoreBump(input: Json): Json {
  const world = decodeWorld(objVal(input, "world"));
  const resource = decodeResourceId(objVal(input, "resource"));
  return encodeWorld(Core.bump(world, resource));
}

function opCoreCommandOf(input: Json): Json {
  const obsJ = objVal(input, "observation");
  const payload = objVal(obsJ, "payload");
  const basis = decodeBasis(objVal(obsJ, "basis"));
  const observedAt = natField(obsJ, "observedAt");
  const o: Core.Observation<Json> = Object.freeze({ payload, basis, observedAt });
  const x = objVal(input, "payload");
  return encodeCommand(Core.commandOf(o, x));
}

function opCoreApply(input: Json): Json {
  const world = decodeWorld(objVal(input, "world"));
  const command = decodeCommand(objVal(input, "command"));
  return encodeApplyOutcome(Core.apply(world, command));
}


type FunctionForm =
  | { readonly kind: "identity" }
  | { readonly kind: "const"; readonly value: Json }
  | { readonly kind: "getField"; readonly name: string }
  | { readonly kind: "setField"; readonly name: string; readonly value: Json }
  | { readonly kind: "wrap"; readonly tag: string };

function decodeFunctionForm(j: Json): FunctionForm {
  const kind = strField(j, "kind");
  switch (kind) {
    case "identity":
      return { kind: "identity" };
    case "const":
      return { kind: "const", value: objVal(j, "value") };
    case "getField":
      return { kind: "getField", name: strField(j, "name") };
    case "setField":
      return { kind: "setField", name: strField(j, "name"), value: objVal(j, "value") };
    case "wrap":
      return { kind: "wrap", tag: strField(j, "tag") };
    default:
      fail(`unknown function form kind ${kind}`);
  }
}

function applyFunctionForm(form: FunctionForm, x: Json): Json {
  switch (form.kind) {
    case "identity":
      return x;
    case "const":
      return form.value;
    case "getField":
      return x !== null && typeof x === "object" && !Array.isArray(x) ? ((x as Record<string, Json>)[form.name] ?? null) : null;
    case "setField":
      if (x !== null && typeof x === "object" && !Array.isArray(x)) {
        return { ...(x as Record<string, Json>), [form.name]: form.value };
      }
      return { [form.name]: form.value };
    case "wrap":
      return { tag: form.tag, value: x };
  }
}

function decodeRequest(j: Json): Call.Request<Json> {
  const payload = objVal(j, "payload");
  const fields = arrField(j, "fields").map(asStr);
  return Call.requestOf(payload, fields);
}

function decodeImmediate(j: Json): Call.Immediate<Json, Json> {
  const identity = strField(j, "identity");
  const required = arrField(j, "required").map(asStr);
  const form = decodeFunctionForm(objVal(j, "output"));
  return Call.immediateOf(identity, required, (x: Json) => applyFunctionForm(form, x));
}

function decodeDeferred(j: Json): Call.Deferred<Json, Json> {
  const identity = strField(j, "identity");
  const required = arrField(j, "required").map(asStr);
  const form = decodeFunctionForm(objVal(j, "output"));
  return Call.deferredOf(identity, required, (x: Json) => applyFunctionForm(form, x));
}

function encodeCallResult(r: Call.CallResult<Json>): Json {
  if (r.tag === "Ok") return { tag: "ok", value: r.value };
  return { tag: "failed", declaration: r.failure.declaration, fields: [...r.failure.fields] };
}

function opCallImmediateOf(input: Json): Json {
  const decl = decodeImmediate(input);
  return { identity: decl.identity, required: [...decl.required] };
}

function opCallDeferredOf(input: Json): Json {
  const decl = decodeDeferred(input);
  return { identity: decl.identity, required: [...decl.required] };
}

function opCallIo(input: Json): Json {
  const decl = decodeImmediate(objVal(input, "declaration"));
  const req = decodeRequest(objVal(input, "request"));
  return encodeCallResult(Call.io(decl, req));
}

function opCallIssue(input: Json): Json {
  const decl = decodeDeferred(objVal(input, "declaration"));
  const req = decodeRequest(objVal(input, "request"));
  return encodeCallResult(Call.issue(decl, req));
}


type AdvanceForm =
  | { readonly mode: "consumeImmediately"; readonly outputs: readonly Json[] }
  | { readonly mode: "reprocessAlways"; readonly outputs: readonly Json[] }
  | { readonly mode: "consumeAfter"; readonly rounds: bigint; readonly outputsPerRound: readonly Json[] };

function stageProjectionFailedJson(s: Iteration.StageProjectionFailed): Json {
  return { position: natToJson(s.position), declaration: s.failure.declaration, fields: [...s.failure.fields] };
}

function decodeFoldReq(j: Json): { req: Iteration.FoldReq<Json> } {
  const step = decodeImmediate(objVal(j, "step"));
  const seed = objVal(j, "seed");
  const count = natField(j, "count");
  const stepFields = arrField(j, "stepFields").map(asStr);
  return { req: { step, seed, count, stepFields } };
}

function encodeFoldOutcome(o: Iteration.FoldOutcome<Json>): Json {
  if (o.tag === "FoldTrace") return { tag: "trace", states: [...o.states] };
  return { tag: "stopped", states: [...o.states], stopped: stageProjectionFailedJson(o.stopped) };
}

type StepOutcomeForm = { readonly tag: "settled" } | { readonly tag: "advance"; readonly measure: bigint };

function decodeStepOutcomeForm(j: Json): StepOutcomeForm {
  const tag = strField(j, "tag");
  if (tag === "settled") return { tag: "settled" };
  if (tag === "advance") return { tag: "advance", measure: natField(j, "measure") };
  fail(`unknown step outcome tag ${tag}`);
}

function jsonEq(a: Json, b: Json): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function decodeRecurseTable(j: Json): readonly (readonly [Json, StepOutcomeForm])[] {
  return asArr(j).map((entry) => [objVal(entry, "payload"), decodeStepOutcomeForm(objVal(entry, "outcome"))] as const);
}

function recurseStepOutput(
  table: readonly (readonly [Json, StepOutcomeForm])[],
  nextOf: (x: Json) => Json,
  state: Json
): Iteration.StepOutcome<Json> {
  const hit = table.find(([p]) => jsonEq(p, state));
  if (hit === undefined) return Iteration.settled(state);
  if (hit[1].tag === "settled") return Iteration.settled(state);
  return Iteration.advance(nextOf(state), hit[1].measure);
}

function decodeRecurseReq(j: Json): { req: Iteration.RecurseReq<Json> } {
  const required = arrField(j, "required").map(asStr);
  const table = decodeRecurseTable(objVal(j, "table"));
  const nextForm = decodeFunctionForm(objVal(j, "next"));
  const seed = objVal(j, "seed");
  const stepFields = arrField(j, "stepFields").map(asStr);
  const identity = "necoherence.iteration.recurse.adapter.step";
  const step = Call.immediateOf<Json, Iteration.StepOutcome<Json>>(identity, required, (state) =>
    recurseStepOutput(table, (x) => applyFunctionForm(nextForm, x), state)
  );
  return { req: { step, seed, stepFields } };
}

function encodeRecurseOutcome(o: Iteration.RecurseOutcome<Json>): Json {
  if (o.tag === "RecurseSettled") return { tag: "settled", value: o.value, steps: natToJson(o.steps) };
  if (o.tag === "RecurseDidNotDecrease")
    return {
      tag: "did_not_decrease",
      position: natToJson(o.position),
      state: o.state,
      measure: natToJson(o.measure),
      previousMeasure: natToJson(o.previousMeasure),
    };
  return { tag: "projection_failed", lastState: o.lastState, stopped: stageProjectionFailedJson(o.stopped) };
}

function jsonElements(j: Json): Json[] {
  return Array.isArray(j) ? j : [];
}

function closureElemToJson(s: string): Json {
  try {
    return JSON.parse(s) as Json;
  } catch {
    return null;
  }
}

function closureElemOfJson(j: Json): string {
  return JSON.stringify(j);
}

function decodeClosureReq(j: Json): { req: Iteration.ClosureReq<string> } {
  const stepJ = objVal(j, "step");
  const identity = strField(stepJ, "identity");
  const required = arrField(stepJ, "required").map(asStr);
  const form = decodeFunctionForm(objVal(stepJ, "output"));
  const step = Call.immediateOf<Iteration.ClosureState<string>, readonly string[]>(identity, required, (cs) => {
    const elemsJson = cs.elements.map(closureElemToJson);
    const producedJson = applyFunctionForm(form, elemsJson);
    return jsonElements(producedJson).map(closureElemOfJson);
  });
  const carrier = arrField(j, "carrier").map(closureElemOfJson);
  const seed = arrField(j, "seed").map(closureElemOfJson);
  const stepFields = arrField(j, "stepFields").map(asStr);
  return { req: { step, carrier, seed, stepFields } };
}

function encodeClosureElems(elems: readonly string[]): Json {
  return elems.map(closureElemToJson);
}

function encodeClosureOutcome(o: Iteration.ClosureOutcome<string>): Json {
  if (o.tag === "ClosureFixpoint") return { tag: "fixpoint", result: encodeClosureElems(o.result), position: natToJson(o.position) };
  if (o.tag === "ClosureViolation")
    return { tag: "violation", position: natToJson(o.position), current: encodeClosureElems(o.current), produced: encodeClosureElems(o.produced) };
  return { tag: "projection_failed", current: encodeClosureElems(o.current), stopped: stageProjectionFailedJson(o.stopped) };
}

function opIterationFold(input: Json): Json {
  const { req } = decodeFoldReq(input);
  const outcome = Iteration.fold.output(req as unknown as Iteration.FoldReq<unknown>) as unknown as Iteration.FoldOutcome<Json>;
  return encodeFoldOutcome(outcome);
}

function opIterationRecurse(input: Json): Json {
  const { req } = decodeRecurseReq(input);
  const outcome = Iteration.recurse.output(req as unknown as Iteration.RecurseReq<unknown>) as unknown as Iteration.RecurseOutcome<Json>;
  return encodeRecurseOutcome(outcome);
}

function opIterationClosure(input: Json): Json {
  const { req } = decodeClosureReq(input);
  const outcome = Iteration.closure.output(req as unknown as Iteration.ClosureReq<unknown>) as unknown as Iteration.ClosureOutcome<string>;
  return encodeClosureOutcome(outcome);
}


function decodeStore(j: Json): Store.Store<Json> {
  const arr = asArr(j);
  const admission = Store.snapshotStore(
    arr.map((e) => [decodeResourceId(objVal(e, "resource")), decodeRevision(objVal(e, "revision")), objVal(e, "payload")] as const)
  );
  if (admission.tag === "Rejected") fail(`store entries rejected: ${admission.failure.tag}`);
  return admission.value;
}

function encodeStore(s: Store.Store<Json>): Json {
  return s.entries.map((e) => ({ resource: encodeResourceId(e.resource), revision: encodeRevision(e.revision), payload: e.payload }));
}

function encodeObserve(o: Store.Observed<Json>): Json {
  if (o.tag === "Found") return { tag: "found", revision: encodeRevision(o.revision), payload: o.payload };
  return { tag: "unknown", resource: encodeResourceId(o.unknown.resource) };
}

function encodeStoreApplyOutcome(o: Core.Outcome<readonly [Json, Store.Store<Json>], Core.UnknownResource, Core.StaleBasis, ValueFailure>): Json {
  if (o.tag === "Applied") return { tag: "applied", intent: o.value[0], store: encodeStore(o.value[1]) };
  if (o.tag === "Rejected") return { tag: "rejected", resource: encodeResourceId(o.reason.resource) };
  if (o.tag === "Conflicted") return { tag: "conflicted", expected: encodeRevision(o.conflict.expected), actual: encodeRevision(o.conflict.actual) };
  throw new Error("unreachable boundary failure");
}

function opStoreStoreOf(input: Json): Json {
  return encodeStore(decodeStore(input));
}

function opStoreStoreEntries(input: Json): Json {
  const s = decodeStore(objVal(input, "store"));
  return Store.storeEntries(s).map((e) => ({ resource: encodeResourceId(e.resource), revision: encodeRevision(e.revision), payload: e.payload }));
}

function opStoreObserve(input: Json): Json {
  const s = decodeStore(objVal(input, "store"));
  const resource = decodeResourceId(objVal(input, "resource"));
  return encodeObserve(Store.observe(s, resource));
}

function opStoreApply(input: Json): Json {
  const s = decodeStore(objVal(input, "store"));
  const command = decodeCommand(objVal(input, "command"));
  return encodeStoreApplyOutcome(Store.applyStore(s, command));
}

function opStoreWorldOf(input: Json): Json {
  return encodeWorld(Store.worldOfStore(decodeStore(input)));
}


function decodeCallRecord(j: Json): Record.CallRecord<Json, Json> {
  const declaration = strField(j, "declaration");
  const inputV = objVal(j, "input");
  const product = objVal(j, "product");
  const basisJ = objVal(j, "basis");
  const basis: Record.BasisState = basisJ === null ? Record.noBasis() : Record.withBasis(decodeBasis(basisJ));
  return Object.freeze({ declaration, input: inputV, product, basis });
}

function encodeCallRecord(r: Record.CallRecord<Json, Json>): Json {
  return {
    declaration: r.declaration,
    input: r.input,
    product: r.product,
    basis: r.basis.tag === "NoBasis" ? null : encodeBasis(r.basis.basis),
  };
}

function opRecordRecordOf(input: Json): Json {
  const declaration = strField(input, "declaration");
  const ins = objVal(input, "input");
  const product = objVal(input, "product");
  return encodeCallRecord(Record.recordOf(declaration, ins, product));
}

function opRecordRecordOnBasis(input: Json): Json {
  const declaration = strField(input, "declaration");
  const ins = objVal(input, "input");
  const product = objVal(input, "product");
  const basis = decodeBasis(objVal(input, "basis"));
  return encodeCallRecord(Record.recordOnBasis(declaration, ins, product, basis));
}

function opRecordHasEdge(input: Json): Json {
  const earlier = decodeCallRecord(objVal(input, "earlier"));
  const later = decodeCallRecord(objVal(input, "later"));
  return { holds: Record.hasEdge(earlier, later) };
}


function decodeOptionBasis(j: Json): Record.BasisState {
  return j === null ? Record.noBasis() : Record.withBasis(decodeBasis(j));
}

function resourceIdLe(a: Core.ResourceId, b: Core.ResourceId): number {
  if (a.kind !== b.kind) return a.kind < b.kind ? -1 : 1;
  if (a.name !== b.name) return a.name < b.name ? -1 : 1;
  return 0;
}

function divergenceResource(d: Reconcile.Divergence): Core.ResourceId {
  return d.resource;
}

function encodeDivergence(d: Reconcile.Divergence): Json {
  if (d.tag === "WorldAhead") return { tag: "world_ahead", resource: encodeResourceId(d.resource), recorded: encodeRevision(d.recorded), actual: encodeRevision(d.actual) };
  if (d.tag === "WorldBehind") return { tag: "world_behind", resource: encodeResourceId(d.resource), recorded: encodeRevision(d.recorded), actual: encodeRevision(d.actual) };
  return { tag: "unknown_to_world", resource: encodeResourceId(d.resource), recorded: encodeRevision(d.recorded) };
}

function encodeReconciliation(r: Reconcile.Reconciliation): Json {
  const sorted = [...r.divergences].sort((a, b) => resourceIdLe(divergenceResource(a), divergenceResource(b)));
  return { divergences: sorted.map(encodeDivergence), unbased: natToJson(r.unbased), dropped: natToJson(r.dropped) };
}

function opReconcileReconcile(input: Json): Json {
  const bases = arrField(input, "bases").map(decodeOptionBasis);
  const world = decodeWorld(objVal(input, "world"));
  const dropped = natField(input, "dropped");
  return encodeReconciliation(Reconcile.reconcile(bases, world, dropped));
}

function decodeDivergence(j: Json): Reconcile.Divergence {
  const tag = strField(j, "tag");
  if (tag === "world_ahead")
    return { tag: "WorldAhead", resource: decodeResourceId(objVal(j, "resource")), recorded: decodeRevision(objVal(j, "recorded")), actual: decodeRevision(objVal(j, "actual")) };
  if (tag === "world_behind")
    return { tag: "WorldBehind", resource: decodeResourceId(objVal(j, "resource")), recorded: decodeRevision(objVal(j, "recorded")), actual: decodeRevision(objVal(j, "actual")) };
  if (tag === "unknown_to_world")
    return { tag: "UnknownToWorld", resource: decodeResourceId(objVal(j, "resource")), recorded: decodeRevision(objVal(j, "recorded")) };
  fail(`unknown divergence tag ${tag}`);
}

function opReconcileCoherent(input: Json): Json {
  const divergences = arrField(input, "divergences").map(decodeDivergence);
  const unbased = natField(input, "unbased");
  const dropped = natField(input, "dropped");
  const r: Reconcile.Reconciliation = { divergences, unbased, dropped };
  return { coherent: Reconcile.coherent(r) };
}


function decodeRequestPolicy(j: Json): Progression.RequestPolicy {
  const s = asStr(j);
  if (s === "latestWins") return "LatestWins";
  if (s === "fifo") return "Fifo";
  if (s === "allExecute") return "AllExecute";
  fail(`unknown policy ${s}`);
}

function encodeRequestPolicy(p: Progression.RequestPolicy): Json {
  if (p === "LatestWins") return "latestWins";
  if (p === "Fifo") return "fifo";
  return "allExecute";
}

const phaseDecode: Record<string, Progression.RequestPhase> = {
  pending: "Pending",
  preparing: "Preparing",
  publishing: "Publishing",
  published: "Published",
  superseded: "Superseded",
  cancelled: "Cancelled",
  failed: "Failed",
};

const phaseEncode: Record<Progression.RequestPhase, string> = {
  Pending: "pending",
  Preparing: "preparing",
  Publishing: "publishing",
  Published: "published",
  Superseded: "superseded",
  Cancelled: "cancelled",
  Failed: "failed",
};

function decodeRequestPhase(j: Json): Progression.RequestPhase {
  const s = asStr(j);
  const p = phaseDecode[s];
  if (p === undefined) fail(`unknown phase ${s}`);
  return p;
}

function encodeRequestPhase(p: Progression.RequestPhase): Json {
  return phaseEncode[p];
}

function decodeRequestEffectClass(j: Json): Progression.RequestEffectClass {
  const s = asStr(j);
  if (s === "pure") return "Pure";
  if (s === "orderedEffect") return "OrderedEffect";
  fail(`unknown effect class ${s}`);
}

function encodeRequestEffectClass(e: Progression.RequestEffectClass): Json {
  return e === "Pure" ? "pure" : "orderedEffect";
}

function decodeRequestIdentity(j: Json): Progression.RequestIdentity {
  return { kind: strField(j, "kind"), provenance: strField(j, "provenance"), revision: natField(j, "revision") };
}

function encodeRequestIdentity(i: Progression.RequestIdentity): Json {
  return { kind: i.kind, provenance: i.provenance, revision: natToJson(i.revision) };
}

function decodeRequestFootprint(j: Json): Progression.RequestFootprint {
  return {
    reads: arrField(j, "reads").map(asStr),
    writes: arrField(j, "writes").map(asStr),
    effectClass: decodeRequestEffectClass(objVal(j, "effectClass")),
  };
}

function encodeRequestFootprint(f: Progression.RequestFootprint): Json {
  return { reads: [...f.reads], writes: [...f.writes], effectClass: encodeRequestEffectClass(f.effectClass) };
}

function decodeResourceDemand(j: Json): Progression.ResourceDemand {
  return { pending: natField(j, "pending"), inFlight: natField(j, "inFlight"), concurrent: natField(j, "concurrent") };
}

function encodeResourceDemand(d: Progression.ResourceDemand): Json {
  return { pending: natToJson(d.pending), inFlight: natToJson(d.inFlight), concurrent: natToJson(d.concurrent) };
}

function decodeConfiguredSafetyLimit(j: Json): Progression.ConfiguredSafetyLimit {
  return { resource: strField(j, "resource"), maximum: natField(j, "maximum") };
}

function encodeConfiguredSafetyLimit(l: Progression.ConfiguredSafetyLimit): Json {
  return { resource: l.resource, maximum: natToJson(l.maximum) };
}

function decodeResourceBudget(j: Json): Progression.ResourceBudget {
  return {
    pendingMaximum: decodeConfiguredSafetyLimit(objVal(j, "pendingMaximum")),
    inFlightMaximum: decodeConfiguredSafetyLimit(objVal(j, "inFlightMaximum")),
    concurrentMaximum: decodeConfiguredSafetyLimit(objVal(j, "concurrentMaximum")),
  };
}

function encodeResourceBudget(b: Progression.ResourceBudget): Json {
  return {
    pendingMaximum: encodeConfiguredSafetyLimit(b.pendingMaximum),
    inFlightMaximum: encodeConfiguredSafetyLimit(b.inFlightMaximum),
    concurrentMaximum: encodeConfiguredSafetyLimit(b.concurrentMaximum),
  };
}

function decodeEvidenceVersion(j: Json): Progression.EvidenceVersion {
  return { identifier: strField(j, "identifier"), digest: strField(j, "digest"), artifactPath: strField(j, "artifactPath") };
}

function encodeEvidenceVersion(e: Progression.EvidenceVersion): Json {
  return { identifier: e.identifier, digest: e.digest, artifactPath: e.artifactPath };
}

function decodePermissionDenial(j: Json): Progression.PermissionDenial {
  return Progression.permissionDenial(asStr(j));
}

function encodePermissionDenial(p: Progression.PermissionDenial): Json {
  return p.detail;
}

function decodeMeaningPermission(j: Json): Progression.MeaningPermission {
  const tag = strField(j, "tag");
  if (tag === "permitted")
    return { tag: "permitted", identity: decodeRequestIdentity(objVal(j, "identity")), evidence: arrField(j, "evidence").map(decodeEvidenceVersion) };
  if (tag === "ordered")
    return { tag: "ordered", identity: decodeRequestIdentity(objVal(j, "identity")), evidence: arrField(j, "evidence").map(decodeEvidenceVersion) };
  if (tag === "denied")
    return { tag: "denied", identity: decodeRequestIdentity(objVal(j, "identity")), reason: decodePermissionDenial(objVal(j, "reason")) };
  fail(`unknown meaning permission tag ${tag}`);
}

function encodeMeaningPermission(m: Progression.MeaningPermission): Json {
  if (m.tag === "denied") return { tag: "denied", identity: encodeRequestIdentity(m.identity), reason: encodePermissionDenial(m.reason) };
  return { tag: m.tag, identity: encodeRequestIdentity(m.identity), evidence: m.evidence.map(encodeEvidenceVersion) };
}

function decodeExecutionHandle(j: Json): Progression.ExecutionHandle {
  return { value: asStr(j) };
}

function encodeExecutionHandle(h: Progression.ExecutionHandle): Json {
  return h.value;
}

function decodeCostSelection(j: Json): Progression.CostSelection {
  const tag = strField(j, "tag");
  const identity = decodeRequestIdentity(objVal(j, "identity"));
  const evidence = decodeEvidenceVersion(objVal(j, "evidence"));
  const cost = natField(j, "cost");
  if (tag === "executeNow") return { tag: "executeNow", identity, evidence, cost };
  if (tag === "remainPending") return { tag: "remainPending", identity, evidence, cost };
  fail(`unknown cost selection tag ${tag}`);
}

function encodeCostSelection(c: Progression.CostSelection): Json {
  return {
    tag: c.tag,
    identity: encodeRequestIdentity(c.identity),
    evidence: encodeEvidenceVersion(c.evidence),
    cost: natToJson(c.cost),
  };
}

function decodeRequestEntry(j: Json): Progression.RequestEntry {
  return {
    identity: decodeRequestIdentity(objVal(j, "identity")),
    footprint: decodeRequestFootprint(objVal(j, "footprint")),
    demand: decodeResourceDemand(objVal(j, "demand")),
    phase: decodeRequestPhase(objVal(j, "phase")),
    meaningPermission: decodeMeaningPermission(objVal(j, "meaningPermission")),
    costSelection: orNull(objVal(j, "costSelection"), decodeCostSelection),
    executionHandle: orNull(objVal(j, "executionHandle"), decodeExecutionHandle),
  };
}

function encodeRequestEntry(e: Progression.RequestEntry): Json {
  return {
    identity: encodeRequestIdentity(e.identity),
    footprint: encodeRequestFootprint(e.footprint),
    demand: encodeResourceDemand(e.demand),
    phase: encodeRequestPhase(e.phase),
    meaningPermission: encodeMeaningPermission(e.meaningPermission),
    costSelection: e.costSelection === null ? null : encodeCostSelection(e.costSelection),
    executionHandle: e.executionHandle === null ? null : encodeExecutionHandle(e.executionHandle),
  };
}

function decodeRequestProgressionSnapshot(j: Json): Progression.RequestProgressionSnapshot {
  return {
    policy: decodeRequestPolicy(objVal(j, "policy")),
    budget: decodeResourceBudget(objVal(j, "budget")),
    currentIdentity: orNull(objVal(j, "currentIdentity"), decodeRequestIdentity),
    entries: arrField(j, "entries").map(decodeRequestEntry),
    revision: natField(j, "revision"),
  };
}

function encodeRequestProgressionSnapshot(s: Progression.RequestProgressionSnapshot): Json {
  return {
    policy: encodeRequestPolicy(s.policy),
    budget: encodeResourceBudget(s.budget),
    currentIdentity: s.currentIdentity === null ? null : encodeRequestIdentity(s.currentIdentity),
    entries: s.entries.map(encodeRequestEntry),
    revision: natToJson(s.revision),
  };
}

function decodeRequestInput(j: Json): Progression.RequestInput {
  return {
    identity: decodeRequestIdentity(objVal(j, "identity")),
    footprint: decodeRequestFootprint(objVal(j, "footprint")),
    demand: decodeResourceDemand(objVal(j, "demand")),
    permission: decodeMeaningPermission(objVal(j, "permission")),
  };
}

function decodeAccepted(j: Json): Progression.Accepted {
  return { identity: decodeRequestIdentity(objVal(j, "identity")) };
}

function encodeAccepted(a: Progression.Accepted): Json {
  return { identity: encodeRequestIdentity(a.identity) };
}

function decodeRunning(j: Json): Progression.Running {
  return { identity: decodeRequestIdentity(objVal(j, "identity")), handle: decodeExecutionHandle(objVal(j, "handle")) };
}

function encodeRunning(r: Progression.Running): Json {
  return { identity: encodeRequestIdentity(r.identity), handle: encodeExecutionHandle(r.handle) };
}

function encodeAdapterCommand(c: Progression.AdapterCommand): Json {
  if (c.tag === "startCommand") return { tag: "startCommand", identity: encodeRequestIdentity(c.identity), footprint: encodeRequestFootprint(c.footprint) };
  return { tag: "cancelCommand", identity: encodeRequestIdentity(c.identity), handle: encodeExecutionHandle(c.handle) };
}

function decodeStarting(j: Json): Progression.Starting {
  return { identity: decodeRequestIdentity(objVal(j, "identity")), command: decodeAdapterCommand(objVal(j, "command")) };
}

function encodeStarting(s: Progression.Starting): Json {
  return { identity: encodeRequestIdentity(s.identity), command: encodeAdapterCommand(s.command) };
}

function decodeAdapterCommand(j: Json): Progression.AdapterCommand {
  const tag = strField(j, "tag");
  if (tag === "startCommand") return { tag: "startCommand", identity: decodeRequestIdentity(objVal(j, "identity")), footprint: decodeRequestFootprint(objVal(j, "footprint")) };
  if (tag === "cancelCommand") return { tag: "cancelCommand", identity: decodeRequestIdentity(objVal(j, "identity")), handle: decodeExecutionHandle(objVal(j, "handle")) };
  fail(`unknown adapter command tag ${tag}`);
}

function decodeAdapterSignal(j: Json): Progression.AdapterSignal<Json> {
  const tag = strField(j, "tag");
  if (tag === "started") return { tag: "started", identity: decodeRequestIdentity(objVal(j, "identity")), handle: decodeExecutionHandle(objVal(j, "handle")) };
  if (tag === "completed") return { tag: "completed", identity: decodeRequestIdentity(objVal(j, "identity")), handle: decodeExecutionHandle(objVal(j, "handle")), value: objVal(j, "value") };
  if (tag === "cancelledAtAdapter") return { tag: "cancelledAtAdapter", identity: decodeRequestIdentity(objVal(j, "identity")), handle: decodeExecutionHandle(objVal(j, "handle")) };
  fail(`unknown adapter signal tag ${tag}`);
}

function decodeAdapterFailure(j: Json): Progression.AdapterFailure {
  const tag = strField(j, "tag");
  if (tag === "startAdapterFailure") return { tag: "startAdapterFailure", identity: decodeRequestIdentity(objVal(j, "identity")), detail: strField(j, "detail") };
  if (tag === "completionAdapterFailure") return { tag: "completionAdapterFailure", identity: decodeRequestIdentity(objVal(j, "identity")), handle: decodeExecutionHandle(objVal(j, "handle")), detail: strField(j, "detail") };
  if (tag === "cancellationAdapterFailure") return { tag: "cancellationAdapterFailure", identity: decodeRequestIdentity(objVal(j, "identity")), handle: decodeExecutionHandle(objVal(j, "handle")), detail: strField(j, "detail") };
  fail(`unknown adapter failure tag ${tag}`);
}

function decodeAdapterResult(j: Json): Progression.AdapterResult<Progression.AdapterSignal<Json>, Progression.AdapterFailure> {
  const tag = strField(j, "tag");
  if (tag === "appliedSignal") return { tag: "appliedSignal", signal: decodeAdapterSignal(objVal(j, "signal")) };
  if (tag === "adapterFailed") return { tag: "adapterFailed", failure: decodeAdapterFailure(objVal(j, "failure")) };
  fail(`unknown adapter result tag ${tag}`);
}

function encodeSubmitFailure(f: Progression.SubmitFailure): Json {
  if (f.tag === "duplicateIdentity") return { tag: f.tag, identity: encodeRequestIdentity(f.identity) };
  return { tag: f.tag, demand: encodeResourceDemand(f.demand), budget: encodeResourceBudget(f.budget) };
}

function encodeSubmitResult(r: Progression.SubmitResult): Json {
  if (r.tag === "accepted") return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), accepted: encodeAccepted(r.accepted) };
  return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), failure: encodeSubmitFailure(r.failure) };
}

function encodeStartDecisionFailure(f: Progression.StartDecisionFailure): Json {
  if (f.tag === "permissionDenied") return { tag: f.tag, identity: encodeRequestIdentity(f.identity), reason: encodePermissionDenial(f.reason) };
  if (f.tag === "permissionIdentityMismatch" || f.tag === "costSelectionIdentityMismatch") return { tag: f.tag, identity: encodeRequestIdentity(f.identity), other: encodeRequestIdentity(f.other) };
  if (f.tag === "inFlightLimitExceeded" || f.tag === "concurrentLimitExceeded") return { tag: f.tag, demand: encodeResourceDemand(f.demand), budget: encodeResourceBudget(f.budget) };
  return { tag: f.tag, identity: encodeRequestIdentity(f.identity) };
}

function encodeStartDecisionResult(r: Progression.StartDecisionResult): Json {
  if (r.tag === "execute") return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), starting: encodeStarting(r.starting), command: encodeAdapterCommand(r.command) };
  if (r.tag === "deferred") return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), accepted: encodeAccepted(r.accepted) };
  return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), failure: encodeStartDecisionFailure(r.failure) };
}

function encodeStartObservationFailure(f: Progression.StartObservationFailure): Json {
  if (f.tag === "startIdentityMismatch") return { tag: f.tag, identity: encodeRequestIdentity(f.identity), other: encodeRequestIdentity(f.other) };
  if (f.tag === "startAdapterFailureObserved") return { tag: f.tag, identity: encodeRequestIdentity(f.identity), detail: f.detail };
  return { tag: f.tag, identity: encodeRequestIdentity(f.identity) };
}

function encodeStartObservationResult(r: Progression.StartObservationResult): Json {
  if (r.tag === "publishing") return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), running: encodeRunning(r.running) };
  return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), failure: encodeStartObservationFailure(r.failure) };
}

function encodeCompletionObservationFailure(f: Progression.CompletionObservationFailure): Json {
  if (f.tag === "completionIdentityMismatch") return { tag: f.tag, identity: encodeRequestIdentity(f.identity), other: encodeRequestIdentity(f.other) };
  if (f.tag === "completionAdapterFailureObserved" || f.tag === "cancellationAdapterFailureObserved") return { tag: f.tag, identity: encodeRequestIdentity(f.identity), detail: f.detail };
  return { tag: f.tag, identity: encodeRequestIdentity(f.identity) };
}

function encodeCompletionObservationResult(r: Progression.CompletionObservationResult<Json>): Json {
  if (r.tag === "applied") return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), identity: encodeRequestIdentity(r.identity), value: r.value };
  if (r.tag === "superseded" || r.tag === "cancelled") return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), identity: encodeRequestIdentity(r.identity) };
  return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), failure: encodeCompletionObservationFailure(r.failure) };
}

function encodeCancelFailure(f: Progression.CancelFailure): Json {
  return { tag: f.tag, identity: encodeRequestIdentity(f.identity) };
}

function encodeCancelDecisionResult(r: Progression.CancelDecisionResult): Json {
  if (r.tag === "cancelled") return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), identity: encodeRequestIdentity(r.identity) };
  if (r.tag === "cancelCommand") return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), running: encodeRunning(r.running), command: encodeAdapterCommand(r.command) };
  return { tag: r.tag, snapshot: encodeRequestProgressionSnapshot(r.snapshot), failure: encodeCancelFailure(r.failure) };
}

function opRequestProgressionEmpty(input: Json): Json {
  const policy = decodeRequestPolicy(objVal(input, "policy"));
  const budget = decodeResourceBudget(objVal(input, "budget"));
  return encodeRequestProgressionSnapshot(Progression.empty(policy, budget));
}

function opRequestProgressionSubmit(input: Json): Json {
  const snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
  const request = decodeRequestInput(objVal(input, "request"));
  return encodeSubmitResult(Progression.submit(snapshot, request));
}

function opRequestProgressionDecideStart(input: Json): Json {
  const snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
  const accepted = decodeAccepted(objVal(input, "accepted"));
  const selection = decodeCostSelection(objVal(input, "selection"));
  return encodeStartDecisionResult(Progression.decideStart(snapshot, accepted, selection));
}

function opRequestProgressionApplyStartObservation(input: Json): Json {
  const snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
  const starting = decodeStarting(objVal(input, "starting"));
  const observed = decodeAdapterResult(objVal(input, "observed"));
  return encodeStartObservationResult(Progression.applyStartObservation(snapshot, starting, observed));
}

function opRequestProgressionApplyCompletionObservation(input: Json): Json {
  const snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
  const running = decodeRunning(objVal(input, "running"));
  const observed = decodeAdapterResult(objVal(input, "observed"));
  return encodeCompletionObservationResult(Progression.applyCompletionObservation(snapshot, running, observed));
}

function opRequestProgressionDecideCancel(input: Json): Json {
  const snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
  const identity = decodeRequestIdentity(objVal(input, "identity"));
  return encodeCancelDecisionResult(Progression.decideCancel(snapshot, identity));
}

function opRequestProgressionDerivePending(input: Json): Json {
  const snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
  return encodeResourceDemand(Progression.derivePending(snapshot));
}

function opRequestProgressionDeriveInFlight(input: Json): Json {
  const snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
  return encodeResourceDemand(Progression.deriveInFlight(snapshot));
}

function opRequestProgressionDeriveConcurrent(input: Json): Json {
  const snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
  return encodeResourceDemand(Progression.deriveConcurrent(snapshot));
}


function decodeEnvironmentSpecification(j: Json): Admission.EnvironmentSpecification {
  return { maxObservationAge: natField(j, "maxObservationAge") };
}

function decodeCapacityObservation(j: Json): Admission.CapacityObservation {
  return { observed: decodeResourceBudget(objVal(j, "observed")), observedAt: natField(j, "observedAt") };
}

function decodeSignalKind(j: Json): Admission.SignalKind {
  const s = asStr(j);
  if (s === "pendingCompletion") return "PendingCompletion";
  if (s === "pendingCancellation") return "PendingCancellation";
  fail(`unknown signal kind ${s}`);
}

function encodeSignalKind(k: Admission.SignalKind): Json {
  return k === "PendingCompletion" ? "pendingCompletion" : "pendingCancellation";
}

function decodeAdmissionSignal(j: Json): Admission.AdmissionSignal {
  return {
    identity: decodeRequestIdentity(objVal(j, "identity")),
    handle: decodeExecutionHandle(objVal(j, "handle")),
    kind: decodeSignalKind(objVal(j, "kind")),
  };
}

function encodeAdmissionSignal(s: Admission.AdmissionSignal): Json {
  return { identity: encodeRequestIdentity(s.identity), handle: encodeExecutionHandle(s.handle), kind: encodeSignalKind(s.kind) };
}

function decodeAdmissionProvenance(j: Json): Admission.AdmissionProvenance {
  return {
    futureUses: arrField(j, "futureUses").map(decodeRequestIdentity),
    outstandingSignals: arrField(j, "outstandingSignals").map(decodeAdmissionSignal),
  };
}

function encodeAdmissionProvenance(p: Admission.AdmissionProvenance): Json {
  return { futureUses: p.futureUses.map(encodeRequestIdentity), outstandingSignals: p.outstandingSignals.map(encodeAdmissionSignal) };
}

function decodeDynamicAdmissionState(j: Json): Admission.DynamicAdmissionState {
  return {
    progression: decodeRequestProgressionSnapshot(objVal(j, "progression")),
    configuredSafetyLimit: decodeResourceBudget(objVal(j, "configuredSafetyLimit")),
    provenance: decodeAdmissionProvenance(objVal(j, "provenance")),
  };
}

function encodeDynamicAdmissionState(s: Admission.DynamicAdmissionState): Json {
  return {
    progression: encodeRequestProgressionSnapshot(s.progression),
    configuredSafetyLimit: encodeResourceBudget(s.configuredSafetyLimit),
    provenance: encodeAdmissionProvenance(s.provenance),
  };
}

function decodeDynamicAdmissionInput(j: Json): Admission.DynamicAdmissionInput {
  return {
    state: decodeDynamicAdmissionState(objVal(j, "state")),
    request: decodeRequestInput(objVal(j, "request")),
    environmentSpecification: decodeEnvironmentSpecification(objVal(j, "environmentSpecification")),
    capacityObservation: decodeCapacityObservation(objVal(j, "capacityObservation")),
    observedAt: natField(j, "observedAt"),
    start: orNull(objVal(j, "start"), decodeCostSelection),
  };
}

function encodeDynamicAdmissionFailure(f: Admission.DynamicAdmissionFailure): Json {
  switch (f.tag) {
    case "CapacityObservationUnavailable":
      return { tag: "capacityObservationUnavailable", age: natToJson(f.age), maxAge: natToJson(f.maxAge) };
    case "ResourceCoordinateMismatch":
      return { tag: "resourceCoordinateMismatch", configuredResource: f.configuredResource, observedResource: f.observedResource };
    case "ConfiguredSafetyLimitExceeded":
      return { tag: "configuredSafetyLimitExceeded", resource: f.resource, occupied: natToJson(f.occupied), allowed: natToJson(f.allowed) };
    case "MeaningDenied":
      return { tag: "meaningDenied", identity: encodeRequestIdentity(f.identity), reason: encodePermissionDenial(f.reason) };
    case "PermissionIdentityMismatch":
      return { tag: "permissionIdentityMismatch", requestIdentity: encodeRequestIdentity(f.requestIdentity), permissionIdentity: encodeRequestIdentity(f.permissionIdentity) };
    case "AdapterBindingUnavailable":
      return { tag: "adapterBindingUnavailable", identity: encodeRequestIdentity(f.identity) };
    case "BindingSelectionMismatch":
      return { tag: "bindingSelectionMismatch", identity: encodeRequestIdentity(f.identity) };
    case "ProgressionSubmitFailure":
      return { tag: "progressionSubmitFailure", failure: encodeSubmitFailure(f.failure) };
    case "ProgressionStartFailure":
      return { tag: "progressionStartFailure", failure: encodeStartDecisionFailure(f.failure) };
    case "ProvenanceRetentionRequired":
      return { tag: "provenanceRetentionRequired", identity: encodeRequestIdentity(f.identity) };
    case "UnknownRequest":
      return { tag: "unknownRequest", identity: encodeRequestIdentity(f.identity) };
    case "RequestNotTerminal":
      return { tag: "requestNotTerminal", identity: encodeRequestIdentity(f.identity) };
  }
}

function encodeAdmissionDecision(d: Admission.AdmissionDecision): Json {
  if (d.tag === "Submitted") return { tag: "submitted", state: encodeDynamicAdmissionState(d.state), accepted: encodeAccepted(d.accepted) };
  if (d.tag === "Started") return { tag: "started", state: encodeDynamicAdmissionState(d.state), result: encodeStartDecisionResult(d.result) };
  return { tag: "coalesced", state: encodeDynamicAdmissionState(d.state), identity: encodeRequestIdentity(d.identity) };
}

function encodeProvenanceErasureWitness(w: Admission.ProvenanceErasureWitness): Json {
  if (w.tag === "Erased") return { tag: "erased", identity: encodeRequestIdentity(w.identity) };
  return { tag: "retained", identity: encodeRequestIdentity(w.identity), reason: w.reason };
}

function encodeCoalescingWitness(w: Admission.CoalescingWitness): Json {
  if (w.tag === "Coalesced") return { tag: "coalesced", identity: encodeRequestIdentity(w.identity) };
  return { tag: "notCoalesced", reason: w.reason };
}

function encodeDynamicAdmissionResult(r: Admission.DynamicAdmissionResult): Json {
  return {
    effectiveBudget: encodeResourceBudget(r.effectiveBudget),
    admissionDecision: encodeAdmissionDecision(r.admissionDecision),
    futureUseSet: r.futureUseSet.identities.map(encodeRequestIdentity),
    outstandingSignalSet: r.outstandingSignalSet.signals.map(encodeAdmissionSignal),
    provenanceErasureWitness: r.provenanceErasureWitness === null ? null : encodeProvenanceErasureWitness(r.provenanceErasureWitness),
    coalescingWitness: encodeCoalescingWitness(r.coalescingWitness),
  };
}

function encodeDynamicAdmissionOutcome(o: Core.Outcome<Admission.DynamicAdmissionResult, Admission.DynamicAdmissionFailure, never, never>): Json {
  if (o.tag === "Applied") return { tag: "applied", value: encodeDynamicAdmissionResult(o.value) };
  if (o.tag === "Rejected") return { tag: "rejected", failure: encodeDynamicAdmissionFailure(o.reason) };
  throw new Error("unreachable conflicted/boundaryFailed");
}

function encodeElisionOutcome(
  o: Core.Outcome<readonly [Admission.DynamicAdmissionState, Admission.ProvenanceErasureWitness], Admission.DynamicAdmissionFailure, never, never>
): Json {
  if (o.tag === "Applied") return { tag: "applied", state: encodeDynamicAdmissionState(o.value[0]), witness: encodeProvenanceErasureWitness(o.value[1]) };
  if (o.tag === "Rejected") return { tag: "rejected", failure: encodeDynamicAdmissionFailure(o.reason) };
  throw new Error("unreachable conflicted/boundaryFailed");
}

function opDynamicAdmissionElideAdmissionProvenance(input: Json): Json {
  const state = decodeDynamicAdmissionState(objVal(input, "state"));
  const identity = decodeRequestIdentity(objVal(input, "identity"));
  return encodeElisionOutcome(Admission.elideAdmissionProvenance(state, identity));
}

function opDynamicAdmissionAdmitDynamicRequest(input: Json): Json {
  const admissionInput = decodeDynamicAdmissionInput(input);
  return encodeDynamicAdmissionOutcome(Admission.admitDynamicRequest(admissionInput));
}


type AdvanceEval = (state: Json, input: Json) => Transition.Consumption<Json, Json>;

function decodeAdvanceForm(j: Json): AdvanceForm {
  const mode = strField(j, "mode");
  if (mode === "consumeImmediately") return { mode: "consumeImmediately", outputs: arrField(j, "outputs") };
  if (mode === "reprocessAlways") return { mode: "reprocessAlways", outputs: arrField(j, "outputs") };
  if (mode === "consumeAfter") return { mode: "consumeAfter", rounds: natField(j, "rounds"), outputsPerRound: arrField(j, "outputsPerRound") };
  fail(`unknown advance mode ${mode}`);
}

function roundOf(state: Json): bigint {
  const r = state !== null && typeof state === "object" && !Array.isArray(state) ? (state as Record<string, Json>).round : undefined;
  if (typeof r === "string" && /^[0-9]+$/.test(r)) return BigInt(r);
  return 0n;
}

function stateWithRound(n: bigint): Json {
  return { round: n.toString() };
}

function advanceEval(form: AdvanceForm): AdvanceEval {
  return (state: Json) => {
    if (form.mode === "consumeImmediately") return Transition.consumed(state, form.outputs);
    if (form.mode === "reprocessAlways") return Transition.reprocess(state, form.outputs);
    const r = roundOf(state) + 1n;
    const newState = stateWithRound(r);
    return r >= form.rounds ? Transition.consumed(newState, form.outputsPerRound) : Transition.reprocess(newState, form.outputsPerRound);
  };
}

function encodeStepFailure(f: Transition.StepFailure): Json {
  if (f.tag === "ReprocessLimitExhausted") return { tag: "reprocess_limit_exhausted", applications: natToJson(f.applications) };
  return { tag: "capacity_exceeded", capacity: natToJson(f.capacity), attempted: natToJson(f.attempted) };
}

function encodeStepTransition(t: Transition.StepTransition<Json, Json>): Json {
  if (t.tag === "Settled") return { tag: "settled", state: t.state, outputs: [...t.outputs], applications: natToJson(t.applications) };
  return { tag: "failed", state: t.state, outputs: [...t.outputs], failure: encodeStepFailure(t.failure) };
}

function opStepTransitionStep(input: Json): Json {
  const state = objVal(input, "state");
  const inp = objVal(input, "input");
  const form = decodeAdvanceForm(objVal(input, "advance"));
  const limitN = natField(input, "limit");
  const capacityN = natField(input, "capacity");
  if (limitN <= 0n) fail("limit must be positive");
  const limit = Transition.positiveLimit(limitN);
  const cap = Transition.capacity(capacityN);
  if (!("kind" in limit) || !("kind" in cap)) fail("limit or capacity invalid");
  return encodeStepTransition(Transition.step(state, inp, advanceEval(form), limit as Transition.PositiveLimit, cap as Transition.Capacity));
}


function decodeNormalizedPath(j: Json): FileEffect.NormalizedPath {
  const root = asBool(objVal(j, "root"));
  const segments = arrField(j, "segments").map(asStr);
  return { root, segments };
}

function encodeNormalizedPath(p: FileEffect.NormalizedPath): Json {
  return { root: p.root, segments: [...p.segments] };
}

function decodeContentDigest(j: Json): FileEffect.ContentDigest {
  return { value: asStr(j) };
}

function encodeContentDigest(d: FileEffect.ContentDigest): Json {
  return d.value;
}

function decodeByte(j: Json): number {
  const n = natOfStr(asStr(j));
  if (n >= 256n) fail("byte out of range");
  return Number(n);
}

function encodeByte(b: number): Json {
  return b.toString();
}

function decodeBytes(j: Json): readonly number[] {
  return asArr(j).map(decodeByte);
}

function encodeBytes(bs: readonly number[]): Json {
  return bs.map(encodeByte);
}

function decodeFileRecord(j: Json): FileEffect.FileRecord {
  return { digest: decodeContentDigest(objVal(j, "digest")), bytes: decodeBytes(objVal(j, "bytes")) };
}

function encodeFileRecord(r: FileEffect.FileRecord): Json {
  return { digest: encodeContentDigest(r.digest), bytes: encodeBytes(r.bytes) };
}

function decodeExternalFileState(j: Json): FileEffect.ExternalFileState {
  const files = arrField(j, "files").map((e) => [decodeNormalizedPath(objVal(e, "path")), decodeFileRecord(objVal(e, "record"))] as const);
  const readFailures = arrField(j, "readFailures").map(decodeNormalizedPath);
  const writeFailures = arrField(j, "writeFailures").map(decodeNormalizedPath);
  return { files, readFailures, writeFailures };
}

function encodeExternalFileState(s: FileEffect.ExternalFileState): Json {
  return {
    files: s.files.map(([path, record]) => ({ path: encodeNormalizedPath(path), record: encodeFileRecord(record) })),
    readFailures: s.readFailures.map(encodeNormalizedPath),
    writeFailures: s.writeFailures.map(encodeNormalizedPath),
  };
}

function decodeDigests(j: Json): FileEffect.Digests {
  const arr = asArr(j);
  return { entries: arr.map((e) => [decodeResourceId(objVal(e, "resource")), decodeContentDigest(objVal(e, "digest"))] as const) };
}

function encodeDigests(d: FileEffect.Digests): Json {
  return d.entries.map(([resource, digest]) => ({ resource: encodeResourceId(resource), digest: encodeContentDigest(digest) }));
}

function encodeDigestLookup(l: FileEffect.DigestLookup): Json {
  if (l.tag === "Found") return { tag: "found", digest: encodeContentDigest(l.digest) };
  return { tag: "unobserved", resource: encodeResourceId(l.unobserved.resource) };
}

function encodeObservation<A>(encodePayload: (a: A) => Json, o: Core.Observation<A>): Json {
  return { payload: encodePayload(o.payload), basis: encodeBasis(o.basis), observedAt: natToJson(o.observedAt) };
}

function encodeFileSnapshot(s: FileEffect.FileSnapshot): Json {
  return { path: encodeNormalizedPath(s.path), contents: encodeBytes(s.contents), digest: encodeContentDigest(s.digest) };
}

function encodeTrackResult(t: FileEffect.TrackResult): Json {
  return {
    tag: "applied",
    observation: encodeObservation((r: { readonly value: bigint }) => encodeRevision(r as Core.Revision), t.value.observation),
    world: encodeWorld(t.value.world),
  };
}

function encodeReadResult(r: FileEffect.ReadResult): Json {
  if (r.tag === "Applied")
    return {
      tag: "applied",
      observation: encodeObservation(encodeFileSnapshot, r.value.observation),
      world: encodeWorld(r.value.world),
      digests: encodeDigests(r.value.digests),
    };
  if (r.tag === "Rejected") return { tag: "rejected", resource: encodeResourceId(r.reason.resource) };
  return { tag: "boundaryFailed", path: encodeNormalizedPath(r.failure.path) };
}

function decodeReplaceContents(j: Json): FileEffect.ReplaceContents {
  return { newContents: decodeBytes(objVal(j, "newContents")), newDigest: decodeContentDigest(objVal(j, "newDigest")) };
}

function encodeReplaceRejection(r: FileEffect.ReplaceRejection): Json {
  if (r.tag === "ResourcePathMismatch") return { tag: "resourcePathMismatch", resource: encodeResourceId(r.mismatch.resource), path: encodeNormalizedPath(r.mismatch.path) };
  if (r.tag === "UnknownResource") return { tag: "unknownResource", resource: encodeResourceId(r.unknown.resource) };
  return { tag: "unobservedContents", resource: encodeResourceId(r.unobserved.resource) };
}

function encodeReplaceConflict(c: FileEffect.ReplaceConflict): Json {
  if (c.tag === "StaleBasis") return { tag: "staleBasis", expected: encodeRevision(c.staleBasis.expected), actual: encodeRevision(c.staleBasis.actual) };
  return { tag: "externalMutation", expected: encodeContentDigest(c.mutation.expected), actual: encodeContentDigest(c.mutation.actual) };
}

function encodeReplaceResult(r: FileEffect.ReplaceResult): Json {
  if (r.tag === "Applied")
    return {
      tag: "applied",
      observation: encodeObservation(encodeFileSnapshot, r.value.observation),
      world: encodeWorld(r.value.world),
      digests: encodeDigests(r.value.digests),
      state: encodeExternalFileState(r.value.state),
    };
  if (r.tag === "Rejected") return { tag: "rejected", rejection: encodeReplaceRejection(r.rejection) };
  if (r.tag === "Conflicted") return { tag: "conflicted", conflict: encodeReplaceConflict(r.conflict) };
  return { tag: "boundaryFailed", path: encodeNormalizedPath(r.failure.path) };
}

function opFileEffectNormalizePath(input: Json): Json {
  const root = asBool(objVal(input, "root"));
  const raw = arrField(input, "raw").map(asStr);
  return encodeNormalizedPath(FileEffect.normalizePath(root, raw));
}

function opFileEffectLookupDigest(input: Json): Json {
  const digests = decodeDigests(objVal(input, "digests"));
  const resource = decodeResourceId(objVal(input, "resource"));
  return encodeDigestLookup(FileEffect.lookupDigest(digests, resource));
}

function opFileEffectSetDigest(input: Json): Json {
  const digests = decodeDigests(objVal(input, "digests"));
  const resource = decodeResourceId(objVal(input, "resource"));
  const digest = decodeContentDigest(objVal(input, "digest"));
  return encodeDigests(FileEffect.setDigest(digests, resource, digest));
}

function opFileEffectTrack(input: Json): Json {
  const path = decodeNormalizedPath(objVal(input, "path"));
  const world = decodeWorld(objVal(input, "world"));
  const observedAt = natField(input, "observedAt");
  return encodeTrackResult(FileEffect.track({ path, world, observedAt }));
}

function opFileEffectRead(input: Json): Json {
  const path = decodeNormalizedPath(objVal(input, "path"));
  const world = decodeWorld(objVal(input, "world"));
  const digests = decodeDigests(objVal(input, "digests"));
  const state = decodeExternalFileState(objVal(input, "state"));
  const observedAt = natField(input, "observedAt");
  return encodeReadResult(FileEffect.read({ path, world, digests, state, observedAt }));
}

function opFileEffectReplace(input: Json): Json {
  const intent = decodeReplaceContents(objVal(input, "intent"));
  const basis = decodeBasis(objVal(input, "basis"));
  const command: Core.Command<FileEffect.ReplaceContents> = { intent, basis };
  const path = decodeNormalizedPath(objVal(input, "path"));
  const world = decodeWorld(objVal(input, "world"));
  const digests = decodeDigests(objVal(input, "digests"));
  const state = decodeExternalFileState(objVal(input, "state"));
  const observedAt = natField(input, "observedAt");
  return encodeReplaceResult(FileEffect.replace({ command, path, world, digests, state, observedAt }));
}


const surfaceEntries: readonly (readonly [string, readonly string[]])[] = [
  ["core", ["lookup", "bump", "commandOf", "apply"]],
  ["call", ["immediateOf", "deferredOf", "io", "issue"]],
  ["iteration", ["fold", "recurse", "closure"]],
  ["store", ["storeOf", "storeEntries", "observe", "apply", "worldOf"]],
  ["record", ["recordOf", "recordOnBasis", "hasEdge"]],
  ["reconcile", ["reconcile", "coherent"]],
  ["request_progression", ["empty", "submit", "decideStart", "applyStartObservation", "applyCompletionObservation", "decideCancel", "derivePending", "deriveInFlight", "deriveConcurrent"]],
  ["dynamic_admission", ["elideAdmissionProvenance", "admitDynamicRequest"]],
  ["step_transition", ["step"]],
  ["file_effect", ["normalizePath", "lookupDigest", "setDigest", "track", "read", "replace"]],
];

const knownFeatures = new Set(surfaceEntries.map(([feature]) => feature));

function surfaceJson(): Json {
  return {
    kind: "surface",
    features: surfaceEntries.map(([feature, ops]) => ({ feature, operations: [...ops] })),
  };
}


function dispatch(feature: string, operation: string, input: Json): Json {
  const key = `${feature}.${operation}`;
  switch (key) {
    case "core.lookup":
      return opCoreLookup(input);
    case "core.bump":
      return opCoreBump(input);
    case "core.commandOf":
      return opCoreCommandOf(input);
    case "core.apply":
      return opCoreApply(input);
    case "call.immediateOf":
      return opCallImmediateOf(input);
    case "call.deferredOf":
      return opCallDeferredOf(input);
    case "call.io":
      return opCallIo(input);
    case "call.issue":
      return opCallIssue(input);
    case "iteration.fold":
      return opIterationFold(input);
    case "iteration.recurse":
      return opIterationRecurse(input);
    case "iteration.closure":
      return opIterationClosure(input);
    case "store.storeOf":
      return opStoreStoreOf(input);
    case "store.storeEntries":
      return opStoreStoreEntries(input);
    case "store.observe":
      return opStoreObserve(input);
    case "store.apply":
      return opStoreApply(input);
    case "store.worldOf":
      return opStoreWorldOf(input);
    case "record.recordOf":
      return opRecordRecordOf(input);
    case "record.recordOnBasis":
      return opRecordRecordOnBasis(input);
    case "record.hasEdge":
      return opRecordHasEdge(input);
    case "reconcile.reconcile":
      return opReconcileReconcile(input);
    case "reconcile.coherent":
      return opReconcileCoherent(input);
    case "request_progression.empty":
      return opRequestProgressionEmpty(input);
    case "request_progression.submit":
      return opRequestProgressionSubmit(input);
    case "request_progression.decideStart":
      return opRequestProgressionDecideStart(input);
    case "request_progression.applyStartObservation":
      return opRequestProgressionApplyStartObservation(input);
    case "request_progression.applyCompletionObservation":
      return opRequestProgressionApplyCompletionObservation(input);
    case "request_progression.decideCancel":
      return opRequestProgressionDecideCancel(input);
    case "request_progression.derivePending":
      return opRequestProgressionDerivePending(input);
    case "request_progression.deriveInFlight":
      return opRequestProgressionDeriveInFlight(input);
    case "request_progression.deriveConcurrent":
      return opRequestProgressionDeriveConcurrent(input);
    case "dynamic_admission.elideAdmissionProvenance":
      return opDynamicAdmissionElideAdmissionProvenance(input);
    case "dynamic_admission.admitDynamicRequest":
      return opDynamicAdmissionAdmitDynamicRequest(input);
    case "step_transition.step":
      return opStepTransitionStep(input);
    case "file_effect.normalizePath":
      return opFileEffectNormalizePath(input);
    case "file_effect.lookupDigest":
      return opFileEffectLookupDigest(input);
    case "file_effect.setDigest":
      return opFileEffectSetDigest(input);
    case "file_effect.track":
      return opFileEffectTrack(input);
    case "file_effect.read":
      return opFileEffectRead(input);
    case "file_effect.replace":
      return opFileEffectReplace(input);
    default:
      if (knownFeatures.has(feature)) throw new DecodeFailure("unknown_operation", key);
      throw new DecodeFailure("unknown_feature", feature);
  }
}

function processRequest(j: Json): Json {
  const feature = strField(j, "feature");
  const operation = strField(j, "operation");
  const input = objVal(j, "input");
  const result = dispatch(feature, operation, input);
  return { feature, operation, result };
}

function topKind(j: Json): string {
  if (j === null || typeof j !== "object" || Array.isArray(j)) throw new DecodeFailure("query_shape", "missing or invalid top-level kind");
  const k = (j as Record<string, Json>).kind;
  if (typeof k !== "string") throw new DecodeFailure("query_shape", "missing or invalid top-level kind");
  return k;
}

function decodeQuery(j: Json): Json {
  const kind = topKind(j);
  if (kind === "surface") return surfaceJson();
  if (kind === "evaluate") {
    const reqsJson = (j as Record<string, Json>).requests;
    if (!Array.isArray(reqsJson)) throw new DecodeFailure("query_shape", "missing or invalid requests array");
    const results = reqsJson.map(processRequest);
    return { kind: "results", results };
  }
  throw new DecodeFailure("query_shape", `unknown query kind ${kind}`);
}

function renderInvalid(f: DecodeFailure): Json {
  return { kind: "invalid", failure: { kind: f.kind, detail: f.detail } };
}

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function main(): Promise<void> {
  const content = await readStdin();
  let outJson: Json;
  try {
    const parsed = JSON.parse(content) as Json;
    outJson = decodeQuery(parsed);
  } catch (e) {
    if (e instanceof DecodeFailure) {
      outJson = renderInvalid(e);
    } else if (e instanceof SyntaxError) {
      outJson = renderInvalid(new DecodeFailure("json_syntax", e.message));
    } else {
      throw e;
    }
  }
  process.stdout.write(JSON.stringify(outJson));
}

main();
