// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import {
  type Command,
  type Outcome,
  type ResourceId,
  type Revision,
  type StaleBasis,
  type UnknownResource,
  type World,
  applied,
  conflicted,
  rejected,
  staleBasis,
  unknownResource,
  worldOf,
} from "./core.js";
import {
  type AdmittedValue,
  type Accepted,
  type Rejected,
  type ValueAdmission,
  type ValueFailure,
  type ValuePath,
  snapshotResourceId,
  snapshotRevision,
  snapshotValue,
  valueFailure,
} from "./value.js";
import { type PMap, type PVec, mapEmpty, mapGet, mapSet, pairKey, vecEmpty, vecGet, vecPush, vecSet, vecToArray } from "./persistent.js";

export interface StoreEntry<A = AdmittedValue> {
  readonly resource: ResourceId;
  readonly revision: Revision;
  readonly payload: A;
}

declare const storeBrand: unique symbol;
export interface Store<A = AdmittedValue> {
  readonly [storeBrand]: A;
}

interface StoreFields<A> {
  readonly entries: PVec<StoreEntry<A>>;
  readonly positions: PMap<number>;
}

type StoreState<A> = StoreFields<A> & Store<A>;

export type StoreInputEntry<A> =
  | readonly [ResourceId, Revision, A]
  | {
      readonly resource: ResourceId;
      readonly revision: Revision;
      readonly payload: A;
    };

export type Observed<A> =
  | { readonly tag: "Found"; readonly revision: Revision; readonly payload: A }
  | { readonly tag: "Unknown"; readonly unknown: UnknownResource };

export type StoreAdmission<A = Store<AdmittedValue>> =
  | Accepted<A>
  | Rejected;

function stateOf<A>(store: Store<A>): StoreState<A> {
  return store as StoreState<A>;
}

function sealed<A>(fields: StoreFields<A>): Store<A> {
  return Object.freeze(fields) as StoreState<A>;
}

function resourceKey(resource: ResourceId): string {
  return pairKey(resource.kind, resource.name);
}

function pathForEntry(index: number, field: string): ValuePath {
  return [index, field];
}

function pathText(path: ValuePath): string {
  if (path.length === 0) return "$";
  return path.reduce<string>(
    (text, part) =>
      typeof part === "number" ? `${text}[${part}]` : `${text}.${part}`,
    "$"
  );
}

function cloneResource(resource: ResourceId): ResourceId {
  return Object.freeze({ kind: resource.kind, name: resource.name });
}

function cloneRevision(revision: Revision): Revision {
  return Object.freeze({ value: revision.value });
}

function cloneAdmitted(value: unknown): unknown {
  const result = snapshotValue(value);
  if (result.tag === "Rejected") {
    throw new TypeError(result.failure.path);
  }
  return result.value;
}

function cloneEntry<A>(entry: StoreEntry<A>): StoreEntry<A> {
  return Object.freeze({
    resource: cloneResource(entry.resource),
    revision: cloneRevision(entry.revision),
    payload: cloneAdmitted(entry.payload) as A,
  });
}

function readRawEntry<A>(
  raw: StoreInputEntry<A>,
  index: number
):
  | { readonly resource: unknown; readonly revision: unknown; readonly payload: unknown }
  | ValueFailure {
  try {
    if (Array.isArray(raw)) {
      if (raw.length !== 3) {
        return valueFailure(
          "UnsupportedValue",
          "snapshotStore",
          [index],
          "store entries must contain resource, revision, and payload",
          "entry tuple length"
        );
      }
      return { resource: raw[0], revision: raw[1], payload: raw[2] };
    }
    if (raw !== null && typeof raw === "object" && !Array.isArray(raw)) {
      const record = raw as {
        readonly resource: unknown;
        readonly revision: unknown;
        readonly payload: unknown;
      };
      return {
        resource: record.resource,
        revision: record.revision,
        payload: record.payload,
      };
    }
    return valueFailure(
      "UnsupportedValue",
      "snapshotStore",
      [index],
      "store entries must be tuples or entry records",
      typeof raw
    );
  } catch (error) {
    return valueFailure(
      "ValueAccessFailed",
      "snapshotStore",
      [index],
      "store entry fields must be readable",
      error instanceof Error ? `${error.name}: ${error.message}` : String(error)
    );
  }
}

function withStoreContext(failure: ValueFailure, index: number, field: string): ValueFailure {
  const hasEntryPrefix =
    failure.inputPath[0] === index && failure.inputPath[1] === field;
  const path = hasEntryPrefix
    ? failure.inputPath
    : [...pathForEntry(index, field), ...failure.inputPath];
  const extras: {
    resource?: ResourceId;
    revision?: Revision;
    firstPath?: ValuePath;
  } = {};
  if (failure.resource !== undefined) extras.resource = failure.resource;
  if (failure.revision !== undefined) extras.revision = failure.revision;
  if (failure.firstPath !== undefined) extras.firstPath = failure.firstPath;
  return valueFailure(
    failure.tag,
    "snapshotStore",
    path,
    failure.violatedCondition,
    failure.witness,
    [failure],
    extras
  );
}

export function snapshotStore<A>(
  entries: readonly StoreInputEntry<A>[]
): StoreAdmission<Store<A>> {
  if (!Array.isArray(entries)) {
    return {
      tag: "Rejected",
      failure: valueFailure(
        "UnsupportedValue",
        "snapshotStore",
        [],
        "store entries must be a finite array",
        typeof entries
      ),
    };
  }

  let owned = vecEmpty<StoreEntry<A>>();
  let positions = mapEmpty<number>();
  const revisionObjects = new WeakMap<object, ValuePath>();

  for (let index = 0; index < entries.length; index += 1) {
    const raw = readRawEntry(entries[index] as StoreInputEntry<A>, index);
    if ("tag" in raw) return { tag: "Rejected", failure: raw };

    const resourceResult = snapshotResourceId(raw.resource, pathForEntry(index, "resource"));
    if (resourceResult.tag === "Rejected") {
      return { tag: "Rejected", failure: withStoreContext(resourceResult.failure, index, "resource") };
    }
    const resource = resourceResult.value;
    const duplicate = mapGet(positions, resourceKey(resource)) ?? -1;
    if (duplicate >= 0) {
      return {
        tag: "Rejected",
        failure: valueFailure(
          "DuplicateResource",
          "snapshotStore",
          pathForEntry(index, "resource"),
          "a Store contains at most one entry for each ResourceId(kind,name)",
          `duplicate of entry ${duplicate}`,
          [],
          { resource, firstPath: pathForEntry(duplicate, "resource") }
        ),
      };
    }

    if (raw.revision !== null && typeof raw.revision === "object") {
      const firstPath = revisionObjects.get(raw.revision);
      if (firstPath !== undefined) {
        return {
          tag: "Rejected",
          failure: valueFailure(
            "RevisionAlias",
            "snapshotStore",
            pathForEntry(index, "revision"),
            "each Store entry owns a distinct input Revision object",
            `same Revision object as ${pathText(firstPath)}`,
            [],
            { resource, firstPath }
          ),
        };
      }
      revisionObjects.set(raw.revision, pathForEntry(index, "revision"));
    }

    const revisionResult = snapshotRevision(raw.revision, pathForEntry(index, "revision"));
    if (revisionResult.tag === "Rejected") {
      return { tag: "Rejected", failure: withStoreContext(revisionResult.failure, index, "revision") };
    }
    const payloadResult = snapshotValue(raw.payload);
    if (payloadResult.tag === "Rejected") {
      return { tag: "Rejected", failure: withStoreContext(payloadResult.failure, index, "payload") };
    }
    positions = mapSet(positions, resourceKey(resource), owned.size);
    owned = vecPush(
      owned,
      Object.freeze({
        resource,
        revision: revisionResult.value,
        payload: payloadResult.value as A,
      })
    );
  }

  return { tag: "Accepted", value: sealed({ entries: owned, positions }) };
}

function entryOf<A>(state: StoreState<A>, resource: ResourceId): StoreEntry<A> | undefined {
  const position = mapGet(state.positions, resourceKey(resource));
  return position === undefined ? undefined : vecGet(state.entries, position);
}

export function storeEntries<A>(store: Store<A>): readonly StoreEntry<A>[] {
  return Object.freeze(vecToArray(stateOf(store).entries).map((entry) => cloneEntry(entry)));
}

export function observe<A>(store: Store<A>, resource: ResourceId): Observed<A> {
  const entry = entryOf(stateOf(store), resource);
  if (entry !== undefined) {
    return Object.freeze({
      tag: "Found" as const,
      revision: cloneRevision(entry.revision),
      payload: cloneAdmitted(entry.payload) as A,
    });
  }
  return Object.freeze({
    tag: "Unknown" as const,
    unknown: unknownResource(cloneResource(resource)),
  });
}

function applyFailure(path: ValuePath, cause: ValueFailure): Outcome<never, never, never, ValueFailure> {
  return {
    tag: "BoundaryFailed",
    failure: valueFailure(
      cause.tag,
      "applyStore",
      path,
      "Store update input must be owned before publication",
      cause.path,
      [cause]
    ),
  };
}

export function applyStore<A>(
  store: Store<A>,
  command: Command<A>
): Outcome<readonly [A, Store<A>], UnknownResource, StaleBasis, ValueFailure> {
  const state = stateOf(store);
  let rawResource: unknown;
  let rawRevision: unknown;
  let rawIntent: unknown;
  try {
    rawResource = command.basis.resource;
    rawRevision = command.basis.revision;
    rawIntent = command.intent;
  } catch (error) {
    return {
      tag: "BoundaryFailed",
      failure: valueFailure(
        "ValueAccessFailed",
        "applyStore",
        [],
        "command fields must be readable data",
        error instanceof Error ? `${error.name}: ${error.message}` : String(error)
      ),
    };
  }
  const resourceResult = snapshotResourceId(rawResource, ["basis", "resource"]);
  if (resourceResult.tag === "Rejected") return applyFailure(["basis", "resource"], resourceResult.failure) as never;
  const revisionResult = snapshotRevision(rawRevision, ["basis", "revision"]);
  if (revisionResult.tag === "Rejected") return applyFailure(["basis", "revision"], revisionResult.failure) as never;
  const intentResult = snapshotValue(rawIntent);
  if (intentResult.tag === "Rejected") return applyFailure(["intent"], intentResult.failure) as never;

  const resource = resourceResult.value;
  const revision = revisionResult.value;
  const intent = intentResult.value as A;
  const position = mapGet(state.positions, resourceKey(resource));
  const current = position === undefined ? undefined : vecGet(state.entries, position);
  if (current === undefined) return rejected(unknownResource(resource));
  if (current.revision.value !== revision.value) {
    return conflicted(staleBasis(revision, cloneRevision(current.revision)));
  }

  const next: StoreEntry<A> = Object.freeze({
    resource: current.resource,
    revision: Object.freeze({ value: current.revision.value + 1n }),
    payload: intent,
  });
  const nextStore = sealed({ entries: vecSet(state.entries, position as number, next), positions: state.positions });
  return applied([cloneAdmitted(intent) as A, nextStore] as const);
}

export function worldOfStore<A>(store: Store<A>): World {
  return worldOf(
    vecToArray(stateOf(store).entries).map(
      (entry) => [cloneResource(entry.resource), cloneRevision(entry.revision)] as const
    )
  );
}
