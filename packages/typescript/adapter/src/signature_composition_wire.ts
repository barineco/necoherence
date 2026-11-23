// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import * as C from "./semantic_composition.js";
import * as M from "./typed_mapping.js";
import * as S from "./semantic_signatures.js";
import * as V from "./semantic_values.js";
import { fail, functionRef, producerRef, recordTag, resourceLotRef, row, text, tupleTag, unitTag, type Row } from "./composition_wire_records.js";
export { producerRef };

function bool(value: unknown, path: string): boolean {
  V.wireBool(value, path);
  return value as boolean;
}

function list<T>(value: unknown, path: string, decode: (item: unknown, path: string) => T): readonly T[] {
  if (!Array.isArray(value)) return fail("Syntax", path, "array expected");
  return value.map((item, index) => decode(item, `${path}[${index}]`));
}

function natural(value: unknown, path: string): bigint {
  V.wireNat(value, path);
  return BigInt(value as string);
}

function nullable<T>(value: unknown, path: string, decode: (item: unknown, path: string) => T): T | null {
  return value === null ? null : decode(value, path);
}

function pair<A, B>(value: unknown, path: string, left: (item: unknown, path: string) => A, right: (item: unknown, path: string) => B): readonly [A, B] {
  if (!Array.isArray(value) || value.length !== 2) return fail("Syntax", path, "pair");
  return [left(value[0], `${path}[0]`), right(value[1], `${path}[1]`)];
}




function typeRef(value: unknown, path: string): V.TypeRef {
  return S.signatureTypeRef(text(value, path));
}


function definitionRef(value: unknown, path: string): V.DefinitionRef {
  const reference = typeRef(value, path);
  return { source: reference.source, name: reference.definition_name };
}

function slotContract(value: unknown, path: string): V.SlotContract {
  const record = row(value, ["type_id", "required", "nullable"], path);
  return { type_ref: typeRef(record.type_id, `${path}.type_id`), required: bool(record.required, `${path}.required`), nullable: bool(record.nullable, `${path}.nullable`) };
}

function pathStep(value: unknown, path: string): V.PathStep {
  const tag = V.wireTag(value, path);
  if (tag !== "Field" && tag !== "Index" && tag !== "Variant") return fail("UnknownTag", `${path}.tag`, tag);
  const record = row(value, ["tag", "value"], path);
  return { tag, value: tag === "Index" ? natural(record.value, `${path}.value`).toString() : text(record.value, `${path}.value`) };
}

export function valuePath(value: unknown, path: string): C.ValuePath { return list(value, path, pathStep); }

function exactJson(value: unknown, path: string): V.ExactJson {
  S.wireExactJson(value, path);
  return structuredClone(value) as V.ExactJson;
}

function slotValue(value: unknown, path: string): V.ExactSlot {
  const tag = V.wireTag(value, path);
  if (tag === "Absent" || tag === "Null") return unitTag(value, path, [tag]);
  if (tag === "Present") return { tag, value: exactJson(tupleTag(value, path, tag), `${path}.value`) };
  return fail("UnknownTag", `${path}.tag`, tag);
}


function sourceConstraint(value: unknown, path: string): C.SourceConstraint {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return fail("Syntax", path, "source constraint");
  const tag = text((value as Row).tag, `${path}.tag`);
  if (tag === "AnyCompatible") return unitTag(value, path, [tag]);
  if (tag === "InitialOnly") { const fields = recordTag(value, path, tag, ["input", "path"]); return { tag, fields: { input: text(fields.input, `${path}.fields.input`), path: valuePath(fields.path, `${path}.fields.path`) } }; }
  if (tag === "ProducedBy") { const fields = recordTag(value, path, tag, ["site", "outcome", "port", "path"]); return { tag, fields: { site: text(fields.site, `${path}.fields.site`), outcome: text(fields.outcome, `${path}.fields.outcome`), port: text(fields.port, `${path}.fields.port`), path: valuePath(fields.path, `${path}.fields.path`) } }; }
  return fail("UnknownTag", `${path}.tag`, tag);
}


function resourceProducer(value: unknown, path: string): C.ResourceProducer {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "Initial") { const fields = recordTag(value, path, tag, ["identity", "revision"]); return { tag, fields: { identity: text(fields.identity, `${path}.fields.identity`), revision: text(fields.revision, `${path}.fields.revision`) } }; }
  if (tag === "InvocationOutcome") { const fields = recordTag(value, path, tag, ["site", "outcome"]); return { tag, fields: { site: text(fields.site, `${path}.fields.site`), outcome: text(fields.outcome, `${path}.fields.outcome`) } }; }
  return fail("UnknownTag", `${path}.tag`, tag);
}

function resourceIdentity(value: unknown, path: string): C.ResourceIdentityConstraint {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "Any") return unitTag(value, path, [tag]);
  if (tag === "Exactly") return { tag, value: resourceProducer(tupleTag(value, path, tag), `${path}.value`) };
  return fail("UnknownTag", `${path}.tag`, tag);
}

function resourceLot(value: unknown, path: string): C.ResourceLot {
  const record = row(value, ["id", "token_type", "producer", "revision", "quantity", "provenance"], path);
  return { id: text(record.id, `${path}.id`), tokenType: typeRef(record.token_type, `${path}.token_type`), producer: resourceProducer(record.producer, `${path}.producer`), revision: natural(record.revision, `${path}.revision`), quantity: natural(record.quantity, `${path}.quantity`), provenance: text(record.provenance, `${path}.provenance`) };
}

function resourceRequirement(value: unknown, path: string): C.ResourceRequirement {
  const record = row(value, ["id", "token_type", "mode", "multiplicity", "required_revision", "identity"], path);
  return { id: text(record.id, `${path}.id`), tokenType: typeRef(record.token_type, `${path}.token_type`), mode: unitTag(record.mode, `${path}.mode`, ["Read", "Consume"]), multiplicity: natural(record.multiplicity, `${path}.multiplicity`), requiredRevision: natural(record.required_revision, `${path}.required_revision`), identity: resourceIdentity(record.identity, `${path}.identity`) };
}

function resourceProduction(value: unknown, path: string): C.ResourceProduction {
  const record = row(value, ["id", "token_type", "revision", "quantity", "provenance"], path);
  return { id: text(record.id, `${path}.id`), tokenType: typeRef(record.token_type, `${path}.token_type`), revision: natural(record.revision, `${path}.revision`), quantity: natural(record.quantity, `${path}.quantity`), provenance: text(record.provenance, `${path}.provenance`) };
}

function initialSource(value: unknown, path: string): C.InitialSource {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "Argument") return unitTag(value, path, [tag]);
  if (tag === "SuppliedValue") return { tag, value: slotValue(tupleTag(value, path, tag), `${path}.value`) };
  return fail("UnknownTag", `${path}.tag`, tag);
}

function initialInput(value: unknown, path: string): C.InitialInput {
  const record = row(value, ["id", "contract", "source", "resource"], path);
  return { id: text(record.id, `${path}.id`), contract: slotContract(record.contract, `${path}.contract`), source: initialSource(record.source, `${path}.source`), resource: nullable(record.resource, `${path}.resource`, text) };
}

function inputPort(value: unknown, path: string): C.InputPort {
  const record = row(value, ["id", "contract", "source_constraint", "resource_requirement"], path);
  return { id: text(record.id, `${path}.id`), contract: slotContract(record.contract, `${path}.contract`), sourceConstraint: sourceConstraint(record.source_constraint, `${path}.source_constraint`), resourceRequirement: nullable(record.resource_requirement, `${path}.resource_requirement`, text) };
}

function outputPort(value: unknown, path: string): C.OutputPort {
  const record = row(value, ["id", "contract", "resource_production"], path);
  return { id: text(record.id, `${path}.id`), contract: slotContract(record.contract, `${path}.contract`), resourceProduction: nullable(record.resource_production, `${path}.resource_production`, text) };
}

function origin(value: unknown, path: string): S.Origin {
  const record = row(value, ["source", "locator"], path), source = row(record.source, ["repository", "revision", "path", "content_digest"], `${path}.source`);
  return { source: { repository: text(source.repository, `${path}.source.repository`), revision: text(source.revision, `${path}.source.revision`), path: text(source.path, `${path}.source.path`), content_digest: text(source.content_digest, `${path}.source.content_digest`) }, locator: list(record.locator, `${path}.locator`, text) };
}

function outcomeCause(value: unknown, path: string): S.OutcomeCause {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "ValueContract") { const fields = recordTag(value, path, tag, ["origin"]); return { tag, fields: { origin: origin(fields.origin, `${path}.fields.origin`) } }; }
  if (tag === "ExternalCondition") { const fields = recordTag(value, path, tag, ["specification"]); return { tag, fields: { specification: origin(fields.specification, `${path}.fields.specification`) } }; }
  return fail("UnknownTag", `${path}.tag`, tag);
}

function outcome(reference: C.FunctionRef, value: unknown, path: string): { readonly contract: C.OutcomeContract; readonly cause: C.CauseBinding } {
  const record = row(value, ["id", "form", "cause", "value_ports", "produced_resources"], path);
  const cause = outcomeCause(record.cause, `${path}.cause`), id = text(record.id, `${path}.id`), form = unitTag(record.form, `${path}.form`, ["Success", "DeclaredFailure"]);
  const valuePorts = list(record.value_ports, `${path}.value_ports`, (item, itemPath) => outputPort(item, itemPath));
  const producedResources = list(record.produced_resources, `${path}.produced_resources`, (item, itemPath) => resourceProduction(item, itemPath));
  return { contract: { id, form, valuePorts, producedResources }, cause: { function: reference, outcome: id, cause } };
}

function functionForm(value: unknown, path: string): C.FunctionForm {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "Pure" || tag === "DeclaredTransform") return unitTag(value, path, [tag]);
  if (tag === "Operation") return { tag, value: definitionRef(tupleTag(value, path, tag), `${path}.value`) };
  return fail("UnknownTag", `${path}.tag`, tag);
}

function guardArm(value: unknown, path: string): C.GuardArm {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "Variant") return { tag, value: text(tupleTag(value, path, tag), `${path}.value`) };
  if (tag === "Present" || tag === "Absent" || tag === "Null" || tag === "UnknownVariant" || tag === "Accepted" || tag === "Rejected") return unitTag(value, path, [tag]);
  return fail("UnknownTag", `${path}.tag`, tag);
}

function failureOrigin(value: unknown, path: string): C.FailureOrigin {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "Function") { const fields = recordTag(value, path, tag, ["function", "outcome"]); return { tag, fields: { function: functionRef(fields.function, `${path}.fields.function`), outcome: text(fields.outcome, `${path}.fields.outcome`) } }; }
  if (tag === "Guard") { const fields = recordTag(value, path, tag, ["guard", "arm"]); return { tag, fields: { guard: text(fields.guard, `${path}.fields.guard`), arm: guardArm(fields.arm, `${path}.fields.arm`) } }; }
  return fail("UnknownTag", `${path}.tag`, tag);
}

function functionSignature(value: unknown, path: string): { readonly signature: C.FunctionSignature; readonly causes: readonly C.CauseBinding[] } {
  const record = row(value, ["reference", "form", "effect", "inputs", "outcomes", "resource_inputs", "assumption_ref", "handles_failure"], path);
  const reference = functionRef(record.reference, `${path}.reference`), form = functionForm(record.form, `${path}.form`), effect = unitTag(record.effect, `${path}.effect`, ["PureFunction", "HttpRequestResponse", "DataOnly"]);
  const inputs = list(record.inputs, `${path}.inputs`, (item, itemPath) => inputPort(item, itemPath));
  const outcomes = list(record.outcomes, `${path}.outcomes`, (item, itemPath) => outcome(reference, item, itemPath));
  const resourceInputs = list(record.resource_inputs, `${path}.resource_inputs`, (item, itemPath) => resourceRequirement(item, itemPath));
  const assumptionRef = text(record.assumption_ref, `${path}.assumption_ref`), handlesFailure = nullable(record.handles_failure, `${path}.handles_failure`, failureOrigin);
  return { signature: { reference, form, effect, inputs, outcomes: outcomes.map(item => item.contract), resourceInputs, assumptionRef, handlesFailure }, causes: outcomes.map(item => item.cause) };
}

function invocationSite(value: unknown, path: string): C.InvocationSite { const record = row(value, ["id", "function"], path); return { id: text(record.id, `${path}.id`), function: functionRef(record.function, `${path}.function`) }; }
function permittedProjection(value: unknown, path: string): C.PermittedProjection { const record = row(value, ["source_type", "path"], path); return { sourceType: typeRef(record.source_type, `${path}.source_type`), path: valuePath(record.path, `${path}.path`) }; }
function guardKind(value: unknown, path: string): C.GuardKind { const tag = text((value as Row)?.tag, `${path}.tag`); if (tag === "Presence" || tag === "Variants") return unitTag(value, path, [tag]); if (tag === "Validate") return { tag, value: slotContract(tupleTag(value, path, tag), `${path}.value`) }; return fail("UnknownTag", `${path}.tag`, tag); }
function declaredGuard(value: unknown, path: string): C.DeclaredGuard { const record = row(value, ["id", "source_type", "path", "kind"], path); return { id: text(record.id, `${path}.id`), sourceType: typeRef(record.source_type, `${path}.source_type`), path: valuePath(record.path, `${path}.path`), kind: guardKind(record.kind, `${path}.kind`) }; }
function fieldConstraint(value: unknown, path: string): C.FieldConstraint { const record = row(value, ["field", "source", "presence"], path); return { field: text(record.field, `${path}.field`), source: sourceConstraint(record.source, `${path}.source`), presence: unitTag(record.presence, `${path}.presence`, ["Required", "Optional"]) }; }
function constructionRule(value: unknown, path: string): C.ConstructionRule { const record = row(value, ["identity", "type_id", "nested_fields", "field_constraints"], path); return { identity: text(record.identity, `${path}.identity`), typeRef: typeRef(record.type_id, `${path}.type_id`), nestedFields: list(record.nested_fields, `${path}.nested_fields`, (item, itemPath) => pair(item, itemPath, text, text)), fieldConstraints: list(record.field_constraints, `${path}.field_constraints`, fieldConstraint) }; }
function invocationDomain(value: unknown, path: string): C.InvocationDomain { const record = row(value, ["identity", "revision", "sites", "permitted_projections", "permitted_constructions", "permitted_transforms", "guards"], path); return { identity: text(record.identity, `${path}.identity`), revision: text(record.revision, `${path}.revision`), sites: list(record.sites, `${path}.sites`, invocationSite), permittedProjections: list(record.permitted_projections, `${path}.permitted_projections`, (item, itemPath) => permittedProjection(item, itemPath)), permittedConstructions: list(record.permitted_constructions, `${path}.permitted_constructions`, (item, itemPath) => constructionRule(item, itemPath)), permittedTransforms: list(record.permitted_transforms, `${path}.permitted_transforms`, functionRef), guards: list(record.guards, `${path}.guards`, (item, itemPath) => declaredGuard(item, itemPath)) }; }
function resourceGoal(value: unknown, path: string): C.ResourceGoal { const record = row(value, ["lot", "multiplicity", "revision"], path); return { lot: resourceLotRef(record.lot, `${path}.lot`), multiplicity: natural(record.multiplicity, `${path}.multiplicity`), revision: natural(record.revision, `${path}.revision`) }; }
function goalPort(value: unknown, path: string): C.GoalPort { const record = row(value, ["id", "contract", "source_constraint"], path); return { id: text(record.id, `${path}.id`), contract: slotContract(record.contract, `${path}.contract`), sourceConstraint: sourceConstraint(record.source_constraint, `${path}.source_constraint`) }; }
function failureEmbedding(value: unknown, path: string): C.FailureEmbedding { const record = row(value, ["id", "origin", "contract", "final_resources"], path); return { id: text(record.id, `${path}.id`), origin: failureOrigin(record.origin, `${path}.origin`), contract: slotContract(record.contract, `${path}.contract`), finalResources: list(record.final_resources, `${path}.final_resources`, resourceGoal) }; }
function goalSpec(value: unknown, path: string): C.GoalSpec { const record = row(value, ["outputs", "failures", "final_resources"], path); return { outputs: list(record.outputs, `${path}.outputs`, (item, itemPath) => goalPort(item, itemPath)), failures: list(record.failures, `${path}.failures`, (item, itemPath) => failureEmbedding(item, itemPath)), finalResources: list(record.final_resources, `${path}.final_resources`, resourceGoal) }; }
function resourceBounds(value: unknown, path: string): C.ResourceBounds { const record = row(value, ["max_bindings", "max_search_steps", "max_tokens"], path); return { maxBindings: natural(record.max_bindings, `${path}.max_bindings`), maxSearchSteps: natural(record.max_search_steps, `${path}.max_search_steps`), maxTokens: natural(record.max_tokens, `${path}.max_tokens`) }; }
function searchBounds(value: unknown, path: string): C.SearchBounds { const record = row(value, ["max_expanded_states", "max_binding_candidates", "max_type_obligations", "max_branch_nodes", "resource_bounds", "max_sample_length"], path); return { maxExpandedStates: natural(record.max_expanded_states, `${path}.max_expanded_states`), maxBindingCandidates: natural(record.max_binding_candidates, `${path}.max_binding_candidates`), maxTypeObligations: natural(record.max_type_obligations, `${path}.max_type_obligations`), maxBranchNodes: natural(record.max_branch_nodes, `${path}.max_branch_nodes`), resourceBounds: nullable(record.resource_bounds, `${path}.resource_bounds`, resourceBounds), maxSampleLength: natural(record.max_sample_length, `${path}.max_sample_length`) }; }

export interface DecodedCompositionInput { readonly input: C.CompositionInput; readonly causes: readonly C.CauseBinding[]; }
export class CompositionInputWire {
  private constructor(readonly exactJson: unknown, readonly decoded: DecodedCompositionInput) { Object.freeze(this); }
  static decoded(exactJson: unknown, decoded: DecodedCompositionInput): CompositionInputWire { return new CompositionInputWire(exactJson, decoded); }
}

export function decodeProblem(checked: S.CheckedSignatureLibrary, value: unknown, basis: S.SignatureGenerationBasis = S.signatureBasis(checked.library, [])): DecodedCompositionInput {
  S.requireCheckedLibrary(checked);
  const record = row(value, ["identity", "revision", "basis", "signatures", "initial_inputs", "initial_resources", "goal", "invocation_domain", "allowed_effects", "explicit_order", "selection_policy", "bounds"], "$");
  if (!V.same(S.decodeGenerationBasisWire(record.basis), basis)) return fail("Syntax", "$.basis", "composition signature basis mismatch");
  const functions = list(record.signatures, "$.signatures", (item, path) => functionSignature(item, path));
  return { input: { identity: text(record.identity, "$.identity"), revision: text(record.revision, "$.revision"), basis: V.semanticBasisOf(checked.context), signatures: functions.map(item => item.signature), initialInputs: list(record.initial_inputs, "$.initial_inputs", (item, path) => initialInput(item, path)), initialResources: list(record.initial_resources, "$.initial_resources", (item, path) => resourceLot(item, path)), goal: goalSpec(record.goal, "$.goal"), invocationDomain: invocationDomain(record.invocation_domain, "$.invocation_domain"), allowedEffects: list(record.allowed_effects, "$.allowed_effects", (item, path) => unitTag(item, path, ["PureFunction", "HttpRequestResponse", "DataOnly"])), explicitOrder: list(record.explicit_order, "$.explicit_order", (item, path) => pair(item, path, text, text)), selectionPolicy: nullable(record.selection_policy, "$.selection_policy", (item, path) => unitTag(item, path, ["RequireUnique", "AnyFeasible"])), bounds: searchBounds(record.bounds, "$.bounds") }, causes: functions.flatMap(item => item.causes) };
}

export function decodeCompositionInput(checked: S.CheckedSignatureLibrary, value: unknown): CompositionInputWire {
  return CompositionInputWire.decoded(structuredClone(value), decodeProblem(checked, value));
}

export function encodeCompositionInput(wire: CompositionInputWire): unknown { return structuredClone(wire.exactJson); }

export type SignatureContractResult = { readonly tag: "Ok"; readonly value: S.OperationContract } | { readonly tag: "Failed"; readonly reason: string };

export function signatureContract(causes: readonly C.CauseBinding[], signature: C.FunctionSignature): SignatureContractResult {
  const outcomes: S.SignatureOutcome[] = [];
  for (const outcome of signature.outcomes) {
    const binding = causes.find(candidate => V.same(candidate.function, signature.reference) && candidate.outcome === outcome.id);
    if (binding === undefined) return { tag: "Failed", reason: "missing outcome cause" };
    outcomes.push({ id: outcome.id, form: outcome.form, cause: binding.cause, value_ports: outcome.valuePorts.map(port => ({ id: port.id, contract: { type_id: port.contract.type_ref.definition_name, required: port.contract.required, nullable: port.contract.nullable } })), produced_resources: outcome.producedResources.map(production => ({ id: production.id, token_type: production.tokenType.definition_name, revision: production.revision.toString(), quantity: production.quantity.toString(), provenance: production.provenance })) });
  }
  return { tag: "Ok", value: { effect: { tag: signature.effect.tag === "HttpRequestResponse" ? "HttpRequestResponse" : "DataOnly" }, inputs: signature.inputs.map(port => ({ id: port.id, contract: { type_id: port.contract.type_ref.definition_name, required: port.contract.required, nullable: port.contract.nullable } })), outcomes } };
}

export function checkOperation(checked: S.CheckedSignatureLibrary, graphDigest: string, causes: readonly C.CauseBinding[], signature: C.FunctionSignature, reference: V.DefinitionRef): C.CompositionInputFailure | null {
  const invalid = (reason: string): C.CompositionInputFailure => ({ tag: "InvalidSignature", fields: { function: signature.reference, reason } });
  const definition = checked.library.definitions.find(candidate => candidate.id === reference.name);
  if (definition === undefined) return invalid("unresolved operation identity");
  if (definition.shape.tag !== "Operation") return invalid("definition is not an operation");
  if (signature.reference.identity !== definition.wire_identity || signature.reference.revision !== checked.library.revision || signature.reference.contentDigest !== graphDigest) return invalid("operation identity basis");
  const extended = signatureContract(causes, signature);
  if (extended.tag === "Failed") return invalid(extended.reason);
  const expectedEffect: C.CompositionEffect = { tag: definition.shape.value.effect.tag === "HttpRequestResponse" ? "HttpRequestResponse" : "DataOnly" };
  if (signature.effect.tag !== expectedEffect.tag) return invalid("operation effect");
  try { S.checkOperationSignature(definition.shape.value, extended.value, checked.library); }
  catch { return invalid("base outcome preservation or external supplement"); }
  return null;
}

export function prepare(checked: S.CheckedSignatureLibrary, graphDigest: string, input: C.CompositionInput, causes: readonly C.CauseBinding[]): C.CompositionInputResult<C.PreparedCompositionInput> {
  S.requireCheckedLibrary(checked);
  const libraryFailure = S.libraryCheckFailure(checked.library);
  if (libraryFailure !== null) return { tag: "Failed", failure: { tag: "InvalidLibrary", value: libraryFailure } };
  for (const signature of input.signatures) {
    const contract = signatureContract(causes, signature);
    if (contract.tag === "Failed") return { tag: "Failed", failure: { tag: "InvalidSignature", fields: { function: signature.reference, reason: contract.reason } } };
    if (!contract.value.outcomes.every(outcome => S.outcomeValid(checked.library, outcome))) return { tag: "Failed", failure: { tag: "InvalidSignature", fields: { function: signature.reference, reason: "outcome cause or external failure value" } } };
  }
  return C.prepareDirectComposition(checked.context, input, (signature, reference) => checkOperation(checked, graphDigest, causes, signature, reference), signature => V.meaningObligations(checked.context, [...signature.inputs.map(port => port.contract.type_ref), ...signature.resourceInputs.map(resource => resource.tokenType), ...signature.outcomes.flatMap(outcome => [...outcome.valuePorts.map(port => port.contract.type_ref), ...outcome.producedResources.map(resource => resource.tokenType)])]));
}

function sourceRef(value: unknown, path: string): V.SourceRef {
  const record = row(value, ["repository", "revision", "path", "content_digest"], path);
  return { repository: text(record.repository, `${path}.repository`), revision: text(record.revision, `${path}.revision`), path: text(record.path, `${path}.path`), content_digest: text(record.content_digest, `${path}.content_digest`), document_id: "" };
}
function profileRef(value: unknown, path: string): V.ProfileRef {
  const record = row(value, ["identity", "revision", "content_digest"], path);
  return { identity: text(record.identity, `${path}.identity`), revision: text(record.revision, `${path}.revision`), content_digest: text(record.content_digest, `${path}.content_digest`) };
}
export function valueRef(value: unknown, path: string): C.ValueRef {
  const record = row(value, ["producer", "path"], path); return { producer: producerRef(record.producer, `${path}.producer`), path: valuePath(record.path, `${path}.path`) };
}
function projectionAssumption(value: unknown, path: string): V.ProjectionAssumption {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "Present" || tag === "NonNull") return { tag, value: valuePath(tupleTag(value, path, tag), `${path}.value`) };
  if (tag === "Variant") { const fields = recordTag(value, path, tag, ["path", "tag"]); return { tag, fields: { path: valuePath(fields.path, `${path}.fields.path`), tag: text(fields.tag, `${path}.fields.tag`) } }; }
  if (tag === "IndexPresent") { const fields = recordTag(value, path, tag, ["path", "index"]); return { tag, fields: { path: valuePath(fields.path, `${path}.fields.path`), index: natural(fields.index, `${path}.fields.index`).toString() } }; }
  return fail("UnknownTag", `${path}.tag`, tag);
}
function projectionCertificate(value: unknown, path: string): V.ProjectionCertificate {
  const record = row(value, ["profile", "source_refs", "source", "path", "assumptions", "destination"], path);
  return { profile: profileRef(record.profile, `${path}.profile`), source_refs: list(record.source_refs, `${path}.source_refs`, sourceRef), source: slotContract(record.source, `${path}.source`), path: valuePath(record.path, `${path}.path`), assumptions: list(record.assumptions, `${path}.assumptions`, projectionAssumption), destination: slotContract(record.destination, `${path}.destination`) };
}
function typePair(value: unknown, path: string): C.TypePair {
  const record = row(value, ["source", "destination", "source_tag"], path);
  return { source: slotContract(record.source, `${path}.source`), destination: slotContract(record.destination, `${path}.destination`), sourceTag: nullable(record.source_tag, `${path}.source_tag`, text) };
}
const inclusionRules = ["SameDefinedType", "EmptySource", "Boolean", "IntegerIntersection", "FiniteStrings", "StringConditions", "BytesLength", "Unit", "UnfoldSource", "UnfoldDestination", "Array", "Product", "SourceUnion", "DestinationUnion"] as const;
function inclusionCertificate(checked: S.CheckedSignatureLibrary, basis: S.SignatureGenerationBasis, value: unknown, path: string): C.InclusionCertificate {
  const record = row(value, ["basis", "source", "destination", "empty_types", "pairs", "root"], path);
  if (!V.same(S.decodeGenerationBasisWire(record.basis), basis)) return fail("Syntax", `${path}.basis`, "inclusion basis mismatch");
  const pairs = list(record.pairs, `${path}.pairs`, (item, itemPath): C.PairEntry => {
    const entry = row(item, ["pair", "source_shape", "destination_shape", "rule", "children"], itemPath), pair = typePair(entry.pair, `${itemPath}.pair`);
    const sourceNode = checked.library.nodes.find(node => node.id === pair.source.type_ref.definition_name), destinationNode = checked.library.nodes.find(node => node.id === pair.destination.type_ref.definition_name);
    if (sourceNode === undefined || destinationNode === undefined) return fail("Syntax", itemPath, "undeclared type");
    const sourceDeclared = S.decodeShapeWire(entry.source_shape), destinationDeclared = S.decodeShapeWire(entry.destination_shape);
    if (!S.sameJson(sourceDeclared, sourceNode.shape) || !S.sameJson(destinationDeclared, destinationNode.shape)) return fail("Syntax", itemPath, "inclusion shape mismatch");
    const ruleJson = entry.rule, ruleTag = V.wireTag(ruleJson, `${itemPath}.rule`);
    if (!(inclusionRules as readonly string[]).includes(ruleTag)) return fail("UnknownTag", "$.tag", ruleTag);
    const rule = unitTag(ruleJson, `${itemPath}.rule`, inclusionRules);
    const sourceShape = checked.context.node(pair.source.type_ref).shape, destinationShape = checked.context.node(pair.destination.type_ref).shape;
    return { pair, sourceShape, destinationShape, rule, children: list(entry.children, `${itemPath}.children`, natural) };
  });
  const source = slotContract(record.source, `${path}.source`), destination = slotContract(record.destination, `${path}.destination`);
  const emptyTypes = list(record.empty_types, `${path}.empty_types`, typeRef), root = natural(record.root, `${path}.root`);
  return { basis: V.semanticBasisOf(checked.context), source, destination, emptyTypes, pairs, root };
}
function bindingExpr(checked: S.CheckedSignatureLibrary, basis: S.SignatureGenerationBasis, value: unknown, path: string): C.BindingExpr {
  const tag = V.wireTag(value, path);
  if (tag !== "Source" && tag !== "Product") return fail("UnknownTag", "$.tag", tag);
  const fields = recordTag(value, path, tag, tag === "Source" ? ["value", "projection", "compatibility"] : ["construction", "type_id", "fields"]);
  if (tag === "Source") {
    const compatibilityTag = text((fields.compatibility as Row)?.tag, `${path}.fields.compatibility.tag`);
    const compatibility: C.BindingCompatibility = compatibilityTag === "Inclusion"
      ? { tag: "Inclusion", value: inclusionCertificate(checked, basis, tupleTag(fields.compatibility, `${path}.fields.compatibility`, compatibilityTag), `${path}.fields.compatibility.value`) }
      : compatibilityTag === "SuppliedValue" ? { tag: "SuppliedValue", value: slotValue(recordTag(fields.compatibility, `${path}.fields.compatibility`, compatibilityTag, ["value"]).value, `${path}.fields.compatibility.fields.value`) }
        : fail("UnknownTag", "$.tag", compatibilityTag);
    return { tag, fields: { value: valueRef(fields.value, `${path}.fields.value`), projection: projectionCertificate(fields.projection, `${path}.fields.projection`), compatibility } };
  }
  const entries = list(fields.fields, `${path}.fields.fields`, (item, itemPath) => pair(item, itemPath, text, (child, childPath) => bindingExpr(checked, basis, child, childPath)));
  return { tag, fields: { fields: entries, construction: text(fields.construction, `${path}.fields.construction`), typeRef: typeRef(fields.type_id, `${path}.fields.type_id`) } };
}
function returnPlan(checked: S.CheckedSignatureLibrary, basis: S.SignatureGenerationBasis, value: unknown, path: string): C.ReturnPlan {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "Success") return { tag, value: list(tupleTag(value, path, tag), `${path}.value`, (item, itemPath) => pair(item, itemPath, text, (binding, bindingPath) => bindingExpr(checked, basis, binding, bindingPath))) };
  if (tag === "Failure") { const fields = recordTag(value, path, tag, ["embedding", "value"]); return { tag, fields: { embedding: text(fields.embedding, `${path}.fields.embedding`), value: bindingExpr(checked, basis, fields.value, `${path}.fields.value`) } }; }
  return fail("UnknownTag", "$.tag", tag);
}
function invocationPlan(checked: S.CheckedSignatureLibrary, basis: S.SignatureGenerationBasis, value: unknown, path: string): C.InvocationPlan {
  const record = row(value, ["site", "function", "bindings", "resources"], path);
  const resources = list(record.resources, `${path}.resources`, (item, itemPath) => { const resource = row(item, ["requirement", "lot", "inclusion"], itemPath); return { requirement: text(resource.requirement, `${itemPath}.requirement`), lot: resourceLotRef(resource.lot, `${itemPath}.lot`), inclusion: inclusionCertificate(checked, basis, resource.inclusion, `${itemPath}.inclusion`) }; });
  const bindings = list(record.bindings, `${path}.bindings`, (item, itemPath) => pair(item, itemPath, text, (binding, bindingPath) => bindingExpr(checked, basis, binding, bindingPath)));
  return { site: text(record.site, `${path}.site`), function: functionRef(record.function, `${path}.function`), bindings, resources };
}
function planTree(checked: S.CheckedSignatureLibrary, basis: S.SignatureGenerationBasis, value: unknown, path: string): C.PlanTree {
  const record = row(value, ["rank", "node"], path), rank = natural(record.rank, `${path}.rank`), tag = V.wireTag(record.node, `${path}.node`);
  if (tag === "Return") return { tag: "ReturnValue", fields: { rank, terminal: returnPlan(checked, basis, tupleTag(record.node, `${path}.node`, tag), `${path}.node.value`) } };
  if (tag === "Invoke") {
    const fields = recordTag(record.node, `${path}.node`, tag, ["invocation", "arms", "empty_outcomes"]);
    const arms = list(fields.arms, `${path}.node.fields.arms`, (item, itemPath) => pair(item, itemPath, text, (tree, treePath) => planTree(checked, basis, tree, treePath)));
    const invocation = invocationPlan(checked, basis, fields.invocation, `${path}.node.fields.invocation`);
    return { tag, fields: { rank, invocation, arms, emptyOutcomes: list(fields.empty_outcomes, `${path}.node.fields.empty_outcomes`, text) } };
  }
  if (tag === "Guard") {
    const fields = recordTag(record.node, `${path}.node`, tag, ["guard", "inspected", "arms"]);
    const arms = list(fields.arms, `${path}.node.fields.arms`, (item, itemPath) => pair(item, itemPath, guardArm, (tree, treePath) => planTree(checked, basis, tree, treePath)));
    return { tag, fields: { rank, guard: text(fields.guard, `${path}.node.fields.guard`), inspected: valueRef(fields.inspected, `${path}.node.fields.inspected`), arms } };
  }
  return fail("UnknownTag", "$.tag", tag);
}
export function decodePlan(checked: S.CheckedSignatureLibrary, problem: unknown, value: unknown, basis: S.SignatureGenerationBasis = S.signatureBasis(checked.library, [])): C.CompositionPlan {
  S.requireCheckedLibrary(checked);
  const record = row(value, ["plan", "witness", "selection"], "$"), plan = row(record.plan, ["input_identity", "input_revision", "root"], "$.plan"), witness = row(record.witness, ["input_snapshot", "initial_membership", "resource_traces"], "$.witness");
  if (!S.sameJson(witness.input_snapshot, problem)) return fail("Syntax", "$", "input snapshot mismatch");
  const root = planTree(checked, basis, plan.root, "$.plan.root"), selectionTag = V.wireTag(record.selection, "$.selection");
  if (selectionTag === "AnyFeasible") unitTag(record.selection, "$.selection", [selectionTag]);
  else if (selectionTag !== "Unique") return fail("UnknownTag", "$.tag", selectionTag);
  return { inputIdentity: text(plan.input_identity, "$.plan.input_identity"), inputRevision: text(plan.input_revision, "$.plan.input_revision"), root };
}
