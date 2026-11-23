// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import type { ResourceId, Revision, World } from "./core.js";
import { type PMap, type PVec, mapGet, mapSet, pairKey, vecPush } from "./persistent.js";

export type WorldEntry = readonly [ResourceId, Revision];

export interface WorldFields {
  readonly entries: PVec<WorldEntry>;
  readonly firstPositions: PMap<number>;
}

export type WorldState = WorldFields & World;

export function stateOf(world: World): WorldState {
  return world as WorldState;
}

export function sealed(fields: WorldFields): World {
  return Object.freeze(fields) as WorldState;
}

export function resourceKey(resource: ResourceId): string {
  return pairKey(resource.kind, resource.name);
}

export function worldAppended(world: World, resource: ResourceId, revision: Revision): World {
  const state = stateOf(world);
  const key = resourceKey(resource);
  const firstPositions = mapGet(state.firstPositions, key) === undefined ? mapSet(state.firstPositions, key, state.entries.size) : state.firstPositions;
  return sealed({ entries: vecPush(state.entries, [resource, revision] as const), firstPositions });
}
