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

export interface StoreEntry<A = AdmittedValue> {
  readonly resource: ResourceId;
  readonly revision: Revision;
  readonly payload: A;
}

export interface Store<A = AdmittedValue> {
  readonly entries: readonly StoreEntry<A>[];
}

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

const storeState = Symbol("necoherence.storeState");

type InternalStore<A> = Store<A> & { readonly [storeState]: true };

function sameResource(a: ResourceId, b: ResourceId): boolean {
  return a.kind === b.kind && a.name === b.name;
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

function buildStore<A>(entries: readonly StoreEntry<A>[]): InternalStore<A> {
  const ownedEntries = Object.freeze(
    entries.map((entry) =>
      Object.freeze({
        resource: cloneResource(entry.resource),
        revision: cloneRevision(entry.revision),
        payload: cloneAdmitted(entry.payload) as A,
      })
    )
  );
  return Object.freeze({
    entries: ownedEntries,
    [storeState]: true as const,
  }) as InternalStore<A>;
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

  const owned: StoreEntry<A>[] = [];
  const resources: ResourceId[] = [];
  const revisionObjects = new WeakMap<object, ValuePath>();

  for (let index = 0; index < entries.length; index += 1) {
    const raw = readRawEntry(entries[index] as StoreInputEntry<A>, index);
    if ("tag" in raw) return { tag: "Rejected", failure: raw };

    const resourceResult = snapshotResourceId(raw.resource, pathForEntry(index, "resource"));
    if (resourceResult.tag === "Rejected") {
      return { tag: "Rejected", failure: withStoreContext(resourceResult.failure, index, "resource") };
    }
    const resource = resourceResult.value;
    const duplicate = resources.findIndex((candidate) => sameResource(candidate, resource));
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
    owned.push(
      Object.freeze({
        resource,
        revision: revisionResult.value,
        payload: payloadResult.value as A,
      })
    );
    resources.push(resource);
  }

  return { tag: "Accepted", value: buildStore(owned) };
}

function internalStore<A>(store: Store<A>): InternalStore<A> {
  if (store !== null && typeof store === "object" && storeState in store) {
    return store as InternalStore<A>;
  }
  return buildStore(store.entries.map((entry) => cloneEntry(entry)));
}

export function storeEntries<A>(store: Store<A>): readonly StoreEntry<A>[] {
  const internal = internalStore(store);
  return Object.freeze(internal.entries.map((entry) => cloneEntry(entry)));
}

export function observe<A>(store: Store<A>, resource: ResourceId): Observed<A> {
  const internal = internalStore(store);
  for (const entry of internal.entries) {
    if (sameResource(entry.resource, resource)) {
      return Object.freeze({
        tag: "Found" as const,
        revision: cloneRevision(entry.revision),
        payload: cloneAdmitted(entry.payload) as A,
      });
    }
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
  const internal = internalStore(store);
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
  let current: StoreEntry<A> | undefined;
  for (const entry of internal.entries) {
    if (sameResource(entry.resource, resource)) {
      current = entry;
      break;
    }
  }
  if (current === undefined) return rejected(unknownResource(resource));
  if (rawRevision === current.revision) {
    return {
      tag: "BoundaryFailed",
      failure: valueFailure(
        "RevisionReuse",
        "applyStore",
        ["basis", "revision"],
        "a Store-owned Revision object cannot be reused as an update basis",
        "Store revision alias",
        [],
        { resource, revision }
      ),
    };
  }
  if (current.revision.value !== revision.value) {
    return conflicted(staleBasis(revision, cloneRevision(current.revision)));
  }

  const nextEntries: StoreEntry<A>[] = internal.entries.map((entry) =>
    sameResource(entry.resource, resource)
      ? Object.freeze({
          resource: cloneResource(entry.resource),
          revision: Object.freeze({ value: entry.revision.value + 1n }),
          payload: cloneAdmitted(intent) as A,
        })
      : cloneEntry(entry)
  );
  const nextStore = buildStore(nextEntries);
  return applied([cloneAdmitted(intent) as A, nextStore] as const);
}

export function worldOfStore<A>(store: Store<A>): World {
  const internal = internalStore(store);
  return worldOf(
    internal.entries.map(
      (entry) => [cloneResource(entry.resource), cloneRevision(entry.revision)] as const
    )
  );
}
