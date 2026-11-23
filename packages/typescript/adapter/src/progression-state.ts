// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import type { RequestEntry, RequestIdentity, RequestPhase, RequestPolicy, RequestProgressionSnapshot, ResourceBudget, ResourceDemand } from "./request-progression.js";
import { type PIntSet, type PMap, type PVec, mapGet, mapSet, pairKey, setInsert, setRemove, vecGet, vecPush, vecSet } from "./persistent.js";

function frozen<T>(value: T): T { return Object.freeze(value); }
export function identityKey(identity: RequestIdentity): string { return `${pairKey(identity.kind, identity.provenance)}${identity.revision}`; }


export interface DemandTotals { readonly pending: ResourceDemand; readonly inFlight: ResourceDemand; readonly concurrent: ResourceDemand; }
export interface SnapshotFields {
  readonly policy: RequestPolicy;
  readonly budget: ResourceBudget;
  readonly currentIdentity: RequestIdentity | null;
  readonly entries: PVec<RequestEntry>;
  readonly positions: PMap<number>;
  readonly pendingPositions: PIntSet;
  readonly orderedPendingPositions: PIntSet;
  readonly totals: DemandTotals;
  readonly revision: bigint;
}

const zeroDemand: ResourceDemand = frozen({ pending: 0n, inFlight: 0n, concurrent: 0n });
export const zeroTotals: DemandTotals = frozen({ pending: zeroDemand, inFlight: zeroDemand, concurrent: zeroDemand });

export type SnapshotState = SnapshotFields & RequestProgressionSnapshot;
export function stateOf(snapshot: RequestProgressionSnapshot): SnapshotFields { return snapshot as SnapshotState; }
export function sealed(fields: SnapshotFields): RequestProgressionSnapshot { return frozen(fields) as SnapshotState; }
export function shifted(total: ResourceDemand, demand: ResourceDemand, sign: 1n | -1n): ResourceDemand { return frozen({ pending: total.pending + sign * demand.pending, inFlight: total.inFlight + sign * demand.inFlight, concurrent: total.concurrent + sign * demand.concurrent }); }
export function countsPending(phase: RequestPhase): boolean { return phase === "Pending"; }
export function countsInFlight(phase: RequestPhase): boolean { return phase === "Preparing" || phase === "Publishing"; }
export function countsConcurrent(phase: RequestPhase): boolean { return phase === "Publishing"; }

export function totalsAfter(totals: DemandTotals, before: RequestEntry | null, after: RequestEntry | null): DemandTotals {
  let pending = totals.pending;
  let inFlight = totals.inFlight;
  let concurrent = totals.concurrent;
  if (before !== null) {
    if (countsPending(before.phase)) pending = shifted(pending, before.demand, -1n);
    if (countsInFlight(before.phase)) inFlight = shifted(inFlight, before.demand, -1n);
    if (countsConcurrent(before.phase)) concurrent = shifted(concurrent, before.demand, -1n);
  }
  if (after !== null) {
    if (countsPending(after.phase)) pending = shifted(pending, after.demand, 1n);
    if (countsInFlight(after.phase)) inFlight = shifted(inFlight, after.demand, 1n);
    if (countsConcurrent(after.phase)) concurrent = shifted(concurrent, after.demand, 1n);
  }
  return frozen({ pending, inFlight, concurrent });
}

export function pendingSetsAfter(state: SnapshotFields, position: number, before: RequestEntry | null, after: RequestEntry): Pick<SnapshotState, "pendingPositions" | "orderedPendingPositions"> {
  const wasPending = before !== null && countsPending(before.phase);
  const isPending = countsPending(after.phase);
  if (wasPending === isPending) return state;
  const ordered = after.footprint.effectClass === "OrderedEffect";
  if (isPending) return { pendingPositions: setInsert(state.pendingPositions, position), orderedPendingPositions: ordered ? setInsert(state.orderedPendingPositions, position) : state.orderedPendingPositions };
  return { pendingPositions: setRemove(state.pendingPositions, position), orderedPendingPositions: ordered ? setRemove(state.orderedPendingPositions, position) : state.orderedPendingPositions };
}

export function replaceAt(state: SnapshotFields, position: number, entry: RequestEntry): SnapshotFields {
  const before = vecGet(state.entries, position);
  return { ...state, ...pendingSetsAfter(state, position, before, entry), entries: vecSet(state.entries, position, entry), totals: totalsAfter(state.totals, before, entry) };
}

export function appended(state: SnapshotFields, entry: RequestEntry): SnapshotFields {
  const position = state.entries.size;
  return { ...state, ...pendingSetsAfter(state, position, null, entry), entries: vecPush(state.entries, entry), positions: mapSet(state.positions, identityKey(entry.identity), position), totals: totalsAfter(state.totals, null, entry) };
}

export function positionOf(state: SnapshotFields, identity: RequestIdentity): number | undefined { return mapGet(state.positions, identityKey(identity)); }

export function withProgressionEntry(snapshot: RequestProgressionSnapshot, entry: RequestEntry): RequestProgressionSnapshot {
  const state = stateOf(snapshot);
  const position = positionOf(state, entry.identity);
  return position === undefined ? snapshot : sealed(replaceAt(state, position, entry));
}
