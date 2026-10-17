// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { semanticSignatures as S, semanticValues as V } from "necoherence";

export interface SignatureRenderSurface {
  readonly checked: S.CheckedSignatureLibrary;
  readonly basis: unknown;
}

const q = (value: unknown): string => JSON.stringify(value);
function safe(value: string): string { const name = value.replace(/[^A-Za-z0-9_]/g, "_"); return /^[A-Za-z_]/.test(name) ? name : `T_${name}`; }

export function renderSignatureSurface(surface: SignatureRenderSurface, runtimeModule: string): string {
  S.requireCheckedLibrary(surface.checked);
  const checked = surface.checked;
  const context = checked.context;
  const types = context.graph.nodes;
  const names = new Map(types.map((node, index) => [V.typeIdentity(node.reference), `Type_${safe(node.reference.definition_name)}_${index}`]));
  const name = (reference: V.TypeRef): string => names.get(V.typeIdentity(reference)) ?? "V.ExactJson";
  const native = (reference: V.TypeRef): string => {
    const shape = context.resolve(reference);
    return shape.tag === "Boolean" ? "boolean" : shape.tag === "Integer" ? "bigint" : shape.tag === "Decimal" ? "V.DecimalValue" : shape.tag === "String" ? "string" : name(reference);
  };
  const declaration = (node: V.TypeNode): string => {
    const id = name(node.reference), shape = node.shape;
    if (shape.tag === "Never") return `export type ${id} = never;\nexport const ${id}Codec = unreachableCodec(${q(node.reference)});`;
    if (shape.tag === "Boolean") return `export type ${id} = boolean;\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    if (shape.tag === "Integer") return `export type ${id} = bigint;\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    if (shape.tag === "Decimal") return `export type ${id} = V.DecimalValue;\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    if (shape.tag === "String") return `export type ${id} = string;\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    if (shape.tag === "Unit") return `export type ${id} = null;\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    if (shape.tag === "Alias") return `export type ${id} = ${native(shape.fields.target)};\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    if (shape.tag === "Array") return `export type ${id} = readonly (${native(shape.value.item.type_ref)}${shape.value.item.nullable ? " | null" : ""})[];\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    if (shape.tag === "Product") return `export interface ${id} { readonly [key: string]: unknown; ${shape.value.fields.map(field => `readonly ${q(field.wire_name)}${field.slot.required ? "" : "?"}: ${native(field.slot.type_ref)}${field.slot.nullable ? " | null" : ""}`).join("; ")} }\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    if (shape.tag === "Sealed") { const form = context.profile.tag?.sealed.find(candidate => candidate.tag === shape.fields.tag); return `export interface ${id} { ${form?.fields.map(field => `readonly ${q(field.key)}${field.required ? "" : "?"}: ${field.leaf.tag === "String" ? "string" : "bigint"}`).join("; ") ?? ""} }\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`; }
    if (shape.tag === "TaggedUnion") return `export type ${id} = ${shape.value.branches.map(branch => `{ readonly branch: ${q(branch.wire_tag)}; readonly value: ${native(branch.target)} }`).join(" | ") || "never"};\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    if (shape.tag === "Bytes" || shape.tag === "RawBody") return `export type ${id} = Uint8Array;\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    if (shape.tag === "Unknown") return `export type ${id} = V.DynamicValue;\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
    return `export type ${id} = V.ExactJson;\nexport const ${id}Codec = carrierCodec<${id}>(${q(node.reference)});`;
  };
  return `// SPDX-License-Identifier: MIT
import { networkEffect as N, semanticSignatures as S, semanticValues as V } from ${q(runtimeModule)};
const graph: V.ValueGraph = V.deepFreeze(${q(context.graph)});
const context = new V.ValueContext(graph);
const signatureLibrary = S.checkLibrary(${q(checked.library)});
function integerValue(value: V.ExactJson): bigint {
  if (value.tag === "Integer") return BigInt(value.value);
  if (value.tag === "String") return BigInt(value.value);
  if (value.tag === "Decimal") {
    const [coefficient, exponentText = "0"] = value.text.toLowerCase().split("e");
    const [whole, fraction = ""] = coefficient!.split(".");
    const digits = BigInt(whole! + fraction);
    const exponent = BigInt(exponentText) - BigInt(fraction.length);
    return exponent < 0n ? digits / 10n ** -exponent : digits * 10n ** exponent;
  }
  throw new V.SemanticEvidenceError("integer carrier");
}
function integerExact(shape: Extract<V.TypeShape, { readonly tag: "Integer" }>, value: bigint): V.ExactJson {
  const domain = context.profile.integer_domains.find(candidate => candidate.name === (shape.value.domain ?? context.profile.default_integer_domain));
  if (domain?.forms.some(form => form.tag === "Number")) return { tag: "Integer", value: value.toString() };
  if (domain?.forms.some(form => form.tag === "IntegralDecimal")) return { tag: "Decimal", text: value.toString() + ".0" };
  return { tag: "String", value: value.toString() };
}
function decodeCarrier(reference: V.TypeRef, value: V.ExactJson): unknown {
  const shape = context.node(reference).shape;
  if (shape.tag === "Alias") return decodeCarrier(shape.fields.target, value);
  if (shape.tag === "Never" || shape.tag === "Opaque") throw new V.SemanticEvidenceError("uninhabited carrier");
  if (shape.tag === "Unit") return null;
  if (shape.tag === "Boolean") return (value as Extract<V.ExactJson, { readonly tag: "Bool" }>).value;
  if (shape.tag === "Integer") return integerValue(value);
  if (shape.tag === "Decimal") return new V.DecimalValue((value as Extract<V.ExactJson, { readonly tag: "Decimal" }>).text);
  if (shape.tag === "String") return shape.value.wrapper === null ? (value as Extract<V.ExactJson, { readonly tag: "String" }>).value : V.wrapDecode(context.profile, shape.value.wrapper, value);
  if (shape.tag === "Bytes" || shape.tag === "RawBody") return V.bytesValue(value, context);
  if (shape.tag === "Unknown") return V.immutableDynamic(value);
  if (shape.tag === "Array") return (value as Extract<V.ExactJson, { readonly tag: "Array" }>).items.map(item => item.tag === "Null" && shape.value.item.nullable ? null : decodeCarrier(shape.value.item.type_ref, item));
  if (shape.tag === "Product") {
    const result: Record<string, unknown> = Object.create(null);
    const object = value as Extract<V.ExactJson, { readonly tag: "Object" }>;
    for (const field of shape.value.fields) {
      const item = V.member(object, field.wire_name);
      if (item !== undefined) result[field.wire_name] = item.tag === "Null" && field.slot.nullable ? null : decodeCarrier(field.slot.type_ref, item);
    }
    if (shape.value.extras.tag === "Allow") for (const item of object.members) if (!shape.value.fields.some(field => field.wire_name === item.key) && item.key !== context.profile.tag?.key) result[item.key] = item.value.tag === "Null" && shape.value.extras.fields.value.nullable ? null : decodeCarrier(shape.value.extras.fields.value.type_ref, item.value);
    const tagKey = context.profile.tag?.key;
    if (tagKey !== undefined && !Object.hasOwn(result, tagKey)) {
      const tag = V.member(object, tagKey);
      if (tag !== undefined) result[tagKey] = V.immutableDynamic(tag);
    }
    return V.deepFreeze(V.preserveObjectOrder(result, object.members.map(item => item.key)));
  }
  if (shape.tag === "Sealed") {
    const form = context.profile.tag!.sealed.find(candidate => candidate.tag === shape.fields.tag)!;
    const result: Record<string, unknown> = {};
    for (const field of form.fields) {
      const item = V.member(value, field.key);
      if (item === undefined) continue;
      const refinement = shape.fields.refinements.find(candidate => candidate.key === field.key)?.leaf ?? field.leaf;
      result[field.key] = refinement.tag === "String" ? (refinement.value.wrapper === null ? (item as Extract<V.ExactJson, { readonly tag: "String" }>).value : V.wrapDecode(context.profile, refinement.value.wrapper, item)) : integerValue(item);
    }
    return V.deepFreeze(result);
  }
  if (shape.tag === "TaggedUnion") {
    const branch = V.selectBranch(graph, reference, value);
    if (branch === null) throw new V.SemanticEvidenceError("selected union branch");
    return V.deepFreeze({ branch: branch.wire_tag, value: decodeCarrier(branch.target, value) });
  }
  return value;
}
function encodeCarrier(reference: V.TypeRef, carrier: unknown): V.ExactJson {
  const shape = context.node(reference).shape;
  if (shape.tag === "Alias") return encodeCarrier(shape.fields.target, carrier);
  if (shape.tag === "Never" || shape.tag === "Opaque") throw new V.SemanticEvidenceError("uninhabited carrier");
  if (shape.tag === "Unit") return { tag: "Null" };
  if (shape.tag === "Boolean") return { tag: "Bool", value: carrier as boolean };
  if (shape.tag === "Integer") return integerExact(shape, carrier as bigint);
  if (shape.tag === "Decimal") return { tag: "Decimal", text: String(carrier) };
  if (shape.tag === "String") return shape.value.wrapper === null ? { tag: "String", value: carrier as string } : V.wrapEncode(context.profile, shape.value.wrapper, carrier as string);
  if (shape.tag === "Bytes" || shape.tag === "RawBody") return V.bytesExact(carrier as Uint8Array, context.profile);
  if (shape.tag === "Unknown") return V.dynamicExact(carrier as V.DynamicValue);
  if (shape.tag === "Array") return { tag: "Array", items: (carrier as readonly unknown[]).map(item => item === null && shape.value.item.nullable ? { tag: "Null" } : encodeCarrier(shape.value.item.type_ref, item)) };
  if (shape.tag === "Product") {
    const record = carrier as Record<string, unknown>, members: { key: string; value: V.ExactJson }[] = [];
    for (const field of shape.value.fields) if (record[field.wire_name] !== undefined) members.push({ key: field.wire_name, value: record[field.wire_name] === null && field.slot.nullable ? { tag: "Null" } : encodeCarrier(field.slot.type_ref, record[field.wire_name]) });
    if (shape.value.extras.tag === "Allow") for (const key of Object.keys(record)) if (!shape.value.fields.some(field => field.wire_name === key) && key !== context.profile.tag?.key) members.push({ key, value: record[key] === null && shape.value.extras.fields.value.nullable ? { tag: "Null" } : encodeCarrier(shape.value.extras.fields.value.type_ref, record[key]) });
    const tagKey = context.profile.tag?.key;
    if (tagKey !== undefined && !members.some(item => item.key === tagKey) && Object.hasOwn(record, tagKey)) members.push({ key: tagKey, value: { tag: "String", value: record[tagKey] as string } });
    return V.orderedObject(members, record);
  }
  if (shape.tag === "Sealed") {
    const record = carrier as Record<string, unknown>, form = context.profile.tag!.sealed.find(candidate => candidate.tag === shape.fields.tag)!, members: { key: string; value: V.ExactJson }[] = [];
    for (const field of form.fields) if (record[field.key] !== undefined) {
      const refinement = shape.fields.refinements.find(candidate => candidate.key === field.key)?.leaf ?? field.leaf;
      const value = refinement.tag === "String" ? (refinement.value.wrapper === null ? { tag: "String", value: record[field.key] as string } as const : V.wrapEncode(context.profile, refinement.value.wrapper, record[field.key] as string)) : integerExact({ tag: "Integer", value: refinement.value }, record[field.key] as bigint);
      members.push({ key: field.key, value });
    }
    return V.withMember(context.profile.tag!.key, shape.fields.tag, { tag: "Object", members });
  }
  if (shape.tag === "TaggedUnion") {
    const variant = carrier as { readonly branch: string; readonly value: unknown };
    const branch = shape.value.branches.find(candidate => candidate.wire_tag === variant.branch);
    if (branch === undefined) throw new V.SemanticEvidenceError("declared union branch");
    const encoded = encodeCarrier(branch.target, variant.value);
    return branch.selector.tag === "InternalTag" ? V.withMember(context.profile.tag!.key, branch.wire_tag, encoded) : encoded;
  }
  return carrier as V.ExactJson;
}
function carrierCodec<T>(reference: V.TypeRef) { return Object.freeze({ decode(value: V.ExactJson): T { return decodeCarrier(reference, context.validate(reference, value)) as T; }, decodeWithDefaults(text: string): T { return decodeCarrier(reference, context.decodeWithDefaults(reference, text).value) as T; }, encode(value: T): V.ExactJson { return context.validate(reference, encodeCarrier(reference, value)); } }); }
function unreachableCodec(reference: V.TypeRef) { return Object.freeze({ decode(_value: V.ExactJson): never { throw new V.SemanticValueError({ type: reference, path: [], condition: "Uninhabited", observed: "value" }); }, decodeWithDefaults(text: string): never { context.decodeWithDefaults(reference, text); throw new V.SemanticValueError({ type: reference, path: [], condition: "Uninhabited", observed: "value" }); }, encode(value: never): V.ExactJson { return value; } }); }
${types.map(declaration).join("\n\n")}

export interface NetworkAdapter {
  start(command: N.SendCommand): N.StartObservation | Promise<N.StartObservation>;
  observe(handle: N.ExecutionHandle): N.HostObservation | Promise<N.HostObservation>;
}
export type HttpPreparation<O extends S.TypedOutcome> =
  | { readonly tag: "Ready"; readonly value: N.AttemptInput }
  | { readonly tag: "Completed"; readonly value: { readonly outcome: string; readonly value: O } };
export interface HttpBinding<I, O extends S.TypedOutcome> {
  prepare(input: I): HttpPreparation<O>;
  decode(response: N.RawHttpResponse, provenance: N.HeaderProvenance, effect: N.EffectStatus): O | Promise<O>;
}
export interface NetworkBindings { readonly state: N.NetworkState; readonly adapter: NetworkAdapter; }
export type ExecutionOutcome<O extends S.TypedOutcome> =
  | { readonly tag: "Completed"; readonly outcome: O; readonly state: N.NetworkState }
  | { readonly tag: "Pending"; readonly pending: Pending<O>; readonly state: N.NetworkState }
  | { readonly tag: "Rejected"; readonly failure: unknown; readonly state: N.NetworkState };

const pendingAuthority = Symbol("generated pending authority");
export class Pending<O extends S.TypedOutcome> {
  readonly #resume: () => Promise<ExecutionOutcome<O>>;
  #used = false;
  constructor(authority: symbol, resume: () => Promise<ExecutionOutcome<O>>) {
    if (authority !== pendingAuthority) throw new V.SemanticEvidenceError("pending authority");
    this.#resume = resume;
  }
  resume(): Promise<ExecutionOutcome<O>> {
    if (this.#used) throw new V.SemanticEvidenceError("pending already resumed");
    this.#used = true;
    return this.#resume();
  }
}
export function resume<O extends S.TypedOutcome>(pending: Pending<O>): Promise<ExecutionOutcome<O>> {
  if (!(pending instanceof Pending)) throw new V.SemanticEvidenceError("pending execution");
  return pending.resume();
}
export function validateHttpPreparation<O extends S.TypedOutcome>(
  operation: S.OperationContract,
  prepared: HttpPreparation<O>,
): HttpPreparation<O> {
  if (prepared.tag === "Ready") return prepared;
  const declared = operation.outcomes.find(candidate => candidate.id === prepared.value.outcome);
  if (declared === undefined || declared.cause.tag !== "ExternalCondition" || declared.form.tag !== "DeclaredFailure") {
    throw new V.SemanticEvidenceError("prepare completed external failure");
  }
  S.validateTypedOutcome(signatureLibrary, operation, prepared.value.value);
  if (prepared.value.value.outcome !== prepared.value.outcome) {
    throw new V.SemanticEvidenceError("prepare completed outcome identity");
  }
  return prepared;
}
async function settleHttp<O extends S.TypedOutcome>(
  operation: S.OperationContract,
  binding: HttpBinding<unknown, O>,
  terminal: N.NetworkTerminal,
  state: N.NetworkState,
): Promise<ExecutionOutcome<O>> {
  if (terminal.outcome.tag !== "Response") return { tag: "Rejected", failure: terminal, state };
  try {
    const outcome = await binding.decode(terminal.outcome.response, terminal.outcome.provenance, terminal.effect);
    return { tag: "Completed", outcome: S.validateTypedOutcome(signatureLibrary, operation, outcome) as O, state };
  } catch (failure) {
    return { tag: "Rejected", failure, state };
  }
}
async function observeHttp<O extends S.TypedOutcome>(
  operation: S.OperationContract,
  binding: HttpBinding<unknown, O>,
  adapter: NetworkAdapter,
  started: N.StartedAttempt,
  state: N.NetworkState,
): Promise<ExecutionOutcome<O>> {
  try {
    const step = N.observe(state, await adapter.observe(started.handle));
    if (step.tag === "Rejected") return { tag: "Rejected", failure: step.failure, state: step.state };
    if (step.tag === "Terminal" || step.tag === "Late") return settleHttp(operation, binding, step.settled.terminal, step.state);
    if (step.tag === "Pending" || step.tag === "Started") {
      const next = () => observeHttp(operation, binding, adapter, step.started, step.state);
      const pending = new Pending<O>(pendingAuthority, next);
      return { tag: "Pending", pending, state: step.state };
    }
    return { tag: "Rejected", failure: step, state: step.state };
  } catch (failure) {
    return { tag: "Rejected", failure, state };
  }
}
export async function execute<I, O extends S.TypedOutcome>(
  operation: S.OperationContract,
  input: I,
  binding: HttpBinding<I, O>,
  network: NetworkBindings,
): Promise<ExecutionOutcome<O>> {
  let state = network.state;
  try {
    const initial = N.readNetworkState(state);
    state = initial.state;
    if (initial.tag === "Rejected") return { tag: "Rejected", failure: initial.failure, state };
    const prepared = validateHttpPreparation(operation, binding.prepare(input));
    if (prepared.tag === "Completed") return { tag: "Completed", outcome: prepared.value.value, state };
    const admitted = N.prepare(state, prepared.value);
    state = admitted.state;
    if (admitted.tag === "Rejected") return { tag: "Rejected", failure: admitted.failure, state };
    const command = N.sendCommand(state, admitted.prepared);
    state = command.state;
    if (command.tag === "Rejected") return { tag: "Rejected", failure: command.failure, state };
    const start = N.observeStart(state, admitted.prepared, await network.adapter.start(command.command));
    state = start.state;
    if (start.tag === "Rejected") return { tag: "Rejected", failure: start.failure, state };
    if (start.tag === "Terminal" || start.tag === "Late") return settleHttp(operation, binding as HttpBinding<unknown, O>, start.settled.terminal, state);
    if (start.tag === "Started" || start.tag === "Pending") return observeHttp(operation, binding as HttpBinding<unknown, O>, network.adapter, start.started, state);
    return { tag: "Rejected", failure: start, state };
  } catch (failure) {
    return { tag: "Rejected", failure, state };
  }
}
export const generationBasis = V.deepFreeze(${q(surface.basis)});
`;
}
