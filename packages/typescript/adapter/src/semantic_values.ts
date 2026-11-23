// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { LosslessNumber } from "lossless-json";
import { createScanner } from "jsonc-parser";
import { sha256 } from "@noble/hashes/sha2.js";
import { residual, residualSet, stopped } from "neco-quotient-certificate";
import type { RefinementOutcome, Result, ResidualSet } from "neco-quotient-certificate";
import { nullPrototypeRecord } from "./value.js";

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
export type GraphemeSource = { readonly role: string; readonly origin: { readonly source: SourceIdentity; readonly locator: readonly string[] } };
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
export type Except<T, F> = { readonly tag: "Ok"; readonly value: T } | { readonly tag: "Failed"; readonly failure: F };
export const ok = <T>(value: T): Except<T, never> => ({ tag: "Ok", value });
export const failed = <F>(failure: F): Except<never, F> => ({ tag: "Failed", failure });
export class DeclarationPredicateFailure extends Error {
  constructor(readonly reference: unknown, readonly predicate: string, readonly location: readonly string[]) { super(`${predicate} at ${location.join(".")}`); }
}

const ascii = (text: string): boolean => /^[\x00-\x7F]*$/.test(text);
export function formatRuleWellFormed(rule: FormatRule): boolean {
  if (rule.tag === "Labels") return rule.fields.separator.length > 0 && formatRuleWellFormed(rule.fields.rule);
  if (rule.tag === "Sequence" || rule.tag === "Choice") return rule.value.every(formatRuleWellFormed);
  if (rule.tag === "Optional" || rule.tag === "Not") return formatRuleWellFormed(rule.value);
  if (rule.tag === "Bounded") return formatRuleWellFormed(rule.fields.rule);
  if (rule.tag === "Identifier") return rule.fields.first_alphabet.length > 0 && rule.fields.rest_alphabet.length > 0 && ascii(rule.fields.first_alphabet) && ascii(rule.fields.rest_alphabet) && rule.fields.forbidden.every(unicodeValid) && (rule.fields.exact_length === null || (BigInt(rule.fields.min_length) <= BigInt(rule.fields.exact_length) && (rule.fields.max_length === null || BigInt(rule.fields.exact_length) <= BigInt(rule.fields.max_length)))) && (rule.fields.max_length === null || BigInt(rule.fields.min_length) <= BigInt(rule.fields.max_length));
  if (rule.tag === "AsciiDfa") return BigInt(rule.value.state_count) > 0n && BigInt(rule.value.initial_state) < BigInt(rule.value.state_count) && rule.value.accepting_states.every(state => BigInt(state) < BigInt(rule.value.state_count)) && rule.value.transitions.every(transition => BigInt(transition.from_state) < BigInt(rule.value.state_count) && BigInt(transition.to_state) < BigInt(rule.value.state_count) && BigInt(transition.first) <= BigInt(transition.last) && BigInt(transition.last) < 128n) && rule.value.transitions.every((transition, index) => rule.value.transitions.slice(index + 1).every(other => BigInt(transition.from_state) !== BigInt(other.from_state) || BigInt(transition.last) < BigInt(other.first) || BigInt(other.last) < BigInt(transition.first)));
  if (rule.tag === "Timestamp") return BigInt(rule.value.minimum_year) <= BigInt(rule.value.maximum_year) && BigInt(rule.value.maximum_year) <= 9999n;
  return true;
}

type ProfileFailureRecord = { readonly predicate: ProfilePredicate; readonly location: readonly string[] };

function validProfileReference(ref: ProfileRef): boolean {
  return ref.identity.length > 0 && ref.revision.length > 0 && ref.content_digest.length > 0;
}

function profileRangeValid(range: IntegerDomain): boolean {
  return range.tag !== "Inclusive" || BigInt(range.fields.minimum) <= BigInt(range.fields.maximum);
}

function profileLengthValid(bound: LengthBound): boolean {
  return bound.minimum === null || bound.maximum === null || BigInt(bound.minimum) <= BigInt(bound.maximum);
}

function profileFailure(profile: VersionedSemanticProfile): ProfileFailureRecord | null {
  if (!validProfileReference(profile.reference) || profile.integer_domains.some(item => !validProfileReference(item.reference)) || profile.format_bindings.some(item => !validProfileReference(item.reference)) || profile.bytes_policy !== null && !validProfileReference(profile.bytes_policy.reference) || profile.grapheme_rules !== null && !validProfileReference(profile.grapheme_rules.reference)) return { predicate: "PR01", location: ["profile"] };
  if (!profileNamesUnique(profile.integer_domains.map(item => item.name))) return { predicate: "PR02", location: ["integer_domains"] };
  if (profile.integer_domains.some(item => !profileRangeValid(item.range))) return { predicate: "PR03", location: ["integer_domains"] };
  if (profile.integer_domains.some(item => item.forms.length === 0)) return { predicate: "PR04", location: ["integer_domains"] };
  if (!profile.integer_domains.some(item => item.name === profile.default_integer_domain)) return { predicate: "PR05", location: ["default_integer_domain"] };
  if (!profileNamesUnique(profile.format_bindings.map(item => item.name))) return { predicate: "PR06", location: ["format_bindings"] };
  if (profile.format_bindings.some(item => !formatRuleWellFormed(item.rule))) return { predicate: "PR07", location: ["format_bindings"] };
  if (!profileNamesUnique(profile.wrappers.map(item => item.name)) || !profileNamesUnique(profile.wrappers.map(item => item.key))) return { predicate: "PR08", location: ["wrappers"] };
  if (profile.wrappers.some(item => {
    if (item.payload.tag !== "Text" || item.payload.value === null) return false;
    const formatName = item.payload.value;
    return !profile.format_bindings.some(format => format.name === formatName);
  })) return { predicate: "PR09", location: ["wrappers"] };
  if (profile.bytes_policy?.wrapper !== null && profile.bytes_policy !== null && !profile.wrappers.some(item => item.name === profile.bytes_policy!.wrapper && item.payload.tag === "Bytes")) return { predicate: "PR10", location: ["bytes_policy", "wrapper"] };
  if (profile.tag) {
    if (!profile.tag.key || profile.wrappers.some(item => item.key === profile.tag!.key)) return { predicate: "PR11", location: ["tag", "key"] };
    if (profile.tag.format !== null && !profile.format_bindings.some(item => item.name === profile.tag!.format)) return { predicate: "PR12", location: ["tag", "format"] };
    if (!profileNamesUnique(profile.tag.sealed.map(item => item.tag)) || profile.tag.sealed.some(form => profile.tag!.format !== null && !recognizeFormat(profile.format_bindings.find(binding => binding.name === profile.tag!.format)!.rule, form.tag, profile.grapheme_rules))) return { predicate: "PR13", location: ["tag", "sealed"] };
    if (profile.tag.sealed.some(form => !profileNamesUnique(form.fields.map(field => field.key)) || form.fields.some(field => field.key === profile.tag!.key || profile.wrappers.some(wrapper => wrapper.key === field.key)))) return { predicate: "PR14", location: ["tag", "sealed", "fields"] };
    if (profile.tag.sealed.some(form => form.fields.some(field => {
      if (field.leaf.tag === "Integer") {
        const domainName = field.leaf.value.domain;
        return domainName !== null && !profile.integer_domains.some(domain => domain.name === domainName);
      }
      const spec = field.leaf.value;
      return spec.wrapper !== null && !profile.wrappers.some(wrapper => wrapper.name === spec.wrapper && wrapper.payload.tag === "Text")
        || spec.format?.tag === "Named" && !profile.format_bindings.some(binding => binding.name === spec.format!.value)
        || spec.format?.tag === "Inline" && !formatRuleWellFormed(spec.format.value)
        || spec.lengths.some(bound => !profileLengthValid(bound));
    }))) return { predicate: "PR15", location: ["tag", "sealed", "fields"] };
  }
  const orderedRanges = (rows: readonly CodepointRange[]): boolean => rows.every(row => BigInt(row.first) <= BigInt(row.last));
  if (profile.grapheme_rules && (!orderedRanges(profile.grapheme_rules.properties) || !orderedRanges(profile.grapheme_rules.extended_pictographic) || !orderedRanges(profile.grapheme_rules.indic_conjunct))) return { predicate: "PR16", location: ["grapheme_rules"] };
  return null;
}

const checkedProfileToken = Symbol("checked profile");
export class CheckedProfile {
  private constructor(token: symbol, readonly profile: VersionedSemanticProfile) {
    if (token !== checkedProfileToken) throw new TypeError("checked profile admission authority");
    Object.freeze(this);
  }
  static admit(token: symbol, profile: VersionedSemanticProfile): CheckedProfile { return new CheckedProfile(token, profile); }
}
export function checkProfileDeclaration(profile: VersionedSemanticProfile): CheckedProfile {
  const failure = profileFailure(profile);
  if (failure !== null) throw new DeclarationPredicateFailure(profile.reference, failure.predicate, failure.location);
  return CheckedProfile.admit(checkedProfileToken, deepFreeze(profile));
}

export type WireFailure = { readonly tag: "UnsupportedSchema" | "UnknownField" | "UnknownTag" | "Syntax"; readonly path: string; readonly value: string };
export class WireError extends Error {
  constructor(readonly failure: WireFailure) {
    super(`${failure.tag}:${failure.value}`);
  }
}
export type WireDecoder = (value: unknown, path: string) => void;
type WireVariant = { readonly kind: "unit" } | { readonly kind: "payload"; readonly decode: WireDecoder } | { readonly kind: "fields"; readonly decode: WireDecoder };
export type WireField = readonly [key: string, decode: WireDecoder, at?: "root"];
export function wireSyntax(path: string, message: string): never { throw new WireError({ tag: "Syntax", path, value: message }); }
function plainObject(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype: unknown = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}
export function codePointOrder(left: string, right: string): number {
  let i = 0, j = 0;
  while (i < left.length && j < right.length) {
    const x = left.codePointAt(i)!, y = right.codePointAt(j)!;
    if (x !== y) return x - y;
    i += x > 0xffff ? 2 : 1;
    j += y > 0xffff ? 2 : 1;
  }
  return (i < left.length ? 1 : 0) - (j < right.length ? 1 : 0);
}
export function wireObject(value: unknown, path: string): asserts value is Record<string, unknown> {
  if (!plainObject(value)) wireSyntax(path, "object expected");
}
export function wireKeys(value: unknown, path: string, keys: readonly string[]): asserts value is Record<string, unknown> {
  wireObject(value, path);
  const actual = Object.keys(value).sort(codePointOrder);
  const unknown = actual.find(key => !keys.includes(key));
  if (unknown !== undefined) throw new WireError({ tag: "UnknownField", path: `${path}.${unknown}`, value: unknown });
  const missing = keys.find(key => !actual.includes(key));
  if (missing !== undefined) throw new WireError({ tag: "Syntax", path: `${path}.${missing}`, value: "missing field" });
}
export function wireTag(value: unknown, path: string): string {
  if (!plainObject(value)) wireSyntax(`${path}.tag`, "object expected");
  if (!Object.hasOwn(value, "tag")) wireSyntax(`${path}.tag`, "property not found: tag");
  wireString(value.tag, `${path}.tag`);
  return value.tag as string;
}
export function wireString(value: unknown, path: string): void { if (typeof value !== "string") wireSyntax(path, "String expected"); }
export function wireBool(value: unknown, path: string): void { if (typeof value !== "boolean") wireSyntax(path, "Bool expected"); }
export function wireInt(value: unknown, path: string): void {
  wireString(value, path);
  const text = value as string;
  if (!/^[0-9]+(?:_[0-9]+)*$/.test(text.startsWith("-") ? text.slice(1) : text)) wireSyntax(path, "expected canonical integer");
  if (!/^(?:0|-?[1-9][0-9]*)$/.test(text)) wireSyntax(path, "noncanonical integer");
}
export function wireNat(value: unknown, path: string): void {
  wireInt(value, path);
  if ((value as string).startsWith("-")) wireSyntax(path, "negative natural");
}
export function wireList(decode: WireDecoder): WireDecoder {
  return (value, path) => {
    if (!Array.isArray(value)) wireSyntax(path, "array expected");
    value.forEach((item, index) => decode(item, `${path}[${index}]`));
  };
}
export function wireElements(decode: WireDecoder): WireDecoder {
  return (value, path) => {
    if (!Array.isArray(value)) wireSyntax(path, "array expected");
    for (const item of value) decode(item, path);
  };
}
export function wireOption(decode: WireDecoder): WireDecoder {
  return (value, path) => { if (value !== null) decode(value, path); };
}
export function wireRecord(fields: readonly WireField[]): WireDecoder {
  return (value, path) => {
    wireKeys(value, path, fields.map(field => field[0]));
    for (const [key, decode, at] of fields) decode(value[key], at === "root" ? path : `${path}.${key}`);
  };
}
function taggedWith(variants: Readonly<Record<string, WireVariant>>, keyed: boolean): WireDecoder {
  return (value, path) => {
    const tag = wireTag(value, path);
    if (!Object.hasOwn(variants, tag)) throw new WireError({ tag: "UnknownTag", path: `${path}.tag`, value: tag });
    const variant = variants[tag]!;
    if (variant.kind === "unit") { wireKeys(value, path, ["tag"]); return; }
    if (variant.kind === "payload") { wireKeys(value, path, ["tag", "value"]); variant.decode(value.value, keyed ? `${path}.value` : path); return; }
    wireKeys(value, path, ["tag", "fields"]);
    variant.decode(value.fields, keyed ? `${path}.fields` : path);
  };
}
export function wireTagged(variants: Readonly<Record<string, WireVariant>>): WireDecoder { return taggedWith(variants, false); }
export function wireUnit(): WireVariant { return { kind: "unit" }; }
export function wirePayload(decode: WireDecoder): WireVariant { return { kind: "payload", decode }; }
export function wireFieldsOf(decode: WireDecoder): WireVariant { return { kind: "fields", decode }; }
const wireBytesAlphabet = wireTagged({ Standard: wireUnit(), UrlSafe: wireUnit(), Either: wireUnit() });
export const wireStringLengthUnit = wireTagged({ Utf8Bytes: wireUnit(), UnicodeScalars: wireUnit(), Graphemes: wireUnit() });
const wireGraphemeProperty = wireTagged({ Other: wireUnit(), Cr: wireUnit(), Lf: wireUnit(), Control: wireUnit(), Extend: wireUnit(), Zwj: wireUnit(), RegionalIndicator: wireUnit(), Prepend: wireUnit(), SpacingMark: wireUnit(), L: wireUnit(), V: wireUnit(), T: wireUnit(), Lv: wireUnit(), Lvt: wireUnit() });
const wireIndicProperty = wireTagged({ Other: wireUnit(), Consonant: wireUnit(), Extend: wireUnit(), Linker: wireUnit() });
const wireIntegerForm = wireTagged({ Number: wireUnit(), IntegralDecimal: wireUnit(), DecimalString: wireUnit() });
const wireIntegerDomain = wireTagged({ Unbounded: wireUnit(), Inclusive: wireFieldsOf(wireRecord([["minimum", wireInt], ["maximum", wireInt]])) });
const wireSealedExtras = wireTagged({ Reject: wireUnit(), Any: wireUnit() });
export const wireProfileRef = wireRecord([["identity", wireString], ["revision", wireString], ["content_digest", wireString]]);
export const wireSourceIdentity = wireRecord([["repository", wireString], ["revision", wireString], ["path", wireString], ["content_digest", wireString]]);
export const wireOrigin = wireRecord([["source", wireSourceIdentity], ["locator", wireList(wireString)]]);
const wireIntegerDomainBinding = wireRecord([["name", wireString], ["reference", wireProfileRef], ["range", wireIntegerDomain], ["forms", wireList(wireIntegerForm)]]);
const wireNumberModel = wireRecord([["decimals", wireBool]]);
const wireCodepointRange = wireRecord([["first", wireNat], ["last", wireNat]]);
const wireGraphemeRange = wireRecord([["first", wireNat], ["last", wireNat], ["property", wireGraphemeProperty]]);
const wireIndicRange = wireRecord([["first", wireNat], ["last", wireNat], ["property", wireIndicProperty]]);
const wireGraphemeComponent = wireRecord([["unicode_version", wireString], ["uax29_revision", wireString], ["cluster_profile", wireString]]);
const wireGraphemeSource = wireRecord([["role", wireString], ["origin", wireOrigin]]);
const wireGraphemeRules = wireRecord([["reference", wireProfileRef], ["component", wireGraphemeComponent], ["table_sha256", wireString], ["sources", wireList(wireGraphemeSource)], ["properties", wireList(wireGraphemeRange)], ["extended_pictographic", wireList(wireCodepointRange)], ["indic_conjunct", wireList(wireIndicRange)]]);
const wireBytesPolicy = wireRecord([["reference", wireProfileRef], ["padding_optional", wireBool], ["alphabet", wireBytesAlphabet], ["strict_pad_bits", wireBool], ["wrapper", wireOption(wireString)]]);
const wireCalendarRule = wireRecord([["allow_second_60", wireBool], ["minimum_year", wireNat], ["maximum_year", wireNat], ["rejectUtcYearOutsideRange", wireBool]]);
const wireDfaTransition = wireRecord([["from_state", wireNat], ["first", wireNat], ["last", wireNat], ["to_state", wireNat]]);
const wireDfaSpec = wireRecord([["state_count", wireNat], ["initial_state", wireNat], ["accepting_states", wireList(wireNat)], ["transitions", wireList(wireDfaTransition)]]);
const wireFormatRuleTagged = wireTagged({
  Literal: wirePayload(wireString),
  Sequence: wirePayload(wireElements(wireFormatRule)),
  Optional: wirePayload(wireFormatRule),
  Labels: wireFieldsOf(wireRecord([["separator", wireString], ["min_count", wireNat], ["max_count", wireOption(wireNat)], ["total_max", wireOption(wireNat)], ["rule", wireFormatRule, "root"]])),
  Bounded: wireFieldsOf(wireRecord([["unit", wireStringLengthUnit], ["maximum", wireNat], ["rule", wireFormatRule, "root"]])),
  AsciiDfa: wirePayload(wireDfaSpec),
  Timestamp: wirePayload(wireCalendarRule),
  Choice: wirePayload(wireElements(wireFormatRule)),
  Identifier: wireFieldsOf(wireRecord([["first_alphabet", wireString], ["rest_alphabet", wireString], ["exact_length", wireOption(wireNat)], ["min_length", wireNat], ["max_length", wireOption(wireNat)], ["forbidden", wireList(wireString)]])),
  AbsoluteUri: wireFieldsOf(wireRecord([["max_bytes", wireOption(wireNat)]])),
  LanguageTag: wireFieldsOf(wireRecord([["grandfathered", wireList(wireString)]])),
  Text: wireUnit(),
  Not: wirePayload(wireFormatRule),
});
export function wireFormatRule(value: unknown, path: string): void { wireFormatRuleTagged(value, path); }
export const wireLengthBound = wireRecord([["unit", wireStringLengthUnit], ["minimum", wireOption(wireNat)], ["maximum", wireOption(wireNat)]]);
export const wireFormatUse = wireTagged({ Named: wirePayload(wireString), Inline: wirePayload(wireFormatRule) });
export const wireIntegerSpec = wireRecord([["domain", wireOption(wireString)], ["minimum", wireOption(wireInt)], ["maximum", wireOption(wireInt)], ["const_value", wireOption(wireInt)], ["enum_values", wireOption(wireList(wireInt))], ["default_value", wireOption(wireInt)]]);
export const wireStringSpec = wireRecord([["format", wireOption(wireFormatUse)], ["lengths", wireList(wireLengthBound)], ["wrapper", wireOption(wireString)], ["const_value", wireOption(wireString)], ["enum_values", wireOption(wireList(wireString))], ["examples", wireList(wireString)], ["default_value", wireOption(wireString)]]);
const wireWrapperPayload = wireTagged({ Bytes: wireUnit(), Text: wirePayload(wireOption(wireString)) });
const wireWrapper = wireRecord([["name", wireString], ["key", wireString], ["payload", wireWrapperPayload]]);
export const wireSealedLeaf = wireTagged({ String: wirePayload(wireStringSpec), Integer: wirePayload(wireIntegerSpec) });
const wireSealedField = wireRecord([["key", wireString], ["required", wireBool], ["leaf", wireSealedLeaf]]);
const wireSealedForm = wireRecord([["tag", wireString], ["fields", wireList(wireSealedField)], ["extras", wireSealedExtras]]);
const wireTagModel = wireRecord([["key", wireString], ["format", wireOption(wireString)], ["sealed", wireList(wireSealedForm)]]);
const wireFormatBinding = wireRecord([["name", wireString], ["reference", wireProfileRef], ["rule", wireFormatRule]]);
export const wireVersionedSemanticProfile = wireRecord([["reference", wireProfileRef], ["source_refs", wireList(wireSourceIdentity)], ["integer_domains", wireList(wireIntegerDomainBinding)], ["default_integer_domain", wireString], ["numbers", wireNumberModel], ["grapheme_rules", wireOption(wireGraphemeRules)], ["format_bindings", wireList(wireFormatBinding)], ["bytes_policy", wireOption(wireBytesPolicy)], ["wrappers", wireList(wireWrapper)], ["tag", wireOption(wireTagModel)]]);
export function decodeProfileWireFields(value: unknown): VersionedSemanticProfile {
  wireVersionedSemanticProfile(value, "$");
  return structuredClone(value as VersionedSemanticProfile);
}
export function decodeVersionedProfileWire(value: unknown): VersionedSemanticProfile {
  return checkProfileDeclaration(decodeProfileWireFields(value)).profile;
}

export type CanonicalProfileSource = { readonly repository: string; readonly revision: string; readonly path: string; readonly sha256: string };
export function decodeCanonicalProfileArtifact(expected: ProfileRef, sourceRefs: readonly SourceIdentity[], artifactText: string, expectedProfileBytes: string): VersionedSemanticProfile {
  requireEvidence(expected.content_digest !== "" && artifactText === expectedProfileBytes, "profile artifact bytes");
  const syntax = admissionFailure(artifactText);
  if (syntax !== null) wireSyntax("$", syntax);
  let parsed: unknown;
  try { parsed = JSON.parse(artifactText); } catch { throw new SemanticEvidenceError("canonical artifact JSON"); }
  const decoded = decodeProfileWireFields(parsed);
  requireEvidence(same(decoded.reference, expected), "profile reference");
  requireEvidence(same(decoded.source_refs, sourceRefs), "profile sources");
  return checkProfileDeclaration(decoded).profile;
}
export type FieldSpec = { readonly wire_name: string; readonly slot: SlotContract; readonly origin: OccurrenceRef };
export type ElementContract = { readonly type_ref: TypeRef; readonly nullable: boolean };
export type ExtraMembers = { readonly tag: "Reject" } | { readonly tag: "Allow"; readonly fields: { readonly key_format: FormatUse | null; readonly value: ElementContract } };
export type ProductSpec = { readonly fields: readonly FieldSpec[]; readonly extras: ExtraMembers };
export type ArraySpec = { readonly item: ElementContract; readonly min_length: string | null; readonly max_length: string | null };
export type ValueKind = { readonly tag: "Null" | "Boolean" | "Number" | "String" | "Array" | "Object" };
export type MemberTest = { readonly tag: "Absent" } | { readonly tag: "Format"; readonly value: string };
export type MemberCheck = { readonly key: string; readonly test: MemberTest };
export type BranchSelector = { readonly tag: "InternalTag" } | { readonly tag: "MemberShape"; readonly value: readonly MemberCheck[] } | { readonly tag: "Kind"; readonly value: ValueKind } | { readonly tag: "Otherwise" };
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
export type ValueGraph = { readonly profile: VersionedSemanticProfile; readonly nodes: readonly TypeNode[] };
export type DynamicValue = null | boolean | bigint | LosslessNumber | string | readonly DynamicValue[] | { readonly [key: string]: DynamicValue };
export class DecimalValue extends LosslessNumber {
  constructor(text: string) { super(text); Object.freeze(this); }
}
export type ValueCondition =
  | { readonly tag: "MissingRequired" }
  | { readonly tag: "NullNotAllowed" }
  | { readonly tag: "WrongValueKind"; readonly value: string }
  | { readonly tag: "ConstMismatch" }
  | { readonly tag: "EnumMismatch" }
  | { readonly tag: "BelowMinimum" }
  | { readonly tag: "AboveMaximum" }
  | { readonly tag: "IntegerDomain" }
  | { readonly tag: "StringLength" }
  | { readonly tag: "ArrayLength" }
  | { readonly tag: "BytesLength" }
  | { readonly tag: "Format"; readonly value: string }
  | { readonly tag: "InvalidBytes" }
  | { readonly tag: "InvalidWrapper"; readonly value: string }
  | { readonly tag: "InvalidTag" }
  | { readonly tag: "ReservedForm" }
  | { readonly tag: "NoBranchSelected" }
  | { readonly tag: "KeyFormat"; readonly value: string }
  | { readonly tag: "Uninhabited" }
  | { readonly tag: "DuplicateField"; readonly value: string }
  | { readonly tag: "UnexpectedField"; readonly value: string }
  | { readonly tag: "InvalidDataModel" }
  | { readonly tag: "ReferenceCycle" };
function valueConditionText(condition: ValueCondition): string {
  return "value" in condition ? `${condition.tag}:${condition.value}` : condition.tag;
}
export interface ValueFailure { readonly type: TypeRef; readonly definitionRef: DefinitionRef; readonly origin: OccurrenceRef; readonly path: readonly (string | bigint)[]; readonly condition: ValueCondition; readonly observed: ExactSlot; readonly referenceTrace: readonly TypeRef[]; }
export function valueFailure(type: TypeRef, path: readonly (string | bigint)[], condition: ValueCondition, observed: ExactSlot, referenceTrace: readonly TypeRef[]): ValueFailure {
  return { type, definitionRef: { source: type.source, name: type.definition_name }, origin: { source: type.source, pointer: type.pointer }, path, condition, observed, referenceTrace };
}
export class SemanticValueError extends Error {
  constructor(readonly failure: ValueFailure) { super(`${failure.type.source.path}#${failure.type.definition_name}: ${failure.path.join(".")}: ${valueConditionText(failure.condition)}`); }
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
  if (left === null || right === null || typeof left !== "object" || typeof right !== "object" || Array.isArray(left) || Array.isArray(right)) return false;
  const a = left as Record<string, unknown>, b = right as Record<string, unknown>, keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every(k => Object.hasOwn(b, k) && same(a[k], b[k]));
}
export function formatRuleEqual(source: FormatRule, destination: FormatRule): boolean {
  switch (source.tag) {
    case "Literal": return destination.tag === "Literal" && source.value === destination.value;
    case "Sequence": return destination.tag === "Sequence" && formatRulesEqual(source.value, destination.value);
    case "Optional": return destination.tag === "Optional" && formatRuleEqual(source.value, destination.value);
    case "Labels": return destination.tag === "Labels" && source.fields.separator === destination.fields.separator
      && source.fields.min_count === destination.fields.min_count && source.fields.max_count === destination.fields.max_count
      && source.fields.total_max === destination.fields.total_max && formatRuleEqual(source.fields.rule, destination.fields.rule);
    case "Bounded": return destination.tag === "Bounded" && same(source.fields.unit, destination.fields.unit)
      && source.fields.maximum === destination.fields.maximum && formatRuleEqual(source.fields.rule, destination.fields.rule);
    case "AsciiDfa": return destination.tag === "AsciiDfa" && same(source.value, destination.value);
    case "Identifier": return destination.tag === "Identifier" && same(source.fields, destination.fields);
    case "Timestamp": return destination.tag === "Timestamp" && same(source.value, destination.value);
    case "AbsoluteUri": return destination.tag === "AbsoluteUri" && source.fields.max_bytes === destination.fields.max_bytes;
    case "LanguageTag": return destination.tag === "LanguageTag" && same(source.fields.grandfathered, destination.fields.grandfathered);
    case "Choice": return destination.tag === "Choice" && formatRulesEqual(source.value, destination.value);
    case "Text": return destination.tag === "Text";
    case "Not": return destination.tag === "Not" && formatRuleEqual(source.value, destination.value);
  }
}
export function formatRulesEqual(sources: readonly FormatRule[], destinations: readonly FormatRule[]): boolean {
  return sources.length === destinations.length && sources.every((rule, index) => formatRuleEqual(rule, destinations[index]!));
}
export function profileNamesUnique(values: readonly string[]): boolean { return values.every(Boolean) && new Set(values).size === values.length; }
export function deepFreeze<T>(value: T): T {
  const pending: unknown[] = [value];
  while (pending.length > 0) {
    const item = pending.pop();
    if (item !== null && typeof item === "object" && !Object.isFrozen(item)) {
      for (const child of Object.values(item)) pending.push(child);
      Object.freeze(item);
    }
  }
  return value;
}

/** Copies a tree of plain objects, arrays, and primitives without recursion, with the result of structuredClone for such values. */
export function cloneTree<T>(root: T): T {
  const containers: object[] = [];
  const pending: unknown[] = [root];
  while (pending.length > 0) {
    const item = pending.pop();
    if (item === null || typeof item !== "object") continue;
    containers.push(item);
    for (const child of Object.values(item)) pending.push(child);
  }
  const copies = new Map<object, unknown>();
  const copyOf = (item: unknown): unknown => item !== null && typeof item === "object" ? copies.get(item) : item;
  for (let index = containers.length - 1; index >= 0; index--) {
    const item = containers[index]!;
    if (Array.isArray(item)) {
      copies.set(item, item.map(copyOf));
      continue;
    }
    const copy: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(item)) Object.defineProperty(copy, key, { value: copyOf(child), enumerable: true, writable: true, configurable: true });
    copies.set(item, copy);
  }
  return copyOf(root) as T;
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
export function parseLossless(text: string): unknown { return parseJson(text, losslessBuilder); }
export function toExact(value: unknown): ExactJson {
  if (value === null) return { tag: "Null" };
  if (typeof value === "boolean") return { tag: "Bool", value };
  if (typeof value === "string") { requireEvidence(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value), "Unicode scalar string"); return { tag: "String", value }; }
  if (typeof value === "bigint") return { tag: "Integer", value: value.toString() };
  if (value instanceof DecimalValue) return { tag: "Decimal", text: value.value };
  if (value instanceof LosslessNumber) return exactNumber(value.value);
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
      const out = nullPrototypeRecord<DynamicValue>();
      for (const { key, value: item } of value.members) { requireEvidence(!Object.hasOwn(out, key), "duplicate member"); out[key] = fromExact(item); }
      return Object.freeze(preserveObjectOrder(out, value.members.map(item => item.key)));
    }
  }
}
const exponentLimit = 10000;
function hexDigit(code: number): number | null {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x41 && code <= 0x46) return code - 0x37;
  if (code >= 0x61 && code <= 0x66) return code - 0x57;
  return null;
}
function hexCode(text: string, start: number): number | null {
  let code = 0;
  for (let offset = 0; offset < 4; offset += 1) {
    const digit = hexDigit(text.charCodeAt(start + offset));
    if (digit === null) return null;
    code = code * 16 + digit;
  }
  return code;
}
function exponentDigits(text: string, start: number): number {
  const code = text.charCodeAt(start);
  return code === 0x2d || code === 0x2b ? start + 1 : start;
}
function exponentValue(text: string, index: number, value: number, count: number): readonly [number, number] {
  let next = index, accumulated = value, digits = count;
  for (; next < text.length; next += 1) {
    const code = text.charCodeAt(next);
    if (code < 0x30 || code > 0x39) break;
    accumulated = Math.min(exponentLimit, accumulated * 10 + (code - 0x30)); digits += 1;
  }
  return [accumulated, digits];
}
function exponentMagnitudeAtLimit(text: string, start: number): boolean {
  const [value, count] = exponentValue(text, exponentDigits(text, start), 0, 0);
  return count > 0 && value >= exponentLimit;
}
function isHighSurrogate(code: number): boolean { return 0xd800 <= code && code <= 0xdbff; }
function isLowSurrogate(code: number): boolean { return 0xdc00 <= code && code <= 0xdfff; }
export function admissionFailure(text: string): string | null {
  let inString = false;
  for (let index = 0; index < text.length;) {
    const character = text.charCodeAt(index);
    if (character === 0x22) { inString = !inString; index += 1; continue; }
    if (inString && character === 0x5c) {
      if (text.charCodeAt(index + 1) !== 0x75) { index += 2; continue; }
      const code = hexCode(text, index + 2);
      if (code === null) { index += 2; continue; }
      if (isLowSurrogate(code)) return "unpaired Unicode surrogate";
      if (isHighSurrogate(code)) {
        const low = text.charCodeAt(index + 6) === 0x5c && text.charCodeAt(index + 7) === 0x75 ? hexCode(text, index + 8) : null;
        if (low === null || !isLowSurrogate(low)) return "unpaired Unicode surrogate";
        index += 12;
        continue;
      }
      index += 6;
      continue;
    }
    if (!inString && (character === 0x65 || character === 0x45) && exponentMagnitudeAtLimit(text, index + 1)) return "exponent too large";
    index += 1;
  }
  return null;
}
interface JsonBuilder<T> {
  readonly null: () => T;
  readonly bool: (value: boolean) => T;
  readonly string: (value: string) => T;
  readonly number: (source: string) => T;
  readonly array: (items: T[]) => T;
  readonly object: (members: { readonly key: string; readonly value: T }[]) => T;
}
type JsonArrayFrame<T> = { readonly items: T[] };
type JsonObjectFrame<T> = { readonly members: { readonly key: string; readonly value: T }[]; readonly names: Set<string>; key: string };
type JsonFrame<T> = JsonArrayFrame<T> | JsonObjectFrame<T>;
const jsonToken = { openBrace: 1, closeBrace: 2, openBracket: 3, closeBracket: 4, comma: 5, colon: 6, nullKeyword: 7, trueKeyword: 8, falseKeyword: 9, string: 10, number: 11, lineBreak: 14, trivia: 15, end: 17 } as const;
type JsonParser<T> = { readonly scanner: ReturnType<typeof createScanner>; token: number; readonly stack: JsonFrame<T>[]; readonly build: JsonBuilder<T> };
function jsonSyntax(): never { throw new SemanticEvidenceError("strict JSON syntax"); }
function scanJsonToken<T>(parser: JsonParser<T>): number {
  for (;;) {
    const kind = parser.scanner.scan();
    if (parser.scanner.getTokenError() !== 0) jsonSyntax();
    if (kind !== jsonToken.trivia && kind !== jsonToken.lineBreak) return kind;
  }
}
function strictValue<T>(parser: JsonParser<T>): T | undefined {
  switch (parser.token) {
    case jsonToken.openBracket:
      parser.token = scanJsonToken(parser);
      if (parser.token !== jsonToken.closeBracket) { parser.stack.push({ items: [] }); return undefined; }
      return parser.build.array([]);
    case jsonToken.openBrace: {
      parser.token = scanJsonToken(parser);
      if (parser.token !== jsonToken.closeBrace) { const frame: JsonObjectFrame<T> = { members: [], names: new Set<string>(), key: "" }; parser.stack.push(frame); strictObject(parser, frame); return undefined; }
      return parser.build.object([]);
    }
    case jsonToken.nullKeyword: return parser.build.null();
    case jsonToken.trueKeyword: return parser.build.bool(true);
    case jsonToken.falseKeyword: return parser.build.bool(false);
    case jsonToken.string: return parser.build.string(parser.scanner.getTokenValue());
    case jsonToken.number: return parser.build.number(parser.scanner.getTokenValue());
    default: return jsonSyntax();
  }
}
function strictObject<T>(parser: JsonParser<T>, frame: JsonObjectFrame<T>): void {
  if (parser.token !== jsonToken.string) jsonSyntax();
  const key = parser.scanner.getTokenValue();
  requireEvidence(!frame.names.has(key), `duplicate object key: ${key}`);
  frame.names.add(key);
  frame.key = key;
  if (scanJsonToken(parser) !== jsonToken.colon) jsonSyntax();
  parser.token = scanJsonToken(parser);
}
function strictArray<T>(parser: JsonParser<T>, frame: JsonArrayFrame<T>, value: T): T | undefined {
  frame.items.push(value);
  parser.token = scanJsonToken(parser);
  if (parser.token === jsonToken.comma) { parser.token = scanJsonToken(parser); return undefined; }
  if (parser.token !== jsonToken.closeBracket) jsonSyntax();
  parser.stack.pop();
  return parser.build.array(frame.items);
}
function strictObjectMember<T>(parser: JsonParser<T>, frame: JsonObjectFrame<T>, value: T): T | undefined {
  frame.members.push({ key: frame.key, value });
  parser.token = scanJsonToken(parser);
  if (parser.token === jsonToken.comma) { parser.token = scanJsonToken(parser); strictObject(parser, frame); return undefined; }
  if (parser.token !== jsonToken.closeBrace) jsonSyntax();
  parser.stack.pop();
  return parser.build.object(frame.members);
}
function parseJson<T>(text: string, build: JsonBuilder<T>): T {
  const parser: JsonParser<T> = { scanner: createScanner(text, false), token: 0, stack: [], build };
  parser.token = scanJsonToken(parser);
  for (;;) {
    let value = strictValue(parser);
    while (value !== undefined) {
      const frame = parser.stack[parser.stack.length - 1];
      if (frame === undefined) { if (scanJsonToken(parser) !== jsonToken.end) jsonSyntax(); return value; }
      value = "items" in frame ? strictArray(parser, frame, value) : strictObjectMember(parser, frame, value);
    }
  }
}
function leanJsonNumberText(mantissa: bigint, exponent: bigint): string {
  const sign = mantissa < 0n ? "-" : "";
  const magnitude = mantissa < 0n ? -mantissa : mantissa;
  const scientific = 9n + BigInt(magnitude.toString().length) - exponent;
  const shift = scientific < 0n ? scientific : 0n;
  const divisor = 10n ** (exponent + shift);
  const left = (magnitude / divisor).toString();
  if (magnitude % divisor === 0n && shift === 0n) return sign + left;
  const right = (divisor + magnitude % divisor).toString().slice(1).replace(/0+$/, "");
  return `${sign}${left}.${right}${shift === 0n ? "" : `e${shift}`}`;
}
function exactNumber(source: string): ExactJson {
  const parts = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?)([0-9]+))?$/.exec(source);
  if (parts === null) throw new SemanticEvidenceError("exact JSON number");
  const [, sign, whole, fraction = "", expSign, expDigits] = parts;
  let mantissa = BigInt(whole + fraction) * (sign === "-" ? -1n : 1n);
  let exponent = BigInt(fraction.length);
  if (expDigits !== undefined) {
    const count = BigInt(expDigits);
    if (expSign === "-") exponent += count;
    else if (count >= exponent) { mantissa *= 10n ** (count - exponent); exponent = 0n; }
    else exponent -= count;
  }
  if (exponent === 0n) return { tag: "Integer", value: mantissa.toString() };
  return { tag: "Decimal", text: mantissa === 0n ? "0" : leanJsonNumberText(mantissa, exponent) };
}
const exactBuilder: JsonBuilder<ExactJson> = {
  null: () => ({ tag: "Null" }),
  bool: value => ({ tag: "Bool", value }),
  string: value => toExact(value),
  number: exactNumber,
  array: items => ({ tag: "Array", items }),
  object: members => ({ tag: "Object", members: [...members].sort((left, right) => codePointOrder(left.key, right.key)) }),
};
const losslessBuilder: JsonBuilder<unknown> = {
  null: () => null,
  bool: value => value,
  string: value => { toExact(value); return value; },
  number: source => /^-?(0|[1-9][0-9]*)$/.test(source) ? new LosslessNumber(BigInt(source).toString()) : new DecimalValue(source),
  array: items => items,
  object: members => { const object = nullPrototypeRecord<unknown>(); for (const member of members) object[member.key] = member.value; return object; },
};
export function parseExact(text: string): ExactJson { return parseJson(text, exactBuilder); }
function boundedJsonParse<T>(text: string, build: JsonBuilder<T>): T {
  const failure = admissionFailure(text);
  if (failure !== null) wireSyntax("$", failure);
  try { return parseJson(text, build); }
  catch (error) {
    if (error instanceof SemanticEvidenceError) wireSyntax(error.path, error.condition);
    throw error;
  }
}
export function boundedParseLossless(text: string): unknown { return boundedJsonParse(text, losslessBuilder); }
export function boundedParseExact(text: string): ExactJson { return boundedJsonParse(text, exactBuilder); }
export function parsesAsJsonNumber(text: string): boolean {
  if (admissionFailure(text) !== null) return false;
  try { return parseLossless(text) instanceof LosslessNumber; }
  catch (error) {
    if (error instanceof SemanticEvidenceError) return false;
    throw error;
  }
}
export function numberText(text: string): string {
  if (admissionFailure(text) === "exponent too large") throw new SemanticEvidenceError("exponent too large");
  const number = exactNumber(text);
  if (number.tag === "Integer") return `${number.value}.0`;
  if (number.tag !== "Decimal") throw new SemanticEvidenceError("exact JSON number");
  return number.text.includes(".") ? number.text : `${number.text}.0`;
}
export function encodeExact(value: ExactJson): string {
  const parts: string[] = [];
  const pending: (ExactJson | string)[] = [value];
  while (pending.length > 0) {
    const item = pending.pop()!;
    if (typeof item === "string") {
      parts.push(item);
      continue;
    }
    switch (item.tag) {
      case "Null": parts.push("null"); break;
      case "Bool": parts.push(item.value ? "true" : "false"); break;
      case "Integer": parts.push(item.value); break;
      case "Decimal": parts.push(numberText(item.text)); break;
      case "String": parts.push(JSON.stringify(item.value)); break;
      case "Array":
        parts.push("[");
        pending.push("]");
        for (let index = item.items.length - 1; index >= 0; index--) {
          pending.push(item.items[index]!);
          if (index > 0) pending.push(",");
        }
        break;
      case "Object":
        parts.push("{");
        pending.push("}");
        for (let index = item.members.length - 1; index >= 0; index--) {
          const member = item.members[index]!;
          pending.push(member.value);
          pending.push(`${JSON.stringify(member.key)}:`);
          if (index > 0) pending.push(",");
        }
        break;
    }
  }
  return parts.join("");
}
export function exactObject(members: readonly { readonly key: string; readonly value: ExactJson }[]): ExactJson { return { tag: "Object", members }; }
export function slotOf(value: ExactJson | undefined): ExactSlot { return value === undefined ? { tag: "Absent" } : value.tag === "Null" ? { tag: "Null" } : { tag: "Present", value }; }
export function presentContract(typeRef: TypeRef): SlotContract { return { type_ref: typeRef, required: true, nullable: false }; }
export function indexText(value: string): boolean { return /^(0|[1-9][0-9]*)$/.test(value); }
function tagMatches(profile: VersionedSemanticProfile, members: readonly { readonly key: string; readonly value: ExactJson }[], tag: string): boolean {
  if (profile.tag === null) return false;
  const actual = memberValue(profile.tag.key, members);
  return actual?.tag === "String" && actual.value === tag;
}
function valueAtPath(profile: VersionedSemanticProfile, root: ExactJson, path: readonly PathStep[]): ExactSlot {
  let value = root;
  for (const step of path) {
    if (value.tag === "Null") return { tag: "Null" };
    if (step.tag === "Field") {
      const child = value.tag === "Object" ? memberValue(step.value, value.members) : undefined;
      if (child === undefined) return { tag: "Absent" };
      if (child.tag === "Null") return { tag: "Null" };
      value = child;
    } else if (step.tag === "Index") {
      if (value.tag !== "Array" || !indexText(step.value) || BigInt(step.value) >= BigInt(value.items.length)) return { tag: "Absent" };
      const item = value.items[Number(step.value)]!;
      if (item.tag === "Null") return { tag: "Null" };
      value = item;
    } else if (value.tag !== "Object" || !tagMatches(profile, value.members, step.value)) return { tag: "Absent" };
  }
  return { tag: "Present", value };
}
export function projectedValue(value: ExactSlot, path: readonly PathStep[], profile: VersionedSemanticProfile): ExactSlot {
  if (value.tag !== "Present") return value;
  return valueAtPath(profile, value.value, path);
}
const utf8Encoder = new TextEncoder();
export function encodeTuple(parts: readonly string[]): string { return parts.map(s => `${utf8Encoder.encode(s).length}:${s}`).join(""); }
export function typeIdentity(ref: TypeRef): string {
  const declared = ref.source.declared_revision;
  return encodeTuple([
    "type", ref.source.repository, ref.source.revision, ref.source.path, ref.source.content_digest,
    ref.source.document_id, declared === undefined || declared === null ? "none" : "some",
    declared ?? "", ref.definition_name, encodeTuple(ref.pointer),
  ]);
}
function extraChildren(extras: ExtraMembers): readonly TypeRef[] {
  return extras.tag === "Allow" ? [extras.fields.value.type_ref] : [];
}

export function typeChildren(shape: TypeShape): readonly TypeRef[] {
  switch (shape.tag) {
    case "Product": return [...shape.value.fields.map(field => field.slot.type_ref), ...extraChildren(shape.value.extras)];
    case "Array": return [shape.value.item.type_ref];
    case "Alias": return [shape.fields.target];
    case "TaggedUnion": return shape.value.branches.map(branch => branch.target);
    default: return [];
  }
}
function base64Digit(alphabet: BytesAlphabet, character: string): number | null {
  const common = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const commonValue = common.indexOf(character);
  if (commonValue >= 0) return commonValue;
  if (character === "+" && alphabet.tag !== "UrlSafe" || character === "-" && alphabet.tag !== "Standard") return 62;
  if (character === "/" && alphabet.tag !== "UrlSafe" || character === "_" && alphabet.tag !== "Standard") return 63;
  return null;
}
function base64TailBits(alphabet: BytesAlphabet, text: string, remainder: number): boolean {
  if (text.length === 0) return true;
  const digit = base64Digit(alphabet, text[text.length - 1]!);
  if (digit === null) return false;
  return remainder === 2 ? digit % 16 === 0 : remainder === 3 ? digit % 4 === 0 : true;
}
export function base64Length(text: string, policy: BytesPolicy): number | null {
  const parts = text.split("="), body = parts[0]!, padding = parts.length - 1, remainder = body.length % 4;
  if (padding > 2 || parts.slice(1).some(part => part !== "")) return null;
  if (remainder === 1 || [...body].some(character => base64Digit(policy.alphabet, character) === null)) return null;
  if (policy.strict_pad_bits && !base64TailBits(policy.alphabet, body, remainder)) return null;
  if (padding > 0 && (text.length % 4 !== 0 || padding !== (4 - remainder) % 4)) return null;
  if (padding === 0 && !policy.padding_optional && remainder !== 0) return null;
  return Math.floor(body.length / 4) * 3 + (remainder === 0 ? 0 : remainder - 1);
}
export function base64Decode(text: string, policy: BytesPolicy): Uint8Array | null {
  const length = base64Length(text, policy);
  if (length === null) return null;
  const digits = [...text.split("=")[0]!].map(character => base64Digit(policy.alphabet, character));
  const out = new Uint8Array(length); let bits = 0, acc = 0, index = 0;
  for (const digit of digits) { acc = (acc << 6) | digit!; bits += 6; if (bits >= 8) { bits -= 8; out[index++] = (acc >> bits) & 255; } acc &= (1 << bits) - 1; }
  return out;
}
export function base64Encode(bytes: Uint8Array, policy: BytesPolicy): string {
  const alphabet = policy.alphabet.tag === "UrlSafe" ? "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" : "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; let text = "";
  for (let i = 0; i < bytes.length; i += 3) { const a = bytes[i]!, b = bytes[i + 1], c = bytes[i + 2]; text += alphabet[a >> 2]! + alphabet[((a & 3) << 4) | ((b ?? 0) >> 4)]! + (b === undefined ? "=" : alphabet[((b & 15) << 2) | ((c ?? 0) >> 6)]!) + (c === undefined ? "=" : alphabet[c & 63]!); }
  return text;
}
function asciiLower(text: string): string { return text.replace(/[A-Z]/g, c => c.toLowerCase()); }
function languageSubtag(minimum: number, maximum: number, text: string): boolean {
  return minimum <= text.length && text.length <= maximum && /^[a-z0-9]*$/.test(text);
}
function prefixWhile(items: readonly string[], holds: (item: string) => boolean): readonly string[] {
  const end = items.findIndex(item => !holds(item));
  return end < 0 ? items : items.slice(0, end);
}
function languageExtensions(seen: readonly string[], parts: readonly string[]): boolean {
  if (parts.length === 0) return true;
  const head = parts[0]!, rest = parts.slice(1);
  if (head === "x") return rest.length > 0 && rest.every(part => languageSubtag(1, 8, part));
  if (head.length !== 1 || !/^[a-z0-9]$/.test(head) || seen.includes(head)) return false;
  const values = prefixWhile(rest, part => languageSubtag(2, 8, part));
  return values.length > 0 && languageExtensions([head, ...seen], rest.slice(values.length));
}
function languageVariants(seen: readonly string[], parts: readonly string[]): boolean {
  if (parts.length === 0) return true;
  const part = parts[0]!;
  const variant = languageSubtag(5, 8, part) || part.length === 4 && /^[a-z0-9]+$/.test(part) && /^[0-9]/.test(part);
  if (variant) return !seen.includes(part) && languageVariants([part, ...seen], parts.slice(1));
  return languageExtensions([], parts);
}
function languageSyntax(grandfathered: readonly string[], text: string): boolean {
  if (!/^[\x00-\x7F]*$/.test(text)) return false;
  const lower = asciiLower(text);
  if (grandfathered.some(entry => asciiLower(entry) === lower)) return true;
  const parts = lower.split("-"), primary = parts[0]!, rest = parts.slice(1);
  if (primary === "x") return rest.length > 0 && rest.every(part => languageSubtag(1, 8, part));
  if (!/^[a-z]+$/.test(primary) || primary.length < 2 || primary.length > 8) return false;
  const extended = primary.length <= 3 ? prefixWhile(rest, part => part.length === 3 && /^[a-z]+$/.test(part)).slice(0, 3) : [];
  const afterExtended = rest.slice(extended.length);
  const script = afterExtended[0];
  const afterScript = script !== undefined && script.length === 4 && /^[a-z]+$/.test(script) ? afterExtended.slice(1) : afterExtended;
  const region = afterScript[0];
  const afterRegion = region !== undefined && (/^[a-z]{2}$/.test(region) || /^[0-9]{3}$/.test(region)) ? afterScript.slice(1) : afterScript;
  return languageVariants([], afterRegion);
}
function ipv4(text: string): boolean {
  const parts = text.split(".");
  return parts.length === 4 && parts.every(part => /^[0-9]{1,3}$/.test(part) && (part === "0" || !part.startsWith("0")) && Number(part) <= 255);
}
function ipv6GroupCount(parts: readonly string[]): number | null {
  let count = 0;
  for (let index = 0; index < parts.length; index++) {
    const part = parts[index]!, hex = /^[0-9A-Fa-f]+$/.test(part);
    if (index === parts.length - 1) {
      if (part.includes(".")) return ipv4(part) ? count + 2 : null;
      return part !== "" && part.length <= 4 && hex ? count + 1 : null;
    }
    if (part === "" || part.length > 4 || !hex) return null;
    count++;
  }
  return count;
}
function ipv6(text: string): boolean {
  const halves = text.split("::");
  if (halves.length === 1) return ipv6GroupCount(text.split(":")) === 8;
  if (halves.length !== 2) return false;
  const before = halves[0]!, after = halves[1]!;
  const left = before === "" ? 0 : ipv6GroupCount(before.split(":"));
  const right = after === "" ? 0 : ipv6GroupCount(after.split(":"));
  return left !== null && right !== null && left + right < 8 && !before.includes(".");
}
function splitChar(text: string, delimiter: string): readonly [string, string | null] {
  const index = text.indexOf(delimiter);
  return index < 0 ? [text, null] : [text.slice(0, index), text.slice(index + delimiter.length)];
}
function uriUnreserved(character: string): boolean {
  return /^[A-Za-z0-9\-._~]$/.test(character);
}
function uriSubdelim(character: string): boolean {
  return "!$&'()*+,;=".includes(character);
}
function uriChars(text: string, extra: string): boolean {
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (c === "%") {
      if (i + 2 >= text.length || !/^[0-9A-Fa-f]$/.test(text[i + 1]!) || !/^[0-9A-Fa-f]$/.test(text[i + 2]!)) return false;
      i += 2;
    } else if (!uriUnreserved(c) && !uriSubdelim(c) && !extra.includes(c)) return false;
  }
  return true;
}
function ipLiteral(text: string): boolean {
  if (text.startsWith("v") || text.startsWith("V")) {
    const [version = "", ...tail] = text.split(".");
    return /^[0-9A-Fa-f]+$/.test(version.slice(1)) && /^[A-Za-z0-9\-._~!$&'()*+,;=:]+$/.test(tail.join("."));
  }
  return ipv6(text);
}
function uriHostPort(text: string): boolean {
  if (text.startsWith("[")) {
    const [host, after] = splitChar(text.slice(1), "]");
    return ipLiteral(host) && after !== null && (after === "" || after.startsWith(":") && /^[0-9]*$/.test(after.slice(1)));
  }
  const [host, port] = splitChar(text, ":");
  return uriChars(host, "") && (port === null || /^[0-9]*$/.test(port));
}
function uriAuthority(text: string): boolean {
  const [before, host] = splitChar(text, "@");
  return host === null ? uriHostPort(before) : uriChars(before, ":") && !host.includes("@") && uriHostPort(host);
}
function uriSyntax(text: string): boolean {
  const [scheme, tail] = splitChar(text, ":");
  if (!/^[A-Za-z][A-Za-z0-9+.-]*$/.test(scheme) || tail === null) return false;
  const [beforeFragment, fragment] = splitChar(tail, "#");
  const [hierarchy, query] = splitChar(beforeFragment, "?");
  let pathOk: boolean;
  if (hierarchy.startsWith("//")) {
    const rest = hierarchy.slice(2), slash = rest.indexOf("/"), authority = slash < 0 ? rest : rest.slice(0, slash);
    pathOk = uriAuthority(authority) && uriChars(rest.slice(authority.length), ":@/");
  } else pathOk = uriChars(hierarchy, ":@/");
  return pathOk && (query === null || uriChars(query, ":@/?")) && (fragment === null || uriChars(fragment, ":@/?"));
}
function absoluteUri(text: string, maximum: string | null): boolean {
  if (!/^[\x00-\x7F]*$/.test(text) || maximum !== null && BigInt(text.length) > BigInt(maximum)) return false;
  return uriSyntax(text);
}
export function unicodeValid(text: string): boolean {
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    if (code < 0xd800 || code > 0xdfff) continue;
    if (!isHighSurrogate(code) || !isLowSurrogate(text.charCodeAt(index + 1))) return false;
    index += 1;
  }
  return true;
}

type FormatSpanIds = { next: number };
type LabelsFields = Extract<FormatRule, { readonly tag: "Labels" }>["fields"];
type BoundedFields = Extract<FormatRule, { readonly tag: "Bounded" }>["fields"];
type DfaTable = { readonly initial: number; readonly next: Int32Array; readonly accepting: Uint8Array };
type FormatSpanShape =
  | { readonly tag: "Epsilon" | "Text" }
  | { readonly tag: "Literal"; readonly value: Int32Array }
  | { readonly tag: "Not" | "Optional"; readonly child: FormatSpanNode }
  | { readonly tag: "Choice"; readonly children: readonly FormatSpanNode[] }
  | { readonly tag: "Sequence"; readonly left: FormatSpanNode; readonly right: FormatSpanNode }
  | { readonly tag: "Labels"; readonly fields: LabelsFields; readonly separator: Int32Array; readonly child: FormatSpanNode }
  | { readonly tag: "Bounded"; readonly fields: BoundedFields; readonly maximum: bigint | null; readonly child: FormatSpanNode }
  | { readonly tag: "Identifier"; readonly first: Uint8Array; readonly rest: string; readonly restTable: Uint8Array; readonly forbidden: readonly string[]; readonly forbiddenLengths: ReadonlySet<number> }
  | { readonly tag: "AsciiDfa"; readonly table: DfaTable }
  | { readonly tag: "Leaf"; readonly rule: FormatRule };
type FormatSpanNode = FormatSpanShape & { readonly id: number; readonly min: number; readonly max: number; readonly throwing: boolean };
type FormatSpanProgram = { readonly root: FormatSpanNode; readonly size: number };
type FormatSpanContext = {
  readonly source: string; readonly graphemes: PreparedGraphemes | null; readonly codes: Int32Array; readonly offsets: Int32Array;
  readonly stride: number; readonly memo: (Map<number | string, boolean> | undefined)[];
  ascii: Int32Array | null; bytes: Float64Array | null; readonly alphabets: Map<string, Int32Array>;
};

function digitsNat(chars: readonly string[]): bigint | null {
  if (chars.length === 0 || !chars.every(character => /^[0-9]$/.test(character))) return null;
  return BigInt(chars.join(""));
}
function leapYear(year: bigint): boolean { return year % 4n === 0n && (year % 100n !== 0n || year % 400n === 0n); }
function monthDays(year: bigint, month: bigint): bigint {
  if (month === 2n) return leapYear(year) ? 29n : 28n;
  return [4n, 6n, 9n, 11n].includes(month) ? 30n : 31n;
}
function digitRunLength(chars: readonly string[]): number {
  let length = 0;
  while (length < chars.length && /^[0-9]$/.test(chars[length]!)) length += 1;
  return length;
}
function timestampSyntax(rule: CalendarRule, text: string): boolean {
  const chars = [...text];
  if (chars.length < 20) return false;
  if (chars[4] !== "-" || chars[7] !== "-" || chars[10] !== "T" || chars[13] !== ":" || chars[16] !== ":") return false;
  const year = digitsNat(chars.slice(0, 4)), month = digitsNat(chars.slice(5, 7)), day = digitsNat(chars.slice(8, 10));
  const hour = digitsNat(chars.slice(11, 13)), minute = digitsNat(chars.slice(14, 16)), second = digitsNat(chars.slice(17, 19));
  if (year === null || month === null || day === null || hour === null || minute === null || second === null) return false;
  if (year < BigInt(rule.minimum_year) || year > BigInt(rule.maximum_year) || month < 1n || month > 12n || day < 1n || day > monthDays(year, month) || hour > 23n || minute > 59n || second > (rule.allow_second_60 ? 60n : 59n)) return false;
  const suffix = chars.slice(19);
  const fractionLength = suffix[0] === "." ? digitRunLength(suffix.slice(1)) : 0;
  const timezone = suffix[0] !== "." ? suffix : fractionLength === 0 ? [] : suffix.slice(1 + fractionLength);
  if (timezone.length === 1 && timezone[0] === "Z") return true;
  if (timezone.length !== 6 || timezone[3] !== ":") return false;
  const sign = timezone[0], offsetHour = digitsNat(timezone.slice(1, 3)), offsetMinute = digitsNat(timezone.slice(4, 6));
  if ((sign !== "+" && sign !== "-") || offsetHour === null || offsetMinute === null) return false;
  if (offsetHour > 23n || offsetMinute > 59n || (sign === "-" && offsetHour === 0n && offsetMinute === 0n)) return false;
  if (rule.rejectUtcYearOutsideRange) {
    let precedingDays = 0n;
    for (let previous = 1n; previous < month; previous += 1n) precedingDays += monthDays(year, previous);
    const localMinutes = (precedingDays + day - 1n) * 1440n + hour * 60n + minute;
    const offsetMinutes = offsetHour * 60n + offsetMinute;
    const utcMinutes = sign === "+" ? localMinutes - offsetMinutes : localMinutes + offsetMinutes;
    const yearMinutes = (leapYear(year) ? 366n : 365n) * 1440n;
    if (year === BigInt(rule.minimum_year) && utcMinutes < 0n) return false;
    if (year === BigInt(rule.maximum_year) && utcMinutes >= yearMinutes) return false;
  }
  return true;
}
function buildDfaTable(spec: DfaSpec): DfaTable | null {
  try {
    const states = new Map<bigint, number>();
    const stateIndex = (value: bigint): number => {
      let index = states.get(value);
      if (index === undefined) { index = states.size; states.set(value, index); }
      return index;
    };
    const initial = stateIndex(BigInt(spec.initial_state));
    const rows = spec.transitions.map(item => [stateIndex(BigInt(item.from_state)), BigInt(item.first), BigInt(item.last), stateIndex(BigInt(item.to_state))] as const);
    const next = new Int32Array(states.size * 128).fill(-1);
    for (const [from, first, last, to] of rows) {
      const high = last > 127n ? 127 : Number(last);
      for (let byte = first < 0n ? 0 : first > 127n ? 128 : Number(first); byte <= high; byte += 1) if (next[from * 128 + byte] === -1) next[from * 128 + byte] = to;
    }
    const accepting = new Uint8Array(states.size);
    for (const state of spec.accepting_states) {
      const index = states.get(BigInt(state));
      if (index !== undefined) accepting[index] = 1;
    }
    return { initial, next, accepting };
  } catch { return null; }
}
function dfaRun(table: DfaTable, codes: Int32Array, start: number, finish: number): boolean {
  let state = table.initial;
  for (let index = start; index < finish; index += 1) {
    const byte = codes[index]!;
    if (state < 0 || byte >= 128) return false;
    state = table.next[state * 128 + byte]!;
  }
  return state >= 0 && table.accepting[state] === 1;
}
function dfaAccepts(spec: DfaSpec, text: string): boolean {
  const table = buildDfaTable(spec);
  if (table !== null) { const codes = codePointArray(text); return dfaRun(table, codes.codes, 0, codes.codes.length); }
  let state: bigint | null = BigInt(spec.initial_state);
  for (const character of text) {
    const byte = BigInt(character.codePointAt(0)!);
    if (state === null || byte >= 128n) return false;
    const current: bigint = state;
    const transition: DfaTransition | undefined = spec.transitions.find(item => BigInt(item.from_state) === current && BigInt(item.first) <= byte && byte <= BigInt(item.last));
    state = transition === undefined ? null : BigInt(transition.to_state);
  }
  const final = state;
  return final !== null && spec.accepting_states.some(accepting => BigInt(accepting) === final);
}
function charSplits(chars: readonly string[]): (readonly [readonly string[], readonly string[]])[] {
  return Array.from({ length: chars.length + 1 }, (_, split) => [chars.slice(0, split), chars.slice(split)] as const);
}
function stringSplits(text: string): (readonly [string, string])[] {
  return charSplits([...text]).map(([left, right]) => [left.join(""), right.join("")] as const);
}
function sequenceAcceptsWith(accepts: (rule: FormatRule, text: string) => boolean, parts: readonly FormatRule[], text: string): boolean {
  if (parts.length === 0) return text === "";
  const first = parts[0]!, rest = parts.slice(1);
  return stringSplits(text).some(([left, right]) => accepts(first, left) && sequenceAcceptsWith(accepts, rest, right));
}
function separatorPrefixAt(separator: readonly string[], chars: readonly string[], index: number): boolean {
  return separator.every((character, offset) => chars[index + offset] === character);
}
function splitAtSeparator(separator: readonly string[], fuel: number, chars: readonly string[]): string[][] {
  const labels: string[][] = [[]];
  let remaining = fuel, index = 0;
  while (remaining > 0 && index < chars.length) {
    remaining -= 1;
    if (separatorPrefixAt(separator, chars, index)) { labels.push([]); index += separator.length; }
    else { labels[labels.length - 1]!.push(chars[index]!); index += 1; }
  }
  labels[labels.length - 1]!.push(...chars.slice(index));
  return labels;
}
function labelParts(separator: string, text: string): string[] {
  const chars = [...text];
  return splitAtSeparator([...separator], chars.length, chars).map(label => label.join(""));
}
function formatWithin(graphemes: GraphemeRules | null, unit: StringLengthUnit, maximum: bigint, text: string): boolean {
  const length = formatLength(graphemes, unit, text);
  return length !== null && length <= maximum;
}

export function formatAccepts(graphemes: GraphemeRules | null, rule: FormatRule, text: string): boolean {
  switch (rule.tag) {
    case "Literal": return rule.value === text;
    case "Sequence": return sequenceAcceptsWith((part, piece) => formatAccepts(graphemes, part, piece), rule.value, text);
    case "Optional": return formatAccepts(graphemes, rule.value, text) || text === "";
    case "Labels": {
      const fields = rule.fields;
      if (fields.separator === "") return false;
      const values = labelParts(fields.separator, text);
      return BigInt(values.length) >= BigInt(fields.min_count) && (fields.max_count === null || BigInt(values.length) <= BigInt(fields.max_count)) && (fields.total_max === null || BigInt([...text].length) <= BigInt(fields.total_max)) && values.every(value => formatAccepts(graphemes, fields.rule, value));
    }
    case "Bounded": return formatWithin(graphemes, rule.fields.unit, BigInt(rule.fields.maximum), text) && formatAccepts(graphemes, rule.fields.rule, text);
    case "AsciiDfa": return dfaAccepts(rule.value, text);
    case "Identifier": {
      const fields = rule.fields, chars = [...text], length = BigInt(chars.length);
      return /^[\x00-\x7F]*$/.test(text) && lengthAccepts(fields.min_length, fields.max_length, length) && (fields.exact_length === null || length === BigInt(fields.exact_length)) && !fields.forbidden.includes(text) && chars.length > 0 && fields.first_alphabet.includes(chars[0]!) && chars.slice(1).every(character => fields.rest_alphabet.includes(character));
    }
    case "Timestamp": return timestampSyntax(rule.value, text);
    case "AbsoluteUri": return absoluteUri(text, rule.fields.max_bytes);
    case "LanguageTag": return languageSyntax(rule.fields.grandfathered, text);
    case "Choice": return rule.value.some(candidate => formatAccepts(graphemes, candidate, text));
    case "Text": return true;
    case "Not": return !formatAccepts(graphemes, rule.value, text);
  }
}
function codePointArray(text: string): { readonly codes: Int32Array; readonly offsets: Int32Array } {
  const codes = new Int32Array(text.length), offsets = new Int32Array(text.length + 1);
  let count = 0;
  for (let index = 0; index < text.length; index += 1) {
    const code = text.codePointAt(index)!;
    if (code > 0xffff) index += 1;
    codes[count] = code;
    count += 1;
    offsets[count] = index + 1;
  }
  return { codes: codes.subarray(0, count), offsets: offsets.subarray(0, count + 1) };
}
function codePointCount(text: string): number {
  let count = 0;
  for (let index = 0; index < text.length; index += 1) {
    if (text.codePointAt(index)! > 0xffff) index += 1;
    count += 1;
  }
  return count;
}
function natNumber(text: unknown): number | null {
  return typeof text === "string" && /^[0-9]+$/.test(text) ? Number(text) : null;
}
function asciiTable(alphabet: string): Uint8Array {
  const table = new Uint8Array(128);
  for (let index = 0; index < alphabet.length; index += 1) table[alphabet.charCodeAt(index)] = 1;
  return table;
}
function formatSpanNode(ids: FormatSpanIds, min: number, max: number, throwing: boolean, shape: FormatSpanShape): FormatSpanNode {
  const id = ids.next;
  ids.next = id + 1;
  return throwing ? { ...shape, id, min: 0, max: Infinity, throwing } : { ...shape, id, min, max: Number.isNaN(max) ? Infinity : max, throwing };
}
function binaryFormatSequence(nodes: readonly FormatSpanNode[], ids: FormatSpanIds): FormatSpanNode {
  if (nodes.length === 0) return formatSpanNode(ids, 0, 0, false, { tag: "Epsilon" });
  if (nodes.length === 1) return nodes[0]!;
  const left = nodes[0]!, right = binaryFormatSequence(nodes.slice(1), ids);
  return formatSpanNode(ids, left.min + right.min, left.max + right.max, left.throwing || right.throwing, { tag: "Sequence", left, right });
}
function compileIdentifier(rule: Extract<FormatRule, { readonly tag: "Identifier" }>, ids: FormatSpanIds): FormatSpanNode {
  const fields = rule.fields;
  const minimum = natNumber(fields.min_length), maximum = fields.max_length === null ? Infinity : natNumber(fields.max_length), exact = fields.exact_length === null ? null : natNumber(fields.exact_length);
  const numeric = minimum !== null && maximum !== null && (fields.exact_length === null || exact !== null);
  if (!numeric || !ascii(fields.first_alphabet) || !ascii(fields.rest_alphabet)) return formatSpanNode(ids, 0, Infinity, !numeric, { tag: "Leaf", rule });
  const forbidden = fields.forbidden, forbiddenLengths = new Set(forbidden.map(codePointCount));
  return formatSpanNode(ids, Math.max(1, minimum, exact ?? 0), Math.min(maximum, exact ?? Infinity), false, {
    tag: "Identifier", first: asciiTable(fields.first_alphabet), rest: fields.rest_alphabet, restTable: asciiTable(fields.rest_alphabet), forbidden, forbiddenLengths,
  });
}
function compileFormatSpan(rule: FormatRule, ids: FormatSpanIds): FormatSpanNode {
  switch (rule.tag) {
    case "Literal": { const value = codePointArray(rule.value).codes; return formatSpanNode(ids, value.length, value.length, false, { tag: "Literal", value }); }
    case "Text": return formatSpanNode(ids, 0, Infinity, false, { tag: "Text" });
    case "Not": { const child = compileFormatSpan(rule.value, ids); return formatSpanNode(ids, 0, Infinity, child.throwing, { tag: "Not", child }); }
    case "Choice": {
      const children = rule.value.map(child => compileFormatSpan(child, ids));
      return formatSpanNode(ids, Math.min(...children.map(child => child.min)), Math.max(...children.map(child => child.max)), children.some(child => child.throwing), { tag: "Choice", children });
    }
    case "Sequence": return binaryFormatSequence(rule.value.map(child => compileFormatSpan(child, ids)), ids);
    case "Optional": { const child = compileFormatSpan(rule.value, ids); return formatSpanNode(ids, 0, Math.max(0, child.max), child.throwing, { tag: "Optional", child }); }
    case "Labels": {
      const fields = rule.fields, child = compileFormatSpan(fields.rule, ids), total = fields.total_max === null ? Infinity : natNumber(fields.total_max);
      const throwing = child.throwing || natNumber(fields.min_count) === null || fields.max_count !== null && natNumber(fields.max_count) === null || total === null;
      return formatSpanNode(ids, 0, total ?? Infinity, throwing, { tag: "Labels", fields, separator: codePointArray(fields.separator).codes, child });
    }
    case "Bounded": {
      const fields = rule.fields, child = compileFormatSpan(fields.rule, ids), maximum = natNumber(fields.maximum);
      const scalarBound = maximum !== null && (fields.unit.tag === "Utf8Bytes" || fields.unit.tag === "UnicodeScalars");
      return formatSpanNode(ids, child.min, scalarBound ? Math.min(child.max, maximum) : child.max, child.throwing || maximum === null, { tag: "Bounded", fields, maximum: maximum === null ? null : BigInt(fields.maximum), child });
    }
    case "AsciiDfa": {
      const table = buildDfaTable(rule.value);
      return table === null ? formatSpanNode(ids, 0, Infinity, true, { tag: "Leaf", rule }) : formatSpanNode(ids, 0, Infinity, false, { tag: "AsciiDfa", table });
    }
    case "Identifier": return compileIdentifier(rule, ids);
    case "Timestamp": return formatSpanNode(ids, 20, Infinity, natNumber(rule.value.minimum_year) === null || natNumber(rule.value.maximum_year) === null, { tag: "Leaf", rule });
    case "AbsoluteUri": {
      const maximum = rule.fields.max_bytes === null ? Infinity : natNumber(rule.fields.max_bytes);
      return formatSpanNode(ids, 0, maximum ?? Infinity, maximum === null, { tag: "Leaf", rule });
    }
    default: return formatSpanNode(ids, 0, Infinity, false, { tag: "Leaf", rule });
  }
}
function compileFormatProgram(rule: FormatRule): FormatSpanProgram {
  const ids: FormatSpanIds = { next: 0 };
  return { root: compileFormatSpan(rule, ids), size: ids.next };
}
function formatSpanSubstring(context: FormatSpanContext, start: number, finish: number): string {
  return context.source.slice(context.offsets[start], context.offsets[finish]);
}
function formatSpanLiteral(context: FormatSpanContext, value: Int32Array, start: number): boolean {
  for (let offset = 0; offset < value.length; offset += 1) if (context.codes[start + offset] !== value[offset]) return false;
  return true;
}
function formatSpanPrefix(context: FormatSpanContext, member: (code: number) => boolean): Int32Array {
  const prefix = new Int32Array(context.codes.length + 1);
  for (let index = 0; index < context.codes.length; index += 1) prefix[index + 1] = prefix[index]! + (member(context.codes[index]!) ? 1 : 0);
  return prefix;
}
function formatSpanIdentifier(context: FormatSpanContext, node: Extract<FormatSpanNode, { readonly tag: "Identifier" }>, start: number, finish: number): boolean {
  const width = finish - start;
  context.ascii ??= formatSpanPrefix(context, code => code < 128);
  if (context.ascii[finish]! - context.ascii[start]! !== width) return false;
  if (node.forbiddenLengths.has(width) && node.forbidden.includes(formatSpanSubstring(context, start, finish))) return false;
  if (node.first[context.codes[start]!] !== 1) return false;
  let rest = context.alphabets.get(node.rest);
  if (rest === undefined) { rest = formatSpanPrefix(context, code => code < 128 && node.restTable[code] === 1); context.alphabets.set(node.rest, rest); }
  return rest[finish]! - rest[start + 1]! === width - 1;
}
function formatSpanUtf8Bytes(context: FormatSpanContext, start: number, finish: number): number {
  if (context.bytes === null) {
    const bytes = new Float64Array(context.codes.length + 1);
    for (let index = 0; index < context.codes.length; index += 1) {
      const code = context.codes[index]!;
      bytes[index + 1] = bytes[index]! + (code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4);
    }
    context.bytes = bytes;
  }
  return context.bytes[finish]! - context.bytes[start]!;
}
function formatSpanWithin(context: FormatSpanContext, node: Extract<FormatSpanNode, { readonly tag: "Bounded" }>, start: number, finish: number): boolean {
  const maximum = node.maximum ?? BigInt(node.fields.maximum), unit = node.fields.unit;
  if (unit.tag === "Utf8Bytes") return BigInt(formatSpanUtf8Bytes(context, start, finish)) <= maximum;
  if (unit.tag === "UnicodeScalars") return BigInt(finish - start) <= maximum;
  return context.graphemes !== null && BigInt(graphemeCountOf(graphemeTablesOf(context.graphemes), formatSpanSubstring(context, start, finish))) <= maximum;
}
function formatSpanLabels(context: FormatSpanContext, separator: Int32Array, start: number, finish: number): number[] {
  const bounds = [start];
  let index = start;
  while (index < finish) {
    if (index + separator.length <= finish && formatSpanLiteral(context, separator, index)) {
      bounds.push(index, index + separator.length);
      index += separator.length;
    } else index += 1;
  }
  bounds.push(finish);
  return bounds;
}
function evalFormatSpanNode(context: FormatSpanContext, node: FormatSpanNode, start: number, finish: number): boolean {
  switch (node.tag) {
    case "Epsilon": return start === finish;
    case "Text": return true;
    case "Literal": return formatSpanLiteral(context, node.value, start);
    case "Identifier": return formatSpanIdentifier(context, node, start, finish);
    case "Not": return !evalFormatSpan(context, node.child, start, finish);
    case "Choice": return node.children.some(child => evalFormatSpan(context, child, start, finish));
    case "Sequence": {
      const low = node.throwing ? start : Math.max(start, start + node.left.min, finish - node.right.max);
      const high = node.throwing ? finish : Math.min(finish, start + node.left.max, finish - node.right.min);
      for (let split = low; split <= high; split += 1) if (evalFormatSpan(context, node.left, start, split) && evalFormatSpan(context, node.right, split, finish)) return true;
      return false;
    }
    case "Optional": return start === finish || evalFormatSpan(context, node.child, start, finish);
    case "Labels": {
      const fields = node.fields;
      if (fields.separator === "") return false;
      const bounds = formatSpanLabels(context, node.separator, start, finish), count = bounds.length / 2;
      if (BigInt(count) < BigInt(fields.min_count)) return false;
      if (fields.max_count !== null && BigInt(count) > BigInt(fields.max_count)) return false;
      if (fields.total_max !== null && BigInt(finish - start) > BigInt(fields.total_max)) return false;
      for (let index = 0; index < bounds.length; index += 2) if (!evalFormatSpan(context, node.child, bounds[index]!, bounds[index + 1]!)) return false;
      return true;
    }
    case "Bounded": return formatSpanWithin(context, node, start, finish) && evalFormatSpan(context, node.child, start, finish);
    case "AsciiDfa": return dfaRun(node.table, context.codes, start, finish);
    case "Leaf": return formatAccepts(context.graphemes?.rules ?? null, node.rule, formatSpanSubstring(context, start, finish));
  }
}
function evalFormatSpan(context: FormatSpanContext, node: FormatSpanNode, start: number, finish: number): boolean {
  if (finish - start < node.min || finish - start > node.max) return false;
  if (node.tag === "Epsilon" || node.tag === "Text" || node.tag === "Literal" || node.tag === "Identifier") return evalFormatSpanNode(context, node, start, finish);
  let memo = context.memo[node.id];
  if (memo === undefined) { memo = new Map(); context.memo[node.id] = memo; }
  const key = context.stride === 0 ? `${start}:${finish}` : start * context.stride + finish;
  const known = memo.get(key);
  if (known !== undefined) return known;
  const accepted = evalFormatSpanNode(context, node, start, finish);
  memo.set(key, accepted);
  return accepted;
}
function runFormatProgram(program: FormatSpanProgram, graphemes: PreparedGraphemes | null, text: string): boolean {
  const points = codePointArray(text), stride = points.codes.length + 1;
  const context: FormatSpanContext = {
    source: text, graphemes, codes: points.codes, offsets: points.offsets, stride: stride * stride <= Number.MAX_SAFE_INTEGER ? stride : 0,
    memo: new Array<Map<number | string, boolean> | undefined>(program.size), ascii: null, bytes: null, alphabets: new Map(),
  };
  return evalFormatSpan(context, program.root, 0, points.codes.length);
}
export function formatAcceptsFast(graphemes: GraphemeRules | null, rule: FormatRule, text: string): boolean {
  return runFormatProgram(compileFormatProgram(rule), graphemes === null ? null : { rules: graphemes, tables: null }, text);
}
export function recognizeFormat(rule: FormatRule, text: string, graphemes: GraphemeRules | null): boolean {
  return unicodeValid(text) && formatAcceptsFast(graphemes, rule, text);
}
type GraphemeTable<T> = { readonly rows: readonly T[]; readonly starts: Int32Array; readonly ends: Int32Array; readonly owners: Int32Array };
type GraphemeTables = { readonly properties: GraphemeTable<GraphemeRange>; readonly pictographic: GraphemeTable<CodepointRange>; readonly indic: GraphemeTable<IndicRange> };
function lowerBound(values: readonly number[], target: number): number {
  let low = 0, high = values.length;
  while (low < high) { const middle = (low + high) >> 1; if (values[middle]! < target) low = middle + 1; else high = middle; }
  return low;
}
function graphemeTable<T extends CodepointRange>(rows: readonly T[]): GraphemeTable<T> {
  const spans: (readonly [number, number, number])[] = [];
  rows.forEach((row, index) => {
    const first = Math.max(Math.ceil(Number(row.first)), 0), last = Math.min(Math.floor(Number(row.last)), 0x10ffff);
    if (first <= last) spans.push([first, last, index]);
  });
  let flat = spans;
  if (!spans.every((span, index) => index === 0 || spans[index - 1]![1] < span[0])) {
    const cuts = [...new Set(spans.flatMap(([first, last]) => [first, last + 1]))].sort((left, right) => left - right);
    const owners = new Int32Array(cuts.length).fill(-1);
    for (const [first, last, index] of spans)
      for (let segment = lowerBound(cuts, first); segment < cuts.length - 1 && cuts[segment]! <= last; segment += 1) if (owners[segment] === -1) owners[segment] = index;
    flat = [];
    for (let segment = 0; segment < cuts.length - 1; segment += 1) {
      const owner = owners[segment]!, previous = flat[flat.length - 1];
      if (owner < 0) continue;
      if (previous !== undefined && previous[2] === owner && previous[1] + 1 === cuts[segment]) flat[flat.length - 1] = [previous[0], cuts[segment + 1]! - 1, owner];
      else flat.push([cuts[segment]!, cuts[segment + 1]! - 1, owner]);
    }
  }
  return { rows, starts: Int32Array.from(flat, span => span[0]), ends: Int32Array.from(flat, span => span[1]), owners: Int32Array.from(flat, span => span[2]) };
}
function rangeAt<T>(table: GraphemeTable<T>, cp: number): T | undefined {
  let low = 0, high = table.starts.length - 1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    if (table.ends[middle]! < cp) low = middle + 1;
    else if (table.starts[middle]! > cp) high = middle - 1;
    else return table.rows[table.owners[middle]!];
  }
  return undefined;
}
type PreparedGraphemes = { readonly rules: GraphemeRules; tables: GraphemeTables | null };
function buildGraphemeTables(rules: GraphemeRules): GraphemeTables {
  return { properties: graphemeTable(rules.properties), pictographic: graphemeTable(rules.extended_pictographic), indic: graphemeTable(rules.indic_conjunct) };
}
function attempt<T>(build: () => T): T | null {
  try { return build(); } catch { return null; }
}
function prepareGraphemes(rules: GraphemeRules | null): PreparedGraphemes | null {
  return rules === null ? null : { rules, tables: attempt(() => buildGraphemeTables(rules)) };
}
function graphemeTablesOf(graphemes: PreparedGraphemes): GraphemeTables {
  graphemes.tables ??= buildGraphemeTables(graphemes.rules);
  return graphemes.tables;
}
type GraphemeState = { count: number; previous: string | null; regionalRun: number; pictographicExtends: boolean; previousZwjAfterPictographic: boolean; indicConsonant: boolean; indicLinker: boolean };
function graphemeControl(property: string): boolean { return property === "Cr" || property === "Lf" || property === "Control"; }
function graphemeBreak(state: GraphemeState, next: string, indic: string, ep: boolean): boolean {
  const previous = state.previous;
  if (previous === null) return true;
  if (previous === "Cr" && next === "Lf") return false;
  if (graphemeControl(previous) || graphemeControl(next)) return true;
  if (previous === "L" && (next === "L" || next === "V" || next === "Lv" || next === "Lvt")) return false;
  if ((previous === "Lv" || previous === "V") && (next === "V" || next === "T")) return false;
  if ((previous === "Lvt" || previous === "T") && next === "T") return false;
  if (next === "Extend" || next === "Zwj" || next === "SpacingMark") return false;
  if (previous === "Prepend") return false;
  if (indic === "Consonant" && state.indicConsonant && state.indicLinker) return false;
  if (ep && previous === "Zwj" && state.previousZwjAfterPictographic) return false;
  if (previous === "RegionalIndicator" && next === "RegionalIndicator" && state.regionalRun % 2 === 1) return false;
  return true;
}
function graphemeStep(tables: GraphemeTables, state: GraphemeState, cp: number): void {
  const next = rangeAt(tables.properties, cp)?.property.tag ?? "Other", indic = rangeAt(tables.indic, cp)?.property.tag ?? "Other", ep = rangeAt(tables.pictographic, cp) !== undefined;
  const consonant = state.indicConsonant;
  if (graphemeBreak(state, next, indic, ep)) state.count += 1;
  state.previous = next;
  state.regionalRun = next === "RegionalIndicator" ? state.regionalRun + 1 : 0;
  state.previousZwjAfterPictographic = next === "Zwj" && state.pictographicExtends;
  state.pictographicExtends = ep || (next === "Extend" && state.pictographicExtends);
  state.indicConsonant = indic === "Consonant" || (indic === "Extend" || indic === "Linker") && consonant;
  state.indicLinker = indic === "Consonant" ? false : indic === "Linker" ? consonant : indic === "Extend" && state.indicLinker;
}
function graphemeCountOf(tables: GraphemeTables, text: string): number {
  const state: GraphemeState = { count: 0, previous: null, regionalRun: 0, pictographicExtends: false, previousZwjAfterPictographic: false, indicConsonant: false, indicLinker: false };
  for (let index = 0; index < text.length; index += 1) {
    const cp = text.codePointAt(index)!;
    if (cp > 0xffff) index += 1;
    graphemeStep(tables, state, cp);
  }
  return state.count;
}
export function graphemeLength(rules: GraphemeRules, text: string): bigint {
  return BigInt(graphemeCountOf(buildGraphemeTables(rules), text));
}
export function wrapEncode(profile: VersionedSemanticProfile, wrapperName: string, payload: string | Uint8Array): ExactJson {
  const wrapper = profile.wrappers.find(candidate => candidate.name === wrapperName);
  requireEvidence(wrapper, "declared wrapper");
  return exactObject([{ key: wrapper.key, value: { tag: "String", value: payload instanceof Uint8Array ? (requireEvidence(profile.bytes_policy, "bytes policy"), base64Encode(payload, profile.bytes_policy)) : payload } }]);
}
export function wrapDecode(profile: PreparedProfile, wrapperName: string, value: ExactJson): string | Uint8Array {
  const wrapper = profile.wrappers.find(candidate => candidate.name === wrapperName);
  requireEvidence(wrapper, "declared wrapper");
  const text = wrapperPayloadText(profile, wrapper, value);
  const condition = wrapperPayloadFailure(profile, wrapper, value);
  requireEvidence(text !== null, condition === null ? "wrapper payload" : valueConditionText(condition));
  if (wrapper.payload.tag !== "Bytes") return text;
  requireEvidence(profile.bytes_policy, "bytes policy");
  return base64Decode(text, profile.bytes_policy)!;
}
function bytesText(profile: PreparedProfile, policy: BytesPolicy, value: ExactJson): string | null {
  if (policy.wrapper === null) return value.tag === "String" ? value.value : null;
  const wrapper = profile.wrappers.find(candidate => candidate.name === policy.wrapper);
  return wrapper === undefined ? null : wrapperPayloadText(profile, wrapper, value);
}
export function decodeBytes(profile: PreparedProfile, value: ExactJson): Uint8Array | null {
  const policy = profile.bytes_policy;
  if (policy === null) return null;
  const text = bytesText(profile, policy, value);
  return text === null ? null : base64Decode(text, policy);
}
export function withMember(key: string, text: string, value: ExactJson): ExactJson {
  return value.tag === "Object" ? { tag: "Object", members: [{ key, value: { tag: "String", value: text } }, ...value.members.filter(item => item.key !== key)] } : value;
}
export function selectBranch(context: ValueContext, ref: TypeRef, value: ExactJson): UnionBranch | null {
  const node = findType(context, ref);
  requireEvidence(node?.shape.tag === "TaggedUnion", "union reference");
  return selectUnionBranch(context.prepared, node.shape.value, value);
}
function exactKind(value: ExactJson): ValueKind["tag"] { return value.tag === "Null" ? "Null" : value.tag === "Bool" ? "Boolean" : value.tag === "Integer" || value.tag === "Decimal" ? "Number" : value.tag; }

export interface DefaultApplication {
  readonly value_path: readonly PathStep[];
  readonly type_ref: TypeRef;
  readonly origin: OccurrenceRef;
  readonly value: ExactJson;
}
export type ReasonDisposition = "Residual" | "Stopped" | "Failed";
export function semanticReasonDisposition(reason: SemanticReason): ReasonDisposition {
  switch (reason.tag) {
    case "UnknownFormat": case "MissingGraphemeRules": case "MissingBytesPolicy":
    case "UnknownIntegerDomain": case "UnknownWrapper": case "UnknownSealedTag":
    case "OpaqueType": case "MissingTagModel": case "UninterpretedExtension":
    case "UnresolvedType": case "ProjectionUnavailable": return "Residual";
    case "MembershipBound": return "Stopped";
    case "WrapperPayload": case "DecimalNotAdmitted": case "IntegerBound":
    case "InvalidProfile": case "CertificateMismatch": return "Failed";
  }
}
export function classifyDispositions(classes: readonly ReasonDisposition[]): ReasonDisposition {
  if (classes.length === 0) return "Failed";
  return classes.includes("Failed") ? "Failed" : classes.includes("Stopped") ? "Stopped" : "Residual";
}
export type SemanticReason =
  | { readonly tag: "MembershipBound" | "UnresolvedType" | "MissingGraphemeRules" | "MissingBytesPolicy" | "DecimalNotAdmitted" | "IntegerBound" | "MissingTagModel" }
  | { readonly tag: "UnknownFormat" | "UnknownIntegerDomain" | "UnknownWrapper" | "WrapperPayload" | "UnknownSealedTag" | "OpaqueType" | "UninterpretedExtension" | "InvalidProfile" | "CertificateMismatch" | "ProjectionUnavailable"; readonly value: string };
export interface SemanticObligation {
  readonly type_ref: TypeRef; readonly origin: OccurrenceRef;
  readonly value_path: readonly PathStep[]; readonly profile: ProfileRef;
  readonly reason: SemanticReason;
}
export interface SemanticJudgment { readonly provenance: unknown; readonly obligations: readonly SemanticObligation[]; }
export interface SemanticDecisionFailure { readonly provenance: unknown; readonly obligations: readonly SemanticObligation[]; readonly residuals: ResidualSet<SemanticObligation>; readonly classes: readonly ReasonDisposition[]; }
export type SemanticEvaluation = Result<RefinementOutcome<SemanticJudgment, SemanticObligation, readonly SemanticObligation[]>, SemanticDecisionFailure>;
function sameKey(value: unknown, active: Set<object>): string | null {
  if (value === null) return "z";
  switch (typeof value) {
    case "undefined": return "u";
    case "boolean": return value ? "t" : "f";
    case "string": return JSON.stringify(value);
    case "bigint": return `b${value}`;
    case "number": return Number.isNaN(value) ? null : `n${String(value)}`;
    case "object": break;
    default: return null;
  }
  if (active.has(value)) return null;
  active.add(value);
  try {
    const parts: string[] = [];
    if (Array.isArray(value)) {
      for (let index = 0; index < value.length; index += 1) {
        if (!(index in value)) return null;
        const part = sameKey(value[index], active);
        if (part === null) return null;
        parts.push(part);
      }
      return `[${parts.join(",")}]`;
    }
    const keys = Object.keys(value);
    if (Object.getOwnPropertyNames(value).length !== keys.length) return null;
    for (const key of keys.sort()) {
      const part = sameKey((value as Record<string, unknown>)[key], active);
      if (part === null) return null;
      parts.push(`${JSON.stringify(key)}:${part}`);
    }
    return `{${parts.join(",")}}`;
  } finally { active.delete(value); }
}
function firstResiduals(reasons: readonly SemanticObligation[], classes: readonly ReasonDisposition[]): SemanticObligation[] {
  const keys = reasons.map(reason => sameKey(reason, new Set()));
  if (keys.some(key => key === null)) return reasons.filter((reason, index) => classes[index] === "Residual" && reasons.findIndex(other => same(other, reason)) === index);
  const seen = new Set<string | null>();
  return reasons.filter((_, index) => {
    const key = keys[index]!, first = !seen.has(key);
    seen.add(key);
    return first && classes[index] === "Residual";
  });
}
export function classifySemanticObligations(provenance: unknown, obligations: readonly SemanticObligation[]): SemanticEvaluation {
  const reasons = Object.freeze([...obligations]);
  const classes = reasons.map(reason => semanticReasonDisposition(reason.reason));
  const residuals = firstResiduals(reasons, classes);
  const judgment = { provenance, obligations: reasons };
  const status = classifyDispositions(classes);
  if (status === "Failed") return { ok: false, error: { provenance, obligations: reasons, residuals: residualSet(residuals), classes } };
  if (status === "Residual") return { ok: true, value: residual(judgment, residuals) };
  return { ok: true, value: stopped(judgment, residuals, reasons.filter((_, index) => classes[index] === "Stopped")) };
}
export class SemanticUnresolvedError extends SemanticEvidenceError {
  constructor(readonly reference: TypeRef, readonly obligations: readonly SemanticObligation[]) {
    super("Unresolved");
  }
}

function formatRulesUseGraphemes(rules: readonly FormatRule[]): boolean {
  return rules.some(child => formatRuleUsesGraphemes(child));
}

function formatRuleUsesGraphemes(rule: FormatRule): boolean {
  switch (rule.tag) {
    case "Bounded": return rule.fields.unit.tag === "Graphemes" || formatRuleUsesGraphemes(rule.fields.rule);
    case "Sequence": case "Choice": return formatRulesUseGraphemes(rule.value);
    case "Optional": case "Not": return formatRuleUsesGraphemes(rule.value);
    case "Labels": return formatRuleUsesGraphemes(rule.fields.rule);
    default: return false;
  }
}
function formatUseUsesGraphemes(profile: VersionedSemanticProfile, use: FormatUse | null): boolean {
  if (use === null) return false;
  if (use.tag === "Inline") return formatRuleUsesGraphemes(use.value);
  const binding = profile.format_bindings.find(candidate => candidate.name === use.value);
  return binding !== undefined && formatRuleUsesGraphemes(binding.rule);
}
function nodeMeaningObligations(profile: VersionedSemanticProfile, node: TypeNode): readonly SemanticReason[] {
  const shape = node.shape, reasons: SemanticReason[] = [];
  if (shape.tag === "String") {
    if ((shape.value.lengths.some(bound => bound.unit.tag === "Graphemes") || formatUseUsesGraphemes(profile, shape.value.format)) && profile.grapheme_rules === null) reasons.push({ tag: "MissingGraphemeRules" });
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
const unresolvedReasons: readonly SemanticReason[] = Object.freeze([{ tag: "UnresolvedType" }]);
function defaultOrigin(ref: TypeRef): OccurrenceRef {
  return { source: ref.source, pointer: [...ref.pointer, "default"] };
}
function typeDefault(shape: TypeShape): ExactJson | undefined {
  if (shape.tag === "Boolean" && shape.value.default_value !== null) return { tag: "Bool", value: shape.value.default_value };
  if (shape.tag === "Integer" && shape.value.default_value !== null) return { tag: "Integer", value: shape.value.default_value };
  if (shape.tag === "String" && shape.value.default_value !== null) return { tag: "String", value: shape.value.default_value };
  return undefined;
}
export function checkDefaultApplications(context: ValueContext, before: ExactJson, after: ExactJson, applications: readonly DefaultApplication[]): boolean {
  return checkDefaultApplicationsAt(context, before, after, applications, applications.map(application => context.typeIndexes.get(typeIdentity(application.type_ref)) ?? -1));
}
function checkDefaultApplicationsAt(context: ValueContext, before: ExactJson, after: ExactJson, applications: readonly DefaultApplication[], ids: readonly number[]): boolean {
  return applications.every((application, position) => {
    const first = projectedValue({ tag: "Present", value: before }, application.value_path, context.profile);
    const last = projectedValue({ tag: "Present", value: after }, application.value_path, context.profile);
    const id = ids[position]!, node = id < 0 || id >= context.nodes.length ? undefined : context.nodes[id]!.node;
    return first.tag === "Absent" && last.tag === "Present" && same(last.value, application.value)
      && same(application.origin, defaultOrigin(application.type_ref))
      && node !== undefined && same(typeDefault(node.shape), application.value);
  });
}
export class DefaultedValue {
  readonly #value: ExactJson;
  readonly #applications: readonly DefaultApplication[];
  private constructor(value: ExactJson, applications: readonly DefaultApplication[]) {
    this.#value = deepFreeze(cloneTree(value));
    this.#applications = deepFreeze(cloneTree(applications));
    Object.freeze(this);
  }
  get value(): ExactJson { return this.#value; }
  get applications(): readonly DefaultApplication[] { return this.#applications; }
  static checked(context: ValueContext, ref: TypeRef, before: ExactJson, after: ExactJson, applications: readonly DefaultApplication[], id: number = context.typeIndexes.get(typeIdentity(ref)) ?? -1, applicationIds: readonly number[] = applications.map(application => context.typeIndexes.get(typeIdentity(application.type_ref)) ?? -1)): DefaultedValue {
    validated(meaningFailure(context, ref, id) ?? membership(context, ref, id, after, null), ref);
    requireEvidence(checkDefaultApplicationsAt(context, before, after, applications, applicationIds), "default source, absence, or result");
    return new DefaultedValue(after, applications);
  }
}
export type ValuePath = readonly (string | bigint)[];
type DataFailure = readonly [ValuePath, ValueCondition, ExactJson];
export interface ValueRequirement { readonly typeRef: TypeRef; readonly target: number; readonly valuePath: ValuePath; readonly value: ExactJson; }
export type Expansion =
  | { readonly tag: "Requirements"; readonly value: readonly ValueRequirement[] }
  | { readonly tag: "Rejected"; readonly failure: ValueFailure }
  | { readonly tag: "Unresolved"; readonly obligations: readonly SemanticObligation[] };
export interface MemberProof { readonly children: readonly MemberProof[]; }
export interface MemberCertificate { readonly profile: ProfileRef; readonly source_refs: readonly SourceRef[]; readonly contract: SlotContract; readonly value: ExactSlot; readonly proof: MemberProof | null; }
export type ValidationFailure =
  | { readonly tag: "Value"; readonly failure: ValueFailure }
  | { readonly tag: "Unresolved"; readonly obligations: readonly SemanticObligation[] }
  | { readonly tag: "CertificateMismatch"; readonly condition: string };
export type MembershipResult =
  | { readonly tag: "Accepted"; readonly proof: MemberProof }
  | { readonly tag: "Rejected"; readonly failure: ValueFailure }
  | { readonly tag: "Unresolved"; readonly obligations: readonly SemanticObligation[] }
  | { readonly tag: "InvalidCertificate"; readonly condition: string };
export type Validation<T> = { readonly tag: "Ok"; readonly value: T } | { readonly tag: "Failed"; readonly failure: ValidationFailure };
const validatedValueToken = Symbol("validated value");
export class ValidatedValue {
  private constructor(token: symbol, readonly proof: MemberProof) {
    if (token !== validatedValueToken) throw new TypeError("validated value admission authority");
    Object.freeze(this);
  }
  static admit(token: symbol, proof: MemberProof): ValidatedValue { return new ValidatedValue(token, proof); }
}
const validatedSlotToken = Symbol("validated slot");
export class ValidatedSlot {
  private constructor(token: symbol, readonly certificate: MemberCertificate) {
    if (token !== validatedSlotToken) throw new TypeError("validated slot admission authority");
    Object.freeze(this);
  }
  static admit(token: symbol, certificate: MemberCertificate): ValidatedSlot { return new ValidatedSlot(token, certificate); }
}
export type ValueDecision =
  | { readonly tag: "Accepted" }
  | { readonly tag: "Rejected"; readonly failure: ValueFailure }
  | { readonly tag: "Unresolved"; readonly obligations: readonly SemanticObligation[] };

export function findType(context: ValueContext, ref: TypeRef): TypeNode | undefined {
  const id = context.typeIndexes.get(typeIdentity(ref));
  return id === undefined || id >= context.nodes.length ? undefined : context.nodes[id]!.node;
}
function resolvedShapeFuel(context: ValueContext, fuel: number, reference: TypeRef): TypeShape | undefined {
  if (fuel === 0) return undefined;
  const node = findType(context, reference);
  if (node === undefined) return undefined;
  if (node.shape.tag !== "Alias") return node.shape;
  return resolvedShapeFuel(context, fuel - 1, node.shape.fields.target);
}

export function resolvedShape(context: ValueContext, reference: TypeRef): TypeShape | undefined {
  return resolvedShapeFuel(context, context.graph.nodes.length + 1, reference);
}
function pathSteps(path: ValuePath): readonly PathStep[] {
  return path.map(step => typeof step === "string" ? { tag: "Field", value: step } as const : { tag: "Index", value: step.toString() } as const);
}
function failureAt(ref: TypeRef, path: ValuePath, value: ExactSlot, condition: ValueCondition, trace: readonly TypeRef[] = []): ValueFailure {
  return valueFailure(ref, path, condition, condition.tag === "MissingRequired" ? { tag: "Absent" } : value, trace);
}
function obligationAt(graph: ValueGraph, ref: TypeRef, path: ValuePath, reason: SemanticReason): SemanticObligation {
  return { type_ref: ref, origin: { source: ref.source, pointer: ref.pointer }, value_path: pathSteps(path), profile: graph.profile.reference, reason };
}

function lengthAccepts(minimum: string | null, maximum: string | null, length: bigint): boolean {
  return (minimum === null || BigInt(minimum) <= length) && (maximum === null || length <= BigInt(maximum));
}
function utf8Length(text: string): bigint { return BigInt(utf8Encoder.encode(text).length); }
function formatLength(graphemes: GraphemeRules | null, unit: StringLengthUnit, value: string): bigint | null {
  if (unit.tag === "Utf8Bytes") return utf8Length(value);
  if (unit.tag === "UnicodeScalars") return BigInt(codePointCount(value));
  return graphemes === null ? null : graphemeLength(graphemes, value);
}
function lengthInUnit(profile: PreparedProfile, unit: StringLengthUnit, value: string): bigint | null {
  if (unit.tag === "Utf8Bytes") return utf8Length(value);
  if (unit.tag === "UnicodeScalars") return BigInt(codePointCount(value));
  const graphemes = profile.tables.graphemes;
  return graphemes === null ? null : BigInt(graphemeCountOf(graphemeTablesOf(graphemes), value));
}
function lengthBoundsFailure(profile: PreparedProfile, value: string, bounds: readonly LengthBound[]): ValueCondition | null {
  for (const bound of bounds) {
    const length = lengthInUnit(profile, bound.unit, value);
    if (length === null || !lengthAccepts(bound.minimum, bound.maximum, length)) return { tag: "StringLength" };
  }
  return null;
}
function firstRepeated(seen: Set<string>, keys: readonly string[]): string | null {
  for (const key of keys) { if (seen.has(key)) return key; seen.add(key); }
  return null;
}
function duplicateKey(members: readonly { readonly key: string }[]): string | null {
  return firstRepeated(new Set<string>(), members.map(item => item.key));
}
export function memberValue(key: string, members: readonly { readonly key: string; readonly value: ExactJson }[]): ExactJson | undefined { return members.find(item => item.key === key)?.value; }
type MemberIndex = ReadonlyMap<string, ExactJson>;
function memberIndex(members: readonly { readonly key: string; readonly value: ExactJson }[]): MemberIndex {
  const index = new Map<string, ExactJson>();
  for (const item of members) if (!index.has(item.key)) index.set(item.key, item.value);
  return index;
}

const jsonNumber = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/;
export function normalizeNumber(text: string): readonly [bigint, bigint, bigint] | null {
  const matched = jsonNumber.exec(text.replace(/^[ \t\n\r]+|[ \t\n\r]+$/g, ""));
  if (matched === null) return null;
  const exponent = matched[4];
  if (exponent !== undefined && exponentMagnitudeAtLimit(exponent, 0)) return null;
  const fraction = matched[3] ?? "", mantissa = BigInt(`${matched[2]}${fraction}`), digits = mantissa.toString().length;
  if (mantissa === 0n) return [0n, 0n, 0n];
  let stripped = mantissa;
  while (stripped % 10n === 0n) stripped /= 10n;
  return [matched[1] === "-" ? -1n : 1n, stripped, BigInt(digits) - (BigInt(fraction.length) - BigInt(matched[4] ?? "0"))];
}
function decimalIntegerParts(text: string): readonly [bigint, bigint, bigint] | null {
  if (text.replace(/^[ \t\n\r]+|[ \t\n\r]+$/g, "") !== text || text.startsWith("+")) return null;
  const parts = normalizeNumber(text);
  if (parts === null) return null;
  return parts[1] === 0n || parts[2] >= BigInt(parts[1].toString().length) ? parts : null;
}
function decimalInteger(text: string): bigint | null {
  const parts = decimalIntegerParts(text);
  if (parts === null) return null;
  const [sign, digits, power] = parts, shift = power - BigInt(digits.toString().length);
  return sign * (digits === 0n ? 0n : digits * 10n ** shift);
}
function integerValueForForm(form: IntegerForm, value: ExactJson): bigint | null {
  if (form.tag === "Number" && value.tag === "Integer") return BigInt(value.value);
  if (form.tag === "IntegralDecimal" && value.tag === "Decimal") return decimalInteger(value.text);
  if (form.tag === "DecimalString" && value.tag === "String") return decimalInteger(value.value);
  return null;
}
export function integerBinding(profile: PreparedProfile, domain: string | null): IntegerDomainBinding | undefined {
  return preparedDomain(profile, domain)?.binding;
}
function preparedDomain(profile: PreparedProfile, domain: string | null): PreparedIntegerDomain | undefined {
  return profile.tables.integerBindings.get(domain ?? profile.default_integer_domain);
}
function integerValueForBinding(binding: IntegerDomainBinding, value: ExactJson): bigint | null {
  for (const form of binding.forms) { const integer = integerValueForForm(form, value); if (integer !== null) return integer; }
  return null;
}
export function integerValueForDomain(profile: PreparedProfile, domain: string | null, value: ExactJson): bigint | null {
  const binding = integerBinding(profile, domain);
  return binding === undefined ? null : integerValueForBinding(binding, value);
}
function integerRangeAccepts(domain: PreparedIntegerDomain, value: bigint): boolean {
  const range = domain.binding.range;
  if (range.tag === "Unbounded") return true;
  const bounds = domain.bounds;
  return bounds === null ? BigInt(range.fields.minimum) <= value && value <= BigInt(range.fields.maximum) : bounds[0] <= value && value <= bounds[1];
}
function jsonWholeNumber(text: string): boolean { return /^(0|[1-9][0-9]*)$/.test(text); }
function decimalMagnitudeExceedsRangeDigits(minimum: bigint, maximum: bigint, text: string): boolean {
  const unsigned = text.startsWith("-") ? text.slice(1) : text;
  if (unsigned.startsWith("+")) return false;
  const lowercase = unsigned.split("e"), parts = lowercase.length === 2 ? lowercase : unsigned.split("E");
  if (parts.length !== 2) return false;
  const [base, exponentText] = parts as [string, string], exponentDigits = exponentText.startsWith("+") ? exponentText.slice(1) : exponentText;
  if (exponentDigits.startsWith("-") || exponentDigits === "" || !/^[0-9]+$/.test(exponentDigits)) return false;
  const exponent = BigInt(exponentDigits), magnitude = (value: bigint): bigint => value < 0n ? -value : value;
  const limit = BigInt((magnitude(minimum) > magnitude(maximum) ? magnitude(minimum) : magnitude(maximum)).toString().length);
  const significant = (digits: string): bigint => BigInt(digits.replace(/^0+/, "").length);
  const pieces = base.split(".");
  if (pieces.length === 1) {
    if (!jsonWholeNumber(pieces[0]!)) return false;
    const digits = significant(pieces[0]!);
    return digits !== 0n && digits + exponent > limit;
  }
  if (pieces.length === 2) {
    const [whole, fraction] = pieces as [string, string];
    if (!jsonWholeNumber(whole) || fraction === "" || !/^[0-9]+$/.test(fraction) || exponent < BigInt(fraction.length)) return false;
    const digits = significant(whole + fraction);
    return digits !== 0n && digits + exponent - BigInt(fraction.length) > limit;
  }
  return false;
}
type IntegerInRange = { readonly tag: "NotInteger" } | { readonly tag: "OutOfRange" } | { readonly tag: "Integer"; readonly value: bigint };
function integerValueForBindingInRange(domain: PreparedIntegerDomain, value: ExactJson): IntegerInRange {
  const binding = domain.binding, range = binding.range;
  if (range.tag === "Unbounded") { const integer = integerValueForBinding(binding, value); return integer === null ? { tag: "NotInteger" } : { tag: "Integer", value: integer }; }
  const text = value.tag === "Decimal" && binding.forms.some(form => form.tag === "IntegralDecimal") ? value.text
    : value.tag === "String" && binding.forms.some(form => form.tag === "DecimalString") ? value.value : null;
  if (text !== null) {
    const bounds = domain.bounds ?? [BigInt(range.fields.minimum), BigInt(range.fields.maximum)];
    if (decimalMagnitudeExceedsRangeDigits(bounds[0], bounds[1], text)) return { tag: "OutOfRange" };
  }
  const integer = integerValueForBinding(binding, value);
  if (integer === null) return { tag: "NotInteger" };
  return integerRangeAccepts(domain, integer) ? { tag: "Integer", value: integer } : { tag: "OutOfRange" };
}
function integerInDomain(profile: PreparedProfile, domain: string | null, value: ExactJson): boolean {
  const binding = preparedDomain(profile, domain);
  return binding !== undefined && integerValueForBindingInRange(binding, value).tag === "Integer";
}
export function integerCondition(profile: PreparedProfile, spec: IntegerSpec, value: ExactJson): ValueCondition | null {
  return integerConditionPrepared(profile, prepareIntegerSpec(spec), value);
}
function integerConditionPrepared(profile: PreparedProfile, prepared: PreparedIntegerSpec, value: ExactJson): ValueCondition | null {
  const spec = prepared.spec, binding = preparedDomain(profile, spec.domain);
  if (binding === undefined) return { tag: "IntegerDomain" };
  const checked = integerValueForBindingInRange(binding, value);
  if (checked.tag === "NotInteger") return { tag: "WrongValueKind", value: "integer" };
  if (checked.tag === "OutOfRange") return { tag: "IntegerDomain" };
  const integer = checked.value;
  const limits = prepared.limits;
  if (limits === null) {
    if (spec.const_value !== null && BigInt(spec.const_value) !== integer) return { tag: "ConstMismatch" };
    if (spec.enum_values !== null && !spec.enum_values.some(item => BigInt(item) === integer)) return { tag: "EnumMismatch" };
    if (spec.minimum !== null && integer < BigInt(spec.minimum)) return { tag: "BelowMinimum" };
    if (spec.maximum !== null && BigInt(spec.maximum) < integer) return { tag: "AboveMaximum" };
    return null;
  }
  if (limits.constValue !== null && limits.constValue !== integer) return { tag: "ConstMismatch" };
  if (limits.enumValues !== null && !limits.enumValues.has(integer)) return { tag: "EnumMismatch" };
  if (limits.minimum !== null && integer < limits.minimum) return { tag: "BelowMinimum" };
  if (limits.maximum !== null && limits.maximum < integer) return { tag: "AboveMaximum" };
  return null;
}
type IntegerLimits = { readonly constValue: bigint | null; readonly enumValues: ReadonlySet<bigint> | null; readonly minimum: bigint | null; readonly maximum: bigint | null };
function prepareIntegerSpec(spec: IntegerSpec): PreparedIntegerSpec {
  const parsed = (text: string | null): bigint | null => text === null ? null : BigInt(text);
  let limits: IntegerLimits | null;
  try {
    limits = { constValue: parsed(spec.const_value), enumValues: spec.enum_values === null ? null : new Set(spec.enum_values.map(item => BigInt(item))), minimum: parsed(spec.minimum), maximum: parsed(spec.maximum) };
  } catch { limits = null; }
  return { spec, limits };
}
const unconstrainedInteger: PreparedIntegerSpec = prepareIntegerSpec({ domain: null, minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null });
function prepareStringSpec(spec: StringSpec): PreparedStringSpec {
  return { spec, enumValues: spec.enum_values === null ? null : new Set(spec.enum_values), inline: spec.format?.tag === "Inline" ? prepareFormat(spec.format.value) : null };
}
function prepareFormat(rule: FormatRule): PreparedFormat {
  return { rule, program: attempt(() => compileFormatProgram(rule)) };
}
function recognizePrepared(format: PreparedFormat, text: string, graphemes: PreparedGraphemes | null): boolean {
  return unicodeValid(text) && runFormatProgram(format.program ?? compileFormatProgram(format.rule), graphemes, text);
}
type ObjectClass = { readonly tag: "Sealed"; readonly value: SealedForm } | { readonly tag: "Wrapper"; readonly value: Wrapper } | { readonly tag: "Ordinary" };
export function classOf(profile: VersionedSemanticProfile, members: readonly { readonly key: string; readonly value: ExactJson }[]): ObjectClass {
  return classOfMembers(profile, key => memberValue(key, members));
}
function classOfMembers(profile: VersionedSemanticProfile, lookup: (key: string) => ExactJson | undefined): ObjectClass {
  const tagged = profile.tag === null ? undefined : lookup(profile.tag.key);
  if (tagged?.tag === "String") {
    const form = profile.tag!.sealed.find(candidate => candidate.tag === tagged.value);
    if (form !== undefined) return { tag: "Sealed", value: form };
  }
  const wrapper = profile.wrappers.find(candidate => lookup(candidate.key) !== undefined);
  return wrapper === undefined ? { tag: "Ordinary" } : { tag: "Wrapper", value: wrapper };
}
function namedFormatAccepts(profile: PreparedProfile, name: string, value: string): boolean {
  const format = profile.tables.formats.get(name);
  return format !== undefined && recognizePrepared(format, value, profile.tables.graphemes);
}
export function formatUseAccepts(profile: PreparedProfile, use: FormatUse, text: string): boolean {
  return use.tag === "Named" ? namedFormatAccepts(profile, use.value, text) : recognizePrepared(prepareFormat(use.value), text, profile.tables.graphemes);
}
function preparedUseAccepts(profile: PreparedProfile, use: PreparedFormatUse, text: string): boolean {
  return use.tag === "Named" ? namedFormatAccepts(profile, use.value, text) : recognizePrepared(use.format, text, profile.tables.graphemes);
}
function wrapperPayloadText(profile: PreparedProfile, wrapper: Wrapper, value: ExactJson): string | null {
  if (value.tag !== "Object" || value.members.length !== 1) return null;
  const only = value.members[0]!;
  if (only.value.tag !== "String" || only.key !== wrapper.key) return null;
  const text = only.value.value;
  if (wrapper.payload.tag === "Bytes") return profile.bytes_policy !== null && base64Length(text, profile.bytes_policy) !== null ? text : null;
  if (wrapper.payload.value === null) return unicodeValid(text) ? text : null;
  return unicodeValid(text) && namedFormatAccepts(profile, wrapper.payload.value, text) ? text : null;
}
function wrapperPayloadFailure(profile: PreparedProfile, wrapper: Wrapper, value: ExactJson): ValueCondition | null {
  if (wrapperPayloadText(profile, wrapper, value) !== null) return null;
  if (wrapper.payload.tag === "Bytes") return { tag: "InvalidBytes" };
  return wrapper.payload.value === null ? { tag: "WrongValueKind", value: "wrapper text" } : { tag: "Format", value: wrapper.payload.value };
}
function sealedStringCondition(profile: PreparedProfile, prepared: PreparedStringSpec, value: string): ValueCondition | null {
  const spec = prepared.spec;
  if (!unicodeValid(value)) return { tag: "InvalidDataModel" };
  if (spec.const_value !== null && spec.const_value !== value) return { tag: "ConstMismatch" };
  if (prepared.enumValues !== null && !prepared.enumValues.has(value)) return { tag: "EnumMismatch" };
  const lengths = lengthBoundsFailure(profile, value, spec.lengths);
  if (lengths !== null) return lengths;
  if (spec.format === null) return null;
  if (spec.format.tag === "Named") return namedFormatAccepts(profile, spec.format.value, value) ? null : { tag: "Format", value: spec.format.value };
  return recognizePrepared(prepared.inline!, value, profile.tables.graphemes) ? null : { tag: "Format", value: "inline" };
}
function sealedLeafFailure(profile: PreparedProfile, leaf: PreparedLeaf, value: ExactJson): ValueCondition | null {
  if (leaf.tag === "Integer") return value.tag === "Integer" ? integerConditionPrepared(profile, leaf.value, value) : { tag: "WrongValueKind", value: "integer" };
  if (value.tag === "String") return sealedStringCondition(profile, leaf.value, value.value);
  if (value.tag !== "Object") return { tag: "WrongValueKind", value: "string" };
  const classification = classOf(profile, value.members);
  if (classification.tag !== "Wrapper") return { tag: "WrongValueKind", value: "string" };
  const text = wrapperPayloadText(profile, classification.value, value);
  return text === null ? wrapperPayloadFailure(profile, classification.value, value) : sealedStringCondition(profile, leaf.value, text);
}
function tagMemberFailure(profile: PreparedProfile, members: readonly { readonly key: string; readonly value: ExactJson }[]): readonly [string, ValueCondition, ExactJson] | null {
  if (profile.tag === null) return null;
  const value = memberValue(profile.tag.key, members);
  if (value === undefined) return null;
  if (value.tag !== "String") return [profile.tag.key, { tag: "InvalidTag" }, value];
  if (!unicodeValid(value.value)) return [profile.tag.key, { tag: "InvalidDataModel" }, value];
  if (profile.tag.format === null || namedFormatAccepts(profile, profile.tag.format, value.value)) return null;
  return [profile.tag.key, { tag: "InvalidTag" }, value];
}
export function bytesValueLength(profile: PreparedProfile, value: ExactJson): bigint | null {
  const policy = profile.bytes_policy;
  if (policy === null) return null;
  const text = bytesText(profile, policy, value);
  const length = text === null ? null : base64Length(text, policy);
  return length === null ? null : BigInt(length);
}
function sealedFieldFailure(profile: PreparedProfile, members: MemberIndex, field: PreparedSealedField): readonly [string, ValueCondition, ExactJson] | null {
  const key = field.field.key, value = members.get(key);
  if (value === undefined) return field.field.required ? [key, { tag: "MissingRequired" }, { tag: "Null" }] : null;
  const condition = sealedLeafFailure(profile, field.leaf, value);
  return condition === null ? null : [key, condition, value];
}
function sealedFieldsFailure(profile: PreparedProfile, form: SealedForm, members: MemberIndex): readonly [string, ValueCondition, ExactJson] | null {
  for (const field of profile.tables.sealed.get(form.tag)!.fields) { const failure = sealedFieldFailure(profile, members, field); if (failure !== null) return failure; }
  return null;
}
function sealedRefinementFailure(profile: PreparedProfile, members: MemberIndex, refinements: readonly SealedRefinement[], leaves: readonly PreparedLeaf[]): readonly [string, ValueCondition, ExactJson] | null {
  for (let index = 0; index < refinements.length; index += 1) {
    const key = refinements[index]!.key, value = members.get(key);
    if (value === undefined) continue;
    const condition = sealedLeafFailure(profile, leaves[index]!, value);
    if (condition !== null) return [key, condition, value];
  }
  return null;
}
function objectMemberFailure(profile: PreparedProfile, members: readonly { readonly key: string; readonly value: ExactJson }[]): DataFailure | null {
  const key = duplicateKey(members);
  if (key !== null) return [[], { tag: "DuplicateField", value: key }, { tag: "Object", members }];
  const failure = tagMemberFailure(profile, members);
  return failure === null ? null : [[failure[0]], failure[1], failure[2]];
}
type SealedMembers = { readonly tag: TagModel; readonly form: SealedForm; readonly known: ReadonlySet<string> };
function sealedMembers(tag: TagModel, form: SealedForm): SealedMembers { return { tag, form, known: new Set(form.fields.map(field => field.key)) }; }
function sealedKnownField(sealed: SealedMembers, key: string): boolean { return key === sealed.tag.key || sealed.known.has(key); }
type DataTask =
  | { readonly kind: "value"; readonly path: ValuePath; readonly value: ExactJson }
  | { readonly kind: "member"; readonly path: ValuePath; readonly key: string; readonly value: ExactJson; readonly sealed: SealedMembers | null };
function runDataTasks(profile: PreparedProfile, pending: DataTask[]): DataFailure | null {
  while (pending.length > 0) {
    const task = pending.pop()!;
    const failure = task.kind === "value" ? dataValueFailure(profile, task.path, task.value, pending) : dataMemberFailure(task, pending);
    if (failure !== null) return failure;
  }
  return null;
}
function pushDataMembers(path: ValuePath, members: readonly { readonly key: string; readonly value: ExactJson }[],
  sealed: SealedMembers | null, pending: DataTask[]): void {
  for (let index = members.length - 1; index >= 0; index--) {
    const member = members[index]!;
    pending.push({ kind: "member", path, key: member.key, value: member.value, sealed });
  }
}
function dataItemsFailure(path: ValuePath, items: readonly ExactJson[], pending: DataTask[]): void {
  for (let index = items.length - 1; index >= 0; index--) pending.push({ kind: "value", path: [...path, BigInt(index)], value: items[index]! });
}
function dataMembersFailure(path: ValuePath, members: readonly { readonly key: string; readonly value: ExactJson }[], pending: DataTask[]): void {
  pushDataMembers(path, members, null, pending);
}
function dataSealedMembersFailure(path: ValuePath, tag: TagModel, form: SealedForm, members: readonly { readonly key: string; readonly value: ExactJson }[], pending: DataTask[]): void {
  pushDataMembers(path, members, sealedMembers(tag, form), pending);
}
function dataMemberFailure(task: Extract<DataTask, { readonly kind: "member" }>, pending: DataTask[]): DataFailure | null {
  if (task.sealed !== null) {
    if (sealedKnownField(task.sealed, task.key)) return null;
    if (task.sealed.form.extras.tag === "Reject") return [[...task.path, task.key], { tag: "UnexpectedField", value: task.key }, task.value];
  }
  if (!unicodeValid(task.key)) return [[...task.path, task.key], { tag: "InvalidDataModel" }, task.value];
  pending.push({ kind: "value", path: [...task.path, task.key], value: task.value });
  return null;
}
function dataValueFailure(profile: PreparedProfile, path: ValuePath, value: ExactJson, pending: DataTask[]): DataFailure | null {
  if (value.tag === "Integer") return integerInDomain(profile, null, value) ? null : [path, { tag: "IntegerDomain" }, value];
  if (value.tag === "Decimal") {
    if (normalizeNumber(value.text) === null) return [path, { tag: "InvalidDataModel" }, value];
    const binding = integerBinding(profile, null);
    if (binding !== undefined && binding.range.tag === "Unbounded" && binding.forms.some(form => form.tag === "IntegralDecimal") && decimalIntegerParts(value.text) !== null) return null;
    const condition = integerConditionPrepared(profile, unconstrainedInteger, value);
    if (condition === null) return null;
    if (condition.tag === "IntegerDomain") return [path, condition, value];
    return profile.numbers.decimals ? null : [path, { tag: "InvalidDataModel" }, value];
  }
  if (value.tag === "String") return unicodeValid(value.value) ? null : [path, { tag: "InvalidDataModel" }, value];
  if (value.tag === "Array") {
    dataItemsFailure(path, value.items, pending);
    return null;
  }
  if (value.tag !== "Object") return null;
  const members = value.members, member = objectMemberFailure(profile, members);
  if (member !== null) return [[...path, ...member[0]], member[1], member[2]];
  const index = memberIndex(members), classification = classOfMembers(profile, key => index.get(key));
  if (classification.tag === "Wrapper") { const condition = wrapperPayloadFailure(profile, classification.value, value); return condition === null ? null : [path, condition, value]; }
  if (classification.tag === "Sealed") {
    const form = classification.value, sealed = sealedFieldsFailure(profile, form, index);
    if (sealed !== null) return [[...path, sealed[0]], sealed[1], sealed[2]];
    if (profile.tag === null) return [path, { tag: "InvalidDataModel" }, { tag: "Object", members }];
    dataSealedMembersFailure(path, profile.tag, form, members, pending);
    return null;
  }
  dataMembersFailure(path, members, pending);
  return null;
}
function dataValueAt(profile: PreparedProfile, path: ValuePath, value: ExactJson): DataFailure | null {
  return runDataTasks(profile, [{ kind: "value", path, value }]);
}
export function dataValueAccepts(profile: PreparedProfile, value: ExactJson): boolean {
  return dataValueAt(profile, [], value) === null;
}
export function tagValueAccepts(profile: PreparedProfile, members: readonly { readonly key: string; readonly value: ExactJson }[]): boolean {
  return tagMemberFailure(profile, members) === null;
}
function textWrapper(profile: PreparedProfile): Wrapper | undefined {
  return profile.wrappers.find(wrapper => wrapper.payload.tag === "Text");
}
export function wrapperTextAccepts(profile: PreparedProfile, value: ExactJson): boolean {
  const wrapper = textWrapper(profile);
  return wrapper !== undefined && wrapperPayloadText(profile, wrapper, value) !== null;
}
function sealedExtrasFailure(profile: PreparedProfile, path: ValuePath, form: SealedForm, members: readonly { readonly key: string; readonly value: ExactJson }[]): DataFailure | null {
  const tag = profile.tag;
  if (tag === null) return [path, { tag: "InvalidDataModel" }, { tag: "Object", members }];
  const pending: DataTask[] = [];
  pushDataMembers(path, members, sealedMembers(tag, form), pending);
  return runDataTasks(profile, pending);
}

export function stringCondition(profile: PreparedProfile, spec: StringSpec, value: string): ValueCondition | null {
  return stringConditionPrepared(profile, prepareStringSpec(spec), value);
}
function stringConditionPrepared(profile: PreparedProfile, prepared: PreparedStringSpec, value: string): ValueCondition | null {
  const spec = prepared.spec;
  if (!unicodeValid(value)) return { tag: "InvalidDataModel" };
  if (spec.const_value !== null && spec.const_value !== value) return { tag: "ConstMismatch" };
  if (prepared.enumValues !== null && !prepared.enumValues.has(value)) return { tag: "EnumMismatch" };
  const lengths = lengthBoundsFailure(profile, value, spec.lengths);
  if (lengths !== null) return lengths;
  if (spec.format === null) return null;
  if (spec.format.tag === "Named") {
    const name = spec.format.value, format = profile.tables.formats.get(name);
    return format === undefined || recognizePrepared(format, value, profile.tables.graphemes) ? null : { tag: "Format", value: name };
  }
  return recognizePrepared(prepared.inline!, value, profile.tables.graphemes) ? null : { tag: "Format", value: "inline" };
}
function stringValueCondition(profile: PreparedProfile, prepared: PreparedStringSpec, value: ExactJson): ValueCondition | null {
  const spec = prepared.spec;
  if (spec.wrapper === null) return value.tag === "String" ? stringConditionPrepared(profile, prepared, value.value) : { tag: "WrongValueKind", value: "string" };
  if (value.tag !== "Object") return { tag: "WrongValueKind", value: "string wrapper" };
  const classification = classOf(profile, value.members);
  if (classification.tag !== "Wrapper" || classification.value.name !== spec.wrapper) return { tag: "WrongValueKind", value: "string wrapper" };
  const text = wrapperPayloadText(profile, classification.value, value);
  return text === null ? wrapperPayloadFailure(profile, classification.value, value) : stringConditionPrepared(profile, prepared, text);
}

function slotRequirements(path: ValuePath, members: MemberIndex, fields: readonly FieldSpec[], targets: readonly number[]): Expansion {
  const requests: ValueRequirement[] = [];
  for (let index = 0; index < fields.length; index += 1) {
    const field = fields[index]!;
    const here = [...path, field.wire_name], value = members.get(field.wire_name);
    if (value === undefined && field.slot.required) return { tag: "Rejected", failure: failureAt(field.slot.type_ref, here, { tag: "Absent" }, { tag: "MissingRequired" }) };
    if (value?.tag === "Null" && !field.slot.nullable) return { tag: "Rejected", failure: failureAt(field.slot.type_ref, here, { tag: "Null" }, { tag: "NullNotAllowed" }) };
    if (value !== undefined && value.tag !== "Null") requests.push({ typeRef: field.slot.type_ref, target: targets[index]!, valuePath: here, value });
  }
  return { tag: "Requirements", value: requests };
}
function elementRequirements(contract: ElementContract, target: number, path: ValuePath, value: ExactJson): readonly ValueRequirement[] {
  return value.tag === "Null" && contract.nullable ? [] : [{ typeRef: contract.type_ref, target, valuePath: path, value }];
}
function extraMembersFailure(profile: PreparedProfile, product: PreparedProduct, members: readonly { readonly key: string; readonly value: ExactJson }[]): DataFailure | null {
  const spec = product.spec;
  for (const item of members) {
    if (product.known.has(item.key) || profile.tag !== null && item.key === profile.tag.key) continue;
    if (spec.extras.tag === "Reject") return [[item.key], { tag: "UnexpectedField", value: item.key }, item.value];
    const keyFormat = product.keyFormat;
    if (!unicodeValid(item.key)) return [[item.key], { tag: "InvalidDataModel" }, item.value];
    if (keyFormat !== null && !preparedUseAccepts(profile, keyFormat, item.key)) return [[item.key], { tag: "KeyFormat", value: item.key }, item.value];
  }
  return null;
}
function extraFieldRequirements(profile: PreparedProfile, path: ValuePath, product: PreparedProduct, members: readonly { readonly key: string; readonly value: ExactJson }[]): readonly ValueRequirement[] {
  const spec = product.spec;
  return members.flatMap(item => {
    if (product.known.has(item.key) || profile.tag !== null && item.key === profile.tag.key) return [];
    return spec.extras.tag === "Reject" ? [] : elementRequirements(spec.extras.fields.value, product.extraTarget, [...path, item.key], item.value);
  });
}
function productRequirements(profile: PreparedProfile, path: ValuePath, product: PreparedProduct, members: readonly { readonly key: string; readonly value: ExactJson }[]): Expansion {
  const fields = slotRequirements(path, memberIndex(members), product.spec.fields, product.fieldTargets);
  return fields.tag === "Requirements" ? { tag: "Requirements", value: [...fields.value, ...extraFieldRequirements(profile, path, product, members)] } : fields;
}
function memberTestMatches(profile: PreparedProfile, members: readonly { readonly key: string; readonly value: ExactJson }[], check: MemberCheck): boolean {
  const value = memberValue(check.key, members);
  if (check.test.tag === "Absent") return value === undefined;
  return value?.tag === "String" && namedFormatAccepts(profile, check.test.value, value.value);
}
function valueKindMatches(kind: ValueKind, value: ExactJson): boolean { return exactKind(value) === kind.tag; }
function selectorMatches(profile: PreparedProfile, branch: UnionBranch, value: ExactJson): boolean {
  const selector = branch.selector;
  if (selector.tag === "InternalTag") {
    if (profile.tag === null || value.tag !== "Object") return false;
    const tag = memberValue(profile.tag.key, value.members);
    return tag?.tag === "String" && tag.value === branch.wire_tag;
  }
  if (selector.tag === "MemberShape") return value.tag === "Object" && selector.value.every(check => memberTestMatches(profile, value.members, check));
  if (selector.tag === "Kind") return valueKindMatches(selector.value, value);
  return true;
}
function selectUnionIndex(profile: PreparedProfile, spec: UnionSpec, value: ExactJson): number {
  return spec.branches.findIndex(branch => selectorMatches(profile, branch, value));
}
export function selectUnionBranch(profile: PreparedProfile, spec: UnionSpec, value: ExactJson): UnionBranch | null {
  return spec.branches[selectUnionIndex(profile, spec, value)] ?? null;
}

function compareDecimalBound(text: string, bound: DecimalBound): -1 | 0 | 1 | null {
  const parts = normalizeNumber(text);
  if (parts === null) return null;
  const mantissa = parts[0] * parts[1], exponent = parts[2] - BigInt(parts[1].toString().length) + BigInt(bound.scale), boundMantissa = BigInt(bound.mantissa);
  const left = exponent >= 0n ? mantissa * 10n ** exponent : mantissa, right = exponent >= 0n ? boundMantissa : boundMantissa * 10n ** -exponent;
  return left < right ? -1 : left > right ? 1 : 0;
}
function decimalCondition(spec: DecimalSpec, text: string): ValueCondition | null {
  if (normalizeNumber(text) === null) return { tag: "InvalidDataModel" };
  const minimum = spec.minimum === null ? null : compareDecimalBound(text, spec.minimum);
  if (minimum === -1 || (minimum === 0 && spec.minimum!.exclusive)) return { tag: "BelowMinimum" };
  const maximum = spec.maximum === null ? null : compareDecimalBound(text, spec.maximum);
  if (maximum === 1) return { tag: "AboveMaximum" };
  if (maximum === 0) return spec.maximum!.exclusive ? { tag: "AboveMaximum" } : null;
  return null;
}

function expandPrepared(context: ValueContext, ref: TypeRef, id: number, path: ValuePath, value: ExactJson): Expansion {
  const profile = context.prepared, graph = context.graph, entry = id >= 0 && id < context.nodes.length ? context.nodes[id] : undefined;
  const reject = (condition: ValueCondition): Expansion => ({ tag: "Rejected", failure: failureAt(ref, path, { tag: "Present", value }, condition) });
  const rejectAt = (at: ValuePath, condition: ValueCondition, observed: ExactJson): Expansion => ({ tag: "Rejected", failure: failureAt(ref, at, { tag: "Present", value: observed }, condition) });
  const requirements = (value: readonly ValueRequirement[]): Expansion => ({ tag: "Requirements", value });
  const conditional = (condition: ValueCondition | null): Expansion => condition === null ? requirements([]) : reject(condition);
  if (entry === undefined) return { tag: "Unresolved", obligations: [obligationAt(graph, ref, path, { tag: "UnresolvedType" })] };
  const shape = entry.node.shape, prepared = entry.shape;
  if (shape.tag === "Boolean" && value.tag === "Bool") return shape.value.const_value !== null && shape.value.const_value !== value.value ? reject({ tag: "ConstMismatch" }) : requirements([]);
  if (prepared.tag === "Integer") return conditional(integerConditionPrepared(profile, prepared.spec, value));
  if (shape.tag === "Decimal" && value.tag === "Decimal") return conditional(decimalCondition(shape.value, value.text));
  if (prepared.tag === "String") return conditional(stringValueCondition(profile, prepared.spec, value));
  if (shape.tag === "Bytes") {
    const length = bytesValueLength(profile, value);
    if (length === null) return reject({ tag: "InvalidBytes" });
    return lengthAccepts(shape.value.minimum, shape.value.maximum, length) ? requirements([]) : reject({ tag: "BytesLength" });
  }
  if (prepared.tag === "Product" && value.tag === "Object") {
    const member = objectMemberFailure(profile, value.members);
    if (member !== null) return rejectAt([...path, ...member[0]], member[1], member[2]);
    if (classOf(profile, value.members).tag !== "Ordinary") return reject({ tag: "WrongValueKind", value: "plain data object" });
    const extra = extraMembersFailure(profile, prepared, value.members);
    if (extra !== null) return rejectAt([...path, ...extra[0]], extra[1], extra[2]);
    return productRequirements(profile, path, prepared, value.members);
  }
  if (prepared.tag === "Array" && value.tag === "Array") {
    if (!lengthAccepts(prepared.spec.min_length, prepared.spec.max_length, BigInt(value.items.length))) return reject({ tag: "ArrayLength" });
    return requirements(value.items.flatMap((item, index) => elementRequirements(prepared.spec.item, prepared.item, [...path, BigInt(index)], item)));
  }
  if (prepared.tag === "Alias") return requirements([{ typeRef: prepared.source, target: prepared.target, valuePath: path, value }]);
  if (prepared.tag === "TaggedUnion") {
    if (value.tag === "Object") {
      const member = objectMemberFailure(profile, value.members);
      if (member !== null) return rejectAt([...path, ...member[0]], member[1], member[2]);
    }
    const selected = selectUnionIndex(profile, prepared.spec, value);
    return selected < 0 ? reject({ tag: "NoBranchSelected" }) : requirements([{ typeRef: prepared.spec.branches[selected]!.target, target: prepared.branches[selected]!, valuePath: path, value }]);
  }
  if (shape.tag === "Sealed" && prepared.tag === "Sealed" && value.tag === "Object") {
    const member = objectMemberFailure(profile, value.members);
    if (member !== null) return rejectAt([...path, ...member[0]], member[1], member[2]);
    const index = memberIndex(value.members), classification = classOfMembers(profile, key => index.get(key)), tagModel = profile.tag;
    if (classification.tag !== "Sealed" || tagModel === null) return reject({ tag: "WrongValueKind", value: "sealed object" });
    if (classification.value.tag !== shape.fields.tag) return reject({ tag: "InvalidDataModel" });
    const fields = sealedFieldsFailure(profile, classification.value, index);
    if (fields !== null) return rejectAt([...path, fields[0]], fields[1], fields[2]);
    const members = sealedExtrasFailure(profile, path, classification.value, value.members);
    if (members !== null) return rejectAt(members[0], members[1], members[2]);
    const refinement = sealedRefinementFailure(profile, index, shape.fields.refinements, prepared.refinements);
    return refinement === null ? requirements([]) : rejectAt([...path, refinement[0]], refinement[1], refinement[2]);
  }
  if (shape.tag === "Never") return reject({ tag: "InvalidDataModel" });
  if (shape.tag === "Unknown" && shape.value.tag === "OrdinaryObject" && value.tag === "Object") {
    const member = objectMemberFailure(profile, value.members);
    if (member !== null) return rejectAt([...path, ...member[0]], member[1], member[2]);
    if (classOf(profile, value.members).tag !== "Ordinary") return reject({ tag: "WrongValueKind", value: "ordinary object" });
    const data = dataValueAt(profile, path, value);
    return data === null ? requirements([]) : rejectAt(data[0], data[1], data[2]);
  }
  if (shape.tag === "Unknown" && shape.value.tag === "OrdinaryObject") return reject({ tag: "WrongValueKind", value: "ordinary object" });
  if (shape.tag === "Unknown") {
    const data = dataValueAt(profile, path, value);
    return data === null ? requirements([]) : rejectAt(data[0], data[1], data[2]);
  }
  if (shape.tag === "Unit" && value.tag === "Null") return requirements([]);
  if (shape.tag === "RawBody") return bytesValueLength(profile, value) !== null ? requirements([]) : reject({ tag: "InvalidBytes" });
  if (shape.tag === "Opaque") return { tag: "Unresolved", obligations: [obligationAt(graph, ref, path, { tag: "OpaqueType", value: shape.fields.type_name })] };
  if (shape.tag === "Boolean") return reject({ tag: "WrongValueKind", value: "boolean" });
  if (shape.tag === "Decimal") return reject({ tag: "WrongValueKind", value: "decimal" });
  if (shape.tag === "Sealed") return reject({ tag: "WrongValueKind", value: "sealed object" });
  if (prepared.tag === "Product") return reject({ tag: "WrongValueKind", value: "object" });
  if (prepared.tag === "Array") return reject({ tag: "WrongValueKind", value: "array" });
  return reject({ tag: "WrongValueKind", value: "unit" });
}
export function expandValue(context: ValueContext, ref: TypeRef, path: ValuePath, value: ExactJson): Expansion {
  return expandPrepared(context, ref, context.typeIndexes.get(typeIdentity(ref)) ?? -1, path, value);
}

/** One membership check waiting for the children of its reference at its path. */
interface MembershipFrame {
  readonly refId: number;
  readonly ref: TypeRef;
  readonly path: ValuePath;
  readonly children: readonly ValueRequirement[];
  readonly childFuel: number;
  readonly wanted: readonly MemberProof[] | null;
  readonly proofs: MemberProof[];
  next: number;
}
function checkValueFuel(context: ValueContext, fuel: number, ref: TypeRef, id: number, path: ValuePath, value: ExactJson, expected: MemberProof | null): MembershipResult {
  const graph = context.graph, frames: MembershipFrame[] = [];
  const trace = (): TypeRef[] => frames.map(frame => frame.ref).reverse();
  const revisits = (refId: number, at: ValuePath): boolean => {
    for (let index = frames.length - 1; index >= 0 && frames[index]!.path.length === at.length; index -= 1)
      if (frames[index]!.refId === refId) return true;
    return false;
  };
  const open = (remaining: number, reference: TypeRef, refId: number, at: ValuePath, current: ExactJson, proof: MemberProof | null): MembershipResult | null => {
    if (remaining === 0) return { tag: "Unresolved", obligations: [obligationAt(graph, reference, at, { tag: "MembershipBound" })] };
    if (revisits(refId, at))
      return { tag: "Rejected", failure: failureAt(reference, at, { tag: "Present", value: current }, { tag: "ReferenceCycle" }, trace()) };
    const expansion = expandPrepared(context, reference, refId, at, current);
    if (expansion.tag === "Rejected") return { tag: "Rejected", failure: { ...expansion.failure, referenceTrace: trace() } };
    if (expansion.tag === "Unresolved") return { tag: "Unresolved", obligations: expansion.obligations };
    frames.push({ refId, ref: reference, path: at, children: expansion.value, childFuel: remaining - 1, wanted: proof === null ? null : proof.children, proofs: [], next: 0 });
    return null;
  };
  let outcome = open(fuel, ref, id, path, value, expected);
  while (frames.length > 0) {
    const frame = frames[frames.length - 1]!;
    if (outcome !== null) {
      if (outcome.tag !== "Accepted") {
        frames.pop();
        continue;
      }
      frame.proofs.push(outcome.proof);
      outcome = null;
    }
    const wantedRemaining = frame.wanted === null ? null : Math.max(frame.wanted.length - frame.next, 0);
    if (frame.next < frame.children.length) {
      if (wantedRemaining === 0) {
        frames.pop();
        outcome = { tag: "InvalidCertificate", condition: "missing membership children" };
        continue;
      }
      const child = frame.children[frame.next]!;
      const proof = frame.wanted === null ? null : frame.wanted[frame.next]!;
      frame.next += 1;
      outcome = open(frame.childFuel, child.typeRef, child.target, child.valuePath, child.value, proof);
      continue;
    }
    frames.pop();
    outcome = wantedRemaining !== null && wantedRemaining > 0 ? { tag: "InvalidCertificate", condition: "extra membership children" } : { tag: "Accepted", proof: { children: frame.proofs } };
  }
  return outcome!;
}
export function jsonSize(value: ExactJson): number {
  let size = 0;
  const pending: ExactJson[] = [value];
  while (pending.length > 0) {
    const item = pending.pop()!;
    size += 1;
    if (item.tag === "Array") for (const child of item.items) pending.push(child);
    else if (item.tag === "Object") for (const member of item.members) pending.push(member.value);
  }
  return size;
}

function meaningFailure(context: ValueContext, ref: TypeRef, id: number): Validation<never> | null {
  if (id >= 0 && !context.meaningBlocked[id]) return null;
  return { tag: "Failed", failure: { tag: "Unresolved", obligations: context.meaningObligations([ref]) } };
}
function membership(context: ValueContext, ref: TypeRef, id: number, value: ExactJson, proof: MemberProof | null): Validation<MemberProof> {
  const checked = checkValueFuel(context, (jsonSize(value) + 1) * (context.graph.nodes.length + 1), ref, id, [], value, proof);
  if (checked.tag === "Accepted") return { tag: "Ok", value: checked.proof };
  if (checked.tag === "Rejected") return { tag: "Failed", failure: { tag: "Value", failure: checked.failure } };
  if (checked.tag === "Unresolved") return { tag: "Failed", failure: { tag: "Unresolved", obligations: checked.obligations } };
  return { tag: "Failed", failure: { tag: "CertificateMismatch", condition: checked.condition } };
}
function valueMembership(context: ValueContext, ref: TypeRef, value: ExactJson, proof: MemberProof | null): Validation<MemberProof> {
  const id = context.typeIndexes.get(typeIdentity(ref)) ?? -1;
  return meaningFailure(context, ref, id) ?? membership(context, ref, id, value, proof);
}
function slotMembership(context: ValueContext, slot: SlotContract, value: ExactSlot): Validation<MemberProof | null> {
  const id = context.typeIndexes.get(typeIdentity(slot.type_ref)) ?? -1;
  const blocked = meaningFailure(context, slot.type_ref, id);
  if (blocked !== null) return blocked;
  if (value.tag === "Absent") return slot.required ? { tag: "Failed", failure: { tag: "Value", failure: failureAt(slot.type_ref, [], value, { tag: "MissingRequired" }) } } : { tag: "Ok", value: null };
  if (value.tag === "Null") return slot.nullable ? { tag: "Ok", value: null } : { tag: "Failed", failure: { tag: "Value", failure: failureAt(slot.type_ref, [], value, { tag: "NullNotAllowed" }) } };
  return membership(context, slot.type_ref, id, value.value, null);
}
export function validateValue(context: ValueContext, ref: TypeRef, value: ExactJson, proof: MemberProof | null = null): Validation<ValidatedValue> {
  const checked = valueMembership(context, ref, value, proof);
  return checked.tag === "Failed" ? checked : { tag: "Ok", value: ValidatedValue.admit(validatedValueToken, checked.value) };
}
export function validateSlot(context: ValueContext, slot: SlotContract, value: ExactSlot): Validation<ValidatedSlot> {
  const checked = slotMembership(context, slot, value);
  if (checked.tag === "Failed") return checked;
  return { tag: "Ok", value: ValidatedSlot.admit(validatedSlotToken, { profile: context.graph.profile.reference, source_refs: context.sources, contract: slot, value, proof: checked.value }) };
}
function decisionOf(context: ValueContext, ref: TypeRef, result: Validation<unknown>): ValueDecision {
  if (result.tag === "Ok") return { tag: "Accepted" };
  if (result.failure.tag === "Value") return { tag: "Rejected", failure: result.failure.failure };
  if (result.failure.tag === "Unresolved") return { tag: "Unresolved", obligations: result.failure.obligations };
  return { tag: "Unresolved", obligations: [obligationAt(context.graph, ref, [], { tag: "CertificateMismatch", value: result.failure.condition })] };
}
export function acceptsValue(context: ValueContext, ref: TypeRef, value: ExactJson): ValueDecision { return decisionOf(context, ref, valueMembership(context, ref, value, null)); }
export function acceptsSlot(context: ValueContext, slot: SlotContract, value: ExactSlot): ValueDecision { return decisionOf(context, slot.type_ref, slotMembership(context, slot, value)); }

export function raiseValidation(failure: ValidationFailure, reference: TypeRef): never {
  if (failure.tag === "Value") throw new SemanticValueError(failure.failure);
  if (failure.tag === "Unresolved") throw new SemanticUnresolvedError(reference, failure.obligations);
  throw new SemanticEvidenceError(failure.condition);
}
export function validated<T>(result: Validation<T>, reference: TypeRef): T { return result.tag === "Ok" ? result.value : raiseValidation(result.failure, reference); }


export type PreparedIntegerDomain = { readonly binding: IntegerDomainBinding; readonly bounds: readonly [bigint, bigint] | null };
export type PreparedFormat = { readonly rule: FormatRule; readonly program: FormatSpanProgram | null };
export type PreparedFormatUse = { readonly tag: "Named"; readonly value: string } | { readonly tag: "Inline"; readonly format: PreparedFormat };
export type PreparedStringSpec = { readonly spec: StringSpec; readonly enumValues: ReadonlySet<string> | null; readonly inline: PreparedFormat | null };
export type PreparedIntegerSpec = { readonly spec: IntegerSpec; readonly limits: IntegerLimits | null };
export type PreparedLeaf = { readonly tag: "String"; readonly value: PreparedStringSpec } | { readonly tag: "Integer"; readonly value: PreparedIntegerSpec };
export type PreparedSealedField = { readonly field: SealedField; readonly leaf: PreparedLeaf };
export type PreparedSealedForm = { readonly form: SealedForm; readonly fields: readonly PreparedSealedField[] };
export interface ProfileTables {
  readonly integerBindings: ReadonlyMap<string, PreparedIntegerDomain>;
  readonly formats: ReadonlyMap<string, PreparedFormat>;
  readonly graphemes: PreparedGraphemes | null;
  readonly sealed: ReadonlyMap<string, PreparedSealedForm>;
}
export type PreparedProfile = VersionedSemanticProfile & { readonly tables: ProfileTables };
export type PreparedProduct = { readonly tag: "Product"; readonly spec: ProductSpec; readonly fieldTargets: readonly number[]; readonly extraTarget: number; readonly known: ReadonlySet<string>; readonly keyFormat: PreparedFormatUse | null };
export type PreparedShape =
  | PreparedProduct
  | { readonly tag: "Array"; readonly spec: ArraySpec; readonly item: number }
  | { readonly tag: "Alias"; readonly source: TypeRef; readonly target: number }
  | { readonly tag: "TaggedUnion"; readonly spec: UnionSpec; readonly branches: readonly number[] }
  | { readonly tag: "String"; readonly spec: PreparedStringSpec }
  | { readonly tag: "Integer"; readonly spec: PreparedIntegerSpec }
  | { readonly tag: "Sealed"; readonly refinements: readonly PreparedLeaf[] }
  | { readonly tag: "Other" };
export interface PreparedNode {
  readonly node: TypeNode;
  readonly identity: string;
  readonly reasons: readonly SemanticReason[] | null;
  readonly childRefs: readonly TypeRef[];
  readonly children: readonly number[];
  readonly shape: PreparedShape;
}
function prepareLeaf(leaf: SealedLeaf): PreparedLeaf {
  return leaf.tag === "Integer" ? { tag: "Integer", value: prepareIntegerSpec(leaf.value) } : { tag: "String", value: prepareStringSpec(leaf.value) };
}
function prepareProfile(profile: VersionedSemanticProfile): PreparedProfile {
  const integerBindings = new Map<string, PreparedIntegerDomain>(), formats = new Map<string, PreparedFormat>(), sealed = new Map<string, PreparedSealedForm>();
  for (const binding of profile.integer_domains) {
    if (integerBindings.has(binding.name)) continue;
    const range = binding.range;
    integerBindings.set(binding.name, { binding, bounds: range.tag === "Inclusive" ? attempt(() => [BigInt(range.fields.minimum), BigInt(range.fields.maximum)] as const) : null });
  }
  for (const binding of profile.format_bindings) if (!formats.has(binding.name)) formats.set(binding.name, prepareFormat(binding.rule));
  for (const form of profile.tag?.sealed ?? []) if (!sealed.has(form.tag)) sealed.set(form.tag, { form, fields: form.fields.map(field => ({ field, leaf: prepareLeaf(field.leaf) })) });
  return { ...profile, tables: { integerBindings, formats, graphemes: prepareGraphemes(profile.grapheme_rules), sealed } };
}
function prepareShape(shape: TypeShape, children: readonly number[]): PreparedShape {
  switch (shape.tag) {
    case "Product": {
      const extras = shape.value.extras, key = extras.tag === "Allow" ? extras.fields.key_format : null;
      return {
        tag: "Product", spec: shape.value, fieldTargets: children.slice(0, shape.value.fields.length), extraTarget: children[shape.value.fields.length] ?? -1,
        known: new Set(shape.value.fields.map(field => field.wire_name)),
        keyFormat: key === null ? null : key.tag === "Named" ? { tag: "Named", value: key.value } : { tag: "Inline", format: prepareFormat(key.value) },
      };
    }
    case "Array": return { tag: "Array", spec: shape.value, item: children[0]! };
    case "Alias": return { tag: "Alias", source: shape.fields.target, target: children[0]! };
    case "TaggedUnion": return { tag: "TaggedUnion", spec: shape.value, branches: children };
    case "String": return { tag: "String", spec: prepareStringSpec(shape.value) };
    case "Integer": return { tag: "Integer", spec: prepareIntegerSpec(shape.value) };
    case "Sealed": return { tag: "Sealed", refinements: shape.fields.refinements.map(refinement => prepareLeaf(refinement.leaf)) };
    default: return { tag: "Other" };
  }
}
function prepareNode(profile: VersionedSemanticProfile, node: TypeNode, identity: string, target: (ref: TypeRef) => number): PreparedNode {
  const childRefs = typeChildren(node.shape), children = childRefs.map(target);
  return { node, identity, reasons: attempt(() => nodeMeaningObligations(profile, node)), childRefs, children, shape: prepareShape(node.shape, children) };
}
function meaningBlockedTable(nodes: readonly PreparedNode[], index: ReadonlyMap<string, number>, total: number): readonly boolean[] {
  const blocked = new Array<boolean>(total).fill(false), queue: number[] = [], reverse: number[][] = Array.from({ length: total }, () => []);
  nodes.forEach((entry, position) => {
    if (index.get(entry.identity) !== position) return;
    for (const child of entry.children) reverse[child]!.push(position);
    if (entry.reasons === null || entry.reasons.length > 0) { blocked[position] = true; queue.push(position); }
  });
  for (let id = nodes.length; id < total; id += 1) { blocked[id] = true; queue.push(id); }
  while (queue.length > 0) {
    for (const parent of reverse[queue.pop()!]!) if (!blocked[parent]) { blocked[parent] = true; queue.push(parent); }
  }
  return blocked;
}

export class ValueContext {
  readonly profile: VersionedSemanticProfile;
  readonly sources: readonly SourceRef[];
  readonly prepared: PreparedProfile;
  readonly typeIndexes: ReadonlyMap<string, number>;
  readonly nodes: readonly PreparedNode[];
  readonly graphEdges: number;
  readonly meaningBlocked: readonly boolean[];
  constructor(readonly graph: ValueGraph, sources: readonly SourceRef[] = []) {
    this.profile = graph.profile;
    this.sources = sources;
    this.prepared = prepareProfile(graph.profile);
    const identities = graph.nodes.map(node => typeIdentity(node.reference)), index = new Map<string, number>();
    identities.forEach((identity, position) => { if (!index.has(identity)) index.set(identity, position); });
    let total = graph.nodes.length;
    const target = (ref: TypeRef): number => {
      const identity = typeIdentity(ref);
      let id = index.get(identity);
      if (id === undefined) { id = total; total += 1; index.set(identity, id); }
      return id;
    };
    this.nodes = graph.nodes.map((node, position) => prepareNode(graph.profile, node, identities[position]!, target));
    this.typeIndexes = index;
    this.graphEdges = this.nodes.reduce((sum, entry) => sum + entry.children.length, 0);
    this.meaningBlocked = meaningBlockedTable(this.nodes, index, total);
  }
  node(ref: TypeRef): TypeNode { const node = findType(this, ref); requireEvidence(node, "resolved qualified type"); return node; }
  resolve(ref: TypeRef): TypeShape | undefined { return resolvedShape(this, ref); }
  format(name: string): FormatRule | undefined { return this.prepared.tables.formats.get(name)?.rule; }
  meaningObligations(refs: readonly TypeRef[]): readonly SemanticObligation[] {
    const count = this.nodes.length, extra = new Map<string, number>();
    const idOf = (ref: TypeRef): number => {
      const identity = typeIdentity(ref), known = this.typeIndexes.get(identity);
      if (known !== undefined) return known;
      let id = extra.get(identity);
      if (id === undefined) { id = this.meaningBlocked.length + extra.size; extra.set(identity, id); }
      return id;
    };
    const stack = refs.map(ref => [ref, idOf(ref)] as const).reverse(), visited = new Set<number>(), reached: (readonly [TypeRef, number])[] = [];
    for (let budget = refs.length + count + this.graphEdges + 1; budget > 0 && stack.length; budget--) {
      const [ref, id] = stack.pop()!;
      if (visited.has(id)) continue;
      visited.add(id); reached.push([ref, id]);
      if (id < count) {
        const entry = this.nodes[id]!;
        for (let position = entry.childRefs.length - 1; position >= 0; position--) stack.push([entry.childRefs[position]!, entry.children[position]!]);
      }
    }
    return reached.reverse().flatMap(([ref, id]) => {
      const reasons = id < count ? this.nodes[id]!.reasons ?? nodeMeaningObligations(this.profile, this.nodes[id]!.node) : unresolvedReasons;
      return reasons.map(reason => obligationAt(this.graph, ref, [], reason));
    });
  }

  materializeDefaults(ref: TypeRef, value: ExactJson): DefaultedValue {
    const node = (reference: TypeRef, id: number, path: readonly PathStep[], fuel: number): PreparedNode => {
      const found = id < 0 || id >= this.nodes.length ? undefined : this.nodes[id];
      if (fuel === 0 || found === undefined) throw new SemanticUnresolvedError(reference, [{
        type_ref: reference, origin: { source: reference.source, pointer: reference.pointer },
        value_path: path, profile: this.profile.reference, reason: { tag: fuel === 0 ? "MembershipBound" : "UnresolvedType" },
      }]);
      return found;
    };
    const declared = (reference: TypeRef, id: number): { ref: TypeRef; id: number; value: ExactJson } | undefined => {
      for (let fuel = this.graph.nodes.length + 1; fuel > 0; fuel--) {
        const found = id < 0 || id >= this.nodes.length ? undefined : this.nodes[id];
        if (!found) return undefined;
        if (found.shape.tag === "Alias") { reference = found.shape.source; id = found.shape.target; }
        else { const value = typeDefault(found.node.shape); return value === undefined ? undefined : { ref: reference, id, value }; }
      }
      return undefined;
    };
    type Child = { reference: TypeRef; id: number; value: ExactJson; path: readonly PathStep[]; fuel: number };
    type Frame = { hasNext: () => boolean; next: () => Child | null; accept: (value: ExactJson) => void; finish: () => ExactJson };
    const applications: DefaultApplication[] = [], applicationIds: number[] = [], validDefaults = new Set<number>();
    const arrayFrame = (items: readonly ExactJson[], itemType: TypeRef, itemId: number, path: readonly PathStep[], fuel: number): Frame => {
      const values: ExactJson[] = [];
      let position = 0;
      return {
        hasNext: () => position < items.length,
        next: () => {
          const index = position++;
          return { reference: itemType, id: itemId, value: items[index]!, path: [...path, { tag: "Index", value: String(index) }], fuel };
        },
        accept: value => { values.push(value); },
        finish: () => ({ tag: "Array", items: values }),
      };
    };
    const productFrame = (fields: readonly FieldSpec[], targets: readonly number[], members: readonly { readonly key: string; readonly value: ExactJson }[], path: readonly PathStep[], fuel: number): Frame => {
      const retained: { key: string; value: ExactJson }[] = [], byWire = new Map<string, number>(), present = memberIndex(members);
      fields.forEach((field, index) => { if (!byWire.has(field.wire_name)) byWire.set(field.wire_name, index); });
      let position = 0, pendingKey = "";
      return {
        hasNext: () => position < members.length,
        next: () => {
          const item = members[position++]!;
          const index = byWire.get(item.key), field = index === undefined ? undefined : fields[index]!;
          if (field === undefined || index === undefined || item.value.tag === "Null") {
            retained.push(item);
            return null;
          }
          pendingKey = item.key;
          return { reference: field.slot.type_ref, id: targets[index]!, value: item.value, path: [...path, { tag: "Field", value: item.key }], fuel };
        },
        accept: value => { retained.push({ key: pendingKey, value }); },
        finish: () => {
          for (const [index, field] of fields.entries()) {
            if (present.get(field.wire_name) !== undefined) continue;
            const found = declared(field.slot.type_ref, targets[index]!);
            if (!found) continue;
            if (!validDefaults.has(found.id)) { validated(meaningFailure(this, found.ref, found.id) ?? membership(this, found.ref, found.id, found.value, null), found.ref); validDefaults.add(found.id); }
            applicationIds.push(found.id);
            applications.push({ value_path: [...path, { tag: "Field", value: field.wire_name }], type_ref: found.ref, origin: defaultOrigin(found.ref), value: found.value });
            retained.push({ key: field.wire_name, value: found.value });
          }
          return { tag: "Object", members: retained };
        },
      };
    };
    const open = (reference: TypeRef, id: number, value: ExactJson, path: readonly PathStep[], fuel: number, frames: Frame[]): ExactJson | null => {
      let current = reference, currentId = id, remaining = fuel;
      for (;;) {
        const entry = node(current, currentId, path, remaining), shape = entry.node.shape, prepared = entry.shape;
        if (prepared.tag === "Alias") {
          current = prepared.source;
          currentId = prepared.target;
          remaining -= 1;
          continue;
        }
        if (shape.tag === "TaggedUnion" && prepared.tag === "TaggedUnion" && value.tag === "Object") {
          const tag = memberValue(this.profile.tag?.key ?? "", value.members);
          const position = tag?.tag === "String" ? shape.value.branches.findIndex(candidate => candidate.wire_tag === tag.value) : -1;
          if (position >= 0) {
            current = shape.value.branches[position]!.target;
            currentId = prepared.branches[position]!;
            remaining -= 1;
            continue;
          }
        }
        if (shape.tag === "Array" && prepared.tag === "Array" && value.tag === "Array") {
          frames.push(arrayFrame(value.items, shape.value.item.type_ref, prepared.item, path, remaining - 1));
          return null;
        }
        if (shape.tag === "Product" && prepared.tag === "Product" && value.tag === "Object") {
          frames.push(productFrame(shape.value.fields, prepared.fieldTargets, value.members, path, remaining - 1));
          return null;
        }
        return value;
      }
    };
    const frames: Frame[] = [];
    const rootId = this.typeIndexes.get(typeIdentity(ref)) ?? -1;
    let outcome = open(ref, rootId, value, [], (jsonSize(value) + 1) * (this.graph.nodes.length + 1), frames);
    while (frames.length > 0) {
      const frame = frames[frames.length - 1]!;
      if (outcome !== null) {
        frame.accept(outcome);
        outcome = null;
      }
      if (frame.hasNext()) {
        const child = frame.next();
        if (child !== null) outcome = open(child.reference, child.id, child.value, child.path, child.fuel, frames);
        continue;
      }
      frames.pop();
      outcome = frame.finish();
    }
    return DefaultedValue.checked(this, ref, value, outcome!, applications, rootId, applicationIds);
  }
  decodeWithDefaults(ref: TypeRef, text: string): DefaultedValue { return this.materializeDefaults(ref, boundedParseExact(text)); }
}
export function meaningObligations(context: ValueContext, refs: readonly TypeRef[]): readonly SemanticObligation[] { return context.meaningObligations(refs); }
export function formatUseRule(context: ValueContext, use: FormatUse | null): FormatRule | undefined {
  return use === null ? undefined : use.tag === "Inline" ? use.value : context.format(use.value);
}
export function semanticBasisOf(context: ValueContext): SemanticBasis {
  return { profile: context.profile, sources: context.sources };
}
export function dynamicExact(value: DynamicValue): ExactJson { return toExact(value); }
export function immutableDynamic(value: ExactJson): DynamicValue { return fromExact(value); }
export function bytesExact(value: Uint8Array, profile: VersionedSemanticProfile): ExactJson {
  const policy: BytesPolicy = profile.bytes_policy ?? { reference: profile.reference, padding_optional: false, alphabet: { tag: "Standard" }, strict_pad_bits: true, wrapper: null };
  const wire = base64Encode(value, policy);
  const wrapper = policy.wrapper === null ? undefined : profile.wrappers.find(candidate => candidate.name === policy.wrapper);
  return wrapper === undefined ? { tag: "String", value: wire } : exactObject([{ key: wrapper.key, value: { tag: "String", value: wire } }]);
}
export function bytesValue(value: ExactJson, context: ValueContext): Uint8Array {
  const decoded = decodeBytes(context.prepared, value);
  requireEvidence(decoded, "valid encoded bytes");
  return decoded;
}

export type ValueSlot<T> = { readonly tag: "Absent" } | { readonly tag: "Null" } | { readonly tag: "Present"; readonly value: T };
