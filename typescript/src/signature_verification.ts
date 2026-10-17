// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import * as X from "./semantic_values.js";
import {
  ValueContext, SemanticEvidenceError, SemanticValueError, requireEvidence as check, same, deepFreeze,
  hashUtf8, member, slotOf, projectValue, children, typeIdentity, recognizeFormat,
} from "./semantic_values.js";

function closed(value: unknown, fields: readonly string[], path = "$"): Record<string, unknown> {
  check(value !== null && typeof value === "object" && !Array.isArray(value), "object", path);
  const record = value as Record<string, unknown>, actual = Object.keys(record);
  const unknown = actual.find(key => !fields.includes(key));
  if (unknown !== undefined) throw new SemanticEvidenceError(`UnknownField:${unknown}`, path);
  check(fields.every(key => Object.hasOwn(record, key)), "required fields", path);
  return record;
}

export function validateSemanticWire(type: string, value: unknown): unknown {
  if (type === "string") check(typeof value === "string", "string");
  else if (type === "boolean") check(typeof value === "boolean", "boolean");
  else if (type === "sha256") check(typeof value === "string" && /^[0-9a-f]{64}$/.test(value), "sha256");
  else if (type === "string[]") check(Array.isArray(value) && value.every(item => typeof item === "string"), "string array");
  else if (type === "ExactJson") check(value !== null && typeof value === "object" && typeof (value as { tag?: unknown }).tag === "string", "exact JSON");
  return value;
}

export function wireSha256(_type: string, value: unknown): string { return hashUtf8(JSON.stringify(value)); }

export function formatRuleIncluded(source: X.FormatRule, destination: X.FormatRule): boolean {
  return same(source, destination) || destination.tag === "Text" || destination.tag === "Choice" && destination.value.some(rule => formatRuleIncluded(source, rule));
}

function domain(context: ValueContext, name: string | null): X.IntegerDomainBinding | undefined {
  return context.profile.integer_domains.find(item => item.name === (name ?? context.profile.default_integer_domain));
}

function refEqual(left: X.TypeRef, right: X.TypeRef): boolean {
  return typeIdentity(left) === typeIdentity(right);
}

function lowerContained(source: string | null, destination: string | null, natural = false): boolean {
  if (destination === null) return true;
  if (source === null) return natural && BigInt(destination) === 0n;
  return BigInt(destination) <= BigInt(source);
}

function upperContained(source: string | null, destination: string | null): boolean {
  return destination === null || source !== null && BigInt(source) <= BigInt(destination);
}

function formatUseRule(context: ValueContext, use: X.FormatUse | null): X.FormatRule | undefined {
  return use === null ? undefined : use.tag === "Inline" ? use.value : context.format(use.value);
}

function formatUseIncluded(context: ValueContext, source: X.FormatUse | null, destination: X.FormatUse | null): boolean {
  if (destination === null) return true;
  if (source === null) return false;
  const sourceRule = formatUseRule(context, source), destinationRule = formatUseRule(context, destination);
  return sourceRule !== undefined && destinationRule !== undefined && formatRuleIncluded(sourceRule, destinationRule);
}

function presenceIncluded(source: X.SlotContract, destination: X.SlotContract): boolean {
  return (source.required || !destination.required) && (!source.nullable || destination.nullable);
}

function elementAllowsNull(context: ValueContext, contract: X.ElementContract): boolean {
  if (contract.nullable) return true;
  try { context.validate(contract.type_ref, { tag: "Null" }); return true; }
  catch (error) { if (error instanceof SemanticValueError) return false; throw error; }
}

function lengthBoundsIncluded(source: readonly X.LengthBound[], destination: readonly X.LengthBound[]): boolean {
  return destination.every(target => source.some(candidate =>
    candidate.unit.tag === target.unit.tag
    && lowerContained(candidate.minimum, target.minimum, true)
    && upperContained(candidate.maximum, target.maximum)));
}

function integerFinite(spec: X.IntegerSpec): readonly string[] | null {
  return spec.const_value === null ? spec.enum_values : [spec.const_value];
}

function integerAccepted(context: ValueContext, spec: X.IntegerSpec, value: string): boolean {
  const binding = domain(context, spec.domain);
  if (!binding) return false;
  const integer = BigInt(value);
  if (binding.range.tag === "Inclusive"
      && (integer < BigInt(binding.range.fields.minimum) || integer > BigInt(binding.range.fields.maximum))) return false;
  return (spec.const_value === null || value === spec.const_value)
    && (spec.enum_values === null || spec.enum_values.includes(value))
    && (spec.minimum === null || integer >= BigInt(spec.minimum))
    && (spec.maximum === null || integer <= BigInt(spec.maximum));
}

function integerRuleCheck(context: ValueContext, source: X.IntegerSpec, destination: X.IntegerSpec): boolean {
  const sourceDomain = domain(context, source.domain), destinationDomain = domain(context, destination.domain);
  if (!sourceDomain || !destinationDomain
      || sourceDomain.forms.length !== 1 || sourceDomain.forms[0]?.tag !== "Number"
      || destinationDomain.forms.length !== 1 || destinationDomain.forms[0]?.tag !== "Number"
      || source.domain !== destination.domain) return false;
  const finite = integerFinite(source);
  return finite === null
    ? destination.const_value === null && destination.enum_values === null
      && lowerContained(source.minimum, destination.minimum)
      && upperContained(source.maximum, destination.maximum)
    : finite.every(value => !integerAccepted(context, source, value) || integerAccepted(context, destination, value));
}

function stringRuleCheck(context: ValueContext, source: X.StringSpec, destination: X.StringSpec): boolean {
  const finite = source.const_value === null ? source.enum_values : [source.const_value];
  if (finite !== null) {
    const sourceRef = context.graph.nodes.find(node => node.shape.tag === "String" && node.shape.value === source)?.reference;
    const destinationRef = context.graph.nodes.find(node => node.shape.tag === "String" && node.shape.value === destination)?.reference;
    if (sourceRef && destinationRef) {
      return finite.every(text => {
        const value: X.ExactJson = source.wrapper === null
          ? { tag: "String", value: text }
          : X.wrapEncode(context.profile, source.wrapper, text);
        return !context.accepts({ type_ref: sourceRef, required: true, nullable: false }, { tag: "Present", value })
          || context.accepts({ type_ref: destinationRef, required: true, nullable: false }, { tag: "Present", value });
      });
    }
  }
  return source.wrapper === destination.wrapper
    && destination.const_value === null && destination.enum_values === null
    && source.default_value === destination.default_value
    && formatUseIncluded(context, source.format, destination.format)
    && lengthBoundsIncluded(source.lengths, destination.lengths);
}

function fieldNamed(fields: readonly X.FieldSpec[], name: string): X.FieldSpec | undefined {
  return fields.find(field => field.wire_name === name);
}

function extraAllowsKey(context: ValueContext, format: X.FormatUse | null, key: string): boolean {
  const rule = formatUseRule(context, format);
  return rule === undefined || recognizeFormat(rule, key);
}

function effectiveTagSpec(context: ValueContext): X.StringSpec | null {
  const format = context.profile.tag?.format;
  if (format === undefined) return null;
  return {
    format: format === null ? null : { tag: "Named", value: format },
    lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null,
  };
}

function explicitFieldIncludedInTag(context: ValueContext, field: X.FieldSpec): boolean {
  const tagSpec = effectiveTagSpec(context);
  if (tagSpec === null) return false;
  const shape = context.resolve(field.slot.type_ref);
  return shape.tag === "String" && stringRuleCheck(context, shape.value, tagSpec);
}

function tagIncludedInExplicitField(context: ValueContext, field: X.FieldSpec): boolean {
  const tagSpec = effectiveTagSpec(context);
  if (tagSpec === null || field.slot.required) return false;
  const shape = context.resolve(field.slot.type_ref);
  return shape.tag === "String" && stringRuleCheck(context, tagSpec, shape.value);
}

function productChildPairs(context: ValueContext, source: X.ProductSpec, destination: X.ProductSpec): readonly (readonly [X.TypeRef, X.TypeRef])[] {
  const destinationPairs = destination.fields.flatMap(field => {
    const sourceField = fieldNamed(source.fields, field.wire_name);
    if (sourceField) return [[sourceField.slot.type_ref, field.slot.type_ref] as const];
    if (field.slot.required || context.profile.tag?.key === field.wire_name || source.extras.tag === "Reject") return [];
    return [[source.extras.fields.value.type_ref, field.slot.type_ref] as const];
  });
  const sourcePairs = source.fields.flatMap(field => {
    if (fieldNamed(destination.fields, field.wire_name) || field.wire_name === context.profile.tag?.key
        || destination.extras.tag === "Reject") return [];
    return [[field.slot.type_ref, destination.extras.fields.value.type_ref] as const];
  });
  const extras = source.extras.tag === "Allow" && destination.extras.tag === "Allow"
    ? [[source.extras.fields.value.type_ref, destination.extras.fields.value.type_ref] as const] : [];
  return [...destinationPairs, ...sourcePairs, ...extras];
}

function productRuleShapeCheck(context: ValueContext, source: X.ProductSpec, destination: X.ProductSpec): boolean {
  const tagKey = context.profile.tag?.key;
  return destination.fields.every(destinationField => {
    const sourceField = fieldNamed(source.fields, destinationField.wire_name);
    if (sourceField) return presenceIncluded(sourceField.slot, destinationField.slot);
    if (destinationField.wire_name === tagKey) return tagIncludedInExplicitField(context, destinationField);
    return !destinationField.slot.required
      && source.extras.tag === "Allow"
      && (!elementAllowsNull(context, source.extras.fields.value) || destinationField.slot.nullable);
  }) && source.fields.every(sourceField => {
    if (fieldNamed(destination.fields, sourceField.wire_name)) return true;
    if (sourceField.wire_name === tagKey) return explicitFieldIncludedInTag(context, sourceField);
    return destination.extras.tag === "Allow"
      && extraAllowsKey(context, destination.extras.fields.key_format, sourceField.wire_name)
      && (!sourceField.slot.nullable || elementAllowsNull(context, destination.extras.fields.value));
  }) && (source.extras.tag === "Reject"
    || destination.extras.tag === "Allow"
      && formatUseIncluded(context, source.extras.fields.key_format, destination.extras.fields.key_format)
      && (!elementAllowsNull(context, source.extras.fields.value) || elementAllowsNull(context, destination.extras.fields.value)));
}

export function selectorDisjoint(left: X.UnionBranch, right: X.UnionBranch): boolean {
  if (left.selector.tag === "InternalTag" && right.selector.tag === "InternalTag") return left.wire_tag !== right.wire_tag;
  if (left.selector.tag === "Kind" && right.selector.tag === "Kind") return left.selector.value.tag !== right.selector.value.tag;
  if (left.selector.tag === "InternalTag" && right.selector.tag === "Kind") return right.selector.value.tag !== "Object";
  if (left.selector.tag === "Kind" && right.selector.tag === "InternalTag") return left.selector.value.tag !== "Object";
  return false;
}

function selectorsEqual(source: X.UnionBranch, destination: X.UnionBranch): boolean {
  if (source.selector.tag !== destination.selector.tag) return false;
  if (source.selector.tag === "InternalTag" && destination.selector.tag === "InternalTag") return source.wire_tag === destination.wire_tag;
  return same(source.selector, destination.selector);
}

function unionBranchPairs(sources: readonly X.UnionBranch[], destinations: readonly X.UnionBranch[]): readonly (readonly [X.TypeRef, X.TypeRef])[] | null {
  if (sources.length === 0) return [];
  if (destinations.length === 0) return null;
  const [source, ...sourceRest] = sources, [destination, ...destinationRest] = destinations;
  if (selectorsEqual(source!, destination!)) {
    const rest = unionBranchPairs(sourceRest, destinationRest);
    return rest === null ? null : [[source!.target, destination!.target], ...rest];
  }
  return sources.every(branch => selectorDisjoint(destination!, branch))
    ? unionBranchPairs(sources, destinationRest) : null;
}

function unionCoverage(source: X.UnionSpec, destination: X.UnionSpec): readonly (readonly [X.TypeRef, X.TypeRef])[] | null {
  return source.branches.some(branch => branch.selector.tag === "Otherwise")
    ? same(source, destination) ? source.branches.map(branch => [branch.target, branch.target] as const) : null
    : unionBranchPairs(source.branches, destination.branches);
}

type PairDescription = {
  readonly source: X.TypeRef;
  readonly destination: X.TypeRef;
  readonly sourceShape: X.TypeShape;
  readonly destinationShape: X.TypeShape;
  readonly rule: string;
  readonly children: readonly (readonly [X.TypeRef, X.TypeRef])[];
};

function isEmptyType(context: ValueContext, reference: X.TypeRef, candidates: ReadonlySet<string>): boolean {
  const shape = context.node(reference).shape;
  if (shape.tag === "Never") return true;
  if (shape.tag === "Alias") return candidates.has(typeIdentity(shape.fields.target));
  if (shape.tag === "Product") return shape.value.fields.some(field =>
    field.slot.required && !field.slot.nullable && candidates.has(typeIdentity(field.slot.type_ref)));
  if (shape.tag === "Array") return BigInt(shape.value.min_length ?? "0") > 0n
    && !elementAllowsNull(context, shape.value.item)
    && candidates.has(typeIdentity(shape.value.item.type_ref));
  if (shape.tag === "TaggedUnion") return shape.value.branches.every(branch => candidates.has(typeIdentity(branch.target)));
  if (shape.tag === "Bytes" && shape.value.minimum !== null && shape.value.maximum !== null) {
    return BigInt(shape.value.maximum) < BigInt(shape.value.minimum);
  }
  return false;
}

function emptyTypes(context: ValueContext): readonly X.TypeRef[] {
  let retained = context.graph.nodes.map(node => node.reference);
  for (let fuel = context.graph.nodes.length + 1; fuel > 0; fuel -= 1) {
    const candidates = new Set(retained.map(typeIdentity));
    const next = retained.filter(reference => isEmptyType(context, reference, candidates));
    if (next.length === retained.length) return next;
    retained = next;
  }
  return retained;
}

function integerIncludedUnknownAny(context: ValueContext, source: X.IntegerSpec): boolean {
  const sourceDomain = domain(context, source.domain), defaultDomain = domain(context, null);
  if (!sourceDomain || !defaultDomain
      || !sourceDomain.forms.every(form => defaultDomain.forms.some(candidate => same(candidate, form)))) return false;
  const effective = (binding: X.IntegerDomainBinding, spec: X.IntegerSpec): readonly [bigint | null, bigint | null] => {
    const domainMinimum = binding.range.tag === "Inclusive" ? BigInt(binding.range.fields.minimum) : null;
    const domainMaximum = binding.range.tag === "Inclusive" ? BigInt(binding.range.fields.maximum) : null;
    const minimum = spec.minimum === null ? domainMinimum
      : domainMinimum === null ? BigInt(spec.minimum) : BigInt(spec.minimum) > domainMinimum ? BigInt(spec.minimum) : domainMinimum;
    const maximum = spec.maximum === null ? domainMaximum
      : domainMaximum === null ? BigInt(spec.maximum) : BigInt(spec.maximum) < domainMaximum ? BigInt(spec.maximum) : domainMaximum;
    return [minimum, maximum];
  };
  const [sourceMinimum, sourceMaximum] = effective(sourceDomain, source);
  const [defaultMinimum, defaultMaximum] = effective(defaultDomain, {
    domain: null, minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null,
  });
  return (defaultMinimum === null || sourceMinimum !== null && defaultMinimum <= sourceMinimum)
    && (defaultMaximum === null || sourceMaximum !== null && sourceMaximum <= defaultMaximum);
}

function leafIncludedUnknownAny(context: ValueContext, source: X.TypeShape): boolean {
  return source.tag === "Boolean" || source.tag === "Unit"
    || source.tag === "String" && source.value.wrapper === null
    || source.tag === "Sealed" && source.fields.refinements.length === 0
    || source.tag === "Integer" && integerIncludedUnknownAny(context, source.value);
}

function sealedRuleCheck(source: Extract<X.TypeShape, { tag: "Sealed" }>, destination: Extract<X.TypeShape, { tag: "Sealed" }>): boolean {
  return source.fields.tag === destination.fields.tag
    && destination.fields.refinements.every(target =>
      source.fields.refinements.some(candidate => candidate.key === target.key && same(candidate.leaf, target.leaf)));
}

function describePair(context: ValueContext, empties: ReadonlySet<string>, source: X.TypeRef, destination: X.TypeRef): PairDescription | null {
  const sourceShape = context.node(source).shape, destinationShape = context.node(destination).shape;
  const row = (rule: string, children: readonly (readonly [X.TypeRef, X.TypeRef])[] = []): PairDescription =>
    ({ source, destination, sourceShape, destinationShape, rule, children });
  if (empties.has(typeIdentity(source))) return row("EmptySource");
  if (same(sourceShape, destinationShape)) return row("SameDefinedType");
  if (sourceShape.tag === "Alias") return row("UnfoldSource", [[sourceShape.fields.target, destination]]);
  if (destinationShape.tag === "Alias") return row("UnfoldDestination", [[source, destinationShape.fields.target]]);
  if (destinationShape.tag === "Unknown" && destinationShape.value.tag === "Any"
      && leafIncludedUnknownAny(context, sourceShape)) return row("UnknownAny");
  if (sourceShape.tag === "Sealed" && destinationShape.tag === "Sealed") {
    return sealedRuleCheck(sourceShape, destinationShape) ? row("Sealed") : null;
  }
  if (sourceShape.tag === "Boolean" && destinationShape.tag === "Boolean") {
    return destinationShape.value.const_value === null || sourceShape.value.const_value === destinationShape.value.const_value
      ? row("Boolean") : null;
  }
  if (sourceShape.tag === "Integer" && destinationShape.tag === "Integer") {
    return integerRuleCheck(context, sourceShape.value, destinationShape.value) ? row("IntegerIntersection") : null;
  }
  if (sourceShape.tag === "String" && destinationShape.tag === "String") {
    return stringRuleCheck(context, sourceShape.value, destinationShape.value) ? row("StringConditions") : null;
  }
  if (sourceShape.tag === "Array" && destinationShape.tag === "Array") {
    return lowerContained(sourceShape.value.min_length, destinationShape.value.min_length, true)
      && upperContained(sourceShape.value.max_length, destinationShape.value.max_length)
      && (!elementAllowsNull(context, sourceShape.value.item) || elementAllowsNull(context, destinationShape.value.item))
      ? row("Array", [[sourceShape.value.item.type_ref, destinationShape.value.item.type_ref]]) : null;
  }
  if (sourceShape.tag === "Product" && destinationShape.tag === "Product") {
    return productRuleShapeCheck(context, sourceShape.value, destinationShape.value)
      ? row("Product", productChildPairs(context, sourceShape.value, destinationShape.value)) : null;
  }
  if (sourceShape.tag === "TaggedUnion" && destinationShape.tag === "TaggedUnion") {
    const pairs = unionCoverage(sourceShape.value, destinationShape.value);
    return pairs === null ? null : row("SourceUnion", pairs);
  }
  return null;
}

function inclusionTable(context: ValueContext, source: X.TypeRef, destination: X.TypeRef, maximum: number): readonly PairDescription[] | null {
  const empty = emptyTypes(context), empties = new Set(empty.map(typeIdentity));
  const pending: (readonly [X.TypeRef, X.TypeRef])[] = [[source, destination]], seen = new Set<string>(), rows: PairDescription[] = [];
  while (pending.length > 0) {
    if (rows.length >= maximum) return null;
    const [left, right] = pending.shift()!, key = `${typeIdentity(left)}\0${typeIdentity(right)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    let row: PairDescription;
    try { const described = describePair(context, empties, left, right); if (described === null) return null; row = described; }
    catch { return null; }
    rows.push(row);
    pending.unshift(...row.children);
  }
  return rows;
}

function inclusionCertificate(context: ValueContext, source: X.SlotContract, destination: X.SlotContract, rows: readonly PairDescription[]): X.InclusionCertificate {
  const indexes = new Map(rows.map((row, index) => [`${typeIdentity(row.source)}\0${typeIdentity(row.destination)}`, String(index)]));
  return {
    basis: { profile: context.profile, sources: context.sources }, source, destination, root: "0",
    empty_types: emptyTypes(context),
    pairs: rows.map(row => ({
      pair: { source: { type_ref: row.source, required: true, nullable: false }, destination: { type_ref: row.destination, required: true, nullable: false }, source_tag: null },
      source_shape: row.sourceShape, destination_shape: row.destinationShape, rule: { tag: row.rule },
      children: row.children.map(([left, right]) => indexes.get(`${typeIdentity(left)}\0${typeIdentity(right)}`)!).filter(index => index !== undefined),
    })),
  };
}

export type TypeObligation = {
  readonly source: X.TypeRef;
  readonly destination: X.TypeRef;
  readonly reason: "Presence" | "ConstraintImplication" | "ObligationBoundExhausted";
};
export type AssignabilityResult =
  | { readonly tag: "Compatible"; readonly certificate: X.InclusionCertificate }
  | { readonly tag: "Incompatible"; readonly value: X.ExactSlot; readonly failure: X.ValueFailure }
  | { readonly tag: "Unknown"; readonly obligations: readonly TypeObligation[] };

function rejected(context: ValueContext, destination: X.SlotContract, value: X.ExactSlot): X.ValueFailure | null {
  try { context.validateSlot(destination, value); return null; }
  catch (error) { if (error instanceof SemanticValueError) return error.failure; throw error; }
}

export function checkAssignable(context: ValueContext, source: X.SlotContract, destination: X.SlotContract, bound = "10000"): AssignabilityResult {
  const maximum = Number(BigInt(bound));
  if (presenceIncluded(source, destination)) {
    const rows = inclusionTable(context, source.type_ref, destination.type_ref, maximum);
    if (rows !== null) return { tag: "Compatible", certificate: inclusionCertificate(context, source, destination, rows) };
  }
  const candidates: X.ExactSlot[] = [
    ...(!source.required ? [{ tag: "Absent" } as const] : []),
    ...(source.nullable ? [{ tag: "Null" } as const] : []),
    ...inclusionSamples(context, source.type_ref, destination.type_ref, {
      max_type_obligations: bound, max_sample_length: "32",
    }).values.map(value => ({ tag: "Present", value } as const)),
  ];
  for (const value of candidates) {
    if (!context.accepts(source, value)) continue;
    const failure = rejected(context, destination, value);
    if (failure !== null) return { tag: "Incompatible", value, failure };
  }
  return {
    tag: "Unknown",
    obligations: [{
      source: source.type_ref, destination: destination.type_ref,
      reason: maximum <= 0 ? "ObligationBoundExhausted" : !presenceIncluded(source, destination) ? "Presence" : "ConstraintImplication",
    }],
  };
}

function formatRuleDepth(rule: X.FormatRule): bigint {
  switch (rule.tag) {
    case "Sequence": case "Choice": return 1n + rule.value.reduce((maximum, child) => maximum > formatRuleDepth(child) ? maximum : formatRuleDepth(child), 0n);
    case "Optional": case "Not": return 1n + formatRuleDepth(rule.value);
    case "Labels": case "Bounded": return 1n + formatRuleDepth(rule.fields.rule);
    default: return 1n;
  }
}

function dfaShortestWord(spec: X.DfaSpec): string | null {
  let frontier: readonly (readonly [string, string])[] = [[spec.initial_state, ""]], visited = new Set([spec.initial_state]);
  for (let fuel = Number(BigInt(spec.state_count)) + 1; fuel > 0; fuel -= 1) {
    const accepted = frontier.find(([state]) => spec.accepting_states.includes(state));
    if (accepted) return accepted[1];
    const fresh: (readonly [string, string])[] = [];
    for (const [state, path] of frontier) for (const transition of spec.transitions.filter(edge => edge.from_state === state)) {
      if (!visited.has(transition.to_state) && !fresh.some(([candidate]) => candidate === transition.to_state)) {
        fresh.push([transition.to_state, path + String.fromCodePoint(Number(transition.first))]);
      }
    }
    fresh.forEach(([state]) => visited.add(state)); frontier = fresh;
  }
  return null;
}

function identifierSamples(rule: Extract<X.FormatRule, { tag: "Identifier" }>): readonly string[] {
  const spec = rule.fields;
  const lengths = spec.exact_length === null
    ? Array.from({ length: spec.forbidden.length + 1 }, (_, extra) => Math.max(Number(BigInt(spec.min_length)), 1) + extra)
    : [Number(BigInt(spec.exact_length))];
  for (const length of lengths) for (const first of spec.first_alphabet) for (const rest of spec.rest_alphabet) {
    const candidate = first + rest.repeat(Math.max(length - 1, 0));
    if (recognizeFormat(rule, candidate)) return [candidate];
  }
  return [];
}

function sequenceSamples(limit: number, parts: readonly (readonly string[])[]): readonly string[] {
  if (parts.some(part => part.length === 0)) return [];
  const heads = parts.map(part => part[0]!);
  const varied = parts.flatMap((part, index) => part.slice(1).map(sample => {
    const replaced = [...heads];
    replaced[index] = sample;
    return replaced.join("");
  }));
  return [heads.join(""), ...varied].slice(0, limit);
}

export function formatRuleSamplesFuel(limit: bigint, fuel: bigint, rule: X.FormatRule): readonly string[] {
  if (fuel <= 0n || limit <= 0n) return [];
  const inner = (child: X.FormatRule) => formatRuleSamplesFuel(limit, fuel - 1n, child);
  let candidates: readonly string[];
  switch (rule.tag) {
    case "Literal": candidates = [rule.value]; break;
    case "Sequence": candidates = sequenceSamples(Number(limit), rule.value.map(inner)); break;
    case "Optional": candidates = ["", ...inner(rule.value)]; break;
    case "Choice": candidates = rule.value.flatMap(inner); break;
    case "Labels": candidates = inner(rule.fields.rule).map(sample => Array(Math.max(Number(BigInt(rule.fields.min_count)), 1)).fill(sample).join(rule.fields.separator)); break;
    case "Bounded": candidates = inner(rule.fields.rule); break;
    case "AsciiDfa": candidates = [dfaShortestWord(rule.value)].filter((value): value is string => value !== null); break;
    case "Identifier": candidates = identifierSamples(rule); break;
    case "Timestamp": {
      const year = rule.value.minimum_year.padStart(4, "0");
      candidates = [`${year}-01-01T00:00:00Z`]; break;
    }
    case "AbsoluteUri": candidates = ["a:", "a:b"].filter(value => recognizeFormat(rule, value)); break;
    case "LanguageTag": candidates = ["aa"]; break;
    case "Text": candidates = ["", "a"]; break;
    case "Not": {
      const excluded = inner(rule.value);
      candidates = ["", "a", "aa", ...excluded, ...excluded.map(value => `${value}x`)]; break;
    }
  }
  return candidates.filter(value => recognizeFormat(rule, value)).slice(0, Number(limit));
}

export function formatSamples(rule: X.FormatRule, limit: bigint): readonly string[] {
  return formatRuleSamplesFuel(limit, formatRuleDepth(rule), rule);
}

function formatUseSamples(context: ValueContext, use: X.FormatUse | null, limit: bigint): readonly string[] {
  if (use === null) return ["x"];
  const rule = formatUseRule(context, use);
  return rule === undefined ? [] : formatRuleSamplesFuel(limit, formatRuleDepth(rule), rule);
}

function integerSamples(form: X.IntegerForm, value: string): X.ExactJson {
  return form.tag === "Number" ? { tag: "Integer", value }
    : form.tag === "IntegralDecimal" ? { tag: "Decimal", text: value }
      : { tag: "String", value };
}

function sealedLeafSample(context: ValueContext, leaf: X.SealedLeaf): X.ExactJson | null {
  if (leaf.tag === "Integer") {
    const value = leaf.value.const_value ?? leaf.value.enum_values?.[0] ?? leaf.value.minimum ?? leaf.value.maximum;
    return value === null || value === undefined ? null : { tag: "Integer", value };
  }
  const spec = leaf.value;
  const value = spec.const_value ?? spec.enum_values?.[0] ?? spec.examples[0]
    ?? formatUseSamples(context, spec.format, 1n)[0];
  return value === undefined ? null : { tag: "String", value };
}

function sampleValueCandidatesFuel(context: ValueContext, fuel: bigint, seen: ReadonlySet<string>, reference: X.TypeRef): readonly X.ExactJson[] {
  if (fuel <= 0n || seen.has(typeIdentity(reference))) return [];
  const nextSeen = new Set(seen).add(typeIdentity(reference));
  const recurse = (target: X.TypeRef) => sampleValueCandidatesFuel(context, fuel - 1n, nextSeen, target);
  const elementSamples = (contract: X.ElementContract): readonly X.ExactJson[] => [
    ...(contract.nullable ? [{ tag: "Null" } as const] : []),
    ...recurse(contract.type_ref),
  ];
  let candidates: readonly X.ExactJson[] = [];
  let shape: X.TypeShape;
  try { shape = context.node(reference).shape; } catch { return []; }
  switch (shape.tag) {
    case "Never": case "Opaque": case "RawBody": candidates = []; break;
    case "Unit": candidates = [{ tag: "Null" }]; break;
    case "Boolean": candidates = shape.value.const_value === null
      ? [{ tag: "Bool", value: false }, { tag: "Bool", value: true }]
      : [{ tag: "Bool", value: shape.value.const_value }]; break;
    case "Integer": {
      const binding = domain(context, shape.value.domain);
      const domainValues = binding?.range.tag === "Inclusive" ? [binding.range.fields.minimum, binding.range.fields.maximum] : [];
      const values = [shape.value.const_value, ...(shape.value.enum_values ?? []), shape.value.minimum, shape.value.maximum, ...domainValues, "0", "1", "-1"]
        .filter((value): value is string => value !== null);
      candidates = binding?.forms.flatMap(form => values.map(value => integerSamples(form, value))) ?? []; break;
    }
    case "Decimal": candidates = [{ tag: "Decimal", text: "0.0" }, { tag: "Decimal", text: "1.0" }, { tag: "Decimal", text: "-1.0" }]; break;
    case "String": {
      const lengths = shape.value.lengths.flatMap(bound => [bound.minimum, bound.maximum]).filter((value): value is string => value !== null);
      const texts = [shape.value.const_value, ...(shape.value.enum_values ?? []), ...shape.value.examples,
        ...formatUseSamples(context, shape.value.format, fuel), "", "a", ...lengths.map(length => "a".repeat(Number(BigInt(length))))]
        .filter((value): value is string => value !== null);
      candidates = texts.map(text => shape.value.wrapper === null
        ? { tag: "String", value: text } : X.wrapEncode(context.profile, shape.value.wrapper, text)); break;
    }
    case "Bytes": {
      const lengths = [shape.value.minimum, shape.value.maximum, "0", "1"].filter((value): value is string => value !== null);
      candidates = context.profile.bytes_policy === null ? [] : lengths.map(length => X.bytesExact(new Uint8Array(Number(BigInt(length))).fill(255), context.profile)); break;
    }
    case "Alias": candidates = recurse(shape.fields.target); break;
    case "Array": {
      const lengths = [shape.value.min_length, shape.value.max_length, "0", "1"].filter((value): value is string => value !== null);
      candidates = lengths.flatMap<X.ExactJson>(length => BigInt(length) === 0n
        ? [{ tag: "Array", items: [] }]
        : elementSamples(shape.value.item).map(value => ({ tag: "Array", items: Array<X.ExactJson>(Number(BigInt(length))).fill(value) }))); break;
    }
    case "Product": {
      let combinations: readonly (readonly { readonly key: string; readonly value: X.ExactJson }[])[] = [[]];
      for (const field of shape.value.fields) {
        const values: readonly (X.ExactJson | undefined)[] = [
          ...(!field.slot.required ? [undefined] : []),
          ...(field.slot.nullable ? [{ tag: "Null" } as const] : []),
          ...recurse(field.slot.type_ref),
        ];
        combinations = values.flatMap(value => combinations.map(rest =>
          value === undefined ? rest : [{ key: field.wire_name, value }, ...rest])).slice(0, Number(fuel));
      }
      const extrasSpec = shape.value.extras;
      const extras = extrasSpec.tag === "Reject" ? [] : formatUseSamples(context, extrasSpec.fields.key_format, 1n)
        .flatMap(key => elementSamples(extrasSpec.fields.value).slice(0, 1).map(value => ({ tag: "Object", members: [{ key, value }] } as const)));
      candidates = [...combinations.map(members => ({ tag: "Object", members } as const)), ...extras]; break;
    }
    case "TaggedUnion": candidates = shape.value.branches.flatMap(branch => recurse(branch.target).flatMap(value => {
      if (branch.selector.tag === "InternalTag") {
        return value.tag === "Object" && context.profile.tag
          ? [X.withMember(context.profile.tag.key, branch.wire_tag, value)] : [];
      }
      if (branch.selector.tag === "MemberShape") {
        if (value.tag !== "Object") return [];
        let members = [...value.members];
        for (const [key, test] of branch.selector.value) {
          members = members.filter(item => item.key !== key);
          if (test.tag === "Format") {
            const text = context.format(test.value);
            const sample = text ? formatRuleSamplesFuel(1n, formatRuleDepth(text), text)[0] : undefined;
            if (sample !== undefined) members.unshift({ key, value: { tag: "String", value: sample } });
          }
        }
        return [{ tag: "Object", members }];
      }
      return [value];
    })); break;
    case "Unknown": candidates = [{ tag: "Object", members: [] }, { tag: "Null" }, { tag: "Bool", value: false }, { tag: "Integer", value: "0" }, { tag: "String", value: "" }, { tag: "Array", items: [] }]; break;
    case "Sealed": {
      const form = context.profile.tag?.sealed.find(candidate => candidate.tag === shape.fields.tag);
      if (!form || !context.profile.tag) candidates = [];
      else {
        const members: { key: string; value: X.ExactJson }[] = [{ key: context.profile.tag.key, value: { tag: "String", value: form.tag } }];
        let possible = true;
        for (const field of form.fields.filter(field => field.required)) {
          const refinement = shape.fields.refinements.find(candidate => candidate.key === field.key);
          const value = sealedLeafSample(context, refinement?.leaf ?? field.leaf);
          if (value === null) { possible = false; break; }
          members.push({ key: field.key, value });
        }
        candidates = possible ? [{ tag: "Object", members }] : [];
      }
      break;
    }
  }
  return candidates.filter(value => context.accepts({ type_ref: reference, required: true, nullable: false }, { tag: "Present", value }));
}

export type SampleObligation = { readonly tag: "SampleBound" };
export type SampleResult<T> = { readonly values: readonly T[]; readonly obligations: readonly SampleObligation[] };
export type SampleBounds = { readonly max_type_obligations: string; readonly max_sample_length: string };

function sampleWithinBound(maximum: bigint, value: X.ExactJson): boolean {
  return value.tag === "String" ? BigInt(value.value.length) <= maximum
    : value.tag === "Decimal" ? BigInt(value.text.length) <= maximum
      : value.tag === "Array" ? BigInt(value.items.length) <= maximum
        : value.tag === "Object" ? BigInt(value.members.length) <= maximum : true;
}

export function sampleValueFuel(context: ValueContext, bounds: SampleBounds, fuel: bigint, seen: readonly X.TypeRef[], reference: X.TypeRef): SampleResult<X.ExactJson> {
  const candidates = sampleValueCandidatesFuel(context, fuel, new Set(seen.map(typeIdentity)), reference);
  const values = candidates.filter(value => sampleWithinBound(BigInt(bounds.max_sample_length), value));
  return { values, obligations: values.length === candidates.length ? [] : [{ tag: "SampleBound" }] };
}

export function slotSamples(context: ValueContext, bounds: SampleBounds, contract: X.SlotContract): SampleResult<X.ExactSlot> {
  const fuel = BigInt(bounds.max_type_obligations) < BigInt(context.graph.nodes.length + 1)
    ? BigInt(bounds.max_type_obligations) : BigInt(context.graph.nodes.length + 1);
  const generated = sampleValueFuel(context, bounds, fuel, [], contract.type_ref);
  const values: readonly X.ExactSlot[] = [
    ...(!contract.required ? [{ tag: "Absent" } as const] : []),
    ...(contract.nullable ? [{ tag: "Null" } as const] : []),
    ...generated.values.map(value => ({ tag: "Present", value } as const)),
  ].filter(value => context.accepts(contract, value));
  return { values, obligations: generated.obligations };
}

export function inclusionSamples(context: ValueContext, source: X.TypeRef, destination: X.TypeRef, bounds: SampleBounds): SampleResult<X.ExactJson> {
  const fuel = BigInt(bounds.max_type_obligations) < BigInt(context.graph.nodes.length + 1)
    ? BigInt(bounds.max_type_obligations) : BigInt(context.graph.nodes.length + 1);
  const generated = sampleValueFuel(context, bounds, fuel, [], source);
  let candidates: readonly X.ExactJson[] = [];
  const sourceShape = context.resolve(source), destinationShape = context.resolve(destination);
  if (sourceShape.tag === "Product" && destinationShape.tag === "Product") {
    const missing = destinationShape.value.fields.flatMap(field =>
      sourceShape.value.fields.some(declared => declared.wire_name === field.wire_name) ? []
        : generated.values.slice(0, 1).flatMap(sample => sample.tag !== "Object" ? []
          : [{ tag: "Null" }, { tag: "Bool", value: true }, { tag: "String", value: "x" }, { tag: "String", value: "y" }, { tag: "Integer", value: "0" }]
            .map(value => ({ tag: "Object", members: [{ key: field.wire_name, value }, ...sample.members] } as X.ExactJson))));
    const extrasSpec = sourceShape.value.extras;
    const extras = extrasSpec.tag === "Reject" ? [] : formatUseSamples(context, extrasSpec.fields.key_format, 1n)
      .flatMap(key => [
        ...(extrasSpec.fields.value.nullable ? [{ tag: "Null" } as const] : []),
        ...sampleValueFuel(context, bounds, fuel, [], extrasSpec.fields.value.type_ref).values,
      ].map(value => ({ tag: "Object", members: [{ key, value }] } as X.ExactJson)));
    candidates = [...missing, ...extras];
  }
  const additional = candidates.filter(value => sampleWithinBound(BigInt(bounds.max_sample_length), value)
    && context.accepts({ type_ref: source, required: true, nullable: false }, { tag: "Present", value }));
  return {
    values: [...generated.values, ...additional],
    obligations: [...generated.obligations, ...(additional.length === candidates.length ? [] : [{ tag: "SampleBound" } as const])],
  };
}

export function sampleValues(context: ValueContext, ref: X.TypeRef, maximum = "32"): SampleResult<X.ExactJson> {
  return sampleValueFuel(context, { max_type_obligations: String(context.graph.nodes.length + 1), max_sample_length: maximum },
    BigInt(context.graph.nodes.length + 1), [], ref);
}

export function projectSlot(context: ValueContext, source: X.SlotContract, path: readonly X.PathStep[], _assumptions: readonly X.ProjectionAssumption[] = []): X.ProjectionCertificate {
  let current = source.type_ref;
  for (const step of path) {
    const shape = context.resolve(current);
    if (step.tag === "Field" && shape.tag === "Product") { const field = shape.value.fields.find(item => item.wire_name === step.value); check(field, "projected field"); current = field.slot.type_ref; }
    else if (step.tag === "Index" && shape.tag === "Array") current = shape.value.item.type_ref;
    else if (step.tag === "Variant" && shape.tag === "TaggedUnion") { const branch = shape.value.branches.find(item => item.wire_tag === step.value); check(branch, "projected branch"); current = branch.target; }
    else throw new SemanticEvidenceError("projection unavailable");
  }
  return deepFreeze({ profile: context.profile.reference, source_refs: context.sources, source, path, assumptions: _assumptions, destination: { type_ref: current, required: source.required, nullable: source.nullable } });
}

export function evaluateBinding(context: ValueContext, binding: X.BindingExpr, values: ReadonlyMap<string, X.ExactSlot>): X.ExactSlot {
  if (binding.tag === "Source") { const key = JSON.stringify(binding.fields.value.producer); const value = values.get(key); check(value, "binding source"); return projectValue(value, binding.fields.value.path, context.profile); }
  return { tag: "Present", value: { tag: "Object", members: binding.fields.fields.flatMap(([key, child]) => { const value = evaluateBinding(context, child, values); return value.tag === "Present" ? [{ key, value: value.value }] : value.tag === "Null" ? [{ key, value: { tag: "Null" } as X.ExactJson }] : []; }) } };
}

export function adaptSignatureCompositionWire(value: unknown, _adapter: unknown): X.SignatureCompositionEvidence { closed(value, ["problem", "derivation"]); return value as X.SignatureCompositionEvidence; }
export function verifySignatureComposition(_context: ValueContext, composition: X.SignatureCompositionEvidence, _operationCheck: (signature: X.FunctionSignature) => void): void { check(composition !== null && typeof composition === "object", "composition evidence"); }
