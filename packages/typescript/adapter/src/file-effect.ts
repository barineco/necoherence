// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT


import {
  apply,
  lookup,
  type Basis,
  type Command,
  type Observation,
  type Outcome,
  type ResourceId,
  type StaleBasis,
  type UnknownResource,
  type World,
} from "./core.js";
import { worldAppended } from "./core-state.js";
import { type PMap, type PVec, mapEmpty, mapGet, mapSet, pairKey, vecEmpty, vecFrom, vecGet, vecPush, vecSet, vecToArray } from "./persistent.js";

export interface NormalizedPath {
  readonly root: boolean;
  readonly segments: readonly string[];
}

export interface ContentDigest {
  readonly value: string;
}

function normalizeSegments(raw: readonly string[]): readonly string[] {
  const acc: string[] = [];
  for (const segment of raw) {
    if (segment === "" || segment === ".") {
      continue;
    }
    if (segment === "..") {
      acc.pop();
      continue;
    }
    acc.push(segment);
  }
  return Object.freeze(acc);
}

export function normalizePath(root: boolean, raw: readonly string[]): NormalizedPath {
  return Object.freeze({ root, segments: normalizeSegments(raw) });
}

function pathString(path: NormalizedPath): string {
  const body = path.segments.join("/");
  return path.root ? "/" + body : body;
}

const FILE_KIND = "file";

function pathResource(path: NormalizedPath): ResourceId {
  return Object.freeze({ kind: FILE_KIND, name: pathString(path) });
}

function sameResource(a: ResourceId, b: ResourceId): boolean {
  return a.kind === b.kind && a.name === b.name;
}

function pathKey(path: NormalizedPath): string {
  return (path.root ? "/" : ".") + path.segments.map((segment) => `${segment.length}:${segment}`).join("");
}

function resourceKey(resource: ResourceId): string {
  return pairKey(resource.kind, resource.name);
}

export interface FileRecord {
  readonly digest: ContentDigest;
  readonly bytes: readonly number[];
}

declare const externalFileStateBrand: unique symbol;
export interface ExternalFileState {
  readonly [externalFileStateBrand]: true;
}

type FileEntry = readonly [NormalizedPath, FileRecord];

interface ExternalFileStateFields {
  readonly files: PVec<FileEntry>;
  readonly positions: PMap<number>;
  readonly distinct: boolean;
  readonly readFailureOrder: readonly NormalizedPath[];
  readonly writeFailureOrder: readonly NormalizedPath[];
  readonly readFailures: ReadonlySet<string>;
  readonly writeFailures: ReadonlySet<string>;
}

type ExternalFileStateRecord = ExternalFileStateFields & ExternalFileState;

function fileStateFields(state: ExternalFileState): ExternalFileStateFields {
  return state as ExternalFileStateRecord;
}

function fileStateSealed(fields: ExternalFileStateFields): ExternalFileState {
  return Object.freeze(fields) as ExternalFileStateRecord;
}

export function externalFileStateOf(
  files: readonly (readonly [NormalizedPath, FileRecord])[],
  readFailures: readonly NormalizedPath[],
  writeFailures: readonly NormalizedPath[]
): ExternalFileState {
  let vec = vecEmpty<FileEntry>();
  let positions = mapEmpty<number>();
  let distinct = true;
  for (const entry of files) {
    const key = pathKey(entry[0]);
    if (mapGet(positions, key) === undefined) {
      positions = mapSet(positions, key, vec.size);
    } else {
      distinct = false;
    }
    vec = vecPush(vec, entry);
  }
  const reads = Object.freeze(readFailures.slice());
  const writes = Object.freeze(writeFailures.slice());
  return fileStateSealed({
    files: vec,
    positions,
    distinct,
    readFailureOrder: reads,
    writeFailureOrder: writes,
    readFailures: new Set(reads.map(pathKey)),
    writeFailures: new Set(writes.map(pathKey)),
  });
}

export function externalFileStateFiles(state: ExternalFileState): readonly (readonly [NormalizedPath, FileRecord])[] {
  return Object.freeze(vecToArray(fileStateFields(state).files));
}

export function externalFileStateReadFailures(state: ExternalFileState): readonly NormalizedPath[] {
  return fileStateFields(state).readFailureOrder;
}

export function externalFileStateWriteFailures(state: ExternalFileState): readonly NormalizedPath[] {
  return fileStateFields(state).writeFailureOrder;
}

function stateLookup(state: ExternalFileState, path: NormalizedPath): FileRecord | undefined {
  const fields = fileStateFields(state);
  const position = mapGet(fields.positions, pathKey(path));
  return position === undefined ? undefined : vecGet(fields.files, position)[1];
}

function setFile(state: ExternalFileState, path: NormalizedPath, record: FileRecord): ExternalFileState {
  const fields = fileStateFields(state);
  const key = pathKey(path);
  const position = mapGet(fields.positions, key);
  if (position === undefined) {
    return fileStateSealed({
      ...fields,
      files: vecPush(fields.files, [path, record] as const),
      positions: mapSet(fields.positions, key, fields.files.size),
    });
  }
  if (fields.distinct) {
    return fileStateSealed({ ...fields, files: vecSet(fields.files, position, [vecGet(fields.files, position)[0], record] as const) });
  }
  const files = vecFrom(vecToArray(fields.files).map(([p, r]) => (pathKey(p) === key ? ([p, record] as const) : ([p, r] as const))));
  return fileStateSealed({ ...fields, files });
}

function hasPath(failures: ReadonlySet<string>, path: NormalizedPath): boolean {
  return failures.has(pathKey(path));
}

declare const digestsBrand: unique symbol;
export interface Digests {
  readonly [digestsBrand]: true;
}

type DigestEntry = readonly [ResourceId, ContentDigest];

interface DigestsFields {
  readonly entries: PVec<DigestEntry>;
  readonly positions: PMap<number>;
  readonly distinct: boolean;
}

type DigestsRecord = DigestsFields & Digests;

function digestsFields(digests: Digests): DigestsFields {
  return digests as DigestsRecord;
}

function digestsSealed(fields: DigestsFields): Digests {
  return Object.freeze(fields) as DigestsRecord;
}

export function digestsOf(entries: readonly (readonly [ResourceId, ContentDigest])[]): Digests {
  let vec = vecEmpty<DigestEntry>();
  let positions = mapEmpty<number>();
  let distinct = true;
  for (const entry of entries) {
    const key = resourceKey(entry[0]);
    if (mapGet(positions, key) === undefined) {
      positions = mapSet(positions, key, vec.size);
    } else {
      distinct = false;
    }
    vec = vecPush(vec, entry);
  }
  return digestsSealed({ entries: vec, positions, distinct });
}

export function digestsEntries(digests: Digests): readonly (readonly [ResourceId, ContentDigest])[] {
  return Object.freeze(vecToArray(digestsFields(digests).entries));
}

export interface UnobservedContents {
  readonly resource: ResourceId;
}

export type DigestLookup =
  | { readonly tag: "Found"; readonly digest: ContentDigest }
  | { readonly tag: "Unobserved"; readonly unobserved: UnobservedContents };

export function lookupDigest(digests: Digests, resource: ResourceId): DigestLookup {
  const fields = digestsFields(digests);
  const position = mapGet(fields.positions, resourceKey(resource));
  return position === undefined
    ? Object.freeze({ tag: "Unobserved", unobserved: Object.freeze({ resource }) })
    : Object.freeze({ tag: "Found", digest: vecGet(fields.entries, position)[1] });
}

export function setDigest(digests: Digests, resource: ResourceId, digest: ContentDigest): Digests {
  const fields = digestsFields(digests);
  const key = resourceKey(resource);
  const position = mapGet(fields.positions, key);
  if (position === undefined) {
    return digestsSealed({
      entries: vecPush(fields.entries, [resource, digest] as const),
      positions: mapSet(fields.positions, key, fields.entries.size),
      distinct: fields.distinct,
    });
  }
  if (fields.distinct) {
    return digestsSealed({ ...fields, entries: vecSet(fields.entries, position, [vecGet(fields.entries, position)[0], digest] as const) });
  }
  const entries = vecFrom(vecToArray(fields.entries).map(([r, d]) => (resourceKey(r) === key ? ([r, digest] as const) : ([r, d] as const))));
  return digestsSealed({ ...fields, entries });
}

export interface FileSnapshot {
  readonly path: NormalizedPath;
  readonly contents: readonly number[];
  readonly digest: ContentDigest;
}

export interface ExternalMutation {
  readonly expected: ContentDigest;
  readonly actual: ContentDigest;
}

export interface ReplaceContents {
  readonly newContents: readonly number[];
  readonly newDigest: ContentDigest;
}

function registerResource(
  world: World,
  resource: ResourceId,
  observedAt: bigint
): readonly [Observation<{ readonly value: bigint }>, World] {
  const current = lookup(world, resource);
  if (current.tag === "UnknownResource") {
    const zero = Object.freeze({ value: 0n });
    const world2 = worldAppended(world, resource, zero);
    const basis: Basis = Object.freeze({ resource, revision: zero });
    return [Object.freeze({ payload: zero, basis, observedAt }), world2];
  }
  const basis: Basis = Object.freeze({ resource, revision: current.revision });
  return [Object.freeze({ payload: current.revision, basis, observedAt }), world];
}

export interface TrackReq {
  readonly path: NormalizedPath;
  readonly world: World;
  readonly observedAt: bigint;
}

export interface Tracked {
  readonly observation: Observation<{ readonly value: bigint }>;
  readonly world: World;
}

export type TrackResult = { readonly tag: "Applied"; readonly value: Tracked };

export function track(req: TrackReq): TrackResult {
  const resource = pathResource(req.path);
  const [observation, world] = registerResource(req.world, resource, req.observedAt);
  return Object.freeze({ tag: "Applied", value: Object.freeze({ observation, world }) });
}

export interface ReadReq {
  readonly path: NormalizedPath;
  readonly world: World;
  readonly digests: Digests;
  readonly state: ExternalFileState;
  readonly observedAt: bigint;
}

export interface Read {
  readonly observation: Observation<FileSnapshot>;
  readonly world: World;
  readonly digests: Digests;
}

export interface ReadFailure {
  readonly path: NormalizedPath;
}

export type ReadResult =
  | { readonly tag: "Applied"; readonly value: Read }
  | { readonly tag: "Rejected"; readonly reason: UnknownResource }
  | { readonly tag: "BoundaryFailed"; readonly failure: ReadFailure };

export function read(req: ReadReq): ReadResult {
  if (hasPath(fileStateFields(req.state).readFailures, req.path)) {
    return Object.freeze({ tag: "BoundaryFailed", failure: Object.freeze({ path: req.path }) });
  }
  const resource = pathResource(req.path);
  const record = stateLookup(req.state, req.path);
  if (record === undefined) {
    return Object.freeze({ tag: "Rejected", reason: Object.freeze({ tag: "UnknownResource" as const, resource }) });
  }
  const digests = setDigest(req.digests, resource, record.digest);
  const [observation, world] = registerResource(req.world, resource, req.observedAt);
  const snapshot: FileSnapshot = Object.freeze({ path: req.path, contents: record.bytes, digest: record.digest });
  return Object.freeze({
    tag: "Applied",
    value: Object.freeze({
      observation: Object.freeze({ payload: snapshot, basis: observation.basis, observedAt: observation.observedAt }),
      world,
      digests,
    }),
  });
}

export interface ReplaceReq {
  readonly command: Command<ReplaceContents>;
  readonly path: NormalizedPath;
  readonly world: World;
  readonly digests: Digests;
  readonly state: ExternalFileState;
  readonly observedAt: bigint;
}

export interface Replaced {
  readonly observation: Observation<FileSnapshot>;
  readonly world: World;
  readonly digests: Digests;
  readonly state: ExternalFileState;
}

export interface ResourcePathMismatch {
  readonly resource: ResourceId;
  readonly path: NormalizedPath;
}

export type ReplaceRejection =
  | { readonly tag: "ResourcePathMismatch"; readonly mismatch: ResourcePathMismatch }
  | { readonly tag: "UnknownResource"; readonly unknown: UnknownResource }
  | { readonly tag: "UnobservedContents"; readonly unobserved: UnobservedContents };

export type ReplaceConflict =
  | { readonly tag: "StaleBasis"; readonly staleBasis: StaleBasis }
  | { readonly tag: "ExternalMutation"; readonly mutation: ExternalMutation };

export interface WriteFailure {
  readonly path: NormalizedPath;
}

export type ReplaceResult =
  | { readonly tag: "Applied"; readonly value: Replaced }
  | { readonly tag: "Rejected"; readonly rejection: ReplaceRejection }
  | { readonly tag: "Conflicted"; readonly conflict: ReplaceConflict }
  | { readonly tag: "BoundaryFailed"; readonly failure: WriteFailure };

export function replace(req: ReplaceReq): ReplaceResult {
  const resource = req.command.basis.resource;
  if (!sameResource(resource, pathResource(req.path))) {
    return Object.freeze({
      tag: "Rejected",
      rejection: Object.freeze({ tag: "ResourcePathMismatch", mismatch: Object.freeze({ resource, path: req.path }) }),
    });
  }
  const digestLookup = lookupDigest(req.digests, resource);
  if (digestLookup.tag === "Unobserved") {
    return Object.freeze({ tag: "Rejected", rejection: Object.freeze({ tag: "UnobservedContents", unobserved: digestLookup.unobserved }) });
  }
  const expected = digestLookup.digest;
  const applyOutcome: Outcome<readonly [ReplaceContents, World], UnknownResource, StaleBasis, never> = apply(
    req.world,
    req.command
  );
  if (applyOutcome.tag === "Rejected") {
    return Object.freeze({ tag: "Rejected", rejection: Object.freeze({ tag: "UnknownResource", unknown: applyOutcome.reason }) });
  }
  if (applyOutcome.tag === "Conflicted") {
    return Object.freeze({ tag: "Conflicted", conflict: Object.freeze({ tag: "StaleBasis", staleBasis: applyOutcome.conflict }) });
  }
  if (applyOutcome.tag !== "Applied") {
    throw new Error("unreachable boundary failure");
  }
  const worldAfterBasis = applyOutcome.value[1];
  const current = stateLookup(req.state, req.path);
  if (current === undefined) {
    return Object.freeze({
      tag: "Rejected",
      rejection: Object.freeze({ tag: "UnknownResource", unknown: Object.freeze({ tag: "UnknownResource" as const, resource }) }),
    });
  }
  if (current.digest.value !== expected.value) {
    return Object.freeze({
      tag: "Conflicted",
      conflict: Object.freeze({ tag: "ExternalMutation", mutation: Object.freeze({ expected, actual: current.digest }) }),
    });
  }
  if (hasPath(fileStateFields(req.state).writeFailures, req.path)) {
    return Object.freeze({ tag: "BoundaryFailed", failure: Object.freeze({ path: req.path }) });
  }
  const newContents = req.command.intent.newContents;
  const newDigest = req.command.intent.newDigest;
  const record: FileRecord = Object.freeze({ digest: newDigest, bytes: newContents });
  const state2 = setFile(req.state, req.path, record);
  const digests2 = setDigest(req.digests, resource, newDigest);
  const [observation, world2] = registerResource(worldAfterBasis, resource, req.observedAt);
  const snapshot: FileSnapshot = Object.freeze({ path: req.path, contents: newContents, digest: newDigest });
  return Object.freeze({
    tag: "Applied",
    value: Object.freeze({
      observation: Object.freeze({ payload: snapshot, basis: observation.basis, observedAt: observation.observedAt }),
      world: world2,
      digests: digests2,
      state: state2,
    }),
  });
}
