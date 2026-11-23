// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { type WorldEntry, resourceKey, sealed, stateOf } from "./core-state.js";
import { mapEmpty, mapGet, mapSet, vecEmpty, vecGet, vecPush, vecSet, vecToArray } from "./persistent.js";

export interface Revision {
  readonly value: bigint;
}

export interface ResourceId {
  readonly kind: string;
  readonly name: string;
}

export interface Basis {
  readonly resource: ResourceId;
  readonly revision: Revision;
}

export interface Observation<A> {
  readonly payload: A;
  readonly basis: Basis;
  readonly observedAt: bigint;
}

export interface Command<A> {
  readonly intent: A;
  readonly basis: Basis;
}

export interface Applied<A> {
  readonly tag: "Applied";
  readonly value: A;
}

export interface Rejected<R> {
  readonly tag: "Rejected";
  readonly reason: R;
}

export interface Conflicted<C> {
  readonly tag: "Conflicted";
  readonly conflict: C;
}

export interface BoundaryFailed<F> {
  readonly tag: "BoundaryFailed";
  readonly failure: F;
}

export type Outcome<A, R, C, F> =
  | Applied<A>
  | Rejected<R>
  | Conflicted<C>
  | BoundaryFailed<F>;

export function applied<A>(value: A): Applied<A> {
  return Object.freeze({ tag: "Applied", value });
}

export function rejected<R>(reason: R): Rejected<R> {
  return Object.freeze({ tag: "Rejected", reason });
}

export function conflicted<C>(conflict: C): Conflicted<C> {
  return Object.freeze({ tag: "Conflicted", conflict });
}

export function boundaryFailed<F>(failure: F): BoundaryFailed<F> {
  return Object.freeze({ tag: "BoundaryFailed", failure });
}

export interface UnknownResource {
  readonly tag: "UnknownResource";
  readonly resource: ResourceId;
}

export function unknownResource(resource: ResourceId): UnknownResource {
  return Object.freeze({ tag: "UnknownResource", resource });
}

export interface StaleBasis {
  readonly expected: Revision;
  readonly actual: Revision;
}

export function staleBasis(expected: Revision, actual: Revision): StaleBasis {
  return Object.freeze({ expected, actual });
}

declare const worldBrand: unique symbol;
export interface World {
  readonly [worldBrand]: true;
}

export function worldOf(
  entries: readonly (readonly [ResourceId, Revision])[]
): World {
  let vec = vecEmpty<WorldEntry>();
  let firstPositions = mapEmpty<number>();
  for (const entry of entries) {
    const key = resourceKey(entry[0]);
    if (mapGet(firstPositions, key) === undefined) {
      firstPositions = mapSet(firstPositions, key, vec.size);
    }
    vec = vecPush(vec, entry);
  }
  return sealed({ entries: vec, firstPositions });
}

export function worldEntries(world: World): readonly (readonly [ResourceId, Revision])[] {
  return Object.freeze(vecToArray(stateOf(world).entries));
}

export interface Found {
  readonly tag: "Found";
  readonly revision: Revision;
}

export type Lookup = Found | UnknownResource;

export function found(revision: Revision): Found {
  return Object.freeze({ tag: "Found", revision });
}

export function lookup(world: World, resource: ResourceId): Lookup {
  const state = stateOf(world);
  const position = mapGet(state.firstPositions, resourceKey(resource));
  if (position === undefined) {
    return unknownResource(resource);
  }
  return found(vecGet(state.entries, position)[1]);
}

export function bump(world: World, resource: ResourceId): World {
  const state = stateOf(world);
  const position = mapGet(state.firstPositions, resourceKey(resource));
  if (position === undefined) {
    return world;
  }
  const [rid, rev] = vecGet(state.entries, position);
  return sealed({
    entries: vecSet(state.entries, position, [rid, { value: rev.value + 1n }]),
    firstPositions: state.firstPositions,
  });
}

export function commandOf<A, B>(
  observation: Observation<A>,
  intent: B
): Command<B> {
  return Object.freeze({ intent, basis: observation.basis });
}

function revisionEquals(a: Revision, b: Revision): boolean {
  return a.value === b.value;
}

export function apply<A>(
  world: World,
  command: Command<A>
): Outcome<readonly [A, World], UnknownResource, StaleBasis, never> {
  const current = lookup(world, command.basis.resource);
  if (current.tag === "UnknownResource") {
    return rejected(current);
  }
  if (!revisionEquals(current.revision, command.basis.revision)) {
    return conflicted(staleBasis(command.basis.revision, current.revision));
  }
  return applied([command.intent, bump(world, command.basis.resource)] as const);
}
