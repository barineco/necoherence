// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

// Compare a recorded history against the world it should have produced,
// in one call.

import {
  type ResourceId,
  type Revision,
  type World,
  lookup,
} from "./core.js";
import { type BasisState } from "./record.js";

export type Divergence =
  | {
      readonly tag: "WorldAhead";
      readonly resource: ResourceId;
      readonly recorded: Revision;
      readonly actual: Revision;
    }
  | {
      readonly tag: "WorldBehind";
      readonly resource: ResourceId;
      readonly recorded: Revision;
      readonly actual: Revision;
    }
  | {
      readonly tag: "UnknownToWorld";
      readonly resource: ResourceId;
      readonly recorded: Revision;
    };

export interface Reconciliation {
  readonly divergences: readonly Divergence[];
  readonly unbased: bigint;
  readonly dropped: bigint;
}

function sameResource(a: ResourceId, b: ResourceId): boolean {
  return a.kind === b.kind && a.name === b.name;
}

// Read whether the reconciliation is free of any gap.
export function coherent(reconciliation: Reconciliation): boolean {
  return (
    reconciliation.divergences.length === 0 &&
    reconciliation.unbased === 0n &&
    reconciliation.dropped === 0n
  );
}

// Reconcile the highest recorded revision per resource against `world`.
export function reconcile(
  bases: readonly BasisState[],
  world: World,
  dropped: bigint
): Reconciliation {
  const order: ResourceId[] = [];
  const recorded: { resource: ResourceId; revision: Revision }[] = [];
  let unbased = 0n;

  for (const basis of bases) {
    if (basis.tag === "NoBasis") {
      unbased += 1n;
      continue;
    }
    const existing = recorded.find((entry) =>
      sameResource(entry.resource, basis.basis.resource)
    );
    if (existing !== undefined) {
      if (basis.basis.revision.value > existing.revision.value) {
        existing.revision = basis.basis.revision;
      }
    } else {
      order.push(basis.basis.resource);
      recorded.push({
        resource: basis.basis.resource,
        revision: basis.basis.revision,
      });
    }
  }

  const divergences: Divergence[] = [];
  for (const resource of order) {
    const entry = recorded.find((candidate) =>
      sameResource(candidate.resource, resource)
    );
    if (entry === undefined) {
      continue;
    }
    const actual = lookup(world, resource);
    if (actual.tag === "UnknownResource") {
      divergences.push(
        Object.freeze({
          tag: "UnknownToWorld",
          resource,
          recorded: entry.revision,
        })
      );
      continue;
    }
    if (actual.revision.value > entry.revision.value + 1n) {
      divergences.push(
        Object.freeze({
          tag: "WorldAhead",
          resource,
          recorded: entry.revision,
          actual: actual.revision,
        })
      );
    } else if (actual.revision.value < entry.revision.value) {
      divergences.push(
        Object.freeze({
          tag: "WorldBehind",
          resource,
          recorded: entry.revision,
          actual: actual.revision,
        })
      );
    }
  }

  return Object.freeze({
    divergences: Object.freeze(divergences),
    unbased,
    dropped,
  });
}
