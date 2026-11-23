// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { residual, residualSet, stopped } from "neco-quotient-certificate";
import type { RefinementOutcome, Result, ResidualSet } from "neco-quotient-certificate";
import type * as S from "./semantic_signatures.js";
import * as V from "./semantic_values.js";
import type * as M from "./typed_mapping.js";
import { CheckedEmptyTypes, emptyTypes, verifyEmptyTypes } from "./semantic_empty_types.js";
import { ProjectionError, projectSlot } from "./signature_verification.js";

export interface SemanticBasis { readonly profile: V.VersionedSemanticProfile; readonly sources: readonly V.SourceRef[]; }
export interface FunctionRef { readonly identity: string; readonly revision: string; readonly contentDigest: string; }
export type InputId = string;
export type PortId = string;
export type SiteId = string;
export type OutcomeId = string;
export type GoalPortId = string;
export type LotId = string;
export type RequirementId = string;
export type ProductionId = string;
export type GuardId = string;
export type FailureEmbeddingId = string;
export type ValuePath = readonly V.PathStep[];

export interface TypePair { readonly source: V.SlotContract; readonly destination: V.SlotContract; readonly sourceTag: string | null; }
export type InclusionRule = { readonly tag: "SameDefinedType" | "EmptySource" | "Boolean" | "IntegerIntersection" | "FiniteStrings" | "StringConditions" | "BytesLength" | "Unit" | "UnfoldSource" | "UnfoldDestination" | "Array" | "Product" | "SourceUnion" | "DestinationUnion" };
export interface PairEntry { readonly pair: TypePair; readonly sourceShape: V.TypeShape; readonly destinationShape: V.TypeShape; readonly rule: InclusionRule; readonly children: readonly bigint[]; }
export interface InclusionCertificate { readonly basis: SemanticBasis; readonly source: V.SlotContract; readonly destination: V.SlotContract; readonly emptyTypes: readonly V.TypeRef[]; readonly pairs: readonly PairEntry[]; readonly root: bigint; }
export type TypeObligationReason =
  | { readonly tag: "Meaning"; readonly value: readonly V.SemanticObligation[] }
  | { readonly tag: "ConstraintImplication" | "Presence" | "UnionRemainder" | "Inhabitation" | "ObligationBoundExhausted" }
  | { readonly tag: "ExtraField"; readonly value: string };
export interface TypeObligation { readonly pair: TypePair; readonly path: ValuePath; readonly reason: TypeObligationReason; }
export type InclusionFailure =
  | { readonly tag: "BasisMismatch" | "ContractMismatch" | "MissingPair" | "ForgedEmptiness" | "CounterexampleMismatch" }
  | { readonly tag: "UndefinedMeaning"; readonly value: readonly V.SemanticObligation[] }
  | { readonly tag: "PairMismatch" | "RuleMismatch" | "ChildCoverage"; readonly value: bigint }
  | { readonly tag: "Unresolved"; readonly value: TypeObligation };

export type ProducerRef =
  | { readonly tag: "Initial"; readonly value: InputId }
  | { readonly tag: "InvocationOutcome"; readonly fields: { readonly site: SiteId; readonly outcome: OutcomeId; readonly port: PortId } };
export interface ValueRef { readonly producer: ProducerRef; readonly path: ValuePath; }
export type SourceConstraint =
  | { readonly tag: "AnyCompatible" }
  | { readonly tag: "InitialOnly"; readonly fields: { readonly input: InputId; readonly path: ValuePath } }
  | { readonly tag: "ProducedBy"; readonly fields: { readonly site: SiteId; readonly outcome: OutcomeId; readonly port: PortId; readonly path: ValuePath } };
export type ResourceLotRef =
  | { readonly tag: "Initial"; readonly value: LotId }
  | { readonly tag: "Produced"; readonly fields: { readonly site: SiteId; readonly outcome: OutcomeId; readonly production: ProductionId } };
export type ResourceProducer =
  | { readonly tag: "Initial"; readonly fields: { readonly identity: string; readonly revision: string } }
  | { readonly tag: "InvocationOutcome"; readonly fields: { readonly site: SiteId; readonly outcome: OutcomeId } };
export type ResourceIdentityConstraint = { readonly tag: "Any" } | { readonly tag: "Exactly"; readonly value: ResourceProducer };
export interface ResourceLot { readonly id: LotId; readonly tokenType: V.TypeRef; readonly producer: ResourceProducer; readonly revision: bigint; readonly quantity: bigint; readonly provenance: string; }
export interface ResourceRequirement { readonly id: RequirementId; readonly tokenType: V.TypeRef; readonly mode: M.BindingMode; readonly multiplicity: bigint; readonly requiredRevision: bigint; readonly identity: ResourceIdentityConstraint; }
export interface ResourceProduction { readonly id: ProductionId; readonly tokenType: V.TypeRef; readonly revision: bigint; readonly quantity: bigint; readonly provenance: string; }
export type InitialSource = { readonly tag: "Argument" } | { readonly tag: "SuppliedValue"; readonly value: V.ExactSlot };
export interface InitialInput { readonly id: InputId; readonly contract: V.SlotContract; readonly source: InitialSource; readonly resource: LotId | null; }
export interface InputPort { readonly id: PortId; readonly contract: V.SlotContract; readonly sourceConstraint: SourceConstraint; readonly resourceRequirement: RequirementId | null; }
export interface OutputPort { readonly id: PortId; readonly contract: V.SlotContract; readonly resourceProduction: ProductionId | null; }
export type OutcomeForm = { readonly tag: "Success" | "DeclaredFailure" };
export interface OutcomeContract { readonly id: OutcomeId; readonly form: OutcomeForm; readonly valuePorts: readonly OutputPort[]; readonly producedResources: readonly ResourceProduction[]; }
export type FunctionForm = { readonly tag: "Pure" | "DeclaredTransform" } | { readonly tag: "Operation"; readonly value: V.DefinitionRef };
export type CompositionEffect = { readonly tag: "PureFunction" | "HttpRequestResponse" | "DataOnly" };
export type GuardArm = { readonly tag: "Present" | "Absent" | "Null" | "UnknownVariant" | "Accepted" | "Rejected" } | { readonly tag: "Variant"; readonly value: string };
export type FailureOrigin =
  | { readonly tag: "Function"; readonly fields: { readonly function: FunctionRef; readonly outcome: OutcomeId } }
  | { readonly tag: "Guard"; readonly fields: { readonly guard: GuardId; readonly arm: GuardArm } };
export interface FunctionSignature { readonly reference: FunctionRef; readonly form: FunctionForm; readonly effect: CompositionEffect; readonly inputs: readonly InputPort[]; readonly outcomes: readonly OutcomeContract[]; readonly resourceInputs: readonly ResourceRequirement[]; readonly assumptionRef: string; readonly handlesFailure: FailureOrigin | null; }
export interface InvocationSite { readonly id: SiteId; readonly function: FunctionRef; }
export interface PermittedProjection { readonly sourceType: V.TypeRef; readonly path: ValuePath; }
export type GuardKind = { readonly tag: "Presence" | "Variants" } | { readonly tag: "Validate"; readonly value: V.SlotContract };
export interface DeclaredGuard { readonly id: GuardId; readonly sourceType: V.TypeRef; readonly path: ValuePath; readonly kind: GuardKind; }
export type FieldPresence = { readonly tag: "Required" | "Optional" };
export interface FieldConstraint { readonly field: string; readonly source: SourceConstraint; readonly presence: FieldPresence; }
export interface ConstructionRule { readonly identity: string; readonly typeRef: V.TypeRef; readonly nestedFields: readonly (readonly [string, string])[]; readonly fieldConstraints: readonly FieldConstraint[]; }
export interface InvocationDomain { readonly identity: string; readonly revision: string; readonly sites: readonly InvocationSite[]; readonly permittedProjections: readonly PermittedProjection[]; readonly permittedConstructions: readonly ConstructionRule[]; readonly permittedTransforms: readonly FunctionRef[]; readonly guards: readonly DeclaredGuard[]; }
export interface ResourceGoal { readonly lot: ResourceLotRef; readonly multiplicity: bigint; readonly revision: bigint; }
export interface GoalPort { readonly id: GoalPortId; readonly contract: V.SlotContract; readonly sourceConstraint: SourceConstraint; }
export interface FailureEmbedding { readonly id: FailureEmbeddingId; readonly origin: FailureOrigin; readonly contract: V.SlotContract; readonly finalResources: readonly ResourceGoal[]; }
export interface GoalSpec { readonly outputs: readonly GoalPort[]; readonly failures: readonly FailureEmbedding[]; readonly finalResources: readonly ResourceGoal[]; }
export type SelectionPolicy = { readonly tag: "RequireUnique" | "AnyFeasible" };
export interface ResourceBounds { readonly maxBindings: bigint; readonly maxSearchSteps: bigint; readonly maxTokens: bigint; }
export interface SearchBounds { readonly maxExpandedStates: bigint; readonly maxBindingCandidates: bigint; readonly maxTypeObligations: bigint; readonly maxBranchNodes: bigint; readonly maxSampleLength: bigint; readonly resourceBounds: ResourceBounds | null; }
export interface CompositionInput { readonly identity: string; readonly revision: string; readonly basis: SemanticBasis; readonly signatures: readonly FunctionSignature[]; readonly initialInputs: readonly InitialInput[]; readonly initialResources: readonly ResourceLot[]; readonly goal: GoalSpec; readonly invocationDomain: InvocationDomain; readonly allowedEffects: readonly CompositionEffect[]; readonly explicitOrder: readonly (readonly [SiteId, SiteId])[]; readonly selectionPolicy: SelectionPolicy | null; readonly bounds: SearchBounds; }

export type CompositionInputFailure =
  | { readonly tag: "BasisMismatch" }
  | { readonly tag: "DuplicateIdentity"; readonly fields: { readonly kind: string; readonly identity: string } }
  | { readonly tag: "UnresolvedType"; readonly value: V.TypeRef }
  | { readonly tag: "UnresolvedFunction"; readonly value: FunctionRef }
  | { readonly tag: "InvalidSignature"; readonly fields: { readonly function: FunctionRef; readonly reason: string } }
  | { readonly tag: "InvalidInitialValue"; readonly fields: { readonly input: InputId; readonly failure: V.ValueFailure } }
  | { readonly tag: "SiteEffectNotPermitted"; readonly fields: { readonly site: SiteId; readonly effect: CompositionEffect } }
  | { readonly tag: "TransformNotPermitted"; readonly value: FunctionRef }
  | { readonly tag: "EmptyGoal" }
  | { readonly tag: "GoalSourceConstraintUndefined"; readonly fields: { readonly port: GoalPortId; readonly constraint: SourceConstraint } }
  | { readonly tag: "FailureEmbeddingOriginUndefined"; readonly fields: { readonly embedding: FailureEmbeddingId; readonly origin: FailureOrigin } }
  | { readonly tag: "ConstructionNotProduct"; readonly fields: { readonly identity: string; readonly typeRef: V.TypeRef } }
  | { readonly tag: "FieldConstraintUnknownField"; readonly fields: { readonly identity: string; readonly field: string } }
  | { readonly tag: "ConstrainedNestedField"; readonly fields: { readonly identity: string; readonly field: string } }
  | { readonly tag: "ConstructionFieldSourceUndefined"; readonly fields: { readonly identity: string; readonly constraint: FieldConstraint } }
  | { readonly tag: "NestedFieldUndeclared"; readonly fields: { readonly identity: string; readonly field: string } }
  | { readonly tag: "NestedConstructionMismatch"; readonly fields: { readonly identity: string; readonly field: string; readonly nested: string; readonly typeRef: V.TypeRef } }
  | { readonly tag: "CyclicConstruction"; readonly fields: { readonly identity: string } }
  | { readonly tag: "ExplicitSiteOrderInvalid"; readonly fields: { readonly before: SiteId; readonly after: SiteId } }
  | { readonly tag: "InvalidEmptyTypeClosure"; readonly value: InclusionFailure }
  | { readonly tag: "InvalidResourceDeclaration"; readonly value: string }
  | { readonly tag: "InvalidLibrary"; readonly value: S.LibraryCheckFailure };

export type BindingCompatibility = { readonly tag: "Inclusion"; readonly value: InclusionCertificate } | { readonly tag: "SuppliedValue"; readonly value: V.ExactSlot };
export type BindingExpr =
  | { readonly tag: "Source"; readonly fields: { readonly value: ValueRef; readonly projection: V.ProjectionCertificate; readonly compatibility: BindingCompatibility } }
  | { readonly tag: "Product"; readonly fields: { readonly construction: string; readonly typeRef: V.TypeRef; readonly fields: readonly (readonly [string, BindingExpr])[] } };
export interface ResourceBinding { readonly requirement: RequirementId; readonly lot: ResourceLotRef; readonly inclusion: InclusionCertificate; }
export interface InvocationPlan { readonly site: SiteId; readonly function: FunctionRef; readonly bindings: readonly (readonly [PortId, BindingExpr])[]; readonly resources: readonly ResourceBinding[]; }
export type ReturnPlan = { readonly tag: "Success"; readonly value: readonly (readonly [GoalPortId, BindingExpr])[] } | { readonly tag: "Failure"; readonly fields: { readonly embedding: FailureEmbeddingId; readonly value: BindingExpr } };
export type PlanTree =
  | { readonly tag: "Invoke"; readonly fields: { readonly rank: bigint; readonly invocation: InvocationPlan; readonly arms: readonly (readonly [OutcomeId, PlanTree])[]; readonly emptyOutcomes: readonly OutcomeId[] } }
  | { readonly tag: "Guard"; readonly fields: { readonly rank: bigint; readonly guard: GuardId; readonly inspected: ValueRef; readonly arms: readonly (readonly [GuardArm, PlanTree])[] } }
  | { readonly tag: "ReturnValue"; readonly fields: { readonly rank: bigint; readonly terminal: ReturnPlan } };
export interface CompositionPlan { readonly inputIdentity: string; readonly inputRevision: string; readonly root: PlanTree; }
export type WitnessFailure =
  | { readonly tag: "InputRevisionMismatch" | "GoalMismatch" | "RankViolation" }
  | { readonly tag: "InitialMembership"; readonly value: InputId }
  | { readonly tag: "ProducerMismatch" | "SourceConstraintMismatch" | "SuppliedValueMismatch" | "GuardNotDominating"; readonly value: ValueRef }
  | { readonly tag: "ProjectionMismatch"; readonly value: unknown }
  | { readonly tag: "Inclusion"; readonly value: InclusionFailure }
  | { readonly tag: "ConstructionMismatch"; readonly value: V.TypeRef }
  | { readonly tag: "MissingBinding" | "IncompleteBranchCoverage" | "ResourceLoweringMismatch" | "ResourceReplayMismatch" | "ForgedClosure" | "ForgedAcyclicity" | "MissingEvidence"; readonly value: string }
  | { readonly tag: "SignatureMismatch"; readonly value: SiteId }
  | { readonly tag: "FailureEmbeddingMismatch"; readonly value: FailureEmbeddingId };
export type UnresolvedObligation =
  | { readonly tag: "Type"; readonly fields: { readonly value: ValueRef | null; readonly obligations: readonly TypeObligation[] } }
  | { readonly tag: "Meaning"; readonly value: readonly V.SemanticObligation[] }
  | { readonly tag: "Inhabitation"; readonly fields: { readonly producer: ProducerRef; readonly contract: V.SlotContract } }
  | { readonly tag: "BranchInhabitation" }
  | { readonly tag: "StateBoundExhausted" | "BindingBoundExhausted" | "BranchBoundExhausted" | "UnresolvedUniqueness" }
  | { readonly tag: "ResourceSolverUnknown"; readonly value: M.UnknownReason }
  | { readonly tag: "ResourceCapacityBound"; readonly fields: { readonly required: bigint; readonly limit: bigint } };
export interface CompositionJudgment { readonly provenance: unknown; readonly obligations: readonly UnresolvedObligation[]; }
export interface CompositionReasonFailure { readonly provenance: unknown; readonly obligations: readonly UnresolvedObligation[]; readonly residuals: ResidualSet<UnresolvedObligation>; readonly classes: readonly V.ReasonDisposition[]; }
export type CompositionEvaluation = Result<RefinementOutcome<CompositionJudgment, UnresolvedObligation, readonly UnresolvedObligation[]>, CompositionReasonFailure>;
function distinct<T>(values: readonly T[]): T[] {
  return values.filter((value, index) => values.findIndex(other => V.same(other, value)) === index);
}
function typeReasonDispositions(reason: TypeObligationReason): V.ReasonDisposition[] {
  switch (reason.tag) {
    case "Meaning": return reason.value.length ? reason.value.map(item => V.semanticReasonDisposition(item.reason)) : ["Failed"];
    case "ObligationBoundExhausted": return ["Stopped"];
    case "ConstraintImplication": case "Presence": case "UnionRemainder": case "Inhabitation": case "ExtraField": return ["Residual"];
  }
}
export function unresolvedDispositions(obligation: UnresolvedObligation): V.ReasonDisposition[] {
  switch (obligation.tag) {
    case "Type": {
      const reasons = obligation.fields.obligations;
      return reasons.length ? reasons.flatMap(item => typeReasonDispositions(item.reason)) : ["Failed"];
    }
    case "Meaning": return obligation.value.length ? obligation.value.map(item => V.semanticReasonDisposition(item.reason)) : ["Failed"];
    case "Inhabitation": case "BranchInhabitation": case "UnresolvedUniqueness": return ["Residual"];
    case "StateBoundExhausted": case "BindingBoundExhausted": case "BranchBoundExhausted": case "ResourceSolverUnknown": case "ResourceCapacityBound": return ["Stopped"];
  }
}
export function unresolvedAtoms(obligation: UnresolvedObligation): readonly UnresolvedObligation[] {
  if (obligation.tag === "Meaning") {
    return obligation.value.length ? obligation.value.map((reason): UnresolvedObligation => ({ tag: "Meaning", value: [reason] })) : [obligation];
  }
  if (obligation.tag !== "Type" || obligation.fields.obligations.length === 0) return [obligation];
  const value = obligation.fields.value;
  return obligation.fields.obligations.flatMap((item): UnresolvedObligation[] => {
    const wrap = (reason: TypeObligationReason): UnresolvedObligation => ({ tag: "Type", fields: { value, obligations: [{ ...item, reason }] } });
    if (item.reason.tag !== "Meaning" || item.reason.value.length === 0) return [wrap(item.reason)];
    return item.reason.value.map(reason => wrap({ tag: "Meaning", value: [reason] }));
  });
}
export function classifyUnresolvedObligations(provenance: unknown, obligations: readonly UnresolvedObligation[]): CompositionEvaluation {
  const classes = obligations.flatMap(unresolvedDispositions);
  const atoms = obligations.flatMap(unresolvedAtoms);
  const residuals = distinct(atoms.filter(atom => V.classifyDispositions(unresolvedDispositions(atom)) === "Residual"));
  const stops = atoms.filter(atom => V.classifyDispositions(unresolvedDispositions(atom)) === "Stopped");
  const judgment = { provenance, obligations };
  const status = V.classifyDispositions(classes);
  if (obligations.length === 0 || status === "Failed") return { ok: false, error: { provenance, obligations, residuals: residualSet(residuals), classes } };
  if (status === "Residual") return { ok: true, value: residual(judgment, residuals) };
  return { ok: true, value: stopped(judgment, residuals, stops) };
}
export type LoweringFailure = { readonly tag: "Invalid"; readonly value: string } | { readonly tag: "Unknown"; readonly value: UnresolvedObligation };
export type CompositionEngineFailure = { readonly tag: "ContractViolation"; readonly value: string } | { readonly tag: "Resource"; readonly value: M.SolverFailure } | { readonly tag: "Witness"; readonly value: WitnessFailure };

export type CompositionInputResult<T> = { readonly tag: "Ok"; readonly value: T } | { readonly tag: "Failed"; readonly failure: CompositionInputFailure };
export type OperationChecker = (signature: FunctionSignature, reference: V.DefinitionRef) => CompositionInputFailure | null;
export type OperationMeaning = (signature: FunctionSignature, reference: V.DefinitionRef) => readonly V.SemanticObligation[];

const preparedCompositionInputToken = Symbol("prepared composition input");
const preparedCompositionInputAuthority = new WeakSet<PreparedCompositionInput>();

export class PreparedCompositionInput {
  readonly context: V.ValueContext;
  readonly input: CompositionInput;
  readonly operationChecker: OperationChecker;
  readonly operationMeaning: OperationMeaning;
  readonly emptyRefs: readonly V.TypeRef[];

  private constructor(
    token: symbol,
    context: V.ValueContext,
    input: CompositionInput,
    operationChecker: OperationChecker,
    operationMeaning: OperationMeaning,
    emptyRefs: readonly V.TypeRef[],
  ) {
    if (token !== preparedCompositionInputToken) throw new TypeError("composition input admission authority");
    this.context = context;
    this.input = V.deepFreeze(structuredClone(input));
    this.operationChecker = operationChecker;
    this.operationMeaning = operationMeaning;
    this.emptyRefs = V.deepFreeze(structuredClone(emptyRefs));
    preparedCompositionInputAuthority.add(this);
    Object.freeze(this);
  }

  static admit(token: symbol, context: V.ValueContext, input: CompositionInput, operationChecker: OperationChecker, operationMeaning: OperationMeaning, emptyRefs: readonly V.TypeRef[]): PreparedCompositionInput {
    return new PreparedCompositionInput(token, context, input, operationChecker, operationMeaning, emptyRefs);
  }
}

export function requirePreparedCompositionInput(value: PreparedCompositionInput): void {
  if (!preparedCompositionInputAuthority.has(value)) throw new TypeError("prepared composition input authority");
}

export function signature(input: CompositionInput, reference: FunctionRef): FunctionSignature | undefined {
  return input.signatures.find(candidate => V.same(candidate.reference, reference));
}

export function siteSignature(input: CompositionInput, site: SiteId): FunctionSignature | undefined {
  const invocation = input.invocationDomain.sites.find(candidate => candidate.id === site);
  return invocation === undefined ? undefined : signature(input, invocation.function);
}

function uniqueIds(kind: string, identities: readonly string[]): CompositionInputFailure | null {
  const seen = new Set<string>();
  for (const identity of identities) {
    if (identity === "" || seen.has(identity)) return { tag: "DuplicateIdentity", fields: { kind, identity } };
    seen.add(identity);
  }
  return null;
}

function checkType(context: V.ValueContext, reference: V.TypeRef): CompositionInputFailure | null {
  return V.findType(context, reference) !== undefined
    ? null : { tag: "UnresolvedType", value: reference };
}

function constraintPathDefined(context: V.ValueContext, contract: V.SlotContract, path: ValuePath): boolean {
  const owned = structuredClone({ contract, path });
  const assumptions = owned.path.flatMap((step, index): V.ProjectionAssumption[] => step.tag === "Variant" ? [{ tag: "Variant", fields: { path: owned.path.slice(0, index), tag: step.value } }] : []);
  try { projectSlot(context, owned.contract, owned.path, assumptions); return true; }
  catch (error) { if (error instanceof ProjectionError) return false; throw error; }
}

export function declaredValue(input: CompositionInput, producer: ProducerRef): readonly [V.SlotContract, ResourceLotRef | null] | undefined {
  if (producer.tag === "Initial") {
    const initial = input.initialInputs.find(candidate => candidate.id === producer.value);
    return initial === undefined ? undefined : [initial.contract, initial.resource === null ? null : { tag: "Initial", value: initial.resource }];
  }
  const outcome = siteSignature(input, producer.fields.site)?.outcomes.find(candidate => candidate.id === producer.fields.outcome);
  const port = outcome?.valuePorts.find(candidate => candidate.id === producer.fields.port);
  if (port === undefined) return undefined;
  return [port.contract, port.resourceProduction === null ? null : { tag: "Produced", fields: { site: producer.fields.site, outcome: producer.fields.outcome, production: port.resourceProduction } }];
}

function sourceConstraintDefined(context: V.ValueContext, input: CompositionInput, constraint: SourceConstraint): boolean {
  if (constraint.tag === "AnyCompatible") return true;
  const producer: ProducerRef = constraint.tag === "InitialOnly"
    ? { tag: "Initial", value: constraint.fields.input }
    : { tag: "InvocationOutcome", fields: { site: constraint.fields.site, outcome: constraint.fields.outcome, port: constraint.fields.port } };
  const declared = declaredValue(input, producer);
  return declared !== undefined && constraintPathDefined(context, declared[0], constraint.fields.path);
}

function failureOriginDefined(input: CompositionInput, origin: FailureOrigin): boolean {
  if (origin.tag === "Function") {
    return signature(input, origin.fields.function)?.outcomes.some(outcome => outcome.id === origin.fields.outcome && outcome.form.tag === "DeclaredFailure") ?? false;
  }
  return input.invocationDomain.guards.some(guard => guard.id === origin.fields.guard);
}


function constructionReachable(rules: readonly ConstructionRule[], pendingInput: readonly string[], fuelInput: number): readonly string[] {
  const pending = [...pendingInput], seen: string[] = [];
  for (let fuel = fuelInput; fuel > 0 && pending.length > 0; fuel -= 1) {
    const identity = pending.shift()!;
    if (seen.includes(identity)) continue;
    const children = rules.find(rule => rule.identity === identity)?.nestedFields.map(([, child]) => child) ?? [];
    pending.unshift(...children);
    seen.unshift(identity);
  }
  return seen;
}

export interface LotDeclaration { readonly tokenType: V.TypeRef; readonly producer: ResourceProducer; readonly revision: bigint; readonly quantity: bigint; readonly provenance: string; }
export function declaredLot(input: CompositionInput, reference: ResourceLotRef): LotDeclaration | undefined {
  if (reference.tag === "Initial") {
    const lot = input.initialResources.find(candidate => candidate.id === reference.value);
    return lot === undefined ? undefined : { tokenType: lot.tokenType, producer: lot.producer, revision: lot.revision, quantity: lot.quantity, provenance: lot.provenance };
  }
  const production = siteSignature(input, reference.fields.site)?.outcomes.find(outcome => outcome.id === reference.fields.outcome)
    ?.producedResources.find(candidate => candidate.id === reference.fields.production);
  return production === undefined ? undefined : {
    tokenType: production.tokenType, producer: { tag: "InvocationOutcome", fields: { site: reference.fields.site, outcome: reference.fields.outcome } },
    revision: production.revision, quantity: production.quantity, provenance: production.provenance,
  };
}

export function validateCompositionInput(context: V.ValueContext, input: CompositionInput, operationChecker: OperationChecker): CompositionInputFailure | null {
  if (!V.same(input.basis, V.semanticBasisOf(context))) return { tag: "BasisMismatch" };
  const identities: readonly (readonly [string, readonly string[]])[] = [
    ["input", input.initialInputs.map(value => value.id)],
    ["site", input.invocationDomain.sites.map(value => value.id)],
    ["lot", input.initialResources.map(value => value.id)],
    ["goal", input.goal.outputs.map(value => value.id)],
    ["failure embedding", input.goal.failures.map(value => value.id)],
    ["function", input.signatures.map(value => V.encodeTuple([value.reference.identity, value.reference.revision, value.reference.contentDigest]))],
    ["guard", input.invocationDomain.guards.map(value => value.id)],
  ];
  for (const [kind, values] of identities) { const failure = uniqueIds(kind, values); if (failure !== null) return failure; }
  for (const functionSignature of input.signatures) {
    const invalid = (reason: string): CompositionInputFailure => ({ tag: "InvalidSignature", fields: { function: functionSignature.reference, reason } });
    if (functionSignature.reference.identity === "" || functionSignature.reference.revision === "" || functionSignature.reference.contentDigest === "" || functionSignature.assumptionRef === "" || functionSignature.outcomes.length === 0) return invalid("identity, revision, digest, assumptions, or outcomes");
    for (const [kind, values] of [
      ["input port", functionSignature.inputs.map(value => value.id)],
      ["outcome", functionSignature.outcomes.map(value => value.id)],
      ["resource requirement", functionSignature.resourceInputs.map(value => value.id)],
    ] as const) { const failure = uniqueIds(kind, values); if (failure !== null) return failure; }
    if ((functionSignature.form.tag === "Pure" || functionSignature.form.tag === "DeclaredTransform") && functionSignature.effect.tag !== "PureFunction") return invalid("pure function effect");
    if (functionSignature.form.tag === "Operation") { const failure = operationChecker(functionSignature, functionSignature.form.value); if (failure !== null) return failure; }
    for (const port of functionSignature.inputs) {
      const failure = checkType(context, port.contract.type_ref); if (failure !== null) return failure;
      if (!sourceConstraintDefined(context, input, port.sourceConstraint)) return invalid("input source constraint");
      if (port.resourceRequirement !== null && !functionSignature.resourceInputs.some(requirement => requirement.id === port.resourceRequirement)) return invalid("input resource requirement");
    }
    for (const requirement of functionSignature.resourceInputs) {
      const failure = checkType(context, requirement.tokenType); if (failure !== null) return failure;
      if (requirement.multiplicity === 0n) return invalid("zero resource multiplicity");
    }
    for (const outcome of functionSignature.outcomes) {
      for (const [kind, values] of [["output port", outcome.valuePorts.map(value => value.id)], ["resource production", outcome.producedResources.map(value => value.id)]] as const) {
        const failure = uniqueIds(kind, values); if (failure !== null) return failure;
      }
      for (const port of outcome.valuePorts) {
        const failure = checkType(context, port.contract.type_ref); if (failure !== null) return failure;
        if (port.resourceProduction !== null && !outcome.producedResources.some(production => production.id === port.resourceProduction)) return invalid("output resource production");
      }
      for (const production of outcome.producedResources) { const failure = checkType(context, production.tokenType); if (failure !== null) return failure; }
    }
    if (functionSignature.handlesFailure !== null && !failureOriginDefined(input, functionSignature.handlesFailure)) return invalid("failure handler origin");
  }
  for (const site of input.invocationDomain.sites) {
    const functionSignature = signature(input, site.function);
    if (functionSignature === undefined) return { tag: "UnresolvedFunction", value: site.function };
    if (!input.allowedEffects.some(effect => effect.tag === functionSignature.effect.tag)) return { tag: "SiteEffectNotPermitted", fields: { site: site.id, effect: functionSignature.effect } };
    if (functionSignature.form.tag === "DeclaredTransform" && !input.invocationDomain.permittedTransforms.some(reference => V.same(reference, functionSignature.reference))) return { tag: "TransformNotPermitted", value: functionSignature.reference };
  }
  for (const initial of input.initialInputs) {
    const failure = checkType(context, initial.contract.type_ref); if (failure !== null) return failure;
    if (initial.source.tag === "SuppliedValue") {
      const decision = V.acceptsSlot(context, initial.contract, initial.source.value);
      if (decision.tag === "Rejected") return { tag: "InvalidInitialValue", fields: { input: initial.id, failure: decision.failure } };
    }
    if (initial.resource !== null && !input.initialResources.some(lot => lot.id === initial.resource)) return { tag: "InvalidResourceDeclaration", value: "initial backing lot" };
  }
  for (const lot of input.initialResources) {
    const failure = checkType(context, lot.tokenType); if (failure !== null) return failure;
    if (lot.producer.tag !== "Initial") return { tag: "InvalidResourceDeclaration", value: "initial lot has an invocation producer" };
    if (lot.producer.fields.identity === "" || lot.producer.fields.revision === "" || lot.provenance === "") return { tag: "InvalidResourceDeclaration", value: "initial producer or provenance" };
  }
  if (input.goal.outputs.length === 0) return { tag: "EmptyGoal" };
  for (const goal of input.goal.outputs) {
    const failure = checkType(context, goal.contract.type_ref); if (failure !== null) return failure;
    if (!sourceConstraintDefined(context, input, goal.sourceConstraint)) return { tag: "GoalSourceConstraintUndefined", fields: { port: goal.id, constraint: goal.sourceConstraint } };
  }
  for (const embedding of input.goal.failures) {
    const failure = checkType(context, embedding.contract.type_ref); if (failure !== null) return failure;
    if (!failureOriginDefined(input, embedding.origin)) return { tag: "FailureEmbeddingOriginUndefined", fields: { embedding: embedding.id, origin: embedding.origin } };
  }
  for (const projection of input.invocationDomain.permittedProjections) { const failure = checkType(context, projection.sourceType); if (failure !== null) return failure; }
  { const failure = uniqueIds("construction", input.invocationDomain.permittedConstructions.map(rule => rule.identity)); if (failure !== null) return failure; }
  const constructionEdges = input.invocationDomain.permittedConstructions.reduce((count, rule) => count + rule.nestedFields.length, 0);
  for (const construction of input.invocationDomain.permittedConstructions) {
    const failure = checkType(context, construction.typeRef); if (failure !== null) return failure;
    const shape = V.resolvedShape(context, construction.typeRef);
    if (shape?.tag !== "Product") return { tag: "ConstructionNotProduct", fields: { identity: construction.identity, typeRef: construction.typeRef } };
    for (const [kind, values] of [["nested field", construction.nestedFields.map(([name]) => name)], ["field constraint", construction.fieldConstraints.map(constraint => constraint.field)]] as const) {
      const duplicate = uniqueIds(kind, values); if (duplicate !== null) return duplicate;
    }
    for (const constraint of construction.fieldConstraints) {
      if (!shape.value.fields.some(field => field.wire_name === constraint.field)) return { tag: "FieldConstraintUnknownField", fields: { identity: construction.identity, field: constraint.field } };
      if (construction.nestedFields.some(([name]) => name === constraint.field)) return { tag: "ConstrainedNestedField", fields: { identity: construction.identity, field: constraint.field } };
      if (!sourceConstraintDefined(context, input, constraint.source)) return { tag: "ConstructionFieldSourceUndefined", fields: { identity: construction.identity, constraint } };
    }
    for (const [name, nested] of construction.nestedFields) {
      const field = shape.value.fields.find(candidate => candidate.wire_name === name);
      if (field === undefined) return { tag: "NestedFieldUndeclared", fields: { identity: construction.identity, field: name } };
      if (!input.invocationDomain.permittedConstructions.some(rule => rule.identity === nested && V.same(rule.typeRef, field.slot.type_ref))) return { tag: "NestedConstructionMismatch", fields: { identity: construction.identity, field: name, nested, typeRef: field.slot.type_ref } };
      const reached = constructionReachable(input.invocationDomain.permittedConstructions, [nested], input.invocationDomain.permittedConstructions.length + constructionEdges + 1);
      if (reached.includes(construction.identity)) return { tag: "CyclicConstruction", fields: { identity: construction.identity } };
    }
  }
  for (const guard of input.invocationDomain.guards) {
    let failure = checkType(context, guard.sourceType); if (failure !== null) return failure;
    if (guard.kind.tag === "Validate") { failure = checkType(context, guard.kind.value.type_ref); if (failure !== null) return failure; }
  }
  for (const [before, after] of input.explicitOrder) {
    if (before === after || siteSignature(input, before) === undefined || siteSignature(input, after) === undefined) return { tag: "ExplicitSiteOrderInvalid", fields: { before, after } };
  }
  for (const goal of [...input.goal.finalResources, ...input.goal.failures.flatMap(embedding => embedding.finalResources)]) {
    if (declaredLot(input, goal.lot) === undefined) return { tag: "InvalidResourceDeclaration", value: "terminal resource lot" };
  }
  return null;
}

function verifyEmptyClosureInput(context: V.ValueContext, refs: readonly V.TypeRef[]): CompositionInputResult<CheckedEmptyTypes> {
  const empty = verifyEmptyTypes(context, refs);
  if (empty.tag === "Failed") return { tag: "Failed", failure: { tag: "InvalidEmptyTypeClosure", value: empty.failure } };
  return { tag: "Ok", value: empty.value };
}

export function prepareDirectComposition(context: V.ValueContext, input: CompositionInput, operationChecker: OperationChecker, operationMeaning: OperationMeaning): CompositionInputResult<PreparedCompositionInput> {
  const failure = validateCompositionInput(context, input, operationChecker);
  if (failure !== null) return { tag: "Failed", failure };
  const empty = verifyEmptyClosureInput(context, emptyTypes(context));
  if (empty.tag === "Failed") return empty;
  return { tag: "Ok", value: PreparedCompositionInput.admit(preparedCompositionInputToken, context, input, operationChecker, operationMeaning, empty.value.refs) };
}

export type CauseBinding = { readonly function: FunctionRef; readonly outcome: OutcomeId; readonly cause: S.OutcomeCause };
