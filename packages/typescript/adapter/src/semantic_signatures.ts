// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import * as V from "./semantic_values.js";
import * as C from "./semantic_composition.js";
import * as W from "./signature_composition_wire.js";
import { validateSemanticWire } from "./signature_verification.js";
import { RuleTable, admit, projectionDigests, residualSet } from "neco-quotient-certificate";
import type { Checked, Mismatch, ProjectionDigest, ProjectionDigestsInput } from "neco-quotient-certificate";
import * as E from "./semantic_execution.js";
import { compositionAdmissionToken } from "./composition_admission_token.js";
import type * as N from "./network-effect.js";


export type TypeId = string;
export type DefinitionId = string;
export type GroupId = string;
export type SourceIdentity = V.SourceIdentity;
export interface Origin { readonly source: SourceIdentity; readonly locator: readonly string[]; }
export type AnnotationTarget = { readonly tag: "Library" } | { readonly tag: "Group" | "Definition" | "Type"; readonly value: string } | { readonly tag: "Outcome"; readonly fields: { readonly definition: string; readonly outcome: string } };
export interface Annotation { readonly target: AnnotationTarget; readonly key: string; readonly value: V.ExactJson; }
export interface DefinitionGroup { readonly id: GroupId; readonly members: readonly DefinitionId[]; }
export interface SignatureSlot { readonly type_id: TypeId; readonly required: boolean; readonly nullable: boolean; }
export interface SignaturePort { readonly id: string; readonly contract: SignatureSlot; }
export type OutcomeCause = { readonly tag: "ValueContract"; readonly fields: { readonly origin: Origin } } | { readonly tag: "ExternalCondition"; readonly fields: { readonly specification: Origin } };
export type SignatureResourceProduction = Omit<V.ResourceProduction, "token_type"> & { readonly token_type: TypeId };
export interface SignatureOutcome { readonly id: string; readonly form: V.OutcomeContract["form"]; readonly cause: OutcomeCause; readonly value_ports: readonly SignaturePort[]; readonly produced_resources: readonly SignatureResourceProduction[]; }
export interface OperationContract { readonly effect: { readonly tag: "HttpRequestResponse" | "DataOnly" }; readonly inputs: readonly SignaturePort[]; readonly outcomes: readonly SignatureOutcome[]; }
export type SignatureElementContract = { readonly type_id: TypeId; readonly nullable: boolean };
export type SignatureExtraMembers = { readonly tag: "Reject" } | { readonly tag: "Allow"; readonly fields: { readonly key_format: V.FormatUse | null; readonly value: SignatureElementContract } };
export type ValueTypeShape =
  | Exclude<V.TypeShape, { tag: "Product" | "Array" | "TaggedUnion" | "Alias" }>
  | { readonly tag: "Product"; readonly value: { readonly fields: readonly { readonly wire_name: string; readonly slot: SignatureSlot }[]; readonly extras: SignatureExtraMembers } }
  | { readonly tag: "Array"; readonly value: { readonly item: SignatureElementContract; readonly min_length: string | null; readonly max_length: string | null } }
  | { readonly tag: "TaggedUnion"; readonly value: { readonly branches: readonly { readonly target: TypeId; readonly wire_tag: string; readonly selector: V.BranchSelector }[] } }
  | { readonly tag: "Alias"; readonly fields: { readonly target: TypeId } };
export type SignatureDefinition = { readonly id: DefinitionId; readonly wire_identity: string; readonly shape: { readonly tag: "Value" | "Message" | "Symbol"; readonly value: string } | { readonly tag: "Operation"; readonly value: OperationContract } };
export type SignatureGraphemeRules = Omit<V.GraphemeRules, "sources"> & { readonly sources: readonly { readonly role: string; readonly origin: Origin }[] };
export type ValueSemanticProfile = Omit<V.VersionedSemanticProfile, "source_refs" | "grapheme_rules"> & { readonly source_refs: readonly SourceIdentity[]; readonly grapheme_rules: SignatureGraphemeRules | null };
export interface TypeSignatureLibrary { readonly schema: "ncoh-type-signatures@1"; readonly identity: string; readonly revision: string; readonly profile: ValueSemanticProfile; readonly sources: readonly SourceIdentity[]; readonly provenance: readonly { readonly target: AnnotationTarget; readonly origins: readonly Origin[] }[]; readonly groups: readonly DefinitionGroup[]; readonly annotations: readonly Annotation[]; readonly nodes: readonly { readonly id: TypeId; readonly shape: ValueTypeShape }[]; readonly definitions: readonly SignatureDefinition[]; }
export interface SignatureGenerationBasis { readonly signature_schema: "ncoh-type-signatures@1"; readonly library_identity: string; readonly library_revision: string; readonly profile: V.ProfileRef; readonly graph_sha256: string; readonly provenance_sha256: string; readonly metadata_sha256: string; readonly problem_sha256: string | null; readonly observations_sha256: string | null; readonly entrypoints_sha256: string; }
/** 合成の goal が実行結果として観測させる量の族の宣言。成功時の出力、失敗の埋め込み、最終的な資源の要求、中断とネットワーク指示の列、残余 ( residual ) の集合、型付き実行失敗の種類、結果の来歴を定める。 */
export interface GoalObservations { readonly outputs: readonly unknown[]; readonly failures: readonly unknown[]; readonly final_resources: unknown; readonly effects: readonly string[]; readonly residuals: string; readonly execution_failures: readonly string[]; readonly provenance: string; }
export interface ExpectedSignatureBasis { readonly basis: SignatureGenerationBasis; readonly observations: GoalObservations | null; }
export interface SignatureGenerationInput { readonly schema: "ncoh-checked-generation@5"; readonly basis: SignatureGenerationBasis; readonly signatures: TypeSignatureLibrary; readonly composition: unknown | null; readonly entrypoints: readonly { readonly identity: string; readonly definition: DefinitionId }[]; }
const check: typeof V.requireEvidence = V.requireEvidence;
function object(value: unknown, keys: string): Record<string, unknown> {
  check(value !== null && typeof value === "object" && !Array.isArray(value), "closed object");
  const out = value as Record<string, unknown>, expected = keys.split(" ").filter(Boolean);
  const unknown = Object.keys(out).find(key => !expected.includes(key));
  if (unknown !== undefined) throw new V.SemanticEvidenceError(`UnknownField:${unknown}`);
  check(expected.every(key => Object.hasOwn(out, key)), `closed fields: ${keys}`);
  return out;
}
function identity(value: unknown): asserts value is string { check(typeof value === "string" && value.length > 0, "nonempty opaque identity"); validateSemanticWire("string", value); }
function unique(values: readonly string[]): void { values.forEach(identity); check(new Set(values).size === values.length, "duplicate identity"); }
function canonicalNumber(spelling: string): string {
  const matched = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(spelling);
  if (matched === null) throw new V.SemanticEvidenceError("JSON number");
  const sign = matched[1]!, whole = matched[2]!, fraction = matched[3] ?? "", exponent = Number(matched[4] ?? "0");
  const digits = `${whole}${fraction}`.replace(/^0+/, "");
  if (digits.length === 0) return "0";
  const scale = fraction.length - exponent;
  if (scale <= 0) return `${sign}${digits}${"0".repeat(-scale)}`;
  const scientific = Math.min(9 + digits.length - scale, 0), decimalPlaces = scale + scientific, split = digits.length - decimalPlaces;
  const left = split > 0 ? digits.slice(0, split) : "0";
  const right = `${split < 0 ? "0".repeat(-split) : ""}${digits.slice(Math.max(split, 0))}`.replace(/0+$/, "");
  return scientific === 0 && right === "" ? `${sign}${left}` : `${sign}${left}.${right}${scientific === 0 ? "" : `e${scientific}`}`;
}
function canonicalString(text: string): string {
  let out = "\"";
  for (const character of text) {
    const code = character.codePointAt(0)!;
    if (character === "\"") out += "\\\"";
    else if (character === "\\") out += "\\\\";
    else if (character === "\n") out += "\\n";
    else if (character === "\r") out += "\\r";
    else if (code < 0x20) out += `\\u${code.toString(16).padStart(4, "0")}`;
    else out += character;
  }
  return `${out}"`;
}
export function signatureCanonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(signatureCanonicalJson).join(",")}]`;
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "number") { const spelling = JSON.stringify(value); return spelling === undefined || spelling === "null" ? spelling : canonicalNumber(spelling); }
  if (value !== null && typeof value === "object" && (value as { readonly isLosslessNumber?: unknown }).isLosslessNumber === true) return canonicalNumber((value as { readonly value: string }).value);
  if (value !== null && typeof value === "object") return `{${Object.keys(value).sort(V.codePointOrder).map(k => `${canonicalString(k)}:${signatureCanonicalJson((value as Record<string, unknown>)[k])}`).join(",")}}`;
  return typeof value === "string" ? canonicalString(value) : JSON.stringify(value);
}
export function sameJson(left: unknown, right: unknown): boolean { return signatureCanonicalJson(left) === signatureCanonicalJson(right); }
const digest = (value: unknown): string => V.hashUtf8(signatureCanonicalJson(value));
const ordered = <T extends { readonly id: string }>(items: readonly T[]): readonly T[] => [...items].sort((a, b) => V.codePointOrder(a.id, b.id));
function graphProjection(library: TypeSignatureLibrary): unknown {
  const definitions = ordered(library.definitions).map(d => d.shape.tag === "Operation" ? { ...d, shape: { tag: "Operation", value: { ...d.shape.value, outcomes: d.shape.value.outcomes.map(o => ({ ...o, cause: { tag: o.cause.tag } })) } } } : d);
  return { profile: library.profile, nodes: ordered(library.nodes), definitions };
}
function sourceRef(value: unknown): V.SourceRef {
  const s = object(value, "repository revision path content_digest document_id declared_revision");
  for (const key of ["repository", "revision", "path", "content_digest", "document_id"]) {
    check(typeof s[key] === "string", `source ${key}`);
  }
  check(s.declared_revision === null || typeof s.declared_revision === "string", "source declared revision");
  const source: unknown = s;
  return source as V.SourceRef;
}
export type ProfilePredicate = V.ProfilePredicate;
export type LibraryPredicate = `LB${"01" | "02" | "03" | "04" | "05" | "06" | "07" | "08" | "09" | "10" | "11" | "12" | "13" | "14" | "15" | "16" | "17" | "18" | "19"}`;
export interface ProfileFailure { readonly reference: V.ProfileRef; readonly predicate: ProfilePredicate; readonly location: readonly string[]; }
export interface LibraryFailure { readonly reference: string; readonly predicate: LibraryPredicate; readonly location: readonly string[]; }
export type LibraryCheckFailure = { readonly tag: "Profile"; readonly value: ProfileFailure } | { readonly tag: "Library"; readonly value: LibraryFailure };
export const PredicateFailure = V.DeclarationPredicateFailure;
export type PredicateFailure = V.DeclarationPredicateFailure;
export function checkProfile(profile: V.VersionedSemanticProfile): V.CheckedProfile {
  return V.checkProfileDeclaration(profile);
}

export function decodeProfileWire(value: unknown): V.VersionedSemanticProfile {
  return V.decodeVersionedProfileWire(value);
}

const wireDecimalBound = V.wireRecord([["mantissa", V.wireInt], ["scale", V.wireNat], ["exclusive", V.wireBool]]);
export const wireDecimalSpec = V.wireRecord([["minimum", V.wireOption(wireDecimalBound)], ["maximum", V.wireOption(wireDecimalBound)]]);
export const wireBooleanSpec = V.wireRecord([["const_value", V.wireOption(V.wireBool)], ["default_value", V.wireOption(V.wireBool)]]);
const wireLengthSpec = V.wireRecord([["minimum", V.wireOption(V.wireNat)], ["maximum", V.wireOption(V.wireNat)]]);
const wireSlot = V.wireRecord([["type_id", V.wireString], ["required", V.wireBool], ["nullable", V.wireBool]]);
const wireElementContract = V.wireRecord([["type_id", V.wireString], ["nullable", V.wireBool]]);
const wireField = V.wireRecord([["wire_name", V.wireString], ["slot", wireSlot]]);
const wireExtraMembers = V.wireTagged({ Reject: V.wireUnit(), Allow: V.wireFieldsOf(V.wireRecord([["key_format", V.wireOption(V.wireFormatUse)], ["value", wireElementContract]])) });
const wireProductSpec = V.wireRecord([["fields", V.wireList(wireField)], ["extras", wireExtraMembers]]);
const wireArraySpec = V.wireRecord([["item", wireElementContract], ["min_length", V.wireOption(V.wireNat)], ["max_length", V.wireOption(V.wireNat)]]);
const wireValueKind = V.wireTagged({ Null: V.wireUnit(), Boolean: V.wireUnit(), Number: V.wireUnit(), String: V.wireUnit(), Array: V.wireUnit(), Object: V.wireUnit() });
const wireMemberTest = V.wireTagged({ Absent: V.wireUnit(), Format: V.wirePayload(V.wireString) });
const wireMemberCheck = V.wireRecord([["key", V.wireString], ["test", wireMemberTest]]);
export const wireBranchSelector = V.wireTagged({ InternalTag: V.wireUnit(), MemberShape: V.wirePayload(V.wireElements(wireMemberCheck)), Kind: V.wirePayload(wireValueKind), Otherwise: V.wireUnit() });
const wireUnionBranch = V.wireRecord([["target", V.wireString], ["wire_tag", V.wireString], ["selector", wireBranchSelector]]);
const wireUnionSpec = V.wireRecord([["branches", V.wireList(wireUnionBranch)]]);
const wireSealedRefinement = V.wireRecord([["key", V.wireString], ["leaf", V.wireSealedLeaf]]);
export const wireUnknownKind = V.wireTagged({ Any: V.wireUnit(), OrdinaryObject: V.wireUnit() });
const wireShape: V.WireDecoder = V.wireTagged({
  Unknown: V.wirePayload(wireUnknownKind),
  Unit: V.wireUnit(),
  Boolean: V.wirePayload(wireBooleanSpec),
  Integer: V.wirePayload(V.wireIntegerSpec),
  Decimal: V.wirePayload(wireDecimalSpec),
  String: V.wirePayload(V.wireStringSpec),
  Bytes: V.wirePayload(wireLengthSpec),
  Product: V.wirePayload(wireProductSpec),
  Array: V.wirePayload(wireArraySpec),
  TaggedUnion: V.wirePayload(wireUnionSpec),
  Sealed: V.wireFieldsOf(V.wireRecord([["tag", V.wireString], ["refinements", V.wireList(wireSealedRefinement)]])),
  Never: V.wireUnit(),
  Alias: V.wireFieldsOf(V.wireRecord([["target", V.wireString]])),
  RawBody: V.wireFieldsOf(V.wireRecord([["encoding", V.wireString]])),
  Opaque: V.wireFieldsOf(V.wireRecord([["type_name", V.wireString]])),
});
const wireNode = V.wireRecord([["id", V.wireString], ["shape", wireShape]]);
const wireEffectPoint = V.wireTagged({ HttpRequestResponse: V.wireUnit(), DataOnly: V.wireUnit() });
const wireOutcomeForm = V.wireTagged({ Success: V.wireUnit(), DeclaredFailure: V.wireUnit() });
const wireOutcomeCause = V.wireTagged({ ValueContract: V.wireFieldsOf(V.wireRecord([["origin", V.wireOrigin]])), ExternalCondition: V.wireFieldsOf(V.wireRecord([["specification", V.wireOrigin]])) });
const wirePort = V.wireRecord([["id", V.wireString], ["contract", wireSlot]]);
const wireResourceProduction = V.wireRecord([["id", V.wireString], ["token_type", V.wireString], ["revision", V.wireNat], ["quantity", V.wireNat], ["provenance", V.wireString]]);
const wireOutcomeContract = V.wireRecord([["id", V.wireString], ["form", wireOutcomeForm], ["cause", wireOutcomeCause], ["value_ports", V.wireList(wirePort)], ["produced_resources", V.wireList(wireResourceProduction)]]);
const wireOperationContract = V.wireRecord([["effect", wireEffectPoint], ["inputs", V.wireList(wirePort)], ["outcomes", V.wireList(wireOutcomeContract)]]);
const wireDefinitionShape = V.wireTagged({ Value: V.wirePayload(V.wireString), Symbol: V.wirePayload(V.wireString), Operation: V.wirePayload(wireOperationContract), Message: V.wirePayload(V.wireString) });
const wireDefinition = V.wireRecord([["id", V.wireString], ["wire_identity", V.wireString], ["shape", wireDefinitionShape]]);
const wireAnnotationTarget = V.wireTagged({ Library: V.wireUnit(), Group: V.wirePayload(V.wireString), Definition: V.wirePayload(V.wireString), Type: V.wirePayload(V.wireString), Outcome: V.wireFieldsOf(V.wireRecord([["definition", V.wireString], ["outcome", V.wireString]])) });
export function wireExactJson(value: unknown, path: string): void {
  const tag = V.wireTag(value, path);
  switch (tag) {
    case "Null": V.wireKeys(value, path, ["tag"]); return;
    case "Bool": V.wireKeys(value, path, ["tag", "value"]); V.wireBool(value.value, path); return;
    case "Integer": V.wireKeys(value, path, ["tag", "value"]); V.wireInt(value.value, path); return;
    case "Decimal": {
      V.wireKeys(value, path, ["tag", "text"]);
      V.wireString(value.text, `${path}.text`);
      const text = value.text as string;
      if (text.replace(/^[ \t\n\r]+|[ \t\n\r]+$/g, "") !== text) V.wireSyntax(`${path}.text`, "decimal whitespace");
      if (!V.parsesAsJsonNumber(text)) V.wireSyntax(`${path}.text`, "invalid exact decimal");
      return;
    }
    case "String": V.wireKeys(value, path, ["tag", "value"]); V.wireString(value.value, path); return;
    case "Array": V.wireKeys(value, path, ["tag", "items"]); V.wireElements(wireExactJson)(value.items, path); return;
    case "Object": V.wireKeys(value, path, ["tag", "members"]); V.wireElements(wireExactMember)(value.members, path); return;
    default: throw new V.WireError({ tag: "UnknownTag", path: `${path}.tag`, value: tag });
  }
}
const wireExactMember = V.wireRecord([["key", V.wireString], ["value", wireExactJson, "root"]]);
const wireAnnotation = V.wireRecord([["target", wireAnnotationTarget], ["key", V.wireString], ["value", wireExactJson]]);
const wireProvenanceBinding = V.wireRecord([["target", wireAnnotationTarget], ["origins", V.wireList(V.wireOrigin)]]);
const wireDefinitionGroup = V.wireRecord([["id", V.wireString], ["members", V.wireList(V.wireString)]]);
const wireTypeSignatureLibrary = V.wireRecord([
  ["schema", V.wireString], ["identity", V.wireString], ["revision", V.wireString], ["profile", V.wireVersionedSemanticProfile],
  ["sources", V.wireList(V.wireSourceIdentity)], ["provenance", V.wireList(wireProvenanceBinding)], ["groups", V.wireList(wireDefinitionGroup)],
  ["annotations", V.wireList(wireAnnotation)], ["nodes", V.wireList(wireNode)], ["definitions", V.wireList(wireDefinition)],
]);

export function decodeProfileJson(text: string): V.VersionedSemanticProfile {
  return decodeProfileWire(V.boundedParseLossless(text));
}

export function encodeProfileWire(profile: V.VersionedSemanticProfile): string {
  return signatureCanonicalJson(decodeProfileWire(structuredClone(profile)));
}

export function decodeFormatRuleWire(value: unknown): V.FormatRule {
  V.wireFormatRule(value, "$");
  return V.deepFreeze(structuredClone(value as V.FormatRule));
}

export function encodeFormatRuleWire(value: V.FormatRule): string {
  return signatureCanonicalJson(decodeFormatRuleWire(value));
}

export function decodeShapeWire(value: unknown): ValueTypeShape {
  wireShape(value, "$");
  return V.deepFreeze(structuredClone(value as ValueTypeShape));
}

export function encodeShapeWire(value: ValueTypeShape): string {
  return signatureCanonicalJson(decodeShapeWire(value));
}

export type ValueCondition = V.ValueCondition;
const valueConditionTags = new Set([
  "MissingRequired", "NullNotAllowed", "ConstMismatch", "EnumMismatch", "BelowMinimum",
  "AboveMaximum", "IntegerDomain", "StringLength", "ArrayLength", "BytesLength",
  "InvalidBytes", "InvalidTag", "ReservedForm", "NoBranchSelected", "Uninhabited",
  "InvalidDataModel", "ReferenceCycle",
]);
const valueConditionPayloadTags = new Set([
  "WrongValueKind", "Format", "InvalidWrapper", "KeyFormat", "DuplicateField", "UnexpectedField",
]);

export function decodeValueConditionWire(value: unknown): ValueCondition {
  const condition = value as { readonly tag?: string };
  if (typeof condition?.tag === "string" && valueConditionTags.has(condition.tag)) object(condition, "tag");
  else if (typeof condition?.tag === "string" && valueConditionPayloadTags.has(condition.tag)) object(condition, "tag value");
  else throw new V.SemanticEvidenceError(`UnknownTag:${String(condition?.tag)}`);
  return V.deepFreeze(structuredClone(condition)) as ValueCondition;
}

export function encodeValueConditionWire(value: ValueCondition): string {
  return signatureCanonicalJson(decodeValueConditionWire(value));
}

export interface SignatureValueFailure {
  readonly type_ref: V.TypeRef;
  readonly definition_ref: V.DefinitionRef;
  readonly origin: V.OccurrenceRef;
  readonly value_path: readonly V.PathStep[];
  readonly condition: ValueCondition;
  readonly observed: V.ExactSlot;
  readonly reference_trace: readonly V.TypeRef[];
}
function decodeTypeRefWire(value: unknown): V.TypeRef {
  const ref = object(value, "source definition_name pointer");
  sourceRef(ref.source); identity(ref.definition_name); validateSemanticWire("string[]", ref.pointer);
  const typed: unknown = V.deepFreeze(structuredClone(ref));
  return typed as V.TypeRef;
}
function decodeDefinitionRefWire(value: unknown): V.DefinitionRef {
  const ref = object(value, "source name");
  sourceRef(ref.source); identity(ref.name);
  return V.deepFreeze(structuredClone(ref)) as V.DefinitionRef;
}
function decodeOccurrenceRefWire(value: unknown): V.OccurrenceRef {
  const ref = object(value, "source pointer");
  sourceRef(ref.source); validateSemanticWire("string[]", ref.pointer);
  return V.deepFreeze(structuredClone(ref)) as V.OccurrenceRef;
}
function decodePathStepWire(value: unknown): V.PathStep {
  const step = object(value, "tag value");
  const tag = step.tag;
  if (typeof tag !== "string" || !["Field", "Index", "Variant"].includes(tag)) throw new V.SemanticEvidenceError(`UnknownTag:${String(tag)}`);
  validateSemanticWire("string", step.value);
  if (tag === "Index") validateSemanticWire("natural", step.value);
  const typed: unknown = V.deepFreeze(structuredClone(step));
  return typed as V.PathStep;
}
function decodeExactSlotWire(value: unknown): V.ExactSlot {
  const slot = value as V.ExactSlot;
  if (slot?.tag === "Absent" || slot?.tag === "Null") object(slot, "tag");
  else if (slot?.tag === "Present") { object(slot, "tag value"); validateSemanticWire("ExactJson", slot.value); }
  else throw new V.SemanticEvidenceError(`UnknownTag:${String(typeof value === "object" && value !== null && "tag" in value ? value.tag : undefined)}`);
  return V.deepFreeze(structuredClone(slot));
}
export function decodeDiagnosticWire(value: unknown): SignatureValueFailure {
  const row = object(value, "type_ref definition_ref origin value_path condition observed reference_trace");
  if (!Array.isArray(row.value_path) || !Array.isArray(row.reference_trace)) throw new V.SemanticEvidenceError("diagnostic arrays");
  const decoded: SignatureValueFailure = {
    type_ref: decodeTypeRefWire(row.type_ref),
    definition_ref: decodeDefinitionRefWire(row.definition_ref),
    origin: decodeOccurrenceRefWire(row.origin),
    value_path: row.value_path.map(decodePathStepWire),
    condition: decodeValueConditionWire(row.condition),
    observed: decodeExactSlotWire(row.observed),
    reference_trace: row.reference_trace.map(decodeTypeRefWire),
  };
  return V.deepFreeze(decoded);
}
export function decodeDiagnosticJson(text: string): SignatureValueFailure {
  return decodeDiagnosticWire(V.boundedParseLossless(text));
}
export function encodeDiagnosticWire(value: SignatureValueFailure): string {
  return signatureCanonicalJson(decodeDiagnosticWire(value));
}

const wireGenerationBasis = V.wireRecord([
  ["signature_schema", V.wireString], ["library_identity", V.wireString], ["library_revision", V.wireString], ["profile", V.wireProfileRef],
  ["graph_sha256", V.wireString], ["provenance_sha256", V.wireString], ["metadata_sha256", V.wireString],
  ["problem_sha256", V.wireOption(V.wireString)], ["observations_sha256", V.wireOption(V.wireString)], ["entrypoints_sha256", V.wireString],
]);
const GOAL_OBSERVATION_KEYS = ["outputs", "failures", "final_resources", "effects", "residuals", "execution_failures", "provenance"];
const EXECUTION_FAILURES = ["argumentCoverage", "invalidOutcome", "invalidPlan", "missingArgument", "missingProvider", "missingValue", "network", "networkTerminal", "provider", "providerCoverage", "providerEffect", "resource", "value"];
function wireGoalObservations(value: unknown, path: string): void { V.wireKeys(value, path, GOAL_OBSERVATION_KEYS); }
function member(value: unknown, key: string): unknown {
  return value !== null && typeof value === "object" && !Array.isArray(value) && Object.hasOwn(value, key) ? (value as Record<string, unknown>)[key]! : null;
}
function goalRows(value: unknown, keys: readonly string[]): unknown[] {
  return Array.isArray(value) ? value.map(item => Object.fromEntries(keys.map(key => [key, member(item, key)]))) : [];
}
export function goalObservations(composition: unknown): GoalObservations {
  const goal = member(member(composition, "problem"), "goal");
  return V.deepFreeze(structuredClone({
    outputs: goalRows(member(goal, "outputs"), ["id", "contract"]),
    failures: goalRows(member(goal, "failures"), ["id", "contract", "final_resources"]),
    final_resources: member(goal, "final_resources"),
    effects: ["network_instruction", "pending"],
    residuals: "residual_set",
    execution_failures: EXECUTION_FAILURES,
    provenance: "certificate_basis",
  }));
}
function planReturns(tree: unknown): unknown[] {
  const node = member(tree, "node");
  const tag = member(node, "tag");
  if (tag === "Return") return [member(node, "value")];
  if (tag !== "Invoke" && tag !== "Guard") return [];
  const arms = member(member(node, "fields"), "arms");
  return Array.isArray(arms) ? arms.flatMap(arm => Array.isArray(arm) && arm.length === 2 ? planReturns(arm[1]) : []) : [];
}
function rowId(item: unknown): string | null {
  const id = member(item, "id");
  return typeof id === "string" ? id : null;
}
function keptRows(value: unknown, keys: readonly string[], kept: (id: string) => boolean, extra: readonly string[]): unknown[] {
  const declared = Array.isArray(value) ? value.filter(item => kept(rowId(item) ?? "")) : [];
  return [...goalRows(declared, keys), ...extra.map(id => Object.fromEntries(keys.map(key => [key, key === "id" ? id : null])))];
}
/** 合成の導出の Return 節点が出力する値と失敗の埋め込みから作る観測関数族。Return 節点の集まりが goal の宣言と一致する時に、goal から作る観測関数族と等しい。 */
export function planObservations(composition: unknown): GoalObservations {
  const goal = member(member(composition, "problem"), "goal");
  const returns = planReturns(member(member(member(composition, "derivation"), "plan"), "root"));
  const successes = returns.filter(value => member(value, "tag") === "Success").map(value => {
    const pairs = member(value, "value");
    return Array.isArray(pairs) ? pairs.flatMap(pair => Array.isArray(pair) && typeof pair[0] === "string" ? [pair[0] as string] : []) : [];
  });
  const embeddings = returns.filter(value => member(value, "tag") !== "Success").flatMap(value => {
    const embedding = member(member(value, "fields"), "embedding");
    return typeof embedding === "string" ? [embedding] : [];
  });
  const outputs = member(goal, "outputs"), failures = member(goal, "failures");
  const ids = (rows: unknown) => Array.isArray(rows) ? rows.flatMap(item => { const id = rowId(item); return id === null ? [] : [id]; }) : [];
  const outputIds = ids(outputs), failureIds = ids(failures);
  return V.deepFreeze(structuredClone({
    outputs: keptRows(outputs, ["id", "contract"], id => successes.length > 0 && successes.every(ports => ports.includes(id)),
      [...new Set(successes.flat().filter(port => !outputIds.includes(port)))]),
    failures: keptRows(failures, ["id", "contract", "final_resources"], id => embeddings.includes(id),
      [...new Set(embeddings.filter(embedding => !failureIds.includes(embedding)))]),
    final_resources: member(goal, "final_resources"),
    effects: ["network_instruction", "pending"],
    residuals: "residual_set",
    execution_failures: EXECUTION_FAILURES,
    provenance: "certificate_basis",
  }));
}
export function expectedSignatureBasis(input: Pick<SignatureGenerationInput, "basis" | "composition">): ExpectedSignatureBasis {
  return V.deepFreeze({ basis: structuredClone(input.basis), observations: input.composition === null ? null : goalObservations(input.composition) });
}
function wireExpectedBasis(value: unknown, path: string): void {
  V.wireKeys(value, path, ["basis", "observations"]);
  wireGenerationBasis(value.basis, `${path}.basis`);
  V.wireOption(wireGoalObservations)(value.observations, `${path}.observations`);
}
export function decodeExpectedBasisWire(value: unknown): ExpectedSignatureBasis {
  wireExpectedBasis(value, "$");
  return V.deepFreeze(structuredClone(value as ExpectedSignatureBasis));
}
export function decodeExpectedBasisJson(text: string): ExpectedSignatureBasis {
  return decodeExpectedBasisWire(V.boundedParseLossless(text));
}
export function encodeExpectedBasisWire(value: ExpectedSignatureBasis): string {
  return signatureCanonicalJson(decodeExpectedBasisWire(value));
}
export function decodeGenerationBasisWire(value: unknown): SignatureGenerationBasis {
  wireGenerationBasis(value, "$");
  return V.deepFreeze(structuredClone(value as SignatureGenerationBasis));
}
export function decodeGenerationBasisJson(text: string): SignatureGenerationBasis {
  return decodeGenerationBasisWire(V.boundedParseLossless(text));
}
export function encodeGenerationBasisWire(value: SignatureGenerationBasis): string {
  return signatureCanonicalJson(decodeGenerationBasisWire(value));
}

function sourceRefWire(value: V.SourceRef): unknown {
  return { repository: value.repository, revision: value.revision, path: value.path, content_digest: value.content_digest, document_id: value.document_id, declared_revision: value.declared_revision ?? null };
}
function profileRefWire(value: V.ProfileRef): unknown {
  return { identity: value.identity, revision: value.revision, content_digest: value.content_digest };
}
function typeRefWireValue(value: V.TypeRef): unknown {
  return { source: sourceRefWire(value.source), definition_name: value.definition_name, pointer: [...value.pointer] };
}
function occurrenceRefWire(value: V.OccurrenceRef): unknown {
  return { source: sourceRefWire(value.source), pointer: [...value.pointer] };
}
function pathStepWire(value: V.PathStep): unknown {
  return { tag: value.tag, value: value.value };
}
function semanticReasonWire(value: V.SemanticReason): unknown {
  return "value" in value ? { tag: value.tag, value: value.value } : { tag: value.tag };
}
function semanticObligationWire(value: V.SemanticObligation): unknown {
  return {
    type_ref: typeRefWireValue(value.type_ref),
    origin: occurrenceRefWire(value.origin),
    value_path: value.value_path.map(pathStepWire),
    profile: profileRefWire(value.profile),
    reason: semanticReasonWire(value.reason),
  };
}
function exactJsonWire(value: V.ExactJson): unknown {
  switch (value.tag) {
    case "Null": return { tag: "Null" };
    case "Bool": return { tag: "Bool", value: value.value };
    case "Integer": return { tag: "Integer", value: value.value };
    case "Decimal": return { tag: "Decimal", text: value.text };
    case "String": return { tag: "String", value: value.value };
    case "Array": return { tag: "Array", items: value.items.map(exactJsonWire) };
    case "Object": return { tag: "Object", members: value.members.map(member => ({ key: member.key, value: exactJsonWire(member.value) })) };
  }
}
export function encodeTypeRefWire(value: V.TypeRef): string {
  return signatureCanonicalJson(typeRefWireValue(value));
}
export function encodeExactJsonWire(value: V.ExactJson): string {
  return signatureCanonicalJson(exactJsonWire(value));
}
export function encodeSemanticObligationsWire(values: readonly V.SemanticObligation[]): string {
  return signatureCanonicalJson(values.map(semanticObligationWire));
}

function sha256Hex(text: string): boolean { return /^[0-9a-f]{64}$/.test(text); }
function semanticProfile(profile: ValueSemanticProfile): V.VersionedSemanticProfile {
  const rules = profile.grapheme_rules;
  return { ...profile, grapheme_rules: rules === null ? null : { ...rules, sources: rules.sources.map(item => ({ role: item.role, source: item.origin.source })) } } as V.VersionedSemanticProfile;
}
function libraryFormatRuleValid(profile: ValueSemanticProfile, use: V.FormatUse): boolean {
  const rule = use.tag === "Inline" ? use.value : profile.format_bindings.find(binding => binding.name === use.value)?.rule;
  return rule !== undefined && V.formatRuleWellFormed(rule);
}
function originResolved(library: TypeSignatureLibrary, origin: Origin): boolean { return library.sources.some(source => V.same(source, origin.source)); }
export function outcomeValid(library: TypeSignatureLibrary, outcome: SignatureOutcome): boolean {
  if (!V.profileNamesUnique(outcome.value_ports.map(port => port.id))) return false;
  if (!V.profileNamesUnique(outcome.produced_resources.map(resource => resource.id))) return false;
  if (outcome.cause.tag === "ValueContract") return originResolved(library, outcome.cause.fields.origin);
  return originResolved(library, outcome.cause.fields.specification) && outcome.value_ports.length > 0 && outcome.form.tag === "DeclaredFailure";
}
function operationValid(library: TypeSignatureLibrary, operation: OperationContract): boolean {
  return V.profileNamesUnique(operation.inputs.map(port => port.id)) && V.profileNamesUnique(operation.outcomes.map(outcome => outcome.id)) && operation.outcomes.length > 0 && operation.outcomes.every(outcome => outcomeValid(library, outcome));
}
function targetValid(library: TypeSignatureLibrary, target: AnnotationTarget): boolean {
  if (target.tag === "Library") return true;
  if (target.tag === "Outcome") return library.definitions.some(definition => definition.id === target.fields.definition && definition.shape.tag === "Operation" && definition.shape.value.outcomes.some(outcome => outcome.id === target.fields.outcome));
  if (target.tag === "Group") return library.groups.some(group => group.id === target.value);
  if (target.tag === "Definition") return library.definitions.some(definition => definition.id === target.value);
  return library.nodes.some(node => node.id === target.value);
}
export function referenceIds(shape: ValueTypeShape): readonly string[] { return shape.tag === "Product" ? [...shape.value.fields.map(field => field.slot.type_id), ...(shape.value.extras.tag === "Allow" ? [shape.value.extras.fields.value.type_id] : [])] : shape.tag === "Array" ? [shape.value.item.type_id] : shape.tag === "Alias" ? [shape.fields.target] : shape.tag === "TaggedUnion" ? shape.value.branches.map(branch => branch.target) : []; }
function libraryDeclarationValid(library: TypeSignatureLibrary): boolean {
  const nodeIds = new Set(library.nodes.map(node => node.id)), definitionIds = new Set(library.definitions.map(definition => definition.id));
  return library.schema === "ncoh-type-signatures@1" && library.identity !== "" && library.revision !== "" && sha256Hex(library.profile.reference.content_digest)
    && library.sources.every(source => sha256Hex(source.content_digest)) && new Set(library.sources.map(source => signatureCanonicalJson(source))).size === library.sources.length
    && V.profileNamesUnique(library.nodes.map(node => node.id)) && V.profileNamesUnique(library.definitions.map(definition => definition.id)) && V.profileNamesUnique(library.groups.map(group => group.id))
    && library.nodes.every(node => referenceIds(node.shape).every(id => nodeIds.has(id)))
    && library.definitions.every(definition => definitionReferences(definition.shape).every(id => nodeIds.has(id)) && (definition.shape.tag !== "Operation" || operationValid(library, definition.shape.value)))
    && library.groups.every(group => group.members.every(id => definitionIds.has(id)))
    && library.provenance.every(binding => targetValid(library, binding.target) && binding.origins.every(origin => originResolved(library, origin)))
    && library.annotations.every(annotation => targetValid(library, annotation.target));
}
function slot(value: SignatureSlot, refs: ReadonlyMap<string, V.TypeRef>): V.SlotContract { identity(value.type_id); const ref = refs.get(value.type_id); check(ref, "unresolved TypeId"); return { type_ref: ref, required: value.required, nullable: value.nullable }; }
function convertShape(shape: ValueTypeShape, refs: ReadonlyMap<string, V.TypeRef>, occurrence: V.OccurrenceRef): V.TypeShape {
  const ref = (id: string): V.TypeRef => { const found = refs.get(id); check(found, "resolved TypeId"); return found; };
  if (shape.tag === "Product") return { tag: "Product", value: { fields: shape.value.fields.map(field => ({ wire_name: field.wire_name, slot: slot(field.slot, refs), origin: occurrence })), extras: shape.value.extras.tag === "Reject" ? { tag: "Reject" } : { tag: "Allow", fields: { key_format: shape.value.extras.fields.key_format, value: { type_ref: ref(shape.value.extras.fields.value.type_id), nullable: shape.value.extras.fields.value.nullable } } } } };
  if (shape.tag === "Array") return { tag: "Array", value: { item: { type_ref: ref(shape.value.item.type_id), nullable: shape.value.item.nullable }, min_length: shape.value.min_length, max_length: shape.value.max_length } };
  if (shape.tag === "TaggedUnion") return { tag: "TaggedUnion", value: { branches: shape.value.branches.map(branch => ({ ...branch, target: ref(branch.target), origin: occurrence })) } };
  if (shape.tag === "Alias") return { tag: "Alias", fields: { target: ref(shape.fields.target), reference_text: "" } };
  return shape as V.TypeShape;
}
export function checkOperationSignature(base: OperationContract, signature: OperationContract, library: TypeSignatureLibrary): void {
  check(V.same(base.effect, signature.effect) && V.same(base.inputs, signature.inputs), "operation input/effect contracts"); unique(signature.outcomes.map(o => o.id));
  for (const expected of base.outcomes) check(signature.outcomes.some(o => V.same(o, expected)), "basic outcome deleted or replaced");
  for (const o of signature.outcomes) if (!base.outcomes.some(b => b.id === o.id)) check(o.cause.tag === "ExternalCondition" && outcomeValid(library, o), "external outcome supplement");
}
const checkedLibraryAuthority = new WeakSet<CheckedSignatureLibrary>();
const signatureLibraryAdmissionToken = Symbol("signature library admission");
export class CheckedSignatureLibrary {
  private constructor(token: symbol, readonly library: TypeSignatureLibrary, readonly context: V.ValueContext, readonly refs: ReadonlyMap<TypeId, V.TypeRef>) { check(token === signatureLibraryAdmissionToken, "signature library admission authority"); checkedLibraryAuthority.add(this); Object.freeze(this); }
  static admit(token: symbol, library: TypeSignatureLibrary, context: V.ValueContext, refs: ReadonlyMap<TypeId, V.TypeRef>): CheckedSignatureLibrary {
    return new CheckedSignatureLibrary(token, library, context, refs);
  }
}
function definitionReferences(shape: SignatureDefinition["shape"]): readonly TypeId[] {
  if (shape.tag === "Value" || shape.tag === "Message") return [shape.value];
  if (shape.tag === "Operation") return [
    ...shape.value.inputs.map(port => port.contract.type_id),
    ...shape.value.outcomes.flatMap(outcome => [
      ...outcome.value_ports.map(port => port.contract.type_id),
      ...outcome.produced_resources.map(resource => resource.token_type),
    ]),
  ];
  return [];
}
function checkLibraryPredicate(library: TypeSignatureLibrary): void {
  const fail = (predicate: LibraryPredicate): never => { throw new PredicateFailure(library.identity, predicate, ["library"]); };
  const profile = new V.ValueContext({ profile: semanticProfile(library.profile), nodes: [] }).prepared;
  const tag = library.profile.tag;
  if (!libraryDeclarationValid(library)) fail("LB01");
  if (library.nodes.some(node => node.shape.tag === "Product" && !V.profileNamesUnique(node.shape.value.fields.map(field => field.wire_name)))) fail("LB02");
  if (library.nodes.some(node => node.shape.tag === "Product" && node.shape.value.fields.some(field => library.profile.wrappers.some(wrapper => wrapper.key === field.wire_name)))) fail("LB03");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && new Set(node.shape.value.branches.map(branch => branch.wire_tag)).size !== node.shape.value.branches.length)) fail("LB04");
  if (library.nodes.some(({ shape }) => shape.tag === "TaggedUnion" && shape.value.branches.some((branch, index) => branch.selector.tag === "Otherwise" && index + 1 !== shape.value.branches.length))) fail("LB05");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => !branch.wire_tag || branch.selector.tag === "MemberShape" && branch.selector.value.some(check => !check.key)))) fail("LB06");
  if (tag !== null && library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => branch.selector.tag === "InternalTag" && tag.format !== null && !V.recognizeFormat(library.profile.format_bindings.find(binding => binding.name === tag.format)!.rule, branch.wire_tag, profile.grapheme_rules)))) fail("LB07");
  if (tag !== null && library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => branch.selector.tag === "InternalTag" && tag.sealed.some(form => form.tag === branch.wire_tag) !== library.nodes.some(target => target.id === branch.target && target.shape.tag === "Sealed" && target.shape.fields.tag === branch.wire_tag)))) fail("LB08");
  if (library.nodes.some(({ shape }) => shape.tag === "TaggedUnion" && shape.value.branches.some(branch => branch.selector.tag === "MemberShape" && (!V.profileNamesUnique(branch.selector.value.map(check => check.key)) || branch.selector.value.some(check => { const test = check.test; return test.tag === "Format" && !library.profile.format_bindings.some(binding => binding.name === test.value); }))))) fail("LB09");
  if (library.nodes.some(({ shape }) => shape.tag === "Sealed" && (() => {
    const sealedTag = shape.fields.tag;
    const form = tag?.sealed.find(candidate => candidate.tag === sealedTag);
    return !form || !V.profileNamesUnique(shape.fields.refinements.map(refinement => refinement.key))
      || shape.fields.refinements.some(refinement => !form.fields.some(field => field.key === refinement.key && field.leaf.tag === refinement.leaf.tag));
  })())) fail("LB10");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => branch.selector.tag === "InternalTag" && !library.nodes.some(target => target.id === branch.target && (target.shape.tag === "Product" || target.shape.tag === "Sealed"))))) fail("LB11");
  if (library.nodes.some(({ shape }) => {
    if (shape.tag !== "Product" || shape.value.extras.tag !== "Allow") return false;
    const keyFormat = shape.value.extras.fields.key_format;
    return keyFormat?.tag === "Named" && !library.profile.format_bindings.some(binding => binding.name === keyFormat.value);
  })) fail("LB12");
  if (library.nodes.some(({ shape }) => shape.tag === "String" && (shape.value.wrapper !== null && !library.profile.wrappers.some(wrapper => wrapper.name === shape.value.wrapper && wrapper.payload.tag === "Text") || shape.value.format !== null && !libraryFormatRuleValid(library.profile, shape.value.format) || shape.value.lengths.some(bound => bound.minimum !== null && bound.maximum !== null && BigInt(bound.minimum) > BigInt(bound.maximum))))) fail("LB13");
  if (library.nodes.some(({ shape }) => shape.tag === "Integer" && (shape.value.minimum !== null && shape.value.maximum !== null && BigInt(shape.value.minimum) > BigInt(shape.value.maximum) || shape.value.domain !== null && !library.profile.integer_domains.some(domain => domain.name === shape.value.domain)))) fail("LB14");
  if (library.nodes.some(node => node.shape.tag === "Decimal" && node.shape.value.minimum !== null && node.shape.value.maximum !== null && (node.shape.value.minimum.scale !== node.shape.value.maximum.scale || BigInt(node.shape.value.maximum.mantissa) < BigInt(node.shape.value.minimum.mantissa)))) fail("LB15");
  if (library.nodes.some(node => node.shape.tag === "Array" && node.shape.value.min_length !== null && node.shape.value.max_length !== null && BigInt(node.shape.value.min_length) > BigInt(node.shape.value.max_length) || node.shape.tag === "Bytes" && node.shape.value.minimum !== null && node.shape.value.maximum !== null && BigInt(node.shape.value.minimum) > BigInt(node.shape.value.maximum))) fail("LB16");
  if (tag !== null && library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => branch.selector.tag === "InternalTag" && library.nodes.some(target => {
    if (target.id !== branch.target || target.shape.tag !== "Product") return false;
    const tagField = target.shape.value.fields.find(field => field.wire_name === tag.key);
    if (!tagField) return true;
    const tagNode = library.nodes.find(candidate => candidate.id === tagField.slot.type_id);
    if (!tagNode || tagNode.shape.tag !== "String") return true;
    return V.stringCondition(profile, tagNode.shape.value, branch.wire_tag) !== null;
  })))) fail("LB17");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && new Set(node.shape.value.branches.map(branch => signatureCanonicalJson(branch.selector.tag === "InternalTag" ? [branch.selector, branch.wire_tag] : branch.selector))).size !== node.shape.value.branches.length)) fail("LB18");
  if (library.nodes.some(node => {
    if (node.shape.tag === "String") {
      const spec = node.shape.value;
      return [...(spec.const_value === null ? [] : [spec.const_value]), ...(spec.enum_values ?? []), ...(spec.default_value === null ? [] : [spec.default_value])].some(value => V.stringCondition(profile, spec, value) !== null);
    }
    if (node.shape.tag === "Integer") {
      const spec = node.shape.value;
      return [...(spec.const_value === null ? [] : [spec.const_value]), ...(spec.enum_values ?? []), ...(spec.default_value === null ? [] : [spec.default_value])].some(value => V.integerCondition(profile, spec, { tag: "Integer", value }) !== null);
    }
    return false;
  })) fail("LB19");
}

const signatureSource: V.SourceRef = { repository: "ncoh-type-signatures", revision: "1", path: "", content_digest: "", document_id: "", declared_revision: null };
export function signatureTypeRef(id: TypeId): V.TypeRef { return { source: signatureSource, definition_name: id, pointer: [] }; }
export function decodeTypeSignatureLibraryWireFields(value: unknown): TypeSignatureLibrary {
  wireTypeSignatureLibrary(value, "$");
  return structuredClone(value as TypeSignatureLibrary);
}
export function checkLibrary(value: TypeSignatureLibrary): CheckedSignatureLibrary {
  const library = decodeTypeSignatureLibraryWireFields(value);
  const profile = checkProfile(semanticProfile(library.profile)).profile;
  checkLibraryPredicate(library);
  const refs = new Map(library.nodes.map(node => [node.id, signatureTypeRef(node.id)]));
  const nodes = library.nodes.map(node => ({ reference: refs.get(node.id)!, shape: convertShape(node.shape, refs, { source: signatureSource, pointer: [] }), description: null, attributes: [], extensions: [] }));
  const context = new V.ValueContext(V.deepFreeze({ profile, nodes }));
  return CheckedSignatureLibrary.admit(signatureLibraryAdmissionToken, V.deepFreeze(library), context, refs);
}
export function libraryCheckFailure(library: TypeSignatureLibrary): LibraryCheckFailure | null {
  try { checkLibrary(library); return null; }
  catch (error) {
    if (!(error instanceof PredicateFailure)) throw error;
    if (error.predicate.startsWith("PR")) return { tag: "Profile", value: { reference: error.reference as V.ProfileRef, predicate: error.predicate as ProfilePredicate, location: error.location } };
    return { tag: "Library", value: { reference: library.identity, predicate: error.predicate as LibraryPredicate, location: error.location } };
  }
}
export function requireCheckedLibrary(checked: CheckedSignatureLibrary): void {
  check(checkedLibraryAuthority.has(checked), "checked library authority");
}
export function decodeLibraryWire(value: unknown): TypeSignatureLibrary {
  return checkLibrary(structuredClone(value) as TypeSignatureLibrary).library;
}
export function decodeLibraryJson(text: string): TypeSignatureLibrary {
  return decodeLibraryWire(V.boundedParseLossless(text));
}
export function encodeLibraryWire(value: TypeSignatureLibrary): string {
  return signatureCanonicalJson(decodeLibraryWire(value));
}
export function signatureBasis(library: TypeSignatureLibrary, entrypoints: SignatureGenerationInput["entrypoints"], composition: unknown | null = null): SignatureGenerationBasis {
  checkLibrary(library);
  const { metadata, evidence } = generationComponents(library, entrypoints, composition);
  return { signature_schema: metadata.signature_schema, library_identity: metadata.library_identity, library_revision: metadata.library_revision, profile: metadata.profile, graph_sha256: digest(evidence.graph), provenance_sha256: digest(evidence.provenance), metadata_sha256: digest(evidence.metadata), problem_sha256: evidence.composition === null ? null : digest(evidence.composition), observations_sha256: evidence.composition === null ? null : digest(goalObservations(evidence.composition)), entrypoints_sha256: digest(evidence.entrypoints) };
}
interface GenerationLibraryMetadata { readonly signature_schema: TypeSignatureLibrary["schema"]; readonly library_identity: string; readonly library_revision: string; readonly profile: V.ProfileRef }
interface GenerationEvidence { readonly graph: unknown; readonly provenance: unknown; readonly metadata: unknown; readonly entrypoints: unknown; readonly composition: unknown | null }
function generationComponents(library: TypeSignatureLibrary, entrypoints: SignatureGenerationInput["entrypoints"], composition: unknown | null): { readonly metadata: GenerationLibraryMetadata; readonly evidence: GenerationEvidence } {
  const outcome_origins = ordered(library.definitions).flatMap(d => d.shape.tag === "Operation" ? ordered(d.shape.value.outcomes).map(o => ({ definition: d.id, outcome: o.id, cause: o.cause })) : []);
  const sortCanonical = <T>(values: readonly T[]): T[] => [...values].sort((a, b) => V.codePointOrder(signatureCanonicalJson(a), signatureCanonicalJson(b)));
  const sources = [...library.sources].sort((a, b) => { for (const k of ["repository", "revision", "path", "content_digest"] as const) { const result = V.codePointOrder(a[k], b[k]); if (result) return result; } return 0; });
  const provenance = [...library.provenance].sort((a, b) => V.codePointOrder(signatureCanonicalJson(a.target), signatureCanonicalJson(b.target))).map(b => ({ ...b, origins: sortCanonical(b.origins) }));
  const annotations = [...library.annotations].sort((a, b) => { const left = [signatureCanonicalJson(a.target), a.key, signatureCanonicalJson(a.value)], right = [signatureCanonicalJson(b.target), b.key, signatureCanonicalJson(b.value)]; for (let i = 0; i < left.length; i++) { const result = V.codePointOrder(left[i]!, right[i]!); if (result) return result; } return 0; });
  return {
    metadata: { signature_schema: library.schema, library_identity: library.identity, library_revision: library.revision, profile: library.profile.reference },
    evidence: { graph: graphProjection(library), provenance: { sources, provenance, outcome_origins }, metadata: { groups: ordered(library.groups).map(g => ({ ...g, members: [...g.members].sort(V.codePointOrder) })), annotations }, entrypoints: [...entrypoints].sort((a, b) => V.codePointOrder(a.identity, b.identity)), composition },
  };
}
const authority = new WeakSet<CheckedSignatureGeneration>();
const signatureAdmissionToken = Symbol("signature generation admission");
const GENERATION_RULE = "ncoh-checked-generation@5";
const CERTIFICATE_PROVENANCE = "admit_signature_generation";
export type InputDecodeFailure = { readonly tag: "Json"; readonly value: V.WireFailure } | { readonly tag: "Wire"; readonly value: V.WireFailure };
export type AdmissionFailure =
  | { readonly tag: "EntrypointsEmpty" }
  | { readonly tag: "EntrypointIdentityEmpty" }
  | { readonly tag: "EntrypointDuplicate"; readonly value: { readonly identity: string } }
  | { readonly tag: "EntrypointUnresolved"; readonly value: { readonly identity: string; readonly definition: string } }
  | { readonly tag: "Library"; readonly value: PredicateFailure }
  | { readonly tag: "Certificate"; readonly value: Mismatch<string> }
  | { readonly tag: "CompositionInput"; readonly value: C.CompositionInputFailure }
  | { readonly tag: "Decode"; readonly value: InputDecodeFailure }
  | { readonly tag: "Wire"; readonly value: V.WireFailure };
export class GenerationWireError extends Error { constructor(readonly failure: AdmissionFailure) { super(failure.tag === "Certificate" ? failure.value.toString() : failure.tag); } }
const scopedDigest = (value: string): ProjectionDigest => ({ digest: value, scope: { kind: "cross_language", encoding: "sha256" } });
const generationRule = (_source: unknown, _coordinate: unknown, _observations: unknown, evidence: GenerationEvidence): ProjectionDigestsInput => ({
  entrypoints: scopedDigest(digest(evidence.entrypoints)),
  graph: scopedDigest(digest(evidence.graph)),
  metadata: scopedDigest(digest(evidence.metadata)),
  ...(evidence.composition === null ? {} : { problem: scopedDigest(digest(evidence.composition)) }),
  ...(evidence.composition === null ? {} : { observations: scopedDigest(digest(goalObservations(evidence.composition))) }),
  provenance: scopedDigest(digest(evidence.provenance)),
});
const generationTableResult = RuleTable.create([[GENERATION_RULE, generationRule]]);
check(generationTableResult.ok, "generation rule table");
const generationTable = generationTableResult.value;
const generationComparison = {
  sameSource: (left: string, right: string) => left === right,
  sameRevision: (left: string, right: string) => left === right,
  sameCoordinate: (left: unknown, right: unknown) => V.same(left, right),
  sameObservations: (left: GoalObservations | null, right: GoalObservations | null) => left === null || right === null ? left === right : signatureCanonicalJson(left) === signatureCanonicalJson(right),
  sameResidual: () => true,
  identityText: (identity: string) => identity,
  revisionText: (revision: string) => revision,
};
function generationCoordinate(basis: SignatureGenerationBasis, actual: GenerationLibraryMetadata) {
  return { signature_schema: basis.signature_schema, profile: basis.profile, graph_sha256: basis.graph_sha256, provenance_sha256: basis.provenance_sha256, metadata_sha256: basis.metadata_sha256, problem_sha256: basis.problem_sha256, observations_sha256: basis.observations_sha256, entrypoints_sha256: basis.entrypoints_sha256, actual_library: actual };
}
function declaredLibraryMetadata(basis: SignatureGenerationBasis): GenerationLibraryMetadata {
  return { signature_schema: basis.signature_schema, library_identity: basis.library_identity, library_revision: basis.library_revision, profile: basis.profile };
}
function certifiedDigests(basis: SignatureGenerationBasis) {
  return projectionDigests({ entrypoints: scopedDigest(basis.entrypoints_sha256), graph: scopedDigest(basis.graph_sha256), metadata: scopedDigest(basis.metadata_sha256), ...(basis.problem_sha256 === null ? {} : { problem: scopedDigest(basis.problem_sha256) }), ...(basis.observations_sha256 === null ? {} : { observations: scopedDigest(basis.observations_sha256) }), provenance: scopedDigest(basis.provenance_sha256) });
}
export type GenerationAdmission = Checked<string, string, ReturnType<typeof generationCoordinate>, GoalObservations | null, never, GenerationEvidence>;
function admitGenerationCertificate(expected: ExpectedSignatureBasis, input: SignatureGenerationInput, actual: GenerationLibraryMetadata, evidence: GenerationEvidence, planDecoded: boolean): GenerationAdmission {
  const certificate = { ruleRevision: input.schema, source: { identity: input.basis.library_identity, revision: input.basis.library_revision }, coordinate: generationCoordinate(input.basis, actual), digests: certifiedDigests(input.basis), residuals: residualSet([]), observations: evidence.composition === null ? null : planDecoded ? planObservations(evidence.composition) : goalObservations(evidence.composition), evidence };
  const expectation = { ruleRevision: GENERATION_RULE, source: { identity: expected.basis.library_identity, revision: expected.basis.library_revision }, coordinate: generationCoordinate(expected.basis, declaredLibraryMetadata(input.basis)), observations: expected.observations, residuals: residualSet([]) };
  const result = admit(generationTable, certificate, expectation, CERTIFICATE_PROVENANCE, generationComparison);
  if (!result.ok) throw new GenerationWireError({ tag: "Certificate", value: result.error });
  return result.value;
}
export class CheckedSignatureGeneration {
  private constructor(token: symbol, readonly input: SignatureGenerationInput, readonly signatures: CheckedSignatureLibrary, readonly composition: E.AdmittedComposition | null, readonly admission: GenerationAdmission) { check(token === signatureAdmissionToken, "signature admission authority"); authority.add(this); Object.freeze(this); }
  static admit(expected: ExpectedSignatureBasis, input: SignatureGenerationInput): CheckedSignatureGeneration {
    if (input.entrypoints.length === 0 && input.composition === null) throw new GenerationWireError({ tag: "EntrypointsEmpty" });
    if (input.entrypoints.some(entry => entry.identity === "")) throw new GenerationWireError({ tag: "EntrypointIdentityEmpty" });
    const identities = new Set<string>();
    for (const entry of input.entrypoints) {
      if (identities.has(entry.identity)) throw new GenerationWireError({ tag: "EntrypointDuplicate", value: { identity: entry.identity } });
      identities.add(entry.identity);
    }
    for (const entry of input.entrypoints) {
      if (!input.signatures.definitions.some(candidate => candidate.id === entry.definition)) throw new GenerationWireError({ tag: "EntrypointUnresolved", value: { identity: entry.identity, definition: entry.definition } });
    }
    const checked = checkLibrary(input.signatures);
    const { metadata, evidence } = generationComponents(checked.library, input.entrypoints, input.composition);
    const admitted = input.composition === null ? null : admitSignatureComposition(checked, input.composition);
    const admission = admitGenerationCertificate(expected, input, metadata, evidence, admitted?.tag === "Admitted");
    let composition: E.AdmittedComposition | null = null;
    if (admitted !== null) {
      if (admitted.tag === "Failed") throw new GenerationWireError(admitted.failure);
      composition = admitted.value;
    }
    return new CheckedSignatureGeneration(signatureAdmissionToken, V.deepFreeze(structuredClone(input)), checked, composition, admission);
  }
  codec<T extends V.ExactJson = V.ExactJson>(typeId: TypeId): SignatureCodec<T> { check(authority.has(this), "checked generation authority"); return new SignatureCodec<T>(this.signatures, typeId); }
}
const wireEntrypoint = V.wireRecord([["identity", V.wireString], ["definition", V.wireString]]);
function wireGenerationInput(value: unknown, path: string): void {
  V.wireKeys(value, path, ["schema", "basis", "signatures", "composition", "entrypoints"]);
  V.wireString(value.schema, `${path}.schema`);
  if (value.schema !== GENERATION_RULE) throw new V.WireError({ tag: "UnsupportedSchema", path: `${path}.schema`, value: value.schema as string });
  wireGenerationBasis(value.basis, `${path}.basis`);
  wireTypeSignatureLibrary(value.signatures, `${path}.signatures`);
  V.wireList(wireEntrypoint)(value.entrypoints, `${path}.entrypoints`);
}
export function decodeGenerationInput(text: string): { readonly tag: "Ok"; readonly value: SignatureGenerationInput } | { readonly tag: "Failed"; readonly failure: InputDecodeFailure } {
  const syntax = V.admissionFailure(text);
  if (syntax !== null) return { tag: "Failed", failure: { tag: "Json", value: { tag: "Syntax", path: "$", value: syntax } } };
  let json: unknown;
  try { json = V.parseLossless(text); }
  catch (error) {
    if (!(error instanceof V.SemanticEvidenceError)) throw error;
    return { tag: "Failed", failure: { tag: "Json", value: { tag: "Syntax", path: error.path, value: error.condition } } };
  }
  try { wireGenerationInput(json, "$"); }
  catch (error) {
    if (!(error instanceof V.WireError)) throw error;
    return { tag: "Failed", failure: { tag: "Wire", value: error.failure } };
  }
  return { tag: "Ok", value: json as SignatureGenerationInput };
}
export function admitSignatureGeneration(expected: ExpectedSignatureBasis, exchangeJson: string): { readonly tag: "Admitted"; readonly checked: CheckedSignatureGeneration } | { readonly tag: "Failed"; readonly failure: AdmissionFailure } {
  const decoded = decodeGenerationInput(exchangeJson);
  if (decoded.tag === "Failed") return { tag: "Failed", failure: { tag: "Decode", value: decoded.failure } };
  try { return { tag: "Admitted", checked: CheckedSignatureGeneration.admit(expected, decoded.value) }; }
  catch (error) {
    if (error instanceof GenerationWireError) return { tag: "Failed", failure: error.failure };
    if (error instanceof PredicateFailure) return { tag: "Failed", failure: { tag: "Library", value: error } };
    throw error;
  }
}
export class SignatureCodec<T extends V.ExactJson = V.ExactJson> {
  readonly #ref: V.TypeRef;
  constructor(readonly checked: CheckedSignatureLibrary, readonly typeId: TypeId) { const ref = checked.refs.get(typeId); check(ref, "resolved codec type"); this.#ref = ref; }
  decodeJson(value: V.ExactJson): T { validateSemanticWire("ExactJson", value); V.validated(V.validateValue(this.checked.context, this.#ref, value), this.#ref); return V.deepFreeze(value) as T; }
  decode(text: string): T { return this.decodeJson(V.boundedParseExact(text)); }
  decodeWithDefaults(text: string): T { return this.checked.context.decodeWithDefaults(this.#ref, text).value as T; }
  encode(value: T): string { return V.encodeExact(this.decodeJson(value)); }
}
function compositionWireFailure(error: V.WireError | V.SemanticEvidenceError): V.WireFailure {
  return error instanceof V.WireError ? error.failure : { tag: "Syntax", path: error.path, value: error.condition };
}
export type CompositionAdmissionFailure = Extract<AdmissionFailure, { readonly tag: "CompositionInput" | "Wire" }>;
export type CompositionAdmission = { readonly tag: "Admitted"; readonly value: E.AdmittedComposition } | { readonly tag: "Failed"; readonly failure: CompositionAdmissionFailure };
function admitSignatureComposition(checked: CheckedSignatureLibrary, composition: unknown): CompositionAdmission {
  try {
    V.wireKeys(composition, "$", ["problem", "derivation"]);
    const basis = signatureBasis(checked.library, []);
    const decoded = W.decodeProblem(checked, composition.problem, basis);
    const prepared = W.prepare(checked, basis.graph_sha256, decoded.input, decoded.causes);
    if (prepared.tag === "Failed") return { tag: "Failed", failure: { tag: "CompositionInput", value: prepared.failure } };
    const plan = W.decodePlan(checked, composition.problem, composition.derivation, basis);
    return { tag: "Admitted", value: E.AdmittedComposition.admit(compositionAdmissionToken, prepared.value, V.deepFreeze(plan)) };
  } catch (error) {
    if (error instanceof V.WireError || error instanceof V.SemanticEvidenceError) return { tag: "Failed", failure: { tag: "Wire", value: compositionWireFailure(error) } };
    throw error;
  }
}
export type TypedOutcome = { readonly outcome: string; readonly values: Readonly<Record<string, V.ExactSlot>> };
export type TypedSignatureSlot<T extends V.ExactJson, Required extends boolean, Nullable extends boolean> = { readonly tag: "Present"; readonly value: T } | (Required extends false ? { readonly tag: "Absent" } : never) | (Nullable extends true ? { readonly tag: "Null" } : never);
export type PrepareResult<T, O> = { readonly tag: "Ready"; readonly value: T } | { readonly tag: "Completed"; readonly value: { readonly outcome: SignatureOutcome; readonly value: O } };
export interface NetworkBinding<A, B> {
  readonly transport: {
    readonly encode: (value: N.AttemptInput) => E.Result<N.AttemptInput>;
    readonly decode: (response: N.RawHttpResponse) => E.Result<B>;
  };
  readonly prepare: (value: A) => E.Result<PrepareResult<N.AttemptInput, B>>;
  readonly outcomeId: (value: B) => string;
}
export { projectSlot } from "./signature_verification.js";
export { emptyTypes, verifyEmptyTypes } from "./semantic_empty_types.js";
export function validateTypedOutcome(checked: CheckedSignatureLibrary, operation: OperationContract, value: TypedOutcome, externalOnly = false): TypedOutcome { const o = operation.outcomes.find(o => o.id === value.outcome); check(o, "declared typed outcome"); if (externalOnly) check(o.cause.tag === "ExternalCondition" && o.form.tag === "DeclaredFailure", "prepare completed external failure"); check(Object.keys(value.values).length === o.value_ports.length, "outcome value ports"); for (const p of o.value_ports) { const v = value.values[p.id]; check(v, "outcome port value"); const contract = slot(p.contract, checked.refs); const decision = V.acceptsSlot(checked.context, contract, v); if (decision.tag === "Rejected") throw new V.SemanticValueError(decision.failure); if (decision.tag === "Unresolved") throw new V.SemanticUnresolvedError(contract.type_ref, decision.obligations); } return V.deepFreeze(value); }
export function completedValid(operation: Pick<OperationContract, "outcomes">, outcome: SignatureOutcome): boolean {
  return operation.outcomes.some(candidate => V.same(candidate, outcome))
    && outcome.cause.tag === "ExternalCondition" && outcome.form.tag === "DeclaredFailure";
}
export function prepareCall<A, B>(operation: Pick<OperationContract, "outcomes">, binding: NetworkBinding<A, B>, value: A): E.Result<PrepareResult<N.AttemptInput, B>> {
  const prepared = binding.prepare(value);
  if (prepared.tag === "Failed" || prepared.value.tag === "Ready") return prepared;
  return completedValid(operation, prepared.value.value.outcome)
      && binding.outcomeId(prepared.value.value.value) === prepared.value.value.outcome.id
    ? prepared
    : { tag: "Failed", failure: { tag: "InvalidPlan", condition: "undeclared external completion" } };
}
