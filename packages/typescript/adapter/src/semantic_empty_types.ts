// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import type * as C from "./semantic_composition.js";
import * as V from "./semantic_values.js";
import { failed, ok } from "./semantic_values.js";

export type VerificationResult<T> = V.Except<T, C.InclusionFailure>;

const frozenCopy = <T>(value: T): T => V.deepFreeze(structuredClone(value));

function natRangeEmpty(minimum: string | null, maximum: string | null): boolean {
  return minimum !== null && maximum !== null && BigInt(maximum) < BigInt(minimum);
}

function stringFinite(spec: V.StringSpec): readonly string[] | null {
  return spec.const_value === null ? spec.enum_values : [spec.const_value];
}

function checkEmptyRow(context: V.ValueContext, references: ReadonlySet<string>, reference: V.TypeRef): VerificationResult<null> {
  const node = V.findType(context, reference);
  if (node === undefined) return failed({ tag: "ForgedEmptiness" });
  const shape = node.shape;
  const row = (condition: boolean): VerificationResult<null> => condition ? ok(null) : failed({ tag: "ForgedEmptiness" });
  if (shape.tag === "Alias") return row(references.has(V.typeIdentity(shape.fields.target)));
  if (shape.tag === "String") {
    if (shape.value.wrapper !== null) return row(false);
    const finite = stringFinite(shape.value);
    return row(finite !== null && finite.every(value => V.stringCondition(context.prepared, shape.value, value) !== null));
  }
  if (shape.tag === "Bytes") return row(natRangeEmpty(shape.value.minimum, shape.value.maximum));
  if (shape.tag === "Product") return row(shape.value.fields.some(field => field.slot.required && !field.slot.nullable
    && references.has(V.typeIdentity(field.slot.type_ref))));
  if (shape.tag === "Array") return row(natRangeEmpty(shape.value.min_length, shape.value.max_length)
    || BigInt(shape.value.min_length ?? "0") > 0n && !shape.value.item.nullable
      && references.has(V.typeIdentity(shape.value.item.type_ref)));
  if (shape.tag === "TaggedUnion") return row(shape.value.branches.every(branch => references.has(V.typeIdentity(branch.target))));
  return row(false);
}

const checkedEmptyTypesToken = Symbol("checked empty types");
const checkedEmptyTypesAuthority = new WeakSet<CheckedEmptyTypes>();

export class CheckedEmptyTypes {
  private constructor(token: symbol, readonly refs: readonly V.TypeRef[]) {
    if (token !== checkedEmptyTypesToken) throw new TypeError("empty type admission authority");
    checkedEmptyTypesAuthority.add(this);
    Object.freeze(this);
  }
  static admit(token: symbol, refs: readonly V.TypeRef[]): CheckedEmptyTypes { return new CheckedEmptyTypes(token, refs); }
}


export function verifyEmptyTypes(context: V.ValueContext, refs: readonly V.TypeRef[]): VerificationResult<CheckedEmptyTypes> {
  const identities = refs.map(V.typeIdentity);
  if (new Set(identities).size !== identities.length) return failed({ tag: "ForgedEmptiness" });
  const candidates = new Set(identities);
  for (const reference of refs) {
    const row = checkEmptyRow(context, candidates, reference);
    if (row.tag === "Failed") return failed(row.failure);
  }
  return ok(CheckedEmptyTypes.admit(checkedEmptyTypesToken, frozenCopy(refs)));
}

function pruneEmptyTypes(context: V.ValueContext, refs: readonly V.TypeRef[]): readonly V.TypeRef[] {
  const identities = refs.map(V.typeIdentity), candidates = new Set(identities), dependents = new Map<string, number[]>();
  refs.forEach((reference, index) => {
    const node = V.findType(context, reference);
    if (node === undefined) return;
    for (const child of V.typeChildren(node.shape)) {
      const key = V.typeIdentity(child), list = dependents.get(key);
      if (list === undefined) dependents.set(key, [index]); else list.push(index);
    }
  });
  const pending = refs.map((_, index) => index), queued = new Set(pending);
  for (let head = 0; head < pending.length; head += 1) {
    const index = pending[head]!, identity = identities[index]!;
    queued.delete(index);
    if (!candidates.has(identity) || checkEmptyRow(context, candidates, refs[index]!).tag === "Ok") continue;
    candidates.delete(identity);
    for (const dependent of dependents.get(identity) ?? []) {
      if (candidates.has(identities[dependent]!) && !queued.has(dependent)) { queued.add(dependent); pending.push(dependent); }
    }
  }
  return refs.filter((_, index) => candidates.has(identities[index]!));
}

export function emptyTypes(context: V.ValueContext): readonly V.TypeRef[] {
  const distinct = [...new Map(context.graph.nodes.map(node => [V.typeIdentity(node.reference), node.reference])).values()];
  return frozenCopy(pruneEmptyTypes(context, distinct));
}
