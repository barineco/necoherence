// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

// Provenance of calls as data. Records never feed a later decision.
// Callers hold the provenance value themselves; no sink or drop counter.

import type { Basis } from "./core.js";

export interface WithBasis {
  readonly tag: "WithBasis";
  readonly basis: Basis;
}

export interface NoBasis {
  readonly tag: "NoBasis";
}

export type BasisState = WithBasis | NoBasis;

export function withBasis(basis: Basis): WithBasis {
  return Object.freeze({ tag: "WithBasis", basis });
}

export function noBasis(): NoBasis {
  return Object.freeze({ tag: "NoBasis" });
}

export interface CallRecord<Input, Product> {
  readonly declaration: string;
  readonly input: Input;
  readonly product: Product;
  readonly basis: BasisState;
}

export function recordOf<Input, Product>(
  declaration: string,
  input: Input,
  product: Product
): CallRecord<Input, Product> {
  return Object.freeze({ declaration, input, product, basis: noBasis() });
}

export function recordOnBasis<Input, Product>(
  declaration: string,
  input: Input,
  product: Product,
  basis: Basis
): CallRecord<Input, Product> {
  return Object.freeze({ declaration, input, product, basis: withBasis(basis) });
}

function sameResource(a: Basis, b: Basis): boolean {
  return a.resource.kind === b.resource.kind && a.resource.name === b.resource.name;
}

// An absent edge witnesses that two calls touched disjoint coordinates.
export function hasEdge<IA, PA, IB, PB>(
  earlier: CallRecord<IA, PA>,
  later: CallRecord<IB, PB>
): boolean {
  if (earlier.basis.tag !== "WithBasis" || later.basis.tag !== "WithBasis") {
    return false;
  }
  return sameResource(earlier.basis.basis, later.basis.basis);
}
