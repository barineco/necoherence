// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
// @ts-nocheck

import * as V from "./semantic_values.js";
import { adaptSignatureCompositionWire, validateSemanticWire, verifySignatureComposition } from "./signature_verification.js";

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
export interface SignatureGenerationBasis { readonly signature_schema: "ncoh-type-signatures@1"; readonly library_identity: string; readonly library_revision: string; readonly profile: V.ProfileRef; readonly graph_sha256: string; readonly provenance_sha256: string; readonly metadata_sha256: string; readonly problem_sha256: string | null; readonly entrypoints_sha256: string; }
export interface SignatureGenerationInput { readonly schema: "ncoh-checked-generation@4"; readonly basis: SignatureGenerationBasis; readonly signatures: TypeSignatureLibrary; readonly composition: unknown | null; readonly entrypoints: readonly { readonly identity: string; readonly definition: DefinitionId }[]; }
const check: typeof V.requireEvidence = V.requireEvidence;
function object(value: unknown, keys: string): Record<string, any> {
  check(value !== null && typeof value === "object" && !Array.isArray(value), "closed object");
  const out = value as Record<string, any>, expected = keys.split(" ").filter(Boolean);
  const unknown = Object.keys(out).find(key => !expected.includes(key));
  if (unknown !== undefined) throw new V.SemanticEvidenceError(`UnknownField:${unknown}`);
  check(expected.every(key => Object.hasOwn(out, key)), `closed fields: ${keys}`);
  return out;
}
function identity(value: unknown): asserts value is string { check(typeof value === "string" && value.length > 0, "nonempty opaque identity"); validateSemanticWire("string", value); }
function unique(values: readonly string[]): void { values.forEach(identity); check(new Set(values).size === values.length, "duplicate identity"); }
function compareIdentity(a: string, b: string): number {
  let i = 0, j = 0;
  while (i < a.length && j < b.length) { const x = a.codePointAt(i)!, y = b.codePointAt(j)!; if (x !== y) return x - y; i += x > 0xffff ? 2 : 1; j += y > 0xffff ? 2 : 1; }
  return (i < a.length ? 1 : 0) - (j < b.length ? 1 : 0);
}
export function signatureCanonicalJson(value: unknown): string { if (Array.isArray(value)) return `[${value.map(signatureCanonicalJson).join(",")}]`; if (value !== null && typeof value === "object") return `{${Object.keys(value).sort(compareIdentity).map(k => `${JSON.stringify(k)}:${signatureCanonicalJson((value as Record<string, unknown>)[k])}`).join(",")}}`; return JSON.stringify(value); }
const digest = (value: unknown): string => V.hashUtf8(signatureCanonicalJson(value));
const ordered = <T extends { readonly id: string }>(items: readonly T[]): readonly T[] => [...items].sort((a, b) => compareIdentity(a.id, b.id));
function graphProjection(library: TypeSignatureLibrary): unknown {
  const definitions = ordered(library.definitions).map(d => d.shape.tag === "Operation" ? { ...d, shape: { tag: "Operation", value: { ...d.shape.value, outcomes: d.shape.value.outcomes.map(o => ({ ...o, cause: { tag: o.cause.tag } })) } } } : d);
  return { profile: library.profile, nodes: ordered(library.nodes), definitions };
}
function source(value: unknown): SourceIdentity { const s = object(value, "repository revision path content_digest"); identity(s.repository); identity(s.revision); identity(s.path); validateSemanticWire("sha256", s.content_digest); return s as SourceIdentity; }
function sourceRef(value: unknown): V.SourceRef {
  const hasDeclaredRevision = value !== null && typeof value === "object" && Object.hasOwn(value, "declared_revision");
  const s = object(value, hasDeclaredRevision
    ? "repository revision path content_digest document_id declared_revision"
    : "repository revision path content_digest document_id");
  for (const key of ["repository", "revision", "path", "content_digest", "document_id"]) {
    check(typeof s[key] === "string", `source ${key}`);
  }
  check(!hasDeclaredRevision || s.declared_revision === null || typeof s.declared_revision === "string", "source declared revision");
  return s as V.SourceRef;
}
export type ProfilePredicate = V.ProfilePredicate;
export type MeaningPredicate = `MO${"01" | "02" | "03" | "04" | "05" | "06" | "07" | "08" | "09" | "10" | "11"}`;
export type LibraryPredicate = `LB${"01" | "02" | "03" | "04" | "05" | "06" | "07" | "08" | "09" | "10" | "11" | "12" | "13" | "14" | "15" | "16" | "17" | "18" | "19"}`;
export const PredicateFailure = V.DeclarationPredicateFailure;
export type PredicateFailure = V.DeclarationPredicateFailure;
export function checkProfile(profile: V.VersionedSemanticProfile): V.VersionedSemanticProfile {
  return V.checkProfileDeclaration(profile);
}

export function decodeProfileWire(value: unknown): V.VersionedSemanticProfile {
  return V.decodeVersionedProfileWire(value);
}

function list(value: unknown, condition: string): readonly any[] {
  check(Array.isArray(value), condition);
  return value;
}
function validateUnitWire(value: unknown, tags: readonly string[]): void {
  const row = object(value, "tag");
  if (!tags.includes(String(row.tag))) throw new V.SemanticEvidenceError(`UnknownTag:${String(row.tag)}`);
}
function validateFormatRuleWire(rule: V.FormatRule): void {
  const tag = (rule as { tag?: unknown }).tag;
  if (tag === "Text") { object(rule, "tag"); return; }
  if (tag === "Literal") { object(rule, "tag value"); return; }
  if (tag === "Optional" || tag === "Not") {
    const row = object(rule, "tag value");
    validateFormatRuleWire(row.value);
    return;
  }
  if (tag === "Choice" || tag === "Sequence") {
    const row = object(rule, "tag value");
    list(row.value, "format rule array").forEach(validateFormatRuleWire);
    return;
  }
  if (tag === "AsciiDfa") {
    const row = object(rule, "tag value");
    const spec = object(row.value, "state_count initial_state accepting_states transitions");
    list(spec.transitions, "DFA transitions").forEach(transition => object(transition, "from_state first last to_state"));
    return;
  }
  if (tag === "Timestamp") {
    const row = object(rule, "tag value");
    object(row.value, "allow_second_60 minimum_year maximum_year rejectUtcYearOutsideRange");
    return;
  }
  if (tag === "Labels") {
    const row = object(rule, "tag fields");
    const fields = object(row.fields, "separator min_count max_count total_max rule");
    validateFormatRuleWire(fields.rule);
    return;
  }
  if (tag === "Bounded") {
    const row = object(rule, "tag fields");
    const fields = object(row.fields, "unit maximum rule");
    validateUnitWire(fields.unit, ["Utf8Bytes", "UnicodeScalars", "Graphemes"]);
    validateFormatRuleWire(fields.rule);
    return;
  }
  if (tag === "Identifier") {
    const row = object(rule, "tag fields");
    object(row.fields, "first_alphabet rest_alphabet exact_length min_length max_length forbidden");
    return;
  }
  if (tag === "AbsoluteUri") {
    const row = object(rule, "tag fields");
    object(row.fields, "max_bytes");
    return;
  }
  if (tag === "LanguageTag") {
    const row = object(rule, "tag fields");
    object(row.fields, "grandfathered");
    return;
  }
  throw new V.SemanticEvidenceError(`UnknownTag:${String(tag)}`);
}

function validateFormatUseWire(value: unknown): void {
  const row = object(value, "tag value");
  if (row.tag === "Named") return;
  if (row.tag === "Inline") { validateFormatRuleWire(row.value); return; }
  throw new V.SemanticEvidenceError(`UnknownTag:${String(row.tag)}`);
}
function validateLengthBoundWire(value: unknown): void {
  const row = object(value, "unit minimum maximum");
  validateUnitWire(row.unit, ["Utf8Bytes", "UnicodeScalars", "Graphemes"]);
}
function validateStringSpecWire(value: unknown): void {
  const spec = object(value, "format lengths wrapper const_value enum_values examples default_value");
  if (spec.format !== null) validateFormatUseWire(spec.format);
  list(spec.lengths, "string lengths").forEach(validateLengthBoundWire);
}
function validateIntegerSpecWire(value: unknown): void {
  object(value, "domain minimum maximum const_value enum_values default_value");
}
function validateDecimalSpecWire(value: unknown): void {
  const spec = object(value, "minimum maximum");
  for (const bound of [spec.minimum, spec.maximum]) if (bound !== null) object(bound, "mantissa scale exclusive");
}
function validateLengthSpecWire(value: unknown): void {
  object(value, "minimum maximum");
}
function validateSealedLeafWire(value: unknown): void {
  const leaf = object(value, "tag value");
  if (leaf.tag === "String") validateStringSpecWire(leaf.value);
  else if (leaf.tag === "Integer") validateIntegerSpecWire(leaf.value);
  else throw new V.SemanticEvidenceError(`UnknownTag:${String(leaf.tag)}`);
}
function validateElementWire(value: unknown): void {
  object(value, "type_id nullable");
}
function validateExtrasWire(value: unknown): void {
  const tag = (value as { tag?: unknown })?.tag;
  if (tag === "Reject") { object(value, "tag"); return; }
  if (tag === "Allow") {
    const row = object(value, "tag fields");
    const fields = object(row.fields, "key_format value");
    if (fields.key_format !== null) validateFormatUseWire(fields.key_format);
    validateElementWire(fields.value);
    return;
  }
  throw new V.SemanticEvidenceError(`UnknownTag:${String(tag)}`);
}
function validateMemberTestWire(value: unknown): void {
  const tag = (value as { tag?: unknown })?.tag;
  if (tag === "Absent") { object(value, "tag"); return; }
  if (tag === "Format") { object(value, "tag value"); return; }
  throw new V.SemanticEvidenceError(`UnknownTag:${String(tag)}`);
}
function validateSelectorWire(value: unknown): void {
  const tag = (value as { tag?: unknown })?.tag;
  if (tag === "InternalTag" || tag === "Otherwise") { object(value, "tag"); return; }
  if (tag === "Kind") {
    const row = object(value, "tag value");
    validateUnitWire(row.value, ["Null", "Boolean", "Number", "String", "Array", "Object"]);
    return;
  }
  if (tag === "MemberShape") {
    const row = object(value, "tag value");
    list(row.value, "member selector entries").forEach(entry => {
      check(Array.isArray(entry) && entry.length === 2, "member selector entry");
      validateMemberTestWire(entry[1]);
    });
    return;
  }
  throw new V.SemanticEvidenceError(`UnknownTag:${String(tag)}`);
}

export function decodeProfileJson(text: string): V.VersionedSemanticProfile {
  return decodeProfileWire(V.parseLossless(text));
}

export function encodeProfileWire(profile: V.VersionedSemanticProfile): string {
  return signatureCanonicalJson(decodeProfileWire(structuredClone(profile)));
}

export function checkMeaningDefined(graph: V.ValueGraph, refs: readonly V.TypeRef[]): void {
  const nodes = new Map(graph.nodes.map(node => [V.typeIdentity(node.reference), node]));
  const pending = [...refs], seen = new Set<string>();
  const fail = (ref: V.TypeRef, predicate: MeaningPredicate): never => { throw new PredicateFailure(ref, predicate, []); };
  while (pending.length > 0) {
    const ref = pending.shift()!, identity = V.typeIdentity(ref);
    if (seen.has(identity)) continue;
    seen.add(identity);
    const node = nodes.get(identity);
    if (!node) continue;
    const shape = node.shape;
    if (shape.tag === "String") {
      if (shape.value.format?.tag === "Named" && !graph.profile.format_bindings.some(binding => binding.name === shape.value.format!.value)) fail(ref, "MO01");
      if (shape.value.lengths.some(bound => bound.unit.tag === "Graphemes") && graph.profile.grapheme_rules === null) fail(ref, "MO02");
      if (shape.value.wrapper !== null) {
        const wrapper = graph.profile.wrappers.find(candidate => candidate.name === shape.value.wrapper);
        if (!wrapper) fail(ref, "MO05");
        if (wrapper.payload.tag === "Bytes") fail(ref, "MO06");
      }
    } else if (shape.tag === "Bytes" || shape.tag === "RawBody") {
      if (graph.profile.bytes_policy === null) fail(ref, "MO03");
    } else if (shape.tag === "Integer") {
      const domain = graph.profile.integer_domains.find(binding => binding.name === (shape.value.domain ?? graph.profile.default_integer_domain));
      if (!domain) fail(ref, "MO04");
      if (domain.range.tag === "Inclusive" && (shape.value.minimum !== null && BigInt(shape.value.minimum) < BigInt(domain.range.fields.minimum) || shape.value.maximum !== null && BigInt(shape.value.maximum) > BigInt(domain.range.fields.maximum))) fail(ref, "MO09");
    } else if (shape.tag === "Sealed") {
      if (!graph.profile.tag?.sealed.some(form => form.tag === shape.fields.tag)) fail(ref, "MO07");
    } else if (shape.tag === "Decimal") {
      if (!graph.profile.numbers.decimals) fail(ref, "MO08");
    } else if (shape.tag === "Opaque") {
      fail(ref, "MO10");
    } else if (shape.tag === "TaggedUnion") {
      if (shape.value.branches.some(branch => branch.selector.tag === "InternalTag") && graph.profile.tag === null) fail(ref, "MO11");
    }
    pending.push(...V.children(shape));
  }
}
export function decodeFormatRuleWire(value: unknown): V.FormatRule {
  validateFormatRuleWire(value as V.FormatRule);
  return V.deepFreeze(structuredClone(value as V.FormatRule));
}

export function encodeFormatRuleWire(value: V.FormatRule): string {
  return signatureCanonicalJson(decodeFormatRuleWire(value));
}

export function decodeShapeWire(value: unknown): ValueTypeShape {
  validateShapeWire(value as ValueTypeShape);
  return V.deepFreeze(structuredClone(value as ValueTypeShape));
}

export function encodeShapeWire(value: ValueTypeShape): string {
  return signatureCanonicalJson(decodeShapeWire(value));
}

export type ValueCondition = { readonly tag: string; readonly value?: string };
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
  const condition = value as ValueCondition;
  if (valueConditionTags.has(condition?.tag)) object(condition, "tag");
  else if (valueConditionPayloadTags.has(condition?.tag)) object(condition, "tag value");
  else throw new V.SemanticEvidenceError(`UnknownTag:${String(condition?.tag)}`);
  return V.deepFreeze(structuredClone(condition));
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
  return V.deepFreeze(structuredClone(ref)) as V.TypeRef;
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
  if (!["Field", "Index", "Variant"].includes(step.tag)) throw new V.SemanticEvidenceError(`UnknownTag:${String(step.tag)}`);
  validateSemanticWire("string", step.value);
  if (step.tag === "Index") validateSemanticWire("natural", step.value);
  return V.deepFreeze(structuredClone(step)) as V.PathStep;
}
function decodeExactSlotWire(value: unknown): V.ExactSlot {
  const slot = value as V.ExactSlot;
  if (slot?.tag === "Absent" || slot?.tag === "Null") object(slot, "tag");
  else if (slot?.tag === "Present") { object(slot, "tag value"); validateSemanticWire("ExactJson", slot.value); }
  else throw new V.SemanticEvidenceError(`UnknownTag:${String(slot?.tag)}`);
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
  return decodeDiagnosticWire(V.parseLossless(text));
}
export function encodeDiagnosticWire(value: SignatureValueFailure): string {
  return signatureCanonicalJson(decodeDiagnosticWire(value));
}

export function decodeGenerationBasisWire(value: unknown): SignatureGenerationBasis {
  const row = object(value, "signature_schema library_identity library_revision profile graph_sha256 provenance_sha256 metadata_sha256 problem_sha256 entrypoints_sha256");
  check(row.signature_schema === "ncoh-type-signatures@1", "signature schema");
  identity(row.library_identity); identity(row.library_revision);
  object(row.profile, "identity revision content_digest"); identity(row.profile.identity); identity(row.profile.revision); validateSemanticWire("sha256", row.profile.content_digest);
  for (const key of ["graph_sha256", "provenance_sha256", "metadata_sha256", "entrypoints_sha256"] as const) validateSemanticWire("sha256", row[key]);
  if (row.problem_sha256 !== null) validateSemanticWire("sha256", row.problem_sha256);
  return V.deepFreeze(structuredClone(row)) as SignatureGenerationBasis;
}
export function decodeGenerationBasisJson(text: string): SignatureGenerationBasis {
  return decodeGenerationBasisWire(V.parseLossless(text));
}
export function encodeGenerationBasisWire(value: SignatureGenerationBasis): string {
  return signatureCanonicalJson(decodeGenerationBasisWire(value));
}

function origin(value: unknown, library: TypeSignatureLibrary): Origin { const o = object(value, "source locator"); source(o.source); validateSemanticWire("string[]", o.locator); check(library.sources.some(s => V.same(s, o.source)), "resolved origin source"); return o as Origin; }
function target(value: unknown, library: TypeSignatureLibrary): AnnotationTarget { const t = value as AnnotationTarget; check(t && typeof t === "object", "annotation target"); if (t.tag === "Library") object(t, "tag"); else if (t.tag === "Outcome") { object(t, "tag fields"); object(t.fields, "definition outcome"); const d = library.definitions.find(d => d.id === t.fields.definition); check(d?.shape.tag === "Operation" && d.shape.value.outcomes.some(o => o.id === t.fields.outcome), "resolved outcome target"); } else { object(t, "tag value"); identity(t.value); const ids = t.tag === "Group" ? library.groups.map(g => g.id) : t.tag === "Definition" ? library.definitions.map(d => d.id) : t.tag === "Type" ? library.nodes.map(n => n.id) : []; check(ids.includes(t.value), "resolved annotation target"); } return t; }
function cause(value: unknown, library: TypeSignatureLibrary): OutcomeCause { const c = object(value, "tag fields"); check(c.tag === "ValueContract" || c.tag === "ExternalCondition", "outcome cause"); const f = object(c.fields, c.tag === "ValueContract" ? "origin" : "specification"); origin(f[c.tag === "ValueContract" ? "origin" : "specification"], library); return c as OutcomeCause; }
function slot(value: unknown, refs: ReadonlyMap<string, V.TypeRef>): V.SlotContract { const s = object(value, "type_id required nullable"); identity(s.type_id); const ref = refs.get(s.type_id); check(ref, "unresolved TypeId"); validateSemanticWire("boolean", s.required); validateSemanticWire("boolean", s.nullable); return { type_ref: ref, required: s.required, nullable: s.nullable }; }
function convertShape(shape: ValueTypeShape, refs: ReadonlyMap<string, V.TypeRef>, occurrence: V.OccurrenceRef): V.TypeShape {
  const ref = (id: string): V.TypeRef => { const found = refs.get(id); check(found, "resolved TypeId"); return found; };
  if (shape.tag === "Product") return { tag: "Product", value: { fields: shape.value.fields.map(field => ({ wire_name: field.wire_name, slot: slot(field.slot, refs), origin: occurrence })), extras: shape.value.extras.tag === "Reject" ? { tag: "Reject" } : { tag: "Allow", fields: { key_format: shape.value.extras.fields.key_format, value: { type_ref: ref(shape.value.extras.fields.value.type_id), nullable: shape.value.extras.fields.value.nullable } } } } };
  if (shape.tag === "Array") return { tag: "Array", value: { item: { type_ref: ref(shape.value.item.type_id), nullable: shape.value.item.nullable }, min_length: shape.value.min_length, max_length: shape.value.max_length } };
  if (shape.tag === "TaggedUnion") return { tag: "TaggedUnion", value: { branches: shape.value.branches.map(branch => ({ ...branch, target: ref(branch.target), origin: occurrence })) } };
  if (shape.tag === "Alias") return { tag: "Alias", fields: { target: ref(shape.fields.target), reference_text: "" } };
  return shape as V.TypeShape;
}
function validateOperation(op: OperationContract, library: TypeSignatureLibrary, refs: ReadonlyMap<string, V.TypeRef>): void {
  object(op, "effect inputs outcomes"); validateSemanticWire("EffectPoint", op.effect); check(Array.isArray(op.inputs) && Array.isArray(op.outcomes), "operation ports and outcomes"); unique(op.inputs.map(p => p.id)); unique(op.outcomes.map(o => o.id)); check(op.outcomes.length > 0, "operation outcomes");
  for (const p of op.inputs) { object(p, "id contract"); slot(p.contract, refs); }
  for (const o of op.outcomes) {
    object(o, "id form cause value_ports produced_resources"); validateSemanticWire("OutcomeForm", o.form); cause(o.cause, library);
    check(Array.isArray(o.value_ports) && Array.isArray(o.produced_resources), "typed outcome resources");
    unique(o.value_ports.map((p: SignaturePort) => p.id)); unique(o.produced_resources.map((p: SignatureResourceProduction) => p.id));
    for (const p of o.value_ports) { object(p, "id contract"); slot(p.contract, refs); }
    for (const p of o.produced_resources) { object(p, "id token_type revision quantity provenance"); const ref = refs.get(p.token_type); check(ref, "resolved produced resource TypeId"); validateSemanticWire("ResourceProduction", { ...p, token_type: ref }); }
    if (o.cause.tag === "ExternalCondition") check(o.form.tag === "DeclaredFailure" && o.value_ports.length > 0, "typed external failure");
  }
}
export function checkOperationSignature(base: OperationContract, signature: OperationContract, library: TypeSignatureLibrary): void {
  check(V.same(base.effect, signature.effect) && V.same(base.inputs, signature.inputs), "operation input/effect contracts"); unique(signature.outcomes.map(o => o.id));
  for (const expected of base.outcomes) check(signature.outcomes.some(o => V.same(o, expected)), "basic outcome deleted or replaced");
  for (const o of signature.outcomes) if (!base.outcomes.some(b => b.id === o.id)) { cause(o.cause, library); check(o.cause.tag === "ExternalCondition" && o.form.tag === "DeclaredFailure" && o.value_ports.length > 0, "external outcome supplement"); }
}
export interface CheckedSignatureLibrary { readonly library: TypeSignatureLibrary; readonly context: V.ValueContext; readonly refs: ReadonlyMap<TypeId, V.TypeRef>; }
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
  const uniqueNames = (values: readonly string[]): boolean => values.every(Boolean) && new Set(values).size === values.length;
  const nodeIds = new Set(library.nodes.map(node => node.id));
  if (library.schema !== "ncoh-type-signatures@1" || !library.identity || !library.revision || !uniqueNames(library.nodes.map(node => node.id)) || !uniqueNames(library.definitions.map(definition => definition.id)) || !uniqueNames(library.groups.map(group => group.id))) fail("LB01");
  const referenceIds = (shape: ValueTypeShape): readonly string[] => shape.tag === "Product" ? [...shape.value.fields.map(field => field.slot.type_id), ...(shape.value.extras.tag === "Allow" ? [shape.value.extras.fields.value.type_id] : [])] : shape.tag === "Array" ? [shape.value.item.type_id] : shape.tag === "Alias" ? [shape.fields.target] : shape.tag === "TaggedUnion" ? shape.value.branches.map(branch => branch.target) : [];
  if (library.nodes.some(node => referenceIds(node.shape).some(id => !nodeIds.has(id)))) fail("LB01");
  if (library.definitions.some(definition => definitionReferences(definition.shape).some(id => !nodeIds.has(id)))) fail("LB01");
  if (library.nodes.some(node => node.shape.tag === "Product" && !uniqueNames(node.shape.value.fields.map(field => field.wire_name)))) fail("LB02");
  if (library.nodes.some(node => node.shape.tag === "Product" && node.shape.value.fields.some(field => library.profile.wrappers.some(wrapper => wrapper.key === field.wire_name)))) fail("LB03");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && new Set(node.shape.value.branches.map(branch => branch.wire_tag)).size !== node.shape.value.branches.length)) fail("LB04");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some((branch, index) => branch.selector.tag === "Otherwise" && index + 1 !== node.shape.value.branches.length))) fail("LB05");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => !branch.wire_tag || branch.selector.tag === "MemberShape" && branch.selector.value.some(([key]) => !key)))) fail("LB06");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => branch.selector.tag === "InternalTag" && library.profile.tag?.format && !V.recognizeFormat(library.profile.format_bindings.find(binding => binding.name === library.profile.tag!.format)!.rule, branch.wire_tag)))) fail("LB07");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => branch.selector.tag === "InternalTag" && Boolean(library.profile.tag?.sealed.some(form => form.tag === branch.wire_tag)) !== library.nodes.some(target => target.id === branch.target && target.shape.tag === "Sealed" && target.shape.fields.tag === branch.wire_tag)))) fail("LB08");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => branch.selector.tag === "MemberShape" && (!uniqueNames(branch.selector.value.map(([key]) => key)) || branch.selector.value.some(([, test]) => test.tag === "Format" && !library.profile.format_bindings.some(binding => binding.name === test.value)))))) fail("LB09");
  if (library.nodes.some(node => node.shape.tag === "Sealed" && (() => {
    const form = library.profile.tag?.sealed.find(candidate => candidate.tag === node.shape.fields.tag);
    return !form || new Set(node.shape.fields.refinements.map(refinement => refinement.key)).size !== node.shape.fields.refinements.length
      || node.shape.fields.refinements.some(refinement => !form.fields.some(field => field.key === refinement.key && field.leaf.tag === refinement.leaf.tag));
  })())) fail("LB10");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => branch.selector.tag === "InternalTag" && !library.nodes.some(target => target.id === branch.target && (target.shape.tag === "Product" || target.shape.tag === "Sealed"))))) fail("LB11");
  if (library.nodes.some(node => node.shape.tag === "Product" && node.shape.value.extras.tag === "Allow" && node.shape.value.extras.fields.key_format?.tag === "Named" && !library.profile.format_bindings.some(binding => binding.name === node.shape.value.extras.fields.key_format!.value))) fail("LB12");
  if (library.nodes.some(node => node.shape.tag === "String" && (node.shape.value.wrapper !== null && !library.profile.wrappers.some(wrapper => wrapper.name === node.shape.value.wrapper && wrapper.payload.tag === "Text") || node.shape.value.format?.tag === "Named" && !library.profile.format_bindings.some(binding => binding.name === node.shape.value.format!.value) || node.shape.value.lengths.some(bound => bound.minimum !== null && bound.maximum !== null && BigInt(bound.minimum) > BigInt(bound.maximum))))) fail("LB13");
  if (library.nodes.some(node => node.shape.tag === "Integer" && (node.shape.value.minimum !== null && node.shape.value.maximum !== null && BigInt(node.shape.value.minimum) > BigInt(node.shape.value.maximum) || node.shape.value.domain !== null && !library.profile.integer_domains.some(domain => domain.name === node.shape.value.domain)))) fail("LB14");
  if (library.nodes.some(node => node.shape.tag === "Decimal" && node.shape.value.minimum !== null && node.shape.value.maximum !== null && (node.shape.value.minimum.scale !== node.shape.value.maximum.scale || BigInt(node.shape.value.maximum.mantissa) < BigInt(node.shape.value.minimum.mantissa)))) fail("LB15");
  if (library.nodes.some(node => node.shape.tag === "Array" && node.shape.value.min_length !== null && node.shape.value.max_length !== null && BigInt(node.shape.value.min_length) > BigInt(node.shape.value.max_length) || node.shape.tag === "Bytes" && node.shape.value.minimum !== null && node.shape.value.maximum !== null && BigInt(node.shape.value.minimum) > BigInt(node.shape.value.maximum))) fail("LB16");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && node.shape.value.branches.some(branch => branch.selector.tag === "InternalTag" && library.nodes.some(target => {
    if (target.id !== branch.target || target.shape.tag !== "Product") return false;
    const tagField = target.shape.value.fields.find(field => field.wire_name === library.profile.tag?.key);
    if (!tagField) return true;
    const tagNode = library.nodes.find(candidate => candidate.id === tagField.slot.type_id);
    if (!tagNode || tagNode.shape.tag !== "String") return true;
    const spec = tagNode.shape.value;
    return spec.const_value !== null && spec.const_value !== branch.wire_tag
      || spec.enum_values !== null && !spec.enum_values.includes(branch.wire_tag)
      || spec.format !== null && !V.recognizeFormat(spec.format.tag === "Inline" ? spec.format.value : library.profile.format_bindings.find(binding => binding.name === spec.format!.value)!.rule, branch.wire_tag);
  })))) fail("LB17");
  if (library.nodes.some(node => node.shape.tag === "TaggedUnion" && new Set(node.shape.value.branches.map(branch => JSON.stringify(branch.selector.tag === "InternalTag" ? [branch.selector, branch.wire_tag] : branch.selector))).size !== node.shape.value.branches.length)) fail("LB18");
  if (library.nodes.some(node => {
    if (node.shape.tag === "String") {
      const spec = node.shape.value;
      return [...(spec.const_value === null ? [] : [spec.const_value]), ...(spec.enum_values ?? []), ...(spec.default_value === null ? [] : [spec.default_value])].some(value => spec.format !== null && !V.recognizeFormat(spec.format.tag === "Inline" ? spec.format.value : library.profile.format_bindings.find(binding => binding.name === spec.format!.value)!.rule, value));
    }
    if (node.shape.tag === "Integer") {
      const spec = node.shape.value, binding = library.profile.integer_domains.find(domain => domain.name === (spec.domain ?? library.profile.default_integer_domain));
      return [...(spec.const_value === null ? [] : [spec.const_value]), ...(spec.enum_values ?? []), ...(spec.default_value === null ? [] : [spec.default_value])].some(value => binding?.range.tag === "Inclusive" && (BigInt(value) < BigInt(binding.range.fields.minimum) || BigInt(value) > BigInt(binding.range.fields.maximum)));
    }
    return false;
  })) fail("LB19");
}
function validateShapeWire(shape: ValueTypeShape): void {
  const tag = (shape as { tag?: unknown }).tag;
  if (tag === "Unit" || tag === "Never") { object(shape, "tag"); return; }
  if (tag === "Unknown") {
    const row = object(shape, "tag value");
    validateUnitWire(row.value, ["Any", "OrdinaryObject"]);
    return;
  }
  if (tag === "Boolean") { const row = object(shape, "tag value"); object(row.value, "const_value default_value"); return; }
  if (tag === "Integer") { const row = object(shape, "tag value"); validateIntegerSpecWire(row.value); return; }
  if (tag === "Decimal") { const row = object(shape, "tag value"); validateDecimalSpecWire(row.value); return; }
  if (tag === "String") { const row = object(shape, "tag value"); validateStringSpecWire(row.value); return; }
  if (tag === "Bytes") { const row = object(shape, "tag value"); validateLengthSpecWire(row.value); return; }
  if (tag === "Product") {
    const row = object(shape, "tag value");
    const spec = object(row.value, "fields extras");
    list(spec.fields, "product fields").forEach(field => {
      const member = object(field, "wire_name slot");
      object(member.slot, "type_id required nullable");
    });
    validateExtrasWire(spec.extras);
    return;
  }
  if (tag === "Array") {
    const row = object(shape, "tag value");
    const spec = object(row.value, "item min_length max_length");
    validateElementWire(spec.item);
    return;
  }
  if (tag === "TaggedUnion") {
    const row = object(shape, "tag value");
    const spec = object(row.value, "branches");
    list(spec.branches, "union branches").forEach(branch => {
      const member = object(branch, "target wire_tag selector");
      validateSelectorWire(member.selector);
    });
    return;
  }
  if (tag === "Sealed") {
    const row = object(shape, "tag fields");
    const fields = object(row.fields, "tag refinements");
    list(fields.refinements, "sealed refinements").forEach(refinement => {
      const member = object(refinement, "key leaf");
      validateSealedLeafWire(member.leaf);
    });
    return;
  }
  if (tag === "Alias") { const row = object(shape, "tag fields"); object(row.fields, "target"); return; }
  if (tag === "RawBody") { const row = object(shape, "tag fields"); object(row.fields, "encoding"); return; }
  if (tag === "Opaque") { const row = object(shape, "tag fields"); object(row.fields, "type_name"); return; }
  throw new V.SemanticEvidenceError(`UnknownTag:${String(tag)}`);
}

const checkedLibraryAuthority = new WeakSet<CheckedSignatureLibrary>();
export function checkLibrary(value: TypeSignatureLibrary): CheckedSignatureLibrary {
  const library = structuredClone(value);
  object(library, "schema identity revision profile sources provenance groups annotations nodes definitions");
  check(library.schema === "ncoh-type-signatures@1", "signature schema"); identity(library.identity); identity(library.revision);
  unique(library.nodes.map(node => node.id)); unique(library.definitions.map(definition => definition.id)); unique(library.groups.map(group => group.id)); unique(library.definitions.map(definition => definition.wire_identity));
  library.nodes.forEach(node => { object(node, "id shape"); validateShapeWire(node.shape); });
  const p = library.profile; object(p, "reference source_refs integer_domains default_integer_domain numbers grapheme_rules format_bindings bytes_policy wrappers tag");
  const graphemeRules = p.grapheme_rules === null ? null : { ...p.grapheme_rules, sources: p.grapheme_rules.sources.map(item => ({ role: item.role, source: item.origin.source })) };
  const profile = checkProfile({ ...p, grapheme_rules: graphemeRules } as V.VersionedSemanticProfile);
  checkLibraryPredicate(library);
  const synthetic: V.SourceRef = { repository: "ncoh-type-signatures", revision: "1", path: "", content_digest: "", document_id: "", declared_revision: null };
  const refs = new Map(library.nodes.map(node => [node.id, { source: synthetic, definition_name: node.id, pointer: [] } satisfies V.TypeRef]));
  const nodes = library.nodes.map(node => ({ reference: refs.get(node.id)!, shape: convertShape(node.shape, refs, { source: synthetic, pointer: [] }), description: null, attributes: [], extensions: [] }));
  const context = new V.ValueContext({ profile, nodes });
  for (const node of nodes) context.defined(node.reference);
  for (const definition of library.definitions) {
    if (definition.shape.tag === "Value" || definition.shape.tag === "Message") continue;
    if (definition.shape.tag === "Symbol") identity(definition.shape.value);
    else { check(definition.shape.tag === "Operation", "operation shape"); validateOperation((definition.shape as { readonly tag: "Operation"; readonly value: OperationContract }).value, library, refs); }
  }
  for (const group of library.groups) { unique(group.members); group.members.forEach(id => check(library.definitions.some(definition => definition.id === id), "resolved group member")); }
  const checked = Object.freeze({ library: V.deepFreeze(library), context, refs });
  checkedLibraryAuthority.add(checked);
  return checked;
}
export const checkTypeSignatureLibrary = checkLibrary;
export function requireCheckedLibrary(checked: CheckedSignatureLibrary): void {
  check(checkedLibraryAuthority.has(checked), "checked library authority");
}
export function decodeLibraryWire(value: unknown): TypeSignatureLibrary {
  return checkLibrary(structuredClone(value) as TypeSignatureLibrary).library;
}
export function decodeLibraryJson(text: string): TypeSignatureLibrary {
  return decodeLibraryWire(V.parseLossless(text));
}
export function encodeLibraryWire(value: TypeSignatureLibrary): string {
  return signatureCanonicalJson(decodeLibraryWire(value));
}
export function signatureBasis(library: TypeSignatureLibrary, entrypoints: SignatureGenerationInput["entrypoints"], composition: unknown | null = null): SignatureGenerationBasis {
  checkTypeSignatureLibrary(library);
  const graph = graphProjection(library);
  const outcome_origins = ordered(library.definitions).flatMap(d => d.shape.tag === "Operation" ? ordered(d.shape.value.outcomes).map(o => ({ definition: d.id, outcome: o.id, cause: o.cause })) : []);
  const sortCanonical = <T>(values: readonly T[]): T[] => [...values].sort((a, b) => compareIdentity(signatureCanonicalJson(a), signatureCanonicalJson(b)));
  const sources = [...library.sources].sort((a, b) => { for (const k of ["repository", "revision", "path", "content_digest"] as const) { const result = compareIdentity(a[k], b[k]); if (result) return result; } return 0; });
  const provenance = [...library.provenance].sort((a, b) => compareIdentity(signatureCanonicalJson(a.target), signatureCanonicalJson(b.target))).map(b => ({ ...b, origins: sortCanonical(b.origins) }));
  const annotations = [...library.annotations].sort((a, b) => { const left = [signatureCanonicalJson(a.target), a.key, signatureCanonicalJson(a.value)], right = [signatureCanonicalJson(b.target), b.key, signatureCanonicalJson(b.value)]; for (let i = 0; i < left.length; i++) { const result = compareIdentity(left[i]!, right[i]!); if (result) return result; } return 0; });
  return { signature_schema: library.schema, library_identity: library.identity, library_revision: library.revision, profile: library.profile.reference, graph_sha256: digest(graph), provenance_sha256: digest({ sources, provenance, outcome_origins }), metadata_sha256: digest({ groups: ordered(library.groups).map(g => ({ ...g, members: [...g.members].sort(compareIdentity) })), annotations }), problem_sha256: composition === null ? null : digest(composition), entrypoints_sha256: digest([...entrypoints].sort((a, b) => compareIdentity(a.identity, b.identity))) };
}
const authority = new WeakSet<CheckedSignatureGeneration>();
const signatureAdmissionToken = Symbol("signature generation admission");
export type GenerationWireFailure =
  | { readonly tag: "UnsupportedSchema"; readonly value: string }
  | { readonly tag: "UnknownField"; readonly value: string }
  | { readonly tag: "UnknownTag"; readonly value: string }
  | { readonly tag: "Syntax"; readonly value: string }
  | { readonly tag: "BasisMismatch" | "DigestMismatch" | "InvalidEntrypoints" }
  | { readonly tag: "UnresolvedEntrypoint"; readonly value: string }
  | { readonly tag: "Predicate"; readonly value: PredicateFailure };
export class GenerationWireError extends Error { constructor(readonly failure: GenerationWireFailure) { super(failure.tag); } }
export class CheckedSignatureGeneration {
  private constructor(token: symbol, readonly input: SignatureGenerationInput, readonly signatures: CheckedSignatureLibrary) { check(token === signatureAdmissionToken, "signature admission authority"); authority.add(this); Object.freeze(this); }
  static admit(expected: SignatureGenerationBasis, input: SignatureGenerationInput): CheckedSignatureGeneration {
    object(input, "schema basis signatures composition entrypoints");
    if (input.schema !== "ncoh-checked-generation@4") throw new GenerationWireError({ tag: "UnsupportedSchema", value: String(input.schema) });
    if (!V.same(expected, input.basis)) throw new GenerationWireError({ tag: "BasisMismatch" });
    const checked = checkLibrary(input.signatures);
    if (!V.same(signatureBasis(checked.library, input.entrypoints, input.composition), expected)) throw new GenerationWireError({ tag: "DigestMismatch" });
    unique(input.entrypoints.map(entry => entry.identity));
    if (input.entrypoints.length === 0 && input.composition === null) throw new GenerationWireError({ tag: "InvalidEntrypoints" });
    for (const entry of input.entrypoints) {
      const definition = checked.library.definitions.find(candidate => candidate.id === entry.definition);
      if (!definition) throw new GenerationWireError({ tag: "UnresolvedEntrypoint", value: entry.definition });
      definitionReferences(definition.shape).forEach(id => checked.context.defined(checked.refs.get(id)!));
    }
    if (input.composition !== null) checkSignatureComposition(checked, input.composition);
    return new CheckedSignatureGeneration(signatureAdmissionToken, V.deepFreeze(structuredClone(input)), checked);
  }
  annotations(targetValue: AnnotationTarget): readonly Annotation[] { return this.signatures.library.annotations.filter(annotation => V.same(annotation.target, targetValue)); }
  codec<T extends V.ExactJson = V.ExactJson>(typeId: TypeId): SignatureCodec<T> { check(authority.has(this), "checked generation authority"); return new SignatureCodec<T>(this.signatures, typeId); }
}
export function admitSignatureGeneration(expected: SignatureGenerationBasis, exchangeJson: string): { readonly tag: "Admitted"; readonly checked: CheckedSignatureGeneration } | { readonly tag: "Failed"; readonly failure: GenerationWireFailure } {
  try {
    const input = V.parseLossless(exchangeJson) as SignatureGenerationInput;
    return { tag: "Admitted", checked: CheckedSignatureGeneration.admit(expected, input) };
  } catch (error) {
    if (error instanceof GenerationWireError) return { tag: "Failed", failure: error.failure };
    if (error instanceof PredicateFailure) return { tag: "Failed", failure: { tag: "Predicate", value: error } };
    if (error instanceof V.ProfileWireError) {
      if (error.failure.tag === "UnknownField" || error.failure.tag === "UnknownTag") return { tag: "Failed", failure: error.failure };
      return { tag: "Failed", failure: { tag: "Syntax", value: error.message } };
    }
    if (error instanceof V.SemanticEvidenceError && error.condition.startsWith("UnknownField:")) return { tag: "Failed", failure: { tag: "UnknownField", value: error.condition.slice("UnknownField:".length) } };
    if (error instanceof V.SemanticEvidenceError && error.condition.startsWith("UnknownTag:")) return { tag: "Failed", failure: { tag: "UnknownTag", value: error.condition.slice("UnknownTag:".length) } };
    if (error instanceof V.SemanticEvidenceError && error.condition.startsWith("closed fields:")) return { tag: "Failed", failure: { tag: "UnknownField", value: error.condition.slice("closed fields:".length).trim() } };
    return { tag: "Failed", failure: { tag: "Syntax", value: error instanceof Error ? error.message : "invalid generation input" } };
  }
}
export function requireAdmittedGeneration(checked: CheckedSignatureGeneration): void { check(authority.has(checked), "checked generation authority"); }
export class SignatureCodec<T extends V.ExactJson = V.ExactJson> {
  readonly #ref: V.TypeRef;
  constructor(readonly checked: CheckedSignatureLibrary, readonly typeId: TypeId) { const ref = checked.refs.get(typeId); check(ref, "resolved codec type"); checked.context.defined(ref); this.#ref = ref; }
  decodeJson(value: V.ExactJson): T { validateSemanticWire("ExactJson", value); return V.deepFreeze(this.checked.context.validate(this.#ref, value)) as T; }
  decode(text: string): T { return this.decodeJson(V.parseExact(text)); }
  decodeWithDefaults(text: string): T { return this.checked.context.decodeWithDefaults(this.#ref, text).value as T; }
  encode(value: T): string { return V.encodeExact(this.decodeJson(value)); }
}
export function checkSignatureComposition(checked: CheckedSignatureLibrary, composition: unknown): V.SignatureCompositionEvidence {
  const raw = object(composition, "problem derivation");
  const base = signatureBasis(checked.library, []);
  check(V.same(raw.problem.basis, base), "composition signature basis");
  const type = (id: unknown): V.TypeRef => { identity(id); const ref = checked.refs.get(id); check(ref, "composition unresolved TypeId"); return ref; };
  const c = adaptSignatureCompositionWire(raw, {
    type,
    definition: (id: unknown) => { identity(id); const d = checked.library.definitions.find(definition => definition.id === id); check(d, "composition definition identity"); return { source: type(id).source, name: d.id }; },
    basis: (value: unknown) => { check(V.same(value, base), "evidence signature basis"); return { profile: checked.context.profile, sources: checked.context.sources }; },
    cause: (value: unknown) => { cause(value, checked.library); },
    shape: (id: unknown, value: unknown) => { identity(id); const node = checked.library.nodes.find(candidate => candidate.id === id); check(node && V.same(node.shape, value), "evidence declared value shape"); return checked.context.node(type(id)).shape; },
    snapshot: (value: unknown) => { check(V.same(value, raw.problem), "cause-bound composition snapshot"); },
  });
  for (const fn of raw.problem.signatures) {
    for (const o of fn.outcomes) { cause(o.cause, checked.library); if (o.cause.tag === "ExternalCondition") check(o.form.tag === "DeclaredFailure" && o.value_ports.length > 0, "typed external failure"); }
    if (fn.form.tag !== "Operation") continue;
    const d = checked.library.definitions.find(d => d.id === fn.form.value);
    check(d?.shape.tag === "Operation", "generic operation declaration");
    check(fn.reference.identity === d.wire_identity && fn.reference.revision === checked.library.revision && fn.reference.content_digest === base.graph_sha256, "operation signature identity and version");
    const operation: OperationContract = { effect: fn.effect, inputs: fn.inputs.map((p: any) => ({ id: p.id, contract: p.contract })), outcomes: fn.outcomes.map((o: any) => ({ id: o.id, form: o.form, cause: o.cause, value_ports: o.value_ports.map((p: any) => ({ id: p.id, contract: p.contract })), produced_resources: o.produced_resources })) };
    validateOperation(operation, checked.library, checked.refs);
    checkOperationSignature(d.shape.value, operation, checked.library);
  }
  verifySignatureComposition(checked.context, c, fn => {
    check(fn.form.tag === "Operation", "generic operation form");
    const original = raw.problem.signatures.find((s: any) => V.same(s.reference, fn.reference));
    check(original && original.form.tag === "Operation", "checked operation contract");
  });
  return c;
}
export type TypedOutcome = { readonly outcome: string; readonly values: Readonly<Record<string, V.ExactSlot>> };
export type TypedSignatureSlot<T extends V.ExactJson, Required extends boolean, Nullable extends boolean> = { readonly tag: "Present"; readonly value: T } | (Required extends false ? { readonly tag: "Absent" } : never) | (Nullable extends true ? { readonly tag: "Null" } : never);
export type PrepareResult<T, O extends TypedOutcome = TypedOutcome> = { readonly tag: "Ready"; readonly value: T } | { readonly tag: "Completed"; readonly value: O };
export {
  checkAssignable,
  formatRuleIncluded,
  formatRuleSamplesFuel,
  inclusionSamples,
  projectSlot,
  sampleValueFuel,
  sampleValues,
  slotSamples,
  type AssignabilityResult,
  type SampleBounds,
  type SampleObligation,
  type SampleResult,
  type TypeObligation,
} from "./signature_verification.js";
export function validateTypedOutcome(checked: CheckedSignatureLibrary, operation: OperationContract, value: TypedOutcome, externalOnly = false): TypedOutcome { const o = operation.outcomes.find(o => o.id === value.outcome); check(o, "declared typed outcome"); if (externalOnly) check(o.cause.tag === "ExternalCondition" && o.form.tag === "DeclaredFailure", "prepare completed external failure"); check(Object.keys(value.values).length === o.value_ports.length, "outcome value ports"); for (const p of o.value_ports) { const v = value.values[p.id]; check(v, "outcome port value"); checked.context.validateSlot(slot(p.contract, checked.refs), v); } return V.deepFreeze(value); }
export function prepareSignatureHttp<T, O extends TypedOutcome = TypedOutcome>(checked: CheckedSignatureLibrary, operation: OperationContract, prepared: PrepareResult<T, O>): PrepareResult<T, O> { check(operation.effect.tag === "HttpRequestResponse", "HTTP effect"); if (prepared.tag === "Completed") validateTypedOutcome(checked, operation, prepared.value, true); else check(prepared.tag === "Ready", "HTTP prepare result"); return prepared; }
