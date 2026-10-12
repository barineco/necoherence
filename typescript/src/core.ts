// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

// Immutable values, observations with a basis, commands, closed outcomes.
// World operations are free functions; the world is always the first
// argument. Revisions and every other Lean `Nat` are `bigint`.

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

export interface World {
  readonly entries: readonly (readonly [ResourceId, Revision])[];
}

export function worldOf(
  entries: readonly (readonly [ResourceId, Revision])[]
): World {
  return Object.freeze({ entries: Object.freeze([...entries]) });
}

export interface Found {
  readonly tag: "Found";
  readonly revision: Revision;
}

export type Lookup = Found | UnknownResource;

export function found(revision: Revision): Found {
  return Object.freeze({ tag: "Found", revision });
}

function sameResource(a: ResourceId, b: ResourceId): boolean {
  return a.kind === b.kind && a.name === b.name;
}

// Returns the first matching revision, or the resource's absence.
export function lookup(world: World, resource: ResourceId): Lookup {
  for (const [rid, rev] of world.entries) {
    if (sameResource(rid, resource)) {
      return found(rev);
    }
  }
  return unknownResource(resource);
}

// Returns a world with one matching entry's revision incremented.
export function bump(world: World, resource: ResourceId): World {
  let matched = false;
  const rebuilt: (readonly [ResourceId, Revision])[] = [];
  for (const [rid, rev] of world.entries) {
    if (!matched && sameResource(rid, resource)) {
      rebuilt.push([rid, { value: rev.value + 1n }]);
      matched = true;
    } else {
      rebuilt.push([rid, rev]);
    }
  }
  return worldOf(rebuilt);
}

// Builds a command that keeps the observation's own basis.
export function commandOf<A, B>(
  observation: Observation<A>,
  intent: B
): Command<B> {
  return Object.freeze({ intent, basis: observation.basis });
}

function revisionEquals(a: Revision, b: Revision): boolean {
  return a.value === b.value;
}

// Closes over four branches; the boundary branch never actually fires.
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
