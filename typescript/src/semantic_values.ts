// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { LosslessNumber } from "lossless-json";
import { parseTree } from "jsonc-parser";
import type { Node as JsonNode, ParseError } from "jsonc-parser";
import { sha256 } from "@noble/hashes/sha2.js";

export type ExactJson =
  | { readonly tag: "Null" }
  | { readonly tag: "Bool"; readonly value: boolean }
  | { readonly tag: "Integer"; readonly value: string }
  | { readonly tag: "Decimal"; readonly text: string }
  | { readonly tag: "String"; readonly value: string }
  | { readonly tag: "Array"; readonly items: readonly ExactJson[] }
  | { readonly tag: "Object"; readonly members: readonly { readonly key: string; readonly value: ExactJson }[] };
export type ExactSlot = { readonly tag: "Absent" } | { readonly tag: "Null" } | { readonly tag: "Present"; readonly value: ExactJson };
export interface SourceIdentity { readonly repository: string; readonly revision: string; readonly path: string; readonly content_digest: string; }
export interface SourceRef extends SourceIdentity { readonly document_id: string; readonly declared_revision?: string | null; }
export interface ProfileRef { readonly identity: string; readonly revision: string; readonly content_digest: string; }
export interface TypeRef { readonly source: SourceRef; readonly definition_name: string; readonly pointer: readonly string[]; }
export interface SlotContract { readonly type_ref: TypeRef; readonly required: boolean; readonly nullable: boolean; }
export interface PathStep { readonly tag: "Field" | "Index" | "Variant"; readonly value: string; }
export type SemanticData = Record<string, unknown>;
export type DefinitionRef = { readonly source: SourceRef; readonly name: string };
export type OccurrenceRef = { readonly source: SourceRef; readonly pointer: readonly string[] };
export type IntegerDomain = { readonly tag: "Unbounded" } | { readonly tag: "Inclusive"; readonly fields: { readonly minimum: string; readonly maximum: string } };
export type IntegerForm = { readonly tag: "Number" | "IntegralDecimal" | "DecimalString" };
export interface IntegerDomainBinding { readonly name: string; readonly reference: ProfileRef; readonly range: IntegerDomain; readonly forms: readonly IntegerForm[]; }
export interface NumberModel { readonly decimals: boolean; }
export type BytesAlphabet = { readonly tag: "Standard" | "UrlSafe" | "Either" };
export type StringLengthUnit = { readonly tag: "Utf8Bytes" | "UnicodeScalars" | "Graphemes" };
export type CodepointRange = { readonly first: string; readonly last: string };
export type GraphemeRange = CodepointRange & { readonly property: { readonly tag: "Other" | "Cr" | "Lf" | "Control" | "Extend" | "Zwj" | "RegionalIndicator" | "Prepend" | "SpacingMark" | "L" | "V" | "T" | "Lv" | "Lvt" } };
export type IndicRange = CodepointRange & { readonly property: { readonly tag: "Other" | "Consonant" | "Extend" | "Linker" } };
export type GraphemeComponent = { readonly unicode_version: string; readonly uax29_revision: string; readonly cluster_profile: string };
export type GraphemeSource = { readonly role: string; readonly source: SourceIdentity };
export type GraphemeRules = { readonly reference: ProfileRef; readonly component: GraphemeComponent; readonly table_sha256: string; readonly sources: readonly GraphemeSource[]; readonly properties: readonly GraphemeRange[]; readonly extended_pictographic: readonly CodepointRange[]; readonly indic_conjunct: readonly IndicRange[] };
export type BytesPolicy = { readonly reference: ProfileRef; readonly padding_optional: boolean; readonly alphabet: BytesAlphabet; readonly strict_pad_bits: boolean; readonly wrapper: string | null };
export type CalendarRule = { readonly allow_second_60: boolean; readonly minimum_year: string; readonly maximum_year: string; readonly rejectUtcYearOutsideRange: boolean };
export type DfaTransition = { readonly from_state: string; readonly first: string; readonly last: string; readonly to_state: string };
export type DfaSpec = { readonly state_count: string; readonly initial_state: string; readonly accepting_states: readonly string[]; readonly transitions: readonly DfaTransition[] };
export type FormatRule =
  | { readonly tag: "Literal"; readonly value: string }
  | { readonly tag: "Sequence"; readonly value: readonly FormatRule[] }
  | { readonly tag: "Optional"; readonly value: FormatRule }
  | { readonly tag: "Labels"; readonly fields: { readonly separator: string; readonly min_count: string; readonly max_count: string | null; readonly total_max: string | null; readonly rule: FormatRule } }
  | { readonly tag: "Bounded"; readonly fields: { readonly unit: StringLengthUnit; readonly maximum: string; readonly rule: FormatRule } }
  | { readonly tag: "AsciiDfa"; readonly value: DfaSpec }
  | { readonly tag: "Identifier"; readonly fields: { readonly first_alphabet: string; readonly rest_alphabet: string; readonly exact_length: string | null; readonly min_length: string; readonly max_length: string | null; readonly forbidden: readonly string[] } }
  | { readonly tag: "Timestamp"; readonly value: CalendarRule }
  | { readonly tag: "AbsoluteUri"; readonly fields: { readonly max_bytes: string | null } }
  | { readonly tag: "LanguageTag"; readonly fields: { readonly grandfathered: readonly string[] } }
  | { readonly tag: "Choice"; readonly value: readonly FormatRule[] }
  | { readonly tag: "Text" }
  | { readonly tag: "Not"; readonly value: FormatRule };
export type LengthBound = { readonly unit: StringLengthUnit; readonly minimum: string | null; readonly maximum: string | null };
export type FormatUse = { readonly tag: "Named"; readonly value: string } | { readonly tag: "Inline"; readonly value: FormatRule };
export type FormatBinding = { readonly name: string; readonly reference: ProfileRef; readonly rule: FormatRule };
export type WrapperPayload = { readonly tag: "Bytes" } | { readonly tag: "Text"; readonly value: string | null };
export interface Wrapper { readonly name: string; readonly key: string; readonly payload: WrapperPayload; }
export type BooleanSpec = { readonly const_value: boolean | null; readonly default_value: boolean | null };
export type IntegerSpec = { readonly domain: string | null; readonly minimum: string | null; readonly maximum: string | null; readonly const_value: string | null; readonly enum_values: readonly string[] | null; readonly default_value: string | null };
export type DecimalBound = { readonly mantissa: string; readonly scale: string; readonly exclusive: boolean };
export type DecimalSpec = { readonly minimum: DecimalBound | null; readonly maximum: DecimalBound | null };
export type StringSpec = { readonly format: FormatUse | null; readonly lengths: readonly LengthBound[]; readonly wrapper: string | null; readonly const_value: string | null; readonly enum_values: readonly string[] | null; readonly examples: readonly string[]; readonly default_value: string | null };
export type LengthSpec = { readonly minimum: string | null; readonly maximum: string | null };
export type SealedLeaf = { readonly tag: "String"; readonly value: StringSpec } | { readonly tag: "Integer"; readonly value: IntegerSpec };
export interface SealedField { readonly key: string; readonly required: boolean; readonly leaf: SealedLeaf; }
export type SealedExtras = { readonly tag: "Reject" | "Any" };
export interface SealedForm { readonly tag: string; readonly fields: readonly SealedField[]; readonly extras: SealedExtras; }
export interface TagModel { readonly key: string; readonly format: string | null; readonly sealed: readonly SealedForm[]; }
export type VersionedSemanticProfile = {
  readonly reference: ProfileRef;
  readonly source_refs: readonly SourceIdentity[];
  readonly integer_domains: readonly IntegerDomainBinding[];
  readonly default_integer_domain: string;
  readonly numbers: NumberModel;
  readonly grapheme_rules: GraphemeRules | null;
  readonly format_bindings: readonly FormatBinding[];
  readonly bytes_policy: BytesPolicy | null;
  readonly wrappers: readonly Wrapper[];
  readonly tag: TagModel | null;
};
export type ProfilePredicate = `PR${"01" | "02" | "03" | "04" | "05" | "06" | "07" | "08" | "09" | "10" | "11" | "12" | "13" | "14" | "15" | "16"}`;
export class DeclarationPredicateFailure extends Error {
  constructor(readonly reference: unknown, readonly predicate: string, readonly location: readonly string[]) { super(`${predicate} at ${location.join(".")}`); }
}

export function checkProfileDeclaration(profile: VersionedSemanticProfile): VersionedSemanticProfile {
  const fail = (predicate: ProfilePredicate, location: readonly string[]): never => { throw new DeclarationPredicateFailure(profile.reference, predicate, location); };
  const validRef = (ref: ProfileRef): boolean => ref.identity.length > 0 && ref.revision.length > 0 && ref.content_digest.length > 0;
  if (!validRef(profile.reference) || profile.integer_domains.some(item => !validRef(item.reference)) || profile.format_bindings.some(item => !validRef(item.reference)) || profile.bytes_policy !== null && !validRef(profile.bytes_policy.reference) || profile.grapheme_rules !== null && !validRef(profile.grapheme_rules.reference)) fail("PR01", ["profile"]);
  const names = (values: readonly string[]): boolean => values.every(Boolean) && new Set(values).size === values.length;
  if (!names(profile.integer_domains.map(item => item.name))) fail("PR02", ["integer_domains"]);
  if (profile.integer_domains.some(item => item.range.tag === "Inclusive" && BigInt(item.range.fields.minimum) > BigInt(item.range.fields.maximum))) fail("PR03", ["integer_domains"]);
  if (profile.integer_domains.some(item => item.forms.length === 0)) fail("PR04", ["integer_domains"]);
  if (!profile.integer_domains.some(item => item.name === profile.default_integer_domain)) fail("PR05", ["default_integer_domain"]);
  if (!names(profile.format_bindings.map(item => item.name))) fail("PR06", ["format_bindings"]);
  const wellFormed = (rule: FormatRule): boolean => {
    if (rule.tag === "Labels") return rule.fields.separator.length > 0 && wellFormed(rule.fields.rule);
    if (rule.tag === "Sequence" || rule.tag === "Choice") return rule.value.every(wellFormed);
    if (rule.tag === "Optional" || rule.tag === "Not") return wellFormed(rule.value);
    if (rule.tag === "Bounded") return wellFormed(rule.fields.rule);
    if (rule.tag === "Identifier") return rule.fields.first_alphabet.length > 0 && rule.fields.rest_alphabet.length > 0 && (rule.fields.max_length === null || BigInt(rule.fields.min_length) <= BigInt(rule.fields.max_length));
    if (rule.tag === "AsciiDfa") return BigInt(rule.value.state_count) > 0n && BigInt(rule.value.initial_state) < BigInt(rule.value.state_count) && rule.value.accepting_states.every(state => BigInt(state) < BigInt(rule.value.state_count)) && rule.value.transitions.every(transition => BigInt(transition.from_state) < BigInt(rule.value.state_count) && BigInt(transition.to_state) < BigInt(rule.value.state_count) && BigInt(transition.first) <= BigInt(transition.last) && BigInt(transition.last) < 128n);
    if (rule.tag === "Timestamp") return BigInt(rule.value.minimum_year) <= BigInt(rule.value.maximum_year) && BigInt(rule.value.maximum_year) <= 9999n;
    return true;
  };
  if (profile.format_bindings.some(item => !wellFormed(item.rule))) fail("PR07", ["format_bindings"]);
  if (!names(profile.wrappers.map(item => item.name)) || !names(profile.wrappers.map(item => item.key))) fail("PR08", ["wrappers"]);
  if (profile.wrappers.some(item => {
    if (item.payload.tag !== "Text" || item.payload.value === null) return false;
    const formatName = item.payload.value;
    return !profile.format_bindings.some(format => format.name === formatName);
  })) fail("PR09", ["wrappers"]);
  if (profile.bytes_policy?.wrapper !== null && profile.bytes_policy !== null && !profile.wrappers.some(item => item.name === profile.bytes_policy!.wrapper && item.payload.tag === "Bytes")) fail("PR10", ["bytes_policy", "wrapper"]);
  if (profile.tag) {
    if (!profile.tag.key || profile.wrappers.some(item => item.key === profile.tag!.key)) fail("PR11", ["tag", "key"]);
    if (profile.tag.format !== null && !profile.format_bindings.some(item => item.name === profile.tag!.format)) fail("PR12", ["tag", "format"]);
    if (!names(profile.tag.sealed.map(item => item.tag)) || profile.tag.sealed.some(form => profile.tag!.format !== null && !recognizeFormat(profile.format_bindings.find(binding => binding.name === profile.tag!.format)!.rule, form.tag))) fail("PR13", ["tag", "sealed"]);
    if (profile.tag.sealed.some(form => !names(form.fields.map(field => field.key)) || form.fields.some(field => field.key === profile.tag!.key || profile.wrappers.some(wrapper => wrapper.key === field.key)))) fail("PR14", ["tag", "sealed", "fields"]);
    if (profile.tag.sealed.some(form => form.fields.some(field => {
      if (field.leaf.tag === "Integer") {
        const domainName = field.leaf.value.domain;
        return domainName !== null && !profile.integer_domains.some(domain => domain.name === domainName);
      }
      const spec = field.leaf.value;
      return spec.wrapper !== null && !profile.wrappers.some(wrapper => wrapper.name === spec.wrapper && wrapper.payload.tag === "Text")
        || spec.format?.tag === "Named" && !profile.format_bindings.some(binding => binding.name === spec.format!.value)
        || spec.format?.tag === "Inline" && !wellFormed(spec.format.value)
        || spec.lengths.some(bound => bound.minimum !== null && bound.maximum !== null && BigInt(bound.minimum) > BigInt(bound.maximum));
    }))) fail("PR15", ["tag", "sealed", "fields"]);
  }
  const orderedRanges = (rows: readonly CodepointRange[]): boolean => rows.every(row => BigInt(row.first) <= BigInt(row.last));
  if (profile.grapheme_rules && (!orderedRanges(profile.grapheme_rules.properties) || !orderedRanges(profile.grapheme_rules.extended_pictographic) || !orderedRanges(profile.grapheme_rules.indic_conjunct))) fail("PR16", ["grapheme_rules"]);
  return deepFreeze(profile);
}

export type ProfileWireFailure =
  | { readonly tag: "UnknownField" | "MissingField" | "UnknownTag"; readonly value: string }
  | { readonly tag: "Syntax"; readonly value: string };
export class ProfileWireError extends Error {
  constructor(readonly failure: ProfileWireFailure) {
    super(`${failure.tag}:${failure.value}`);
  }
}
function profileObject(value: unknown, keys: readonly string[]): Record<string, any> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new ProfileWireError({ tag: "Syntax", value: "object" });
  const record = value as Record<string, any>;
  const unknown = Object.keys(record).find(key => !keys.includes(key));
  if (unknown !== undefined) throw new ProfileWireError({ tag: "UnknownField", value: unknown });
  const missing = keys.find(key => !Object.hasOwn(record, key));
  if (missing !== undefined) throw new ProfileWireError({ tag: "MissingField", value: missing });
  return record;
}
function profileTag(value: unknown, units: readonly string[], payloads: readonly string[] = []): Record<string, any> {
  const candidate = value as { readonly tag?: unknown };
  if (typeof candidate?.tag !== "string" || !units.includes(candidate.tag) && !payloads.includes(candidate.tag)) {
    throw new ProfileWireError({ tag: "UnknownTag", value: String(candidate?.tag) });
  }
  return profileObject(value, payloads.includes(candidate.tag) ? ["tag", "value"] : ["tag"]);
}
function profileReference(value: unknown): void { profileObject(value, ["identity", "revision", "content_digest"]); }
function profileFormatRule(value: unknown): void {
  const candidate = value as { readonly tag?: unknown };
  const units = ["Text"];
  const values = ["Literal", "Optional", "Choice", "Sequence", "Not", "AsciiDfa", "Timestamp"];
  const fields = ["Labels", "Bounded", "Identifier", "AbsoluteUri", "LanguageTag"];
  if (units.includes(String(candidate?.tag))) { profileTag(value, units); return; }
  if (values.includes(String(candidate?.tag))) {
    const row = profileTag(value, [], values);
    if (candidate.tag === "Optional" || candidate.tag === "Not") profileFormatRule(row.value);
    if (candidate.tag === "Choice" || candidate.tag === "Sequence") {
      if (!Array.isArray(row.value)) throw new ProfileWireError({ tag: "Syntax", value: "format rule array" });
      row.value.forEach(profileFormatRule);
    }
    return;
  }
  if (fields.includes(String(candidate?.tag))) {
    const row = profileObject(value, ["tag", "fields"]);
    const names = candidate.tag === "Labels" ? ["separator", "min_count", "max_count", "total_max", "rule"]
      : candidate.tag === "Bounded" ? ["unit", "maximum", "rule"]
      : candidate.tag === "Identifier" ? ["first_alphabet", "rest_alphabet", "exact_length", "min_length", "max_length", "forbidden"]
      : candidate.tag === "AbsoluteUri" ? ["max_bytes"] : ["grandfathered"];
    profileObject(row.fields, names);
    if (candidate.tag === "Labels" || candidate.tag === "Bounded") profileFormatRule(row.fields.rule);
    return;
  }
  throw new ProfileWireError({ tag: "UnknownTag", value: String(candidate?.tag) });
}
function profileStringSpec(value: unknown): void { profileObject(value, ["format", "lengths", "wrapper", "const_value", "enum_values", "examples", "default_value"]); }
function profileIntegerSpec(value: unknown): void { profileObject(value, ["domain", "minimum", "maximum", "const_value", "enum_values", "default_value"]); }
export function decodeVersionedProfileWire(value: unknown): VersionedSemanticProfile {
  const profile = profileObject(value, ["reference", "source_refs", "integer_domains", "default_integer_domain", "numbers", "grapheme_rules", "format_bindings", "bytes_policy", "wrappers", "tag"]) as VersionedSemanticProfile;
  profileReference(profile.reference);
  if (!Array.isArray(profile.source_refs) || !Array.isArray(profile.integer_domains) || !Array.isArray(profile.format_bindings) || !Array.isArray(profile.wrappers)) throw new ProfileWireError({ tag: "Syntax", value: "profile arrays" });
  profile.source_refs.forEach(source => profileObject(source, ["repository", "revision", "path", "content_digest"]));
  profile.integer_domains.forEach(domain => {
    profileObject(domain, ["name", "reference", "range", "forms"]); profileReference(domain.reference);
    const range = domain.range as { readonly tag?: unknown };
    if (range?.tag === "Unbounded") profileTag(range, ["Unbounded"]);
    else if (range?.tag === "Inclusive") profileObject(profileObject(range, ["tag", "fields"]).fields, ["minimum", "maximum"]);
    else throw new ProfileWireError({ tag: "UnknownTag", value: String(range?.tag) });
    if (!Array.isArray(domain.forms)) throw new ProfileWireError({ tag: "Syntax", value: "integer forms" });
    domain.forms.forEach((form: unknown) => profileTag(form, ["Number", "IntegralDecimal", "DecimalString"]));
  });
  profileObject(profile.numbers, ["decimals"]);
  if (profile.grapheme_rules !== null) {
    const rules = profileObject(profile.grapheme_rules, ["reference", "component", "table_sha256", "sources", "properties", "extended_pictographic", "indic_conjunct"]);
    profileReference(rules.reference); profileObject(rules.component, ["unicode_version", "uax29_revision", "cluster_profile"]);
    if (!Array.isArray(rules.sources) || !Array.isArray(rules.properties) || !Array.isArray(rules.extended_pictographic) || !Array.isArray(rules.indic_conjunct)) throw new ProfileWireError({ tag: "Syntax", value: "grapheme arrays" });
    rules.sources.forEach((source: unknown) => profileObject(source, ["role", "source"]));
    rules.properties.forEach((range: unknown) => { const row = profileObject(range, ["first", "last", "property"]); profileTag(row.property, ["Other", "Cr", "Lf", "Control", "Extend", "Zwj", "RegionalIndicator", "Prepend", "SpacingMark", "L", "V", "T", "Lv", "Lvt"]); });
    rules.extended_pictographic.forEach((range: unknown) => profileObject(range, ["first", "last"]));
    rules.indic_conjunct.forEach((range: unknown) => { const row = profileObject(range, ["first", "last", "property"]); profileTag(row.property, ["Other", "Consonant", "Extend", "Linker"]); });
  }
  profile.format_bindings.forEach(binding => { profileObject(binding, ["name", "reference", "rule"]); profileReference(binding.reference); profileFormatRule(binding.rule); });
  if (profile.bytes_policy !== null) {
    const policy = profileObject(profile.bytes_policy, ["reference", "padding_optional", "alphabet", "strict_pad_bits", "wrapper"]);
    profileReference(policy.reference); profileTag(policy.alphabet, ["Standard", "UrlSafe", "Either"]);
  }
  profile.wrappers.forEach(wrapper => {
    const row = profileObject(wrapper, ["name", "key", "payload"]);
    const payload = row.payload as { readonly tag?: unknown };
    if (payload?.tag === "Bytes") profileTag(payload, ["Bytes"]);
    else if (payload?.tag === "Text") profileTag(payload, [], ["Text"]);
    else throw new ProfileWireError({ tag: "UnknownTag", value: String(payload?.tag) });
  });
  if (profile.tag !== null) {
    const tag = profileObject(profile.tag, ["key", "format", "sealed"]);
    if (!Array.isArray(tag.sealed)) throw new ProfileWireError({ tag: "Syntax", value: "sealed forms" });
    tag.sealed.forEach((form: unknown) => {
      const row = profileObject(form, ["tag", "fields", "extras"]);
      profileTag(row.extras, ["Reject", "Any"]);
      if (!Array.isArray(row.fields)) throw new ProfileWireError({ tag: "Syntax", value: "sealed fields" });
      row.fields.forEach((field: unknown) => {
        const member = profileObject(field, ["key", "required", "leaf"]);
        const leaf = profileObject(member.leaf, ["tag", "value"]);
        if (leaf.tag === "String") profileStringSpec(leaf.value);
        else if (leaf.tag === "Integer") profileIntegerSpec(leaf.value);
        else throw new ProfileWireError({ tag: "UnknownTag", value: String(leaf.tag) });
      });
    });
  }
  return checkProfileDeclaration(structuredClone(profile));
}

export type CanonicalProfileSource = { readonly repository: string; readonly revision: string; readonly path: string; readonly sha256: string };
export type CanonicalProfileArtifact = { readonly profile: VersionedSemanticProfile };
export function decodeCanonicalProfileArtifact(expected: ProfileRef, sourceRefs: readonly SourceIdentity[], artifactText: string, expectedProfileBytes: string): VersionedSemanticProfile {
  requireEvidence(artifactText === expectedProfileBytes, "profile artifact bytes");
  let parsed: unknown;
  try { parsed = JSON.parse(artifactText); } catch { throw new SemanticEvidenceError("canonical artifact JSON"); }
  requireEvidence(parsed !== null && typeof parsed === "object" && !Array.isArray(parsed), "profile artifact");
  const record = parsed as Record<string, unknown>;
  requireEvidence(Object.keys(record).length === 1 && Object.hasOwn(record, "profile"), "profile artifact fields");
  const decoded = decodeVersionedProfileWire(record.profile);
  requireEvidence(same(decoded.reference, expected), "profile reference");
  requireEvidence(same(decoded.source_refs, sourceRefs), "profile sources");
  return decoded;
}
export type FieldSpec = { readonly wire_name: string; readonly slot: SlotContract; readonly origin: OccurrenceRef };
export type ElementContract = { readonly type_ref: TypeRef; readonly nullable: boolean };
export type ExtraMembers = { readonly tag: "Reject" } | { readonly tag: "Allow"; readonly fields: { readonly key_format: FormatUse | null; readonly value: ElementContract } };
export type ProductSpec = { readonly fields: readonly FieldSpec[]; readonly extras: ExtraMembers };
export type ArraySpec = { readonly item: ElementContract; readonly min_length: string | null; readonly max_length: string | null };
export type ValueKind = { readonly tag: "Null" | "Boolean" | "Number" | "String" | "Array" | "Object" };
export type MemberTest = { readonly tag: "Absent" } | { readonly tag: "Format"; readonly value: string };
export type BranchSelector = { readonly tag: "InternalTag" } | { readonly tag: "MemberShape"; readonly value: readonly (readonly [string, MemberTest])[] } | { readonly tag: "Kind"; readonly value: ValueKind } | { readonly tag: "Otherwise" };
export type UnionBranch = { readonly target: TypeRef; readonly wire_tag: string; readonly selector: BranchSelector; readonly origin: OccurrenceRef };
export type UnionSpec = { readonly branches: readonly UnionBranch[] };
export type SealedRefinement = { readonly key: string; readonly leaf: SealedLeaf };
export type UnknownKind = { readonly tag: "Any" | "OrdinaryObject" };
export type TypeShape =
  | { readonly tag: "Boolean"; readonly value: BooleanSpec }
  | { readonly tag: "Integer"; readonly value: IntegerSpec }
  | { readonly tag: "Decimal"; readonly value: DecimalSpec }
  | { readonly tag: "String"; readonly value: StringSpec }
  | { readonly tag: "Bytes"; readonly value: LengthSpec }
  | { readonly tag: "Product"; readonly value: ProductSpec }
  | { readonly tag: "Array"; readonly value: ArraySpec }
  | { readonly tag: "TaggedUnion"; readonly value: UnionSpec }
  | { readonly tag: "Sealed"; readonly fields: { readonly tag: string; readonly refinements: readonly SealedRefinement[] } }
  | { readonly tag: "Never" }
  | { readonly tag: "Unknown"; readonly value: UnknownKind }
  | { readonly tag: "Unit" }
  | { readonly tag: "Alias"; readonly fields: { readonly target: TypeRef; readonly reference_text: string } }
  | { readonly tag: "RawBody"; readonly fields: { readonly encoding: string } }
  | { readonly tag: "Opaque"; readonly fields: { readonly type_name: string } };
export type TypeNode = { readonly reference: TypeRef; readonly shape: TypeShape; readonly description: string | null; readonly attributes: readonly OccurrenceRef[]; readonly extensions: readonly OccurrenceRef[] };
export type SemanticBasis = { readonly profile: VersionedSemanticProfile; readonly sources: readonly SourceRef[] };
export type TypePair = { readonly source: SlotContract; readonly destination: SlotContract; readonly source_tag: string | null };
export type InclusionCertificate = { readonly basis: SemanticBasis; readonly source: SlotContract; readonly destination: SlotContract; readonly root: string; readonly empty_types: readonly TypeRef[]; readonly pairs: readonly { readonly pair: TypePair; readonly source_shape: TypeShape; readonly destination_shape: TypeShape; readonly rule: { readonly tag: string }; readonly children: readonly string[] }[] };
export type ProjectionAssumption = { readonly tag: "Present"; readonly value: readonly PathStep[] } | { readonly tag: "NonNull"; readonly value: readonly PathStep[] } | { readonly tag: "Variant"; readonly fields: { readonly path: readonly PathStep[]; readonly tag: string } } | { readonly tag: "IndexPresent"; readonly fields: { readonly path: readonly PathStep[]; readonly index: string } };
export type ProjectionCertificate = { readonly profile: ProfileRef; readonly source_refs: readonly SourceRef[]; readonly source: SlotContract; readonly path: readonly PathStep[]; readonly assumptions: readonly ProjectionAssumption[]; readonly destination: SlotContract };
export type FunctionRef = { readonly identity: string; readonly revision: string; readonly content_digest: string };
export type ProducerRef = { readonly tag: "Initial"; readonly value: string } | { readonly tag: "InvocationOutcome"; readonly fields: { readonly site: string; readonly outcome: string; readonly port: string } };
export type ValueRef = { readonly producer: ProducerRef; readonly path: readonly PathStep[] };
export type SourceConstraint = { readonly tag: "AnyCompatible" } | { readonly tag: "InitialOnly"; readonly fields: { readonly input: string; readonly path: readonly PathStep[] } } | { readonly tag: "ProducedBy"; readonly fields: { readonly site: string; readonly outcome: string; readonly port: string; readonly path: readonly PathStep[] } };
export type ResourceLotRef = { readonly tag: "Initial"; readonly value: string } | { readonly tag: "Produced"; readonly fields: { readonly site: string; readonly outcome: string; readonly production: string } };
export type ResourceProducer = { readonly tag: "Initial"; readonly fields: { readonly identity: string; readonly revision: string } } | { readonly tag: "InvocationOutcome"; readonly fields: { readonly site: string; readonly outcome: string } };
export type ResourceLot = { readonly id: string; readonly token_type: TypeRef; readonly producer: ResourceProducer; readonly revision: string; readonly quantity: string; readonly provenance: string };
export type ResourceRequirement = { readonly id: string; readonly token_type: TypeRef; readonly mode: { readonly tag: "Read" | "Consume" }; readonly multiplicity: string; readonly required_revision: string; readonly identity: { readonly tag: "Any" } | { readonly tag: "Exactly"; readonly value: ResourceProducer } };
export type ResourceProduction = { readonly id: string; readonly token_type: TypeRef; readonly revision: string; readonly quantity: string; readonly provenance: string };
export type InitialInput = { readonly id: string; readonly contract: SlotContract; readonly source: { readonly tag: "Argument" } | { readonly tag: "SuppliedValue"; readonly value: ExactSlot }; readonly resource: string | null };
export type InputPort = { readonly id: string; readonly contract: SlotContract; readonly source_constraint: SourceConstraint; readonly resource_requirement: string | null };
export type OutputPort = { readonly id: string; readonly contract: SlotContract; readonly resource_production: string | null };
export type OutcomeContract = { readonly id: string; readonly form: { readonly tag: "Success" | "DeclaredFailure" }; readonly value_ports: readonly OutputPort[]; readonly produced_resources: readonly ResourceProduction[] };
export type GuardArm = { readonly tag: "Present" | "Absent" | "Null" | "UnknownVariant" | "Accepted" | "Rejected" } | { readonly tag: "Variant"; readonly value: string };
export type FailureOrigin = { readonly tag: "Function"; readonly fields: { readonly function: FunctionRef; readonly outcome: string } } | { readonly tag: "Guard"; readonly fields: { readonly guard: string; readonly arm: GuardArm } };
export type FunctionSignature = { readonly reference: FunctionRef; readonly form: { readonly tag: "Pure" | "DeclaredTransform" } | { readonly tag: "Operation"; readonly value: DefinitionRef }; readonly effect: { readonly tag: "PureFunction" | "HttpRequestResponse" | "DataOnly" }; readonly inputs: readonly InputPort[]; readonly outcomes: readonly OutcomeContract[]; readonly resource_inputs: readonly ResourceRequirement[]; readonly assumption_ref: string; readonly handles_failure: FailureOrigin | null };
export type DeclaredGuard = { readonly id: string; readonly source_type: TypeRef; readonly path: readonly PathStep[]; readonly kind: { readonly tag: "Presence" | "Variants" } | { readonly tag: "Validate"; readonly value: SlotContract } };
export type FieldPresence = { readonly tag: "Required" | "Optional" };
export type FieldConstraint = { readonly field: string; readonly source: SourceConstraint; readonly presence: FieldPresence };
export type ConstructionRule = { readonly identity: string; readonly type_ref: TypeRef; readonly nested_fields: readonly (readonly [string, string])[]; readonly field_constraints: readonly FieldConstraint[] };
export type InvocationDomain = { readonly identity: string; readonly revision: string; readonly sites: readonly { readonly id: string; readonly function: FunctionRef }[]; readonly permitted_projections: readonly { readonly source_type: TypeRef; readonly path: readonly PathStep[] }[]; readonly permitted_constructions: readonly ConstructionRule[]; readonly permitted_transforms: readonly FunctionRef[]; readonly guards: readonly DeclaredGuard[] };
export type ResourceGoal = { readonly lot: ResourceLotRef; readonly multiplicity: string; readonly revision: string };
export type GoalPort = { readonly id: string; readonly contract: SlotContract; readonly source_constraint: SourceConstraint };
export type FailureEmbedding = { readonly id: string; readonly origin: FailureOrigin; readonly contract: SlotContract; readonly final_resources: readonly ResourceGoal[] };
export type SearchBounds = { readonly max_expanded_states: string; readonly max_binding_candidates: string; readonly max_type_obligations: string; readonly max_branch_nodes: string; readonly max_sample_length: string; readonly resource_bounds: { readonly max_bindings: string; readonly max_search_steps: string; readonly max_tokens: string } | null };
export type CompositionInput = { readonly identity: string; readonly revision: string; readonly basis: SemanticBasis; readonly signatures: readonly FunctionSignature[]; readonly initial_inputs: readonly InitialInput[]; readonly initial_resources: readonly ResourceLot[]; readonly goal: { readonly outputs: readonly GoalPort[]; readonly failures: readonly FailureEmbedding[]; readonly final_resources: readonly ResourceGoal[] }; readonly invocation_domain: InvocationDomain; readonly allowed_effects: readonly { readonly tag: "PureFunction" | "HttpRequestResponse" | "DataOnly" }[]; readonly explicit_order: readonly (readonly [string, string])[]; readonly selection_policy: { readonly tag: "RequireUnique" | "AnyFeasible" } | null; readonly bounds: SearchBounds };
export type BindingExpr = { readonly tag: "Source"; readonly fields: { readonly value: ValueRef; readonly projection: ProjectionCertificate; readonly compatibility: { readonly tag: "Inclusion"; readonly value: InclusionCertificate } | { readonly tag: "SuppliedValue"; readonly fields: { readonly value: ExactSlot } } } } | { readonly tag: "Product"; readonly fields: { readonly construction: string; readonly type_ref: TypeRef; readonly fields: readonly (readonly [string, BindingExpr])[] } };
export type InvocationPlan = { readonly site: string; readonly function: FunctionRef; readonly bindings: readonly (readonly [string, BindingExpr])[]; readonly resources: readonly { readonly requirement: string; readonly lot: ResourceLotRef; readonly inclusion: InclusionCertificate }[] };
export type ReturnPlan = { readonly tag: "Success"; readonly value: readonly (readonly [string, BindingExpr])[] } | { readonly tag: "Failure"; readonly fields: { readonly embedding: string; readonly value: BindingExpr } };
export type PlanTree = { readonly rank: string; readonly node: { readonly tag: "Return"; readonly value: ReturnPlan } | { readonly tag: "Invoke"; readonly fields: { readonly invocation: InvocationPlan; readonly arms: readonly (readonly [string, PlanTree])[]; readonly empty_outcomes: readonly string[] } } | { readonly tag: "Guard"; readonly fields: { readonly guard: string; readonly inspected: ValueRef; readonly arms: readonly (readonly [GuardArm, PlanTree])[] } } };
export type CompositionPlan = { readonly input_identity: string; readonly input_revision: string; readonly root: PlanTree };
export type TraceStep = { readonly tag: "Invocation"; readonly fields: { readonly invocation: InvocationPlan; readonly outcome: string } } | { readonly tag: "Guard"; readonly fields: { readonly guard: string; readonly inspected: ValueRef; readonly arm: GuardArm } };
export type BranchTrace = { readonly steps: readonly TraceStep[]; readonly terminal: ReturnPlan };
export type AvailableValue = { readonly producer: ProducerRef; readonly contract: SlotContract; readonly resource: ResourceLotRef | null };
export type BranchFact = { readonly guard: string; readonly inspected: ValueRef; readonly arm: GuardArm; readonly refinement: SlotContract | null; readonly assumptions: readonly ProjectionAssumption[]; readonly exact: ExactSlot | null };
export type SearchState = { readonly available: readonly AvailableValue[]; readonly used_sites: readonly string[]; readonly used_guards: readonly string[]; readonly facts: readonly BranchFact[]; readonly trace: readonly TraceStep[]; readonly pending_failure: FailureOrigin | null };
export type ColoredToken = { readonly target: string; readonly index: string; readonly revision: string; readonly kind: { readonly tag: "Input" | "Output" | "Failure" | "Effect" | "Observation" | "Accepted" } };
export type Marking = { readonly places: readonly (readonly [string, readonly ColoredToken[]])[] };
export type TypedPlace = { readonly identity: string; readonly token_type: string; readonly revision: string };
export type TypedTransition = { readonly identity: string; readonly input_places: readonly string[]; readonly output_places: readonly string[]; readonly failure_places: readonly string[]; readonly revision: string };
export type InputBinding = { readonly transition_id: string; readonly name: string; readonly place: string; readonly token_type: string; readonly identity: string; readonly provenance: string; readonly multiplicity: string; readonly mode: { readonly tag: "Read" | "Consume" }; readonly required_revision: string };
export type GoalPredicate = { readonly tag: "Not"; readonly value: GoalPredicate } | { readonly tag: "And" | "Or"; readonly value: readonly [GoalPredicate, GoalPredicate] } | { readonly tag: "PlaceHasAtLeast"; readonly fields: { readonly place: string; readonly count: string } } | { readonly tag: "PlaceHasToken"; readonly fields: { readonly place: string; readonly target: string; readonly index: string; readonly revision: string } };
export type SolverInput = { readonly places: readonly TypedPlace[]; readonly transitions: readonly TypedTransition[]; readonly bindings: readonly InputBinding[]; readonly goal: GoalPredicate; readonly graph: { readonly places: readonly string[]; readonly transitions: readonly string[]; readonly edges: readonly (readonly [string, string])[]; readonly revision: string }; readonly marking: Marking; readonly bound: { readonly target_identity: string; readonly index: string; readonly revision: string; readonly max_bindings: string; readonly max_search_steps: string } };
export type ResourceLotCorrespondence = { readonly lot: ResourceLotRef; readonly place: string; readonly producer: ResourceProducer; readonly token_target: string; readonly token_type: string; readonly revision: string; readonly quantity: string; readonly provenance: string };
export type ValueCorrespondence = { readonly producer: ProducerRef; readonly place: string; readonly token_target: string; readonly revision: string };
export type ResourceCorrespondence = { readonly lots: readonly ResourceLotCorrespondence[]; readonly values: readonly ValueCorrespondence[]; readonly normalized_bindings: readonly { readonly transition: string; readonly lot: ResourceLotRef; readonly read: string; readonly consume: string; readonly required_revision: string }[]; readonly execution_order: readonly string[] };
export type ReachabilityWitness = { readonly path: readonly string[]; readonly final_marking: Marking };
export type ClosureWitness = { readonly explored_markings: readonly Marking[]; readonly steps: string; readonly frontier: readonly Marking[] };
export type ResourceTraceCertificate = { readonly trace: BranchTrace; readonly lowering: SolverInput; readonly correspondence: ResourceCorrespondence; readonly reachability: ReachabilityWitness; readonly acyclicity: ClosureWitness; readonly value_sources: readonly (readonly [ProducerRef, ExactSlot])[] };
export type CompositionWitness = { readonly input_snapshot: CompositionInput; readonly initial_membership: readonly (readonly [string, ExactSlot])[]; readonly resource_traces: readonly ResourceTraceCertificate[] };
export type ChoiceSkeleton = { readonly tag: "Invoke"; readonly fields: { readonly invocation: InvocationPlan; readonly outcomes: readonly string[]; readonly empty_outcomes: readonly string[] } } | { readonly tag: "Guard"; readonly fields: { readonly guard: string; readonly inspected: ValueRef; readonly arms: readonly GuardArm[] } };
export type CounterexampleCertificate = { readonly basis: SemanticBasis; readonly source: SlotContract; readonly destination: SlotContract; readonly value: ExactSlot; readonly destination_failure: { readonly type_ref: TypeRef; readonly definition_ref: DefinitionRef; readonly origin: OccurrenceRef; readonly value_path: readonly PathStep[]; readonly condition: { readonly tag: string; readonly value?: string }; readonly observed: string; readonly reference_trace: readonly TypeRef[] } };
export type ConnectionFailure = { readonly value: ValueRef | null; readonly destination: SlotContract; readonly counterexample: CounterexampleCertificate };
export type TerminalAssessment = { readonly tag: "Feasible"; readonly value: ResourceTraceCertificate } | { readonly tag: "EmptyValues"; readonly value: readonly ProducerRef[] } | { readonly tag: "Unknown"; readonly value: readonly unknown[] } | { readonly tag: "ResourceUnreachable"; readonly fields: { readonly trace: BranchTrace; readonly lowering: SolverInput; readonly correspondence: ResourceCorrespondence; readonly closure: ClosureWitness } } | { readonly tag: "RejectedLowering"; readonly fields: { readonly trace: BranchTrace; readonly reason: string } };
export type ClosedSearchState = { readonly state: SearchState; readonly terminals: readonly { readonly terminal: ReturnPlan; readonly assessment: TerminalAssessment }[]; readonly choices: readonly { readonly choice: ChoiceSkeleton; readonly children: readonly string[] }[]; readonly rejected_connections: readonly ConnectionFailure[]; readonly missing_supply: readonly { readonly site: string | null; readonly port: string; readonly contract: SlotContract }[] };
export type CompositionClosureWitness = { readonly input_snapshot: CompositionInput; readonly root: string; readonly states: readonly ClosedSearchState[] };
export type RawComposition = { readonly plan: CompositionPlan; readonly witness: CompositionWitness; readonly selection: { readonly tag: "AnyFeasible" } | { readonly tag: "Unique"; readonly fields: { readonly closure: CompositionClosureWitness; readonly canonical_plan: string } } };
export type SignatureCompositionEvidence = { readonly problem: CompositionInput; readonly derivation: RawComposition };
export type ValueGraph = { readonly profile: VersionedSemanticProfile; readonly nodes: readonly TypeNode[] };
export type DynamicValue = null | boolean | bigint | LosslessNumber | string | readonly DynamicValue[] | { readonly [key: string]: DynamicValue };
export class DecimalValue extends LosslessNumber {
  constructor(text: string) { super(text); Object.freeze(this); }
}
export interface ValueFailure { readonly type: TypeRef; readonly path: readonly (string | bigint)[]; readonly condition: string; readonly observed: string; readonly referenceTrace?: readonly TypeRef[]; }
export class SemanticValueError extends Error {
  constructor(readonly failure: ValueFailure) { super(`${failure.type.source.path}#${failure.type.definition_name}: ${failure.path.join(".")}: ${failure.condition}`); }
}
export class SemanticEvidenceError extends Error {
  constructor(readonly condition: string, readonly path: string = "$") { super(`${path}: ${condition}`); }
}
export function requireEvidence(condition: unknown, detail: string, path = "$"): asserts condition {
  if (!condition) throw new SemanticEvidenceError(detail, path);
}
export function same(left: unknown, right: unknown): boolean {
  if (left === right) return true;
  if (Array.isArray(left) && Array.isArray(right)) return left.length === right.length && left.every((v, i) => same(v, right[i]));
  if (left === null || right === null || typeof left !== "object" || typeof right !== "object") return false;
  const a = left as Record<string, unknown>, b = right as Record<string, unknown>, keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every(k => Object.hasOwn(b, k) && same(a[k], b[k]));
}
export function deepFreeze<T>(value: T): T {
  if (value !== null && typeof value === "object" && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) deepFreeze(child);
    Object.freeze(value);
  }
  return value;
}

const memberOrder = Symbol("exact object member order");
export function preserveObjectOrder<T extends object>(value: T, order: readonly string[]): T {
  requireEvidence(new Set(order).size === order.length && order.length === Object.keys(value).length
    && order.every(key => Object.hasOwn(value, key)), "exact object member order");
  Object.defineProperty(value, memberOrder, { value: Object.freeze([...order]), enumerable: false });
  return value;
}
function orderedKeys(value: object): readonly string[] {
  const order = (value as { readonly [memberOrder]?: unknown })[memberOrder];
  if (order === undefined) return Object.keys(value);
  requireEvidence(Array.isArray(order) && order.every(key => typeof key === "string")
    && new Set(order).size === order.length && order.length === Object.keys(value).length
    && order.every(key => Object.hasOwn(value, key)), "exact object member order");
  return order;
}
export function orderedObject(members: readonly { readonly key: string; readonly value: ExactJson }[], source: object): ExactJson {
  const order = orderedKeys(source), byKey = new Map(members.map(item => [item.key, item]));
  return { tag: "Object", members: [...order, ...members.map(item => item.key).filter(key => !order.includes(key))]
    .filter(key => byKey.has(key)).map(key => byKey.get(key)!) };
}
export function hashUtf8(text: string): string { return Array.from(sha256(new TextEncoder().encode(text)), n => n.toString(16).padStart(2, "0")).join(""); }
export function parseLossless(text: string): unknown {
  const convert = (value: ExactJson): unknown => {
    switch (value.tag) {
      case "Null": return null;
      case "Bool": case "String": return value.value;
      case "Integer": return new LosslessNumber(value.value);
      case "Decimal": return new DecimalValue(value.text);
      case "Array": return value.items.map(convert);
      case "Object": { const object: SemanticData = Object.create(null); for (const m of value.members) object[m.key] = convert(m.value); return object; }
    }
  };
  return convert(parseExact(text));
}
export function toExact(value: unknown): ExactJson {
  if (value === null) return { tag: "Null" };
  if (typeof value === "boolean") return { tag: "Bool", value };
  if (typeof value === "string") { requireEvidence(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value), "Unicode scalar string"); return { tag: "String", value }; }
  if (typeof value === "bigint") return { tag: "Integer", value: value.toString() };
  if (value instanceof DecimalValue) return { tag: "Decimal", text: value.value };
  if (value instanceof LosslessNumber) { requireEvidence(/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/.test(value.value), "exact JSON number"); return /^-?(0|[1-9][0-9]*)$/.test(value.value) ? { tag: "Integer", value: BigInt(value.value).toString() } : { tag: "Decimal", text: value.value }; }
  if (typeof value === "number") { requireEvidence(Number.isSafeInteger(value), "use bigint for an exact integer"); return { tag: "Integer", value: BigInt(value).toString() }; }
  requireEvidence(typeof value === "object", "finite JSON value");
  const active = new Set<object>();
  const convert = (value: object): ExactJson => {
    requireEvidence(!active.has(value), "finite acyclic value"); active.add(value);
    const child = (item: unknown): ExactJson => item !== null && typeof item === "object" && !(item instanceof LosslessNumber) ? convert(item) : toExact(item);
    try {
      if (Array.isArray(value)) return { tag: "Array", items: value.map(child) };
      requireEvidence(Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null, "plain JSON object");
      const descriptors = Object.getOwnPropertyDescriptors(value);
      requireEvidence(Object.getOwnPropertySymbols(value).every(symbol => symbol === memberOrder) && Object.values(descriptors).every(d => "value" in d), "JSON data properties");
      return { tag: "Object", members: orderedKeys(value).map(key => { toExact(key); return { key, value: child((value as Record<string, unknown>)[key]) }; }) };
    } finally { active.delete(value); }
  };
  return convert(value);
}
export function fromExact(value: ExactJson): DynamicValue {
  switch (value.tag) {
    case "Null": return null;
    case "Bool": case "String": return value.value;
    case "Integer": return BigInt(value.value);
    case "Decimal": return new DecimalValue(value.text);
    case "Array": return Object.freeze(value.items.map(fromExact));
    case "Object": {
      const out: Record<string, DynamicValue> = Object.create(null);
      for (const { key, value: item } of value.members) { requireEvidence(!Object.hasOwn(out, key), "duplicate member"); out[key] = fromExact(item); }
      return Object.freeze(preserveObjectOrder(out, value.members.map(item => item.key)));
    }
  }
}
export function parseExact(text: string): ExactJson {
  const errors: ParseError[] = [], root = parseTree(text, errors, { disallowComments: true, allowTrailingComma: false, allowEmptyContent: false });
  requireEvidence(root && errors.length === 0, "strict JSON syntax");
  const convert = (node: JsonNode): ExactJson => {
    switch (node.type) {
      case "null": return { tag: "Null" };
      case "boolean": { const value: unknown = node.value; requireEvidence(typeof value === "boolean", "boolean node"); return { tag: "Bool", value }; }
      case "string": { const value: unknown = node.value; requireEvidence(typeof value === "string", "string node"); return toExact(value); }
      case "number": { const source = text.slice(node.offset, node.offset + node.length); return /^-?(0|[1-9][0-9]*)$/.test(source) ? { tag: "Integer", value: BigInt(source).toString() } : { tag: "Decimal", text: source }; }
      case "array": return { tag: "Array", items: (node.children ?? []).map(convert) };
      case "object": {
        const names = new Set<string>(), members = (node.children ?? []).map(property => {
          requireEvidence(property.type === "property" && property.children?.length === 2, "property node");
          const key: unknown = property.children[0]!.value; requireEvidence(typeof key === "string" && !names.has(key), "one member with this name"); names.add(key);
          return { key, value: convert(property.children[1]!) };
        });
        return { tag: "Object", members };
      }
      default: throw new SemanticEvidenceError("JSON value node");
    }
  };
  return convert(root);
}
export function encodeExact(value: ExactJson): string {
  switch (value.tag) {
    case "Null": return "null";
    case "Bool": return value.value ? "true" : "false";
    case "Integer": return value.value;
    case "Decimal": return value.text;
    case "String": return JSON.stringify(value.value);
    case "Array": return `[${value.items.map(encodeExact).join(",")}]`;
    case "Object": return `{${value.members.map(m => `${JSON.stringify(m.key)}:${encodeExact(m.value)}`).join(",")}}`;
  }
}
export function member(value: ExactJson, key: string): ExactJson | undefined { return value.tag === "Object" ? value.members.find(m => m.key === key)?.value : undefined; }
export function exactObject(members: readonly { readonly key: string; readonly value: ExactJson }[]): ExactJson { return { tag: "Object", members }; }
export function slotOf(value: ExactJson | undefined): ExactSlot { return value === undefined ? { tag: "Absent" } : value.tag === "Null" ? { tag: "Null" } : { tag: "Present", value }; }
export function projectValue(value: ExactSlot, path: readonly PathStep[], profile: VersionedSemanticProfile): ExactSlot {
  if (value.tag !== "Present") return value;
  let current = value.value;
  for (const step of path) {
    if (current.tag === "Null") return { tag: "Null" };
    if (step.tag === "Field") { const child = member(current, step.value); if (child === undefined) return { tag: "Absent" }; current = child; }
    else if (step.tag === "Index") { if (current.tag !== "Array" || BigInt(step.value) >= BigInt(current.items.length)) return { tag: "Absent" }; current = current.items[Number(step.value)]!; }
    else { const tag = profile.tag && member(current, profile.tag.key); if (tag?.tag !== "String" || tag.value !== step.value) return { tag: "Absent" }; }
  }
  return path.length === 0 ? { tag: "Present", value: current } : slotOf(current);
}
export function tuple(parts: readonly string[]): string { return parts.map(s => `${new TextEncoder().encode(s).length}:${s}`).join(""); }
export function typeIdentity(ref: TypeRef): string {
  const declared = ref.source.declared_revision;
  return tuple([
    "type", ref.source.repository, ref.source.revision, ref.source.path, ref.source.content_digest,
    ref.source.document_id, declared === undefined || declared === null ? "none" : "some",
    declared ?? "", ref.definition_name, tuple(ref.pointer),
  ]);
}
export function children(shape: TypeShape): readonly TypeRef[] {
  switch (shape.tag) {
    case "Product": return [...shape.value.fields.map(field => field.slot.type_ref), ...(shape.value.extras.tag === "Allow" ? [shape.value.extras.fields.value.type_ref] : [])];
    case "Array": return [shape.value.item.type_ref];
    case "Alias": return [shape.fields.target];
    case "TaggedUnion": return shape.value.branches.map(branch => branch.target);
    default: return [];
  }
}
function bounded(value: bigint, minimum: string | null, maximum: string | null): boolean { return (minimum === null || value >= BigInt(minimum)) && (maximum === null || value <= BigInt(maximum)); }
function integralDecimal(text: string): bigint | null {
  const matched = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(text);
  if (!matched) return null;
  const fraction = matched[3] ?? "";
  const exponent = BigInt(matched[4] ?? "0") - BigInt(fraction.length);
  let digits = BigInt(`${matched[1]}${matched[2]}${fraction}`);
  if (exponent >= 0n) return digits * 10n ** exponent;
  const divisor = 10n ** -exponent;
  if (digits % divisor !== 0n) return null;
  return digits / divisor;
}
type IntegralDecimalAdmission = "notIntegral" | "inRange" | "outOfRange";
function integralDecimalAdmission(text: string, range: IntegerDomain): IntegralDecimalAdmission {
  const matched = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(text);
  if (!matched) return "notIntegral";
  const digits = `${matched[2]}${matched[3] ?? ""}`.replace(/^0+/, "");
  const minimum = range.tag === "Inclusive" ? BigInt(range.fields.minimum) : null;
  const maximum = range.tag === "Inclusive" ? BigInt(range.fields.maximum) : null;
  if (digits.length === 0) return range.tag !== "Inclusive" || bounded(0n, range.fields.minimum, range.fields.maximum) ? "inRange" : "outOfRange";
  const boundDigits = range.tag === "Inclusive"
    ? (minimum! < 0n ? -minimum! : minimum!) > (maximum! < 0n ? -maximum! : maximum!)
      ? ((minimum! < 0n ? -minimum! : minimum!).toString().length)
      : ((maximum! < 0n ? -maximum! : maximum!).toString().length)
    : 0;
  const cap = Math.max(digits.length + (matched[3] ?? "").length + 2, boundDigits + 2);
  const exponentText = matched[4] ?? "0";
  const exponentNegative = exponentText.startsWith("-");
  const exponentDigits = exponentText.replace(/^[+-]?0*/, "") || "0";
  const exponent = exponentDigits.length > String(cap).length
    ? (cap + 1) * (exponentNegative ? -1 : 1)
    : Math.min(Number(exponentDigits), cap + 1) * (exponentNegative ? -1 : 1);
  const shift = exponent - (matched[3] ?? "").length;
  let integerDigits: string;
  if (shift < 0) {
    const removed = -shift;
    if (removed > digits.length || !digits.endsWith("0".repeat(removed))) return "notIntegral";
    integerDigits = digits.slice(0, digits.length - removed).replace(/^0+/, "") || "0";
  } else {
    if (range.tag === "Unbounded") return "inRange";
    if (digits.length + shift > boundDigits) return "outOfRange";
    integerDigits = digits + "0".repeat(shift);
  }
  if (range.tag === "Unbounded") return "inRange";
  const integer = BigInt(`${matched[1]}${integerDigits}`);
  return bounded(integer, range.fields.minimum, range.fields.maximum) ? "inRange" : "outOfRange";
}
function base64Digit(alphabet: BytesAlphabet, character: string): number | null {
  const common = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const commonValue = common.indexOf(character);
  if (commonValue >= 0) return commonValue;
  if (character === "+" && alphabet.tag !== "UrlSafe" || character === "-" && alphabet.tag !== "Standard") return 62;
  if (character === "/" && alphabet.tag !== "UrlSafe" || character === "_" && alphabet.tag !== "Standard") return 63;
  return null;
}
export function base64Decode(text: string, policy: BytesPolicy): Uint8Array | null {
  const parts = text.split("="), data = parts[0]!, padding = parts.length - 1, remainder = data.length % 4;
  if (padding > 2 || parts.slice(1).some(part => part !== "")) return null;
  const digits = [...data].map(character => base64Digit(policy.alphabet, character));
  if (digits.some(digit => digit === null) || remainder === 1) return null;
  if (policy.strict_pad_bits && (remainder === 2 && digits[digits.length - 1]! % 16 !== 0 || remainder === 3 && digits[digits.length - 1]! % 4 !== 0)) return null;
  if (padding > 0 && ((data.length + padding) % 4 !== 0 || padding !== (4 - remainder) % 4)) return null;
  if (padding === 0 && !policy.padding_optional && remainder !== 0) return null;
  const out = new Uint8Array(Math.floor(data.length * 6 / 8)); let bits = 0, acc = 0, index = 0;
  for (const digit of digits) { acc = (acc << 6) | digit!; bits += 6; if (bits >= 8) { bits -= 8; out[index++] = (acc >> bits) & 255; } acc &= (1 << bits) - 1; }
  return out;
}
export function base64Encode(bytes: Uint8Array, policy: BytesPolicy): string {
  const alphabet = policy.alphabet.tag === "UrlSafe" ? "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" : "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; let text = "";
  for (let i = 0; i < bytes.length; i += 3) { const a = bytes[i]!, b = bytes[i + 1], c = bytes[i + 2]; text += alphabet[a >> 2]! + alphabet[((a & 3) << 4) | ((b ?? 0) >> 4)]! + (b === undefined ? "=" : alphabet[((b & 15) << 2) | ((c ?? 0) >> 6)]!) + (c === undefined ? "=" : alphabet[c & 63]!); }
  return text;
}
function language(text: string, grandfathered: readonly string[]): boolean {
  if (!/^[\x00-\x7F]+$/.test(text)) return false;
  const lower = text.toLowerCase(); if (grandfathered.some(s => s.toLowerCase() === lower)) return true;
  const parts = lower.split("-"); let i = 0; const first = parts[i++]!, alpha = (s: string) => /^[a-z]+$/.test(s), alnum = (s: string) => /^[a-z0-9]+$/.test(s);
  const privateUse = () => i < parts.length && parts.slice(i).every(p => p.length >= 1 && p.length <= 8 && alnum(p));
  if (first === "x") return privateUse();
  if (first.length < 2 || first.length > 8 || !alpha(first)) return false;
  if (first.length <= 3) for (let n = 0; n < 3 && parts[i]?.length === 3 && alpha(parts[i]!); n++) i++;
  if (parts[i]?.length === 4 && alpha(parts[i]!)) i++;
  if (parts[i] && (/^[a-z]{2}$/.test(parts[i]!) || /^\d{3}$/.test(parts[i]!))) i++;
  const variants = new Set<string>(), extensions = new Set<string>();
  while (parts[i] && (/^[a-z0-9]{5,8}$/.test(parts[i]!) || /^\d[a-z0-9]{3}$/.test(parts[i]!))) { if (variants.has(parts[i]!)) return false; variants.add(parts[i++]!); }
  while (parts[i] && /^[a-wyz0-9]$/.test(parts[i]!)) { const singleton = parts[i++]!; if (extensions.has(singleton)) return false; extensions.add(singleton); const start = i; while (parts[i] && /^[a-z0-9]{2,8}$/.test(parts[i]!)) i++; if (start === i) return false; }
  if (parts[i] === "x") { i++; return privateUse(); }
  return i === parts.length;
}
function ipv6(text: string): boolean {
  if (text.includes("%")) return false;
  const halves = text.split("::"); if (halves.length > 2) return false;
  let count = 0;
  for (const group of text.replace("::", ":").split(":").filter(Boolean)) {
    if (group.includes(".")) { if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(group) || group.split(".").some(v => Number(v) > 255 || v.length > 1 && v.startsWith("0")) || !text.endsWith(group)) return false; count += 2; }
    else { if (!/^[\da-fA-F]{1,4}$/.test(group)) return false; count++; }
  }
  return halves.length === 2 ? count < 8 : count === 8 && !text.startsWith(":") && !text.endsWith(":");
}
function absoluteUri(text: string, maximum: string): boolean {
  if (!/^[\x00-\x7F]*$/.test(text) || BigInt(text.length) > BigInt(maximum)) return false;
  const m = /^([A-Za-z][A-Za-z0-9+.-]*):(.*)$/.exec(text); if (!m) return false;
  let rest = m[2]!;
  const component = (s: string, extra: string) => { for (let i = 0; i < s.length; i++) { const c = s[i]!; if (c === "%") { if (!/^[\da-fA-F]{2}$/.test(s.slice(i + 1, i + 3))) return false; i += 2; } else if (!/[A-Za-z0-9\-._~!$&'()*+,;=]/.test(c) && !extra.includes(c)) return false; } return true; };
  const h = rest.indexOf("#"); if (h >= 0) { if (!component(rest.slice(h + 1), ":@/?")) return false; rest = rest.slice(0, h); }
  const q = rest.indexOf("?"); if (q >= 0) { if (!component(rest.slice(q + 1), ":@/?")) return false; rest = rest.slice(0, q); }
  if (rest.startsWith("//")) {
    const slash = rest.indexOf("/", 2), authority = slash < 0 ? rest.slice(2) : rest.slice(2, slash); rest = slash < 0 ? "" : rest.slice(slash);
    const at = authority.lastIndexOf("@"); if (at >= 0 && !component(authority.slice(0, at), ":")) return false;
    const hostPort = authority.slice(at + 1);
    if (hostPort.startsWith("[")) {
      const end = hostPort.indexOf("]"); if (end < 0 || !/^(|:\d*)$/.test(hostPort.slice(end + 1))) return false;
      const address = hostPort.slice(1, end); if (!ipv6(address) && !/^v[\da-f]+\.[A-Za-z0-9\-._~!$&'()*+,;=:]+$/i.test(address)) return false;
    } else { const colon = hostPort.lastIndexOf(":"); if (colon >= 0 && !/^\d*$/.test(hostPort.slice(colon + 1))) return false; if (!component(colon < 0 ? hostPort : hostPort.slice(0, colon), "")) return false; }
  }
  return component(rest, ":@/");
}
function unicodeScalarString(text: string): boolean {
  return !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(text);
}

function binaryFormatSequence(children: readonly FormatRule[], start: number, end: number): FormatRule {
  if (start === end) return { tag: "Sequence", value: [] };
  if (end - start === 1) return children[start]!;
  const middle = Math.floor((start + end) / 2);
  return { tag: "Sequence", value: [binaryFormatSequence(children, start, middle), binaryFormatSequence(children, middle, end)] };
}

function compileFormatSpan(rule: FormatRule): FormatRule {
  switch (rule.tag) {
    case "Sequence": {
      const children = rule.value.map(compileFormatSpan);
      return binaryFormatSequence(children, 0, children.length);
    }
    case "Choice": return { ...rule, value: rule.value.map(compileFormatSpan) };
    case "Optional": case "Not": return { ...rule, value: compileFormatSpan(rule.value) };
    case "Labels": return { tag: "Labels", fields: { ...rule.fields, rule: compileFormatSpan(rule.fields.rule) } };
    case "Bounded": return { tag: "Bounded", fields: { ...rule.fields, rule: compileFormatSpan(rule.fields.rule) } };
    default: return rule;
  }
}

export function recognizeFormat(rule: FormatRule, text: string): boolean {
  if (!unicodeScalarString(text)) return false;
  const scalars = [...text], memo = new WeakMap<object, Map<string, boolean>>();
  const accepts = (current: FormatRule, start: number, end: number): boolean => {
    let entries = memo.get(current);
    if (!entries) { entries = new Map(); memo.set(current, entries); }
    const key = `${start}:${end}`;
    const known = entries.get(key);
    if (known !== undefined) return known;
    entries.set(key, false);
    const value = current.tag === "Sequence" ? "" : scalars.slice(start, end).join("");
    let accepted: boolean;
    switch (current.tag) {
      case "Literal": accepted = unicodeScalarString(current.value) && value === current.value; break;
      case "Sequence": {
        accepted = current.value.length === 0 && start === end;
        if (current.value.length === 2) {
          for (let split = start; split <= end; split++) {
            if (accepts(current.value[0]!, start, split) && accepts(current.value[1]!, split, end)) { accepted = true; break; }
          }
        }
        break;
      }
      case "Optional": accepted = start === end || accepts(current.value, start, end); break;
      case "Labels": {
        const p = current.fields, labels = p.separator === "" ? [] : value.split(p.separator);
        accepted = p.separator !== "" && BigInt(labels.length) >= BigInt(p.min_count)
          && (p.max_count === null || BigInt(labels.length) <= BigInt(p.max_count))
          && (p.total_max === null || BigInt(end - start) <= BigInt(p.total_max));
        let cursor = start;
        if (accepted) for (const label of labels) {
          const length = [...label].length;
          if (!accepts(p.rule, cursor, cursor + length)) { accepted = false; break; }
          cursor += length + [...p.separator].length;
        }
        break;
      }
      case "Bounded": {
        const length = current.fields.unit.tag === "Utf8Bytes" ? new TextEncoder().encode(value).length : end - start;
        accepted = BigInt(length) <= BigInt(current.fields.maximum) && accepts(current.fields.rule, start, end);
        break;
      }
      case "AsciiDfa": {
        const p = current.value; let state = p.initial_state, valid = true;
        for (const c of value) {
          const byte = c.codePointAt(0)!;
          if (byte >= 128) { valid = false; break; }
          const edge = p.transitions.find(t => t.from_state === state && BigInt(t.first) <= BigInt(byte) && BigInt(t.last) >= BigInt(byte));
          if (!edge) { valid = false; break; }
          state = edge.to_state;
        }
        accepted = valid && p.accepting_states.includes(state);
        break;
      }
      case "Identifier": {
        const p = current.fields, length = end - start;
        accepted = /^[\x00-\x7F]*$/.test(value) && bounded(BigInt(length), p.min_length, p.max_length)
          && (p.exact_length === null || BigInt(length) === BigInt(p.exact_length)) && !p.forbidden.includes(value)
          && length > 0 && p.first_alphabet.includes(scalars[start]!) && scalars.slice(start + 1, end).every(c => p.rest_alphabet.includes(c));
        break;
      }
      case "Timestamp": {
        const p = current.value, m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$/.exec(value);
        if (!m) { accepted = false; break; }
        const year = Number(m[1]), month = Number(m[2]), day = Number(m[3]), hour = Number(m[4]), minute = Number(m[5]), second = Number(m[6]), zone = m[7]!;
        const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0), days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        if (!bounded(BigInt(year), p.minimum_year, p.maximum_year) || month < 1 || month > 12 || day < 1 || day > days[month - 1]! || hour > 23 || minute > 59 || second > (p.allow_second_60 ? 60 : 59)) { accepted = false; break; }
        if (zone === "Z") { accepted = true; break; }
        const oh = Number(zone.slice(1, 3)), om = Number(zone.slice(4));
        if (oh > 23 || om > 59 || zone === "-00:00") { accepted = false; break; }
        const precedingDays = days.slice(0, month - 1).reduce((sum, count) => sum + count, 0);
        const localMinutes = (precedingDays + day - 1) * 1440 + hour * 60 + minute;
        const utcMinutes = localMinutes - (zone[0] === "+" ? 1 : -1) * (oh * 60 + om);
        const yearMinutes = (leap ? 366 : 365) * 1440;
        accepted = !(p.rejectUtcYearOutsideRange && (BigInt(year) === BigInt(p.minimum_year) && utcMinutes < 0 || BigInt(year) === BigInt(p.maximum_year) && utcMinutes >= yearMinutes));
        break;
      }
      case "AbsoluteUri": accepted = current.fields.max_bytes === null || absoluteUri(value, current.fields.max_bytes); break;
      case "LanguageTag": accepted = language(value, current.fields.grandfathered); break;
      case "Choice": accepted = current.value.some(candidate => accepts(candidate, start, end)); break;
      case "Text": accepted = true; break;
      case "Not": accepted = !accepts(current.value, start, end); break;
    }
    entries.set(key, accepted);
    return accepted;
  };
  return accepts(compileFormatSpan(rule), 0, scalars.length);
}
function rangeAt<T extends CodepointRange>(rows: readonly T[], cp: number): T | undefined {
  let low = 0, high = rows.length;
  while (low < high) { const mid = (low + high) >>> 1; if (Number(rows[mid]!.first) <= cp) low = mid + 1; else high = mid; }
  const row = rows[low - 1]; return row && cp <= Number(row.last) ? row : undefined;
}
export function graphemeBoundaries(rules: GraphemeRules, text: string): readonly bigint[] {
  const boundaries: bigint[] = [];
  let previous = "", regional = 0, epExtend = false, zwjAfterEp = false, indicConsonant = false, indicLinker = false, offset = 0n;
  for (const c of text) {
    const cp = c.codePointAt(0)!, property = rangeAt(rules.properties, cp)?.property.tag ?? "Other", indic = rangeAt(rules.indic_conjunct, cp)?.property.tag ?? "Other", ep = rangeAt(rules.extended_pictographic, cp) !== undefined;
    const breaks = previous === "" ? true : previous === "Cr" && property === "Lf" ? false : ["Cr", "Lf", "Control"].includes(previous) || ["Cr", "Lf", "Control"].includes(property) ? true : previous === "L" && ["L", "V", "Lv", "Lvt"].includes(property) || ["Lv", "V"].includes(previous) && ["V", "T"].includes(property) || ["Lvt", "T"].includes(previous) && property === "T" || ["Extend", "Zwj", "SpacingMark"].includes(property) || previous === "Prepend" || indic === "Consonant" && indicConsonant && indicLinker || previous === "Zwj" && ep && zwjAfterEp || previous === "RegionalIndicator" && property === "RegionalIndicator" && regional % 2 === 1 ? false : true;
    if (breaks) boundaries.push(offset);
    zwjAfterEp = property === "Zwj" && epExtend; epExtend = ep || property === "Extend" && epExtend;
    if (indic === "Consonant") { indicConsonant = true; indicLinker = false; } else if (indic === "Linker" && indicConsonant) indicLinker = true; else if (indic === "Other") { indicConsonant = false; indicLinker = false; }
    regional = property === "RegionalIndicator" ? previous === property ? regional + 1 : 1 : 0; previous = property; offset++;
  }
  if (offset > 0n) boundaries.push(offset);
  return boundaries;
}
export function graphemeCount(rules: GraphemeRules, text: string): bigint {
  const boundaries = graphemeBoundaries(rules, text);
  return boundaries.length === 0 ? 0n : BigInt(boundaries.length - 1);
}
function namedRule(profile: VersionedSemanticProfile, use: FormatUse): FormatRule | undefined {
  return use.tag === "Inline" ? use.value : profile.format_bindings.find(binding => binding.name === use.value)?.rule;
}
export function classOf(profile: VersionedSemanticProfile, value: ExactJson): { readonly tag: "Sealed"; readonly value: SealedForm } | { readonly tag: "Wrapper"; readonly value: Wrapper } | { readonly tag: "Ordinary" } {
  if (value.tag !== "Object") return { tag: "Ordinary" };
  const tagged = profile.tag && member(value, profile.tag.key);
  const form = tagged?.tag === "String" ? profile.tag?.sealed.find(candidate => candidate.tag === tagged.value) : undefined;
  if (form) return { tag: "Sealed", value: form };
  const wrapper = profile.wrappers.find(candidate => member(value, candidate.key) !== undefined);
  return wrapper ? { tag: "Wrapper", value: wrapper } : { tag: "Ordinary" };
}
export function wrapEncode(profile: VersionedSemanticProfile, wrapperName: string, payload: string | Uint8Array): ExactJson {
  const wrapper = profile.wrappers.find(candidate => candidate.name === wrapperName);
  requireEvidence(wrapper, "declared wrapper");
  return exactObject([{ key: wrapper.key, value: { tag: "String", value: payload instanceof Uint8Array ? (requireEvidence(profile.bytes_policy, "bytes policy"), base64Encode(payload, profile.bytes_policy)) : payload } }]);
}
type WrapperPayloadResult =
  | { readonly tag: "Accepted"; readonly text: string; readonly decoded: string | Uint8Array }
  | { readonly tag: "Rejected"; readonly condition: string };
function wrapperPayload(profile: VersionedSemanticProfile, wrapper: Wrapper, value: ExactJson): WrapperPayloadResult {
  const condition = wrapper.payload.tag === "Bytes" ? "InvalidBytes"
    : wrapper.payload.value === null ? "WrongValueKind:wrapper text" : `Format:${wrapper.payload.value}`;
  const rejected = { tag: "Rejected", condition } as const;
  if (value.tag !== "Object" || value.members.length !== 1) return rejected;
  const payload = member(value, wrapper.key);
  if (payload?.tag !== "String") return rejected;
  if (wrapper.payload.tag === "Bytes") {
    const decoded = profile.bytes_policy && base64Decode(payload.value, profile.bytes_policy);
    return decoded ? { tag: "Accepted", text: payload.value, decoded } : rejected;
  }
  if (!unicodeScalarString(payload.value)) return rejected;
  if (wrapper.payload.value !== null) {
    const format = wrapper.payload.value;
    const rule = profile.format_bindings.find(binding => binding.name === format)?.rule;
    if (!rule || !recognizeFormat(rule, payload.value)) return rejected;
  }
  return { tag: "Accepted", text: payload.value, decoded: payload.value };
}
export function wrapDecode(profile: VersionedSemanticProfile, wrapperName: string, value: ExactJson): string | Uint8Array {
  const wrapper = profile.wrappers.find(candidate => candidate.name === wrapperName);
  requireEvidence(wrapper, "declared wrapper");
  const result = wrapperPayload(profile, wrapper, value);
  requireEvidence(result.tag === "Accepted", result.tag === "Rejected" ? result.condition : "wrapper payload");
  return result.decoded;
}
function decodeBytes(profile: VersionedSemanticProfile, value: ExactJson): Uint8Array | null {
  const policy = profile.bytes_policy;
  if (policy === null) return null;
  if (policy.wrapper === null) return value.tag === "String" ? base64Decode(value.value, policy) : null;
  const wrapper = profile.wrappers.find(candidate => candidate.name === policy.wrapper);
  if (!wrapper) return null;
  const result = wrapperPayload(profile, wrapper, value);
  if (result.tag === "Rejected") return null;
  return result.decoded instanceof Uint8Array ? result.decoded : base64Decode(result.text, policy);
}
export function withMember(key: string, text: string, value: ExactJson): ExactJson {
  requireEvidence(value.tag === "Object", "object value"); const old = member(value, key);
  requireEvidence(old === undefined || old.tag === "String" && old.value === text, "member agreement");
  return old ? value : { tag: "Object", members: [{ key, value: { tag: "String", value: text } }, ...value.members] };
}
export function selectBranch(graph: ValueGraph, ref: TypeRef, value: ExactJson): UnionBranch | null {
  const node = graph.nodes.find(candidate => typeIdentity(candidate.reference) === typeIdentity(ref));
  requireEvidence(node?.shape.tag === "TaggedUnion", "union reference");
  let prior = false;
  for (const branch of node.shape.value.branches) {
    const selector = branch.selector; let selected = false;
    if (selector.tag === "Otherwise") selected = !prior;
    else if (selector.tag === "Kind") selected = exactKind(value) === selector.value.tag;
    else if (selector.tag === "InternalTag") { const tag = graph.profile.tag && value.tag === "Object" ? member(value, graph.profile.tag.key) : undefined; selected = tag?.tag === "String" && tag.value === branch.wire_tag; }
    else if (value.tag === "Object") selected = selector.value.every(([key, test]) => { const item = member(value, key); return test.tag === "Absent" ? item === undefined : item?.tag === "String" && Boolean(graph.profile.format_bindings.find(binding => binding.name === test.value)?.rule && recognizeFormat(graph.profile.format_bindings.find(binding => binding.name === test.value)!.rule, item.value)); });
    if (selected) return branch; prior ||= selected;
  }
  return null;
}
function exactKind(value: ExactJson): ValueKind["tag"] { return value.tag === "Null" ? "Null" : value.tag === "Bool" ? "Boolean" : value.tag === "Integer" || value.tag === "Decimal" ? "Number" : value.tag; }

export interface DefaultApplication {
  readonly value_path: readonly PathStep[];
  readonly type_ref: TypeRef;
  readonly origin: OccurrenceRef;
  readonly value: ExactJson;
}
export type SemanticReason =
  | { readonly tag: "MembershipBound" | "UnresolvedType" | "MissingGraphemeRules" | "MissingBytesPolicy" | "DecimalNotAdmitted" | "IntegerBound" | "MissingTagModel" }
  | { readonly tag: "UnknownFormat" | "UnknownIntegerDomain" | "UnknownWrapper" | "WrapperPayload" | "UnknownSealedTag" | "OpaqueType"; readonly value: string };
export interface SemanticObligation {
  readonly type_ref: TypeRef; readonly origin: OccurrenceRef;
  readonly value_path: readonly PathStep[]; readonly profile: ProfileRef;
  readonly reason: SemanticReason;
}
export class SemanticUnresolvedError extends SemanticEvidenceError {
  constructor(readonly obligations: readonly SemanticObligation[]) { super("unresolved value meaning"); }
}

function nodeMeaningReasons(graph: ValueGraph, ref: TypeRef): readonly SemanticReason[] {
  const node = graph.nodes.find(node => typeIdentity(node.reference) === typeIdentity(ref));
  if (!node) return [{ tag: "UnresolvedType" }];
  const shape = node.shape, profile = graph.profile, reasons: SemanticReason[] = [];
  if (shape.tag === "String") {
    if (shape.value.lengths.some(bound => bound.unit.tag === "Graphemes") && profile.grapheme_rules === null) reasons.push({ tag: "MissingGraphemeRules" });
    if (shape.value.format?.tag === "Named" && !profile.format_bindings.some(binding => binding.name === shape.value.format!.value)) reasons.push({ tag: "UnknownFormat", value: shape.value.format.value });
    if (shape.value.wrapper !== null) {
      const wrapper = profile.wrappers.find(wrapper => wrapper.name === shape.value.wrapper);
      if (!wrapper) reasons.push({ tag: "UnknownWrapper", value: shape.value.wrapper });
      else if (wrapper.payload.tag !== "Text") reasons.push({ tag: "WrapperPayload", value: shape.value.wrapper });
    }
  } else if (shape.tag === "Integer") {
    const name = shape.value.domain ?? profile.default_integer_domain, binding = profile.integer_domains.find(binding => binding.name === name);
    if (!binding) reasons.push({ tag: "UnknownIntegerDomain", value: name });
    else if (binding.range.tag === "Inclusive" && (shape.value.minimum !== null && BigInt(shape.value.minimum) < BigInt(binding.range.fields.minimum) || shape.value.maximum !== null && BigInt(shape.value.maximum) > BigInt(binding.range.fields.maximum))) reasons.push({ tag: "IntegerBound" });
  } else if (shape.tag === "Decimal" && !profile.numbers.decimals) reasons.push({ tag: "DecimalNotAdmitted" });
  else if ((shape.tag === "Bytes" || shape.tag === "RawBody") && profile.bytes_policy === null) reasons.push({ tag: "MissingBytesPolicy" });
  else if (shape.tag === "Sealed" && !profile.tag?.sealed.some(form => form.tag === shape.fields.tag)) reasons.push({ tag: "UnknownSealedTag", value: shape.fields.tag });
  else if (shape.tag === "TaggedUnion" && profile.tag === null && shape.value.branches.some(branch => branch.selector.tag === "InternalTag")) reasons.push({ tag: "MissingTagModel" });
  else if (shape.tag === "Opaque") reasons.push({ tag: "OpaqueType", value: shape.fields.type_name });
  return reasons;
}
export function meaningObligations(graph: ValueGraph, refs: readonly TypeRef[]): readonly SemanticObligation[] {
  const edges = graph.nodes.reduce((total, node) => total + children(node.shape).length, 0);
  const pending = [...refs], seen = new Set<string>(), reachable: TypeRef[] = [];
  for (let fuel = refs.length + graph.nodes.length + edges + 1; fuel > 0 && pending.length; fuel--) {
    const ref = pending.shift()!, key = typeIdentity(ref);
    if (seen.has(key)) continue;
    seen.add(key); reachable.unshift(ref);
    const node = graph.nodes.find(node => typeIdentity(node.reference) === key);
    if (node) pending.unshift(...children(node.shape));
  }
  return reachable.flatMap(ref => nodeMeaningReasons(graph, ref).map(reason => ({
    type_ref: ref, origin: { source: ref.source, pointer: ref.pointer }, value_path: [],
    profile: graph.profile.reference, reason,
  })));
}
function defaultOrigin(ref: TypeRef): OccurrenceRef {
  return { source: ref.source, pointer: [...ref.pointer, "default"] };
}
function typeDefault(shape: TypeShape): ExactJson | undefined {
  if (shape.tag === "Boolean" && shape.value.default_value !== null) return { tag: "Bool", value: shape.value.default_value };
  if (shape.tag === "Integer" && shape.value.default_value !== null) return { tag: "Integer", value: shape.value.default_value };
  if (shape.tag === "String" && shape.value.default_value !== null) return { tag: "String", value: shape.value.default_value };
  return undefined;
}
export function checkDefaultApplications(graph: ValueGraph, before: ExactJson, after: ExactJson, applications: readonly DefaultApplication[]): boolean {
  return applications.every(application => {
    const first = projectValue({ tag: "Present", value: before }, application.value_path, graph.profile);
    const last = projectValue({ tag: "Present", value: after }, application.value_path, graph.profile);
    const node = graph.nodes.find(node => typeIdentity(node.reference) === typeIdentity(application.type_ref));
    return first.tag === "Absent" && last.tag === "Present" && same(last.value, application.value)
      && same(application.origin, defaultOrigin(application.type_ref))
      && node !== undefined && same(typeDefault(node.shape), application.value);
  });
}
export class DefaultedValue {
  readonly #value: ExactJson;
  readonly #applications: readonly DefaultApplication[];
  private constructor(value: ExactJson, applications: readonly DefaultApplication[]) {
    this.#value = deepFreeze(structuredClone(value));
    this.#applications = deepFreeze(structuredClone(applications));
    Object.freeze(this);
  }
  get value(): ExactJson { return this.#value; }
  get applications(): readonly DefaultApplication[] { return this.#applications; }
  static checked(context: ValueContext, ref: TypeRef, before: ExactJson, after: ExactJson, applications: readonly DefaultApplication[]): DefaultedValue {
    context.validate(ref, after);
    requireEvidence(checkDefaultApplications(context.graph, before, after, applications), "default source, absence, or result");
    return new DefaultedValue(after, applications);
  }
}
export class ValueContext {
  readonly #nodes = new Map<string, TypeNode>();
  readonly profile: VersionedSemanticProfile;
  readonly sources: readonly SourceRef[];
  constructor(readonly graph: ValueGraph, sources: readonly SourceRef[] = []) { this.profile = graph.profile; this.sources = sources; graph.nodes.forEach(node => this.#nodes.set(typeIdentity(node.reference), node)); }
  node(ref: TypeRef): TypeNode { const node = this.#nodes.get(typeIdentity(ref)); requireEvidence(node, "resolved qualified type"); return node; }
  resolve(ref: TypeRef): TypeShape { const seen = new Set<string>(); while (true) { const id = typeIdentity(ref); requireEvidence(!seen.has(id), "finite alias unfolding"); seen.add(id); const shape = this.node(ref).shape; if (shape.tag !== "Alias") return shape; ref = shape.fields.target; } }
  format(name: string): FormatRule | undefined { return this.profile.format_bindings.find(binding => binding.name === name)?.rule; }
  defined(ref: TypeRef): void { const pending = [ref], seen = new Set<string>(); while (pending.length) { const current = pending.pop()!, id = typeIdentity(current); if (seen.has(id)) continue; seen.add(id); const node = this.node(current); requireEvidence(node.extensions.length === 0 && node.shape.tag !== "Opaque", "defined primitive meaning"); pending.push(...children(node.shape)); } }
  validateSlot(contract: SlotContract, value: ExactSlot): ExactSlot { if (value.tag === "Absent" && contract.required) this.reject(contract.type_ref, [], "MissingRequired", "absent"); if (value.tag === "Null" && !contract.nullable) this.reject(contract.type_ref, [], "NullNotAllowed", "null"); if (value.tag === "Present") this.validate(contract.type_ref, value.value); return value; }
  validate(ref: TypeRef, value: ExactJson): ExactJson { const obligations = meaningObligations(this.graph, [ref]); if (obligations.length) throw new SemanticUnresolvedError(obligations); this.evaluate(ref, value, [], new Set()); return value; }
  accepts(contract: SlotContract, value: ExactSlot): boolean { try { this.validateSlot(contract, value); return true; } catch (error) { if (error instanceof SemanticValueError) return false; throw error; } }
  private reject(ref: TypeRef, path: readonly (string | bigint)[], condition: string, observed: string): never { throw new SemanticValueError({ type: ref, path, condition, observed }); }
  private domain(name: string | null): IntegerDomainBinding { const found = this.profile.integer_domains.find(item => item.name === (name ?? this.profile.default_integer_domain)); requireEvidence(found, "integer domain"); return found; }
  private integer(spec: IntegerSpec, value: ExactJson): bigint | null {
    const forms = this.domain(spec.domain).forms;
    if (value.tag === "Integer" && forms.some(form => form.tag === "Number")) return BigInt(value.value);
    if (value.tag === "Decimal" && forms.some(form => form.tag === "IntegralDecimal")) return integralDecimal(value.text);
    if (value.tag === "String" && forms.some(form => form.tag === "DecimalString")) return integralDecimal(value.value);
    return null;
  }
  private string(ref: TypeRef, spec: StringSpec, value: ExactJson, path: readonly (string | bigint)[]): void {
    let text: string;
    if (spec.wrapper === null) {
      if (value.tag !== "String") this.reject(ref, path, "WrongValueKind:string", value.tag);
      text = value.value;
    } else {
      const classification = classOf(this.profile, value);
      if (classification.tag !== "Wrapper" || classification.value.name !== spec.wrapper) this.reject(ref, path, "WrongValueKind:string wrapper", value.tag);
      text = this.wrapperText(ref, classification.value, value, path);
    }
    this.stringText(ref, spec, text, path);
  }
  private wrapperText(ref: TypeRef, wrapper: Wrapper, value: ExactJson, path: readonly (string | bigint)[]): string {
    const result = wrapperPayload(this.profile, wrapper, value);
    if (result.tag === "Rejected") this.reject(ref, path, result.condition, value.tag);
    return result.text;
  }
  private stringText(ref: TypeRef, spec: StringSpec, text: string, path: readonly (string | bigint)[]): void {
    if (!unicodeScalarString(text)) this.reject(ref, path, "InvalidDataModel", text);
    if (spec.const_value !== null && text !== spec.const_value) this.reject(ref, path, "ConstMismatch", text);
    if (spec.enum_values !== null && !spec.enum_values.includes(text)) this.reject(ref, path, "EnumMismatch", text);
    for (const bound of spec.lengths) { const length = bound.unit.tag === "Utf8Bytes" ? BigInt(new TextEncoder().encode(text).length) : bound.unit.tag === "UnicodeScalars" ? BigInt([...text].length) : (requireEvidence(this.profile.grapheme_rules, "grapheme rules"), graphemeCount(this.profile.grapheme_rules, text)); if (!bounded(length, bound.minimum, bound.maximum)) this.reject(ref, path, "StringLength", text); }
    if (spec.format !== null) {
      const rule = namedRule(this.profile, spec.format);
      if (rule && !recognizeFormat(rule, text)) this.reject(ref, path, `Format:${spec.format.tag === "Named" ? spec.format.value : "inline"}`, text);
    }
  }
  private element(contract: ElementContract, value: ExactJson, path: readonly (string | bigint)[],
      validate: (target: TypeRef, item: ExactJson, at: readonly (string | bigint)[]) => void): void {
    if (value.tag === "Null" && contract.nullable) return;
    validate(contract.type_ref, value, path);
  }
  private evaluate(ref: TypeRef, value: ExactJson, path: readonly (string | bigint)[], active: Set<string>): void {
    const cycle = `${typeIdentity(ref)}:${encodeExact(value)}`; if (active.has(cycle)) this.reject(ref, path, "ReferenceCycle", value.tag); active.add(cycle);
    const shape = this.node(ref).shape, fail = (condition: string): never => this.reject(ref, path, condition, value.tag), child = (target: TypeRef, item: ExactJson, at = path): void => {
      try { this.evaluate(target, item, at, active); }
      catch (error) {
        if (error instanceof SemanticValueError) throw new SemanticValueError({
          ...error.failure,
          referenceTrace: [ref, ...(error.failure.referenceTrace ?? [])],
        });
        throw error;
      }
    };
    try { switch (shape.tag) {
      case "Never": fail("InvalidDataModel");
      case "Unit": if (value.tag !== "Null") fail("WrongValueKind:unit"); break;
      case "Boolean": if (value.tag !== "Bool") fail("WrongValueKind:boolean"); else if (shape.value.const_value !== null && value.value !== shape.value.const_value) fail("ConstMismatch"); break;
      case "Integer": { const candidate = this.integer(shape.value, value); if (candidate === null) return fail("WrongValueKind:integer"); const n = candidate, range = this.domain(shape.value.domain).range; if (range.tag === "Inclusive" && !bounded(n, range.fields.minimum, range.fields.maximum)) fail("IntegerDomain"); if (shape.value.const_value !== null && n !== BigInt(shape.value.const_value)) fail("ConstMismatch"); if (shape.value.enum_values && !shape.value.enum_values.includes(n.toString())) fail("EnumMismatch"); if (shape.value.minimum !== null && n < BigInt(shape.value.minimum)) fail("BelowMinimum"); if (shape.value.maximum !== null && n > BigInt(shape.value.maximum)) fail("AboveMaximum"); break; }
      case "Decimal": if (value.tag !== "Decimal") fail("WrongValueKind:decimal"); else if (!this.profile.numbers.decimals) fail("InvalidDataModel"); break;
      case "String": this.string(ref, shape.value, value, path); break;
      case "Alias": child(shape.fields.target, value); break;
      case "Array": if (value.tag !== "Array") fail("WrongValueKind:array"); else { if (!bounded(BigInt(value.items.length), shape.value.min_length, shape.value.max_length)) fail("ArrayLength"); value.items.forEach((item, index) => this.element(shape.value.item, item, [...path, BigInt(index)], child)); } break;
      case "Bytes": case "RawBody": { const bytes = decodeBytes(this.profile, value); if (!bytes) return fail("InvalidBytes"); if (shape.tag === "Bytes" && !bounded(BigInt(bytes.length), shape.value.minimum, shape.value.maximum)) fail("BytesLength"); break; }
      case "Product": { if (value.tag !== "Object") return fail("WrongValueKind:object"); this.members(ref, value, path); this.tagMember(ref, value, path); if (classOf(this.profile, value).tag !== "Ordinary") fail("WrongValueKind:plain data object"); for (const field of shape.value.fields) { const item = member(value, field.wire_name); if (item === undefined) { if (field.slot.required) this.reject(field.slot.type_ref, [...path, field.wire_name], "MissingRequired", "absent"); } else if (item.tag === "Null") { if (!field.slot.nullable) this.reject(field.slot.type_ref, [...path, field.wire_name], "NullNotAllowed", "null"); } else child(field.slot.type_ref, item, [...path, field.wire_name]); } for (const item of value.members) if (!shape.value.fields.some(field => field.wire_name === item.key) && item.key !== this.profile.tag?.key) { if (shape.value.extras.tag === "Reject") this.reject(ref, [...path, item.key], `UnexpectedField:${item.key}`, item.key); const extras = shape.value.extras.tag === "Allow" ? shape.value.extras.fields : null; if (extras?.key_format) { const rule = namedRule(this.profile, extras.key_format); if (!rule || !recognizeFormat(rule, item.key)) this.reject(ref, [...path, item.key], `KeyFormat:${item.key}`, item.key); } if (extras) this.element(extras.value, item.value, [...path, item.key], child); } break; }
      case "Unknown": if (shape.value.tag === "OrdinaryObject" && (value.tag !== "Object" || classOf(this.profile, value).tag !== "Ordinary")) fail("WrongValueKind:ordinary object"); this.data(ref, value, path); break;
      case "Sealed": this.sealed(ref, shape.fields.tag, shape.fields.refinements, value, path); break;
      case "TaggedUnion": { if (value.tag === "Object") { this.members(ref, value, path); this.tagMember(ref, value, path); } const selected = selectBranch(this.graph, ref, value); if (!selected) return fail("NoBranchSelected"); child(selected.target, value); break; }
      case "Opaque": fail("UndefinedType");
    } } finally { active.delete(cycle); }
  }
  private members(ref: TypeRef, value: Extract<ExactJson, { tag: "Object" }>, path: readonly (string | bigint)[]): void { const seen = new Set<string>(); for (const item of value.members) { if (seen.has(item.key)) this.reject(ref, path, `DuplicateField:${item.key}`, item.key); seen.add(item.key); } }
  private tagMember(ref: TypeRef, value: Extract<ExactJson, { tag: "Object" }>, path: readonly (string | bigint)[]): void {
    if (!this.profile.tag) return;
    const tag = member(value, this.profile.tag.key);
    if (tag === undefined) return;
    const rule = this.profile.tag.format === null ? undefined : this.profile.format_bindings.find(binding => binding.name === this.profile.tag!.format)?.rule;
    if (tag.tag !== "String") {
      this.reject(ref, [...path, this.profile.tag.key], "InvalidTag", tag.tag);
    }
    if (!unicodeScalarString(tag.value)) {
      this.reject(ref, [...path, this.profile.tag.key], "InvalidDataModel", tag.tag);
    }
    if (rule !== undefined && !recognizeFormat(rule, tag.value)) {
      this.reject(ref, [...path, this.profile.tag.key], "InvalidTag", tag.tag);
    }
  }
  private data(ref: TypeRef, value: ExactJson, path: readonly (string | bigint)[]): void {
    if (value.tag === "Decimal") {
      if (!/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/.test(value.text)) this.reject(ref, path, "InvalidDataModel", value.text);
      const domain = this.domain(null);
      if (domain.forms.some(form => form.tag === "IntegralDecimal")) {
        const admission = integralDecimalAdmission(value.text, domain.range);
        if (admission === "inRange") return;
        if (admission === "outOfRange") this.reject(ref, path, "IntegerDomain", value.text);
      }
      if (!this.profile.numbers.decimals) this.reject(ref, path, "InvalidDataModel", value.text);
    }
    if (value.tag === "Integer") { const range = this.domain(null).range; if (range.tag === "Inclusive" && !bounded(BigInt(value.value), range.fields.minimum, range.fields.maximum)) this.reject(ref, path, "IntegerDomain", value.value); }
    if (value.tag === "Array") value.items.forEach((item, i) => this.data(ref, item, [...path, BigInt(i)]));
    if (value.tag === "Object") {
      this.members(ref, value, path);
      this.tagMember(ref, value, path);
      const classification = classOf(this.profile, value);
      if (classification.tag === "Wrapper") this.wrapperText(ref, classification.value, value, path);
      else if (classification.tag === "Sealed") {
        this.sealed(ref, classification.value.tag, [], value, path);
        if (classification.value.extras.tag === "Any") {
          for (const item of value.members) if (item.key !== this.profile.tag?.key && !classification.value.fields.some(field => field.key === item.key)) this.data(ref, item.value, [...path, item.key]);
        }
      } else value.members.forEach(item => this.data(ref, item.value, [...path, item.key]));
    }
  }
  private sealedLeaf(ref: TypeRef, leaf: SealedLeaf, value: ExactJson, path: readonly (string | bigint)[]): void {
    if (leaf.tag === "String") {
      let text: string;
      if (value.tag === "String") text = value.value;
      else {
        const classification = classOf(this.profile, value);
        if (classification.tag !== "Wrapper") this.reject(ref, path, "WrongValueKind:string", value.tag);
        text = this.wrapperText(ref, classification.value, value, path);
      }
      this.stringText(ref, leaf.value, text, path);
      if (leaf.value.format?.tag === "Named" && !this.format(leaf.value.format.value)) this.reject(ref, path, `Format:${leaf.value.format.value}`, text);
    } else if (this.integer(leaf.value, value) === null) this.reject(ref, path, "WrongValueKind:integer", value.tag);
  }
  private sealed(ref: TypeRef, tagName: string, refinements: readonly SealedRefinement[], value: ExactJson, path: readonly (string | bigint)[]): void {
    if (value.tag !== "Object" || !this.profile.tag) this.reject(ref, path, "WrongValueKind:sealed object", value.tag);
    this.members(ref, value, path);
    this.tagMember(ref, value, path);
    const classification = classOf(this.profile, value);
    if (classification.tag !== "Sealed") this.reject(ref, path, "WrongValueKind:sealed object", value.tag);
    if (classification.value.tag !== tagName) this.reject(ref, path, "InvalidDataModel", value.tag);
    const form = classification.value;
    for (const field of form.fields) {
      const item = member(value, field.key);
      if (item === undefined) { if (field.required) this.reject(ref, [...path, field.key], "MissingRequired", "absent"); }
      else this.sealedLeaf(ref, field.leaf, item, [...path, field.key]);
    }
    for (const refinement of refinements) {
      const item = member(value, refinement.key);
      if (item !== undefined) this.sealedLeaf(ref, refinement.leaf, item, [...path, refinement.key]);
    }
    if (form.extras.tag === "Reject") for (const item of value.members) if (item.key !== this.profile.tag.key && !form.fields.some(field => field.key === item.key)) this.reject(ref, [...path, item.key], `UnexpectedField:${item.key}`, item.key);
  }
  materializeDefaults(ref: TypeRef, value: ExactJson): DefaultedValue {
    const node = (reference: TypeRef, path: readonly PathStep[], fuel: number): TypeNode => {
      const found = this.graph.nodes.find(node => typeIdentity(node.reference) === typeIdentity(reference));
      if (fuel === 0 || found === undefined) throw new SemanticUnresolvedError([{
        type_ref: reference, origin: { source: reference.source, pointer: reference.pointer },
        value_path: path, profile: this.profile.reference, reason: { tag: fuel === 0 ? "MembershipBound" : "UnresolvedType" },
      }]);
      return found;
    };
    const declared = (reference: TypeRef): { ref: TypeRef; value: ExactJson } | undefined => {
      for (let fuel = this.graph.nodes.length + 1; fuel > 0; fuel--) {
        const found = this.graph.nodes.find(node => typeIdentity(node.reference) === typeIdentity(reference));
        if (!found) return undefined;
        if (found.shape.tag === "Alias") reference = found.shape.fields.target;
        else { const value = typeDefault(found.shape); return value === undefined ? undefined : { ref: reference, value }; }
      }
      return undefined;
    };
    const draft = (reference: TypeRef, value: ExactJson, path: readonly PathStep[], fuel: number): { value: ExactJson; applications: DefaultApplication[] } => {
      const shape = node(reference, path, fuel).shape;
      if (shape.tag === "Alias") return draft(shape.fields.target, value, path, fuel - 1);
      if (shape.tag === "TaggedUnion" && value.tag === "Object") {
        const tag = member(value, this.profile.tag?.key ?? "");
        const branch = tag?.tag === "String" ? shape.value.branches.find(branch => branch.wire_tag === tag.value) : undefined;
        if (branch) return draft(branch.target, value, path, fuel - 1);
      }
      const applications: DefaultApplication[] = [];
      if (shape.tag === "Array" && value.tag === "Array") return { value: { tag: "Array", items: value.items.map((item, index) => {
        const child = draft(shape.value.item.type_ref, item, [...path, { tag: "Index", value: String(index) }], fuel - 1);
        applications.push(...child.applications); return child.value;
      }) }, applications };
      if (shape.tag === "Product" && value.tag === "Object") {
        const members = value.members.map(item => {
          const field = shape.value.fields.find(field => field.wire_name === item.key);
          if (!field || item.value.tag === "Null") return item;
          const child = draft(field.slot.type_ref, item.value, [...path, { tag: "Field", value: item.key }], fuel - 1);
          applications.push(...child.applications); return { key: item.key, value: child.value };
        });
        for (const field of shape.value.fields) if (member(value, field.wire_name) === undefined) {
          const found = declared(field.slot.type_ref);
          if (found) {
            this.validate(found.ref, found.value);
            applications.push({ value_path: [...path, { tag: "Field", value: field.wire_name }], type_ref: found.ref, origin: defaultOrigin(found.ref), value: found.value });
            members.push({ key: field.wire_name, value: found.value });
          }
        }
        return { value: { tag: "Object", members }, applications };
      }
      return { value, applications };
    };
    const size = (value: ExactJson): number => 1 + (value.tag === "Array" ? value.items.reduce((sum, item) => sum + size(item), 0) : value.tag === "Object" ? value.members.reduce((sum, item) => sum + size(item.value), 0) : 0);
    const result = draft(ref, value, [], (size(value) + 1) * (this.graph.nodes.length + 1));
    return DefaultedValue.checked(this, ref, value, result.value, result.applications);
  }
  decodeWithDefaults(ref: TypeRef, text: string): DefaultedValue { return this.materializeDefaults(ref, parseExact(text)); }
}
export interface Encodable { toExact(): ExactJson; }
export interface Codec<T extends Encodable> { decodeJson(value: ExactJson): T; }
export function instanceExact(value: Encodable): ExactJson { requireEvidence(value !== null && typeof value === "object" && typeof value.toExact === "function", "typed validated value"); return value.toExact(); }
export function encodeValidated(context: ValueContext, ref: TypeRef, value: Encodable): string { return encodeExact(context.validate(ref, instanceExact(value))); }
export function dynamicExact(value: DynamicValue): ExactJson { return toExact(value); }
export function immutableDynamic(value: ExactJson): DynamicValue { return fromExact(value); }
export function bytesExact(value: Uint8Array, profile: VersionedSemanticProfile): ExactJson {
  requireEvidence(profile.bytes_policy, "bytes policy");
  return profile.bytes_policy.wrapper === null
    ? { tag: "String", value: base64Encode(value, profile.bytes_policy) }
    : wrapEncode(profile, profile.bytes_policy.wrapper, value);
}
export function bytesValue(value: ExactJson, context: ValueContext): Uint8Array {
  const decoded = decodeBytes(context.profile, value);
  requireEvidence(decoded, "valid encoded bytes");
  return decoded;
}

export type ValueSlot<T> = { readonly tag: "Absent" } | { readonly tag: "Null" } | { readonly tag: "Present"; readonly value: T };
export interface ResourceSnapshot { readonly lot: ResourceLotRef; readonly producer: ResourceProducer; readonly revision: bigint; readonly quantity: bigint; readonly provenance: string; }
export class ResourceLedger {
  readonly #lots = new Map<string, ResourceSnapshot>();
  constructor(initial: readonly ResourceLot[]) {
    for (const lot of initial) {
      const reference: ResourceLotRef = { tag: "Initial", value: lot.id };
      this.#lots.set(JSON.stringify(reference), { lot: reference, producer: lot.producer, revision: BigInt(lot.revision), quantity: BigInt(lot.quantity), provenance: lot.provenance });
    }
  }
  reserve(selections: readonly { readonly requirement: string; readonly lot: ResourceLotRef }[], requirements: readonly ResourceRequirement[], backingReads: readonly ResourceLotRef[]): void {
    const normalized = new Map<string, { readonly lot: ResourceLotRef; read: bigint; consume: bigint }>();
    const add = (lot: ResourceLotRef, count: bigint, consume: boolean) => { const key = JSON.stringify(lot), old = normalized.get(key); if (!old) normalized.set(key, { lot, read: consume ? 0n : count, consume: consume ? count : 0n }); else if (consume) old.consume += count; else if (old.read < count) old.read = count; };
    for (const lot of backingReads) add(lot, 1n, false);
    for (const requirement of requirements) {
      const selected = selections.filter(r => r.requirement === requirement.id); requireEvidence(selected.length === 1, "resource requirement coverage");
      const binding = selected[0]!, current = this.#lots.get(JSON.stringify(binding.lot)); requireEvidence(current && current.revision === BigInt(requirement.required_revision) && (requirement.identity.tag === "Any" || same(current.producer, requirement.identity.value)), "resource producer/revision");
      add(binding.lot, BigInt(requirement.multiplicity), requirement.mode.tag === "Consume");
    }
    for (const [key, demand] of normalized) { const lot = this.#lots.get(key); requireEvidence(lot && lot.quantity >= demand.read && lot.quantity >= demand.consume, "resource quantity"); }
    for (const [key, demand] of normalized) { const lot = this.#lots.get(key)!; if (demand.consume > 0n) this.#lots.set(key, { ...lot, quantity: lot.quantity - demand.consume }); }
  }
  produce(site: string, outcome: OutcomeContract): void {
    for (const production of outcome.produced_resources) {
      const lot: ResourceLotRef = { tag: "Produced", fields: { site, outcome: outcome.id, production: production.id } }, key = JSON.stringify(lot);
      requireEvidence(!this.#lots.has(key), "one resource production per invocation");
      this.#lots.set(key, { lot, producer: { tag: "InvocationOutcome", fields: { site, outcome: outcome.id } }, quantity: BigInt(production.quantity), revision: BigInt(production.revision), provenance: production.provenance });
    }
  }
  finish(goals: readonly ResourceGoal[], backingReads: readonly ResourceLotRef[]): readonly ResourceSnapshot[] {
    for (const backing of backingReads) requireEvidence((this.#lots.get(JSON.stringify(backing))?.quantity ?? 0n) >= 1n, "returned resource backing");
    for (const goal of goals) { const lot = this.#lots.get(JSON.stringify(goal.lot)), quantity = BigInt(goal.multiplicity); requireEvidence(quantity === 0n || lot && lot.quantity >= quantity && lot.revision === BigInt(goal.revision), "final resource goal"); }
    return Object.freeze([...this.#lots.values()].map(value => deepFreeze({ ...value })));
  }
  snapshot(): readonly ResourceSnapshot[] { return Object.freeze([...this.#lots.values()].map(value => deepFreeze({ ...value }))); }
}
