// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT


import {
  type ResourceId,
  type Revision,
  type World,
  lookup,
} from "./core.js";
import { type BasisState } from "./record.js";
import { pairKey } from "./persistent.js";

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

export function coherent(reconciliation: Reconciliation): boolean {
  return (
    reconciliation.divergences.length === 0 &&
    reconciliation.unbased === 0n &&
    reconciliation.dropped === 0n
  );
}

export function reconcile(
  bases: readonly BasisState[],
  world: World,
  dropped: bigint
): Reconciliation {
  const recorded = new Map<string, { resource: ResourceId; revision: Revision }>();
  let unbased = 0n;

  for (const basis of bases) {
    if (basis.tag === "NoBasis") {
      unbased += 1n;
      continue;
    }
    const resource = basis.basis.resource;
    const key = pairKey(resource.kind, resource.name);
    const existing = recorded.get(key);
    if (existing === undefined) {
      recorded.set(key, { resource, revision: basis.basis.revision });
    } else if (basis.basis.revision.value > existing.revision.value) {
      recorded.set(key, { resource: existing.resource, revision: basis.basis.revision });
    }
  }

  const divergences: Divergence[] = [];
  for (const { resource, revision } of recorded.values()) {
    const actual = lookup(world, resource);
    if (actual.tag === "UnknownResource") {
      divergences.push(
        Object.freeze({
          tag: "UnknownToWorld",
          resource,
          recorded: revision,
        })
      );
    } else if (actual.revision.value > revision.value + 1n) {
      divergences.push(
        Object.freeze({
          tag: "WorldAhead",
          resource,
          recorded: revision,
          actual: actual.revision,
        })
      );
    } else if (actual.revision.value < revision.value) {
      divergences.push(
        Object.freeze({
          tag: "WorldBehind",
          resource,
          recorded: revision,
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
