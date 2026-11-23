// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

const BITS = 5;
const WIDTH = 32;
const MASK = 31;

export interface PVec<T> {
  readonly size: number;
  readonly shift: number;
  readonly root: readonly unknown[];
  readonly tail: readonly T[];
}

const emptyNode: readonly unknown[] = Object.freeze([]);

export function vecEmpty<T>(): PVec<T> {
  return Object.freeze({ size: 0, shift: BITS, root: emptyNode, tail: Object.freeze([]) as readonly T[] });
}

function tailOffset(size: number): number {
  return size < WIDTH ? 0 : ((size - 1) >>> BITS) << BITS;
}

export function vecGet<T>(vec: PVec<T>, index: number): T {
  if (index >= tailOffset(vec.size)) return vec.tail[index & MASK] as T;
  let node = vec.root;
  for (let level = vec.shift; level > 0; level -= BITS) {
    node = node[(index >>> level) & MASK] as readonly unknown[];
  }
  return node[index & MASK] as T;
}

export function vecSet<T>(vec: PVec<T>, index: number, value: T): PVec<T> {
  if (index >= tailOffset(vec.size)) {
    const tail = vec.tail.slice();
    tail[index & MASK] = value;
    return Object.freeze({ size: vec.size, shift: vec.shift, root: vec.root, tail });
  }
  const root = vec.root.slice();
  let node = root;
  for (let level = vec.shift; level > 0; level -= BITS) {
    const slot = (index >>> level) & MASK;
    const child = (node[slot] as unknown[]).slice();
    node[slot] = child;
    node = child;
  }
  node[index & MASK] = value;
  return Object.freeze({ size: vec.size, shift: vec.shift, root, tail: vec.tail });
}

function newPath(level: number, node: readonly unknown[]): readonly unknown[] {
  return level === 0 ? node : [newPath(level - BITS, node)];
}

function pushTail(size: number, level: number, parent: readonly unknown[], tailNode: readonly unknown[]): readonly unknown[] {
  const slot = ((size - 1) >>> level) & MASK;
  const copy = parent.slice();
  if (level === BITS) {
    copy[slot] = tailNode;
  } else {
    const child = parent[slot] as readonly unknown[] | undefined;
    copy[slot] = child !== undefined ? pushTail(size, level - BITS, child, tailNode) : newPath(level - BITS, tailNode);
  }
  return copy;
}

export function vecPush<T>(vec: PVec<T>, value: T): PVec<T> {
  if (vec.tail.length < WIDTH) {
    const tail = vec.tail.slice();
    tail.push(value);
    return Object.freeze({ size: vec.size + 1, shift: vec.shift, root: vec.root, tail });
  }
  let root: readonly unknown[];
  let shift = vec.shift;
  if (vec.size >>> BITS > 1 << vec.shift) {
    root = [vec.root, newPath(vec.shift, vec.tail)];
    shift += BITS;
  } else {
    root = pushTail(vec.size, vec.shift, vec.root, vec.tail);
  }
  return Object.freeze({ size: vec.size + 1, shift, root, tail: Object.freeze([value]) as readonly T[] });
}

export function vecToArray<T>(vec: PVec<T>): T[] {
  const out: T[] = [];
  for (let index = 0; index < vec.size; index += WIDTH) {
    let node = vec.root;
    if (index >= tailOffset(vec.size)) {
      for (const item of vec.tail) out.push(item);
      break;
    }
    for (let level = vec.shift; level > 0; level -= BITS) {
      node = node[(index >>> level) & MASK] as readonly unknown[];
    }
    for (const item of node) out.push(item as T);
  }
  return out;
}

export function vecFrom<T>(items: readonly T[]): PVec<T> {
  let vec = vecEmpty<T>();
  for (const item of items) vec = vecPush(vec, item);
  return vec;
}

interface MapLeaf<V> {
  readonly hash: number;
  readonly pairs: readonly (readonly [string, V])[];
}

type MapSlot<V> = undefined | MapLeaf<V> | readonly MapSlot<V>[];

export interface PMap<V> {
  readonly root: readonly MapSlot<V>[];
}

function hashOf(key: string): number {
  let hash = 0x811c9dc5;
  for (let index = 0; index < key.length; index += 1) {
    hash ^= key.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

export function mapEmpty<V>(): PMap<V> {
  return Object.freeze({ root: Object.freeze(new Array<MapSlot<V>>(WIDTH).fill(undefined)) });
}

export function mapGet<V>(map: PMap<V>, key: string): V | undefined {
  const hash = hashOf(key);
  let node: readonly MapSlot<V>[] = map.root;
  for (let shift = 0; shift < 35; shift += BITS) {
    const slot: MapSlot<V> = node[(hash >>> shift) & MASK];
    if (slot === undefined) return undefined;
    if (Array.isArray(slot)) {
      node = slot as readonly MapSlot<V>[];
      continue;
    }
    const leaf = slot as MapLeaf<V>;
    if (leaf.hash !== hash) return undefined;
    for (const pair of leaf.pairs) if (pair[0] === key) return pair[1];
    return undefined;
  }
  return undefined;
}

function splitLeaves<V>(first: MapLeaf<V>, second: MapLeaf<V>, shift: number): readonly MapSlot<V>[] {
  const node = new Array<MapSlot<V>>(WIDTH).fill(undefined);
  const firstSlot = (first.hash >>> shift) & MASK;
  const secondSlot = (second.hash >>> shift) & MASK;
  if (firstSlot === secondSlot) {
    node[firstSlot] = splitLeaves(first, second, shift + BITS);
  } else {
    node[firstSlot] = first;
    node[secondSlot] = second;
  }
  return node;
}

function setIn<V>(node: readonly MapSlot<V>[], shift: number, hash: number, key: string, value: V): readonly MapSlot<V>[] {
  const index = (hash >>> shift) & MASK;
  const copy = node.slice();
  const slot = node[index];
  if (slot === undefined) {
    copy[index] = { hash, pairs: [[key, value]] };
  } else if (Array.isArray(slot)) {
    copy[index] = setIn(slot as readonly MapSlot<V>[], shift + BITS, hash, key, value);
  } else {
    const leaf = slot as MapLeaf<V>;
    if (leaf.hash === hash) {
      const pairs = leaf.pairs.filter((pair) => pair[0] !== key);
      pairs.push([key, value]);
      copy[index] = { hash, pairs };
    } else {
      copy[index] = splitLeaves(leaf, { hash, pairs: [[key, value]] }, shift + BITS);
    }
  }
  return copy;
}

export function mapSet<V>(map: PMap<V>, key: string, value: V): PMap<V> {
  return Object.freeze({ root: setIn(map.root, 0, hashOf(key), key, value) });
}

interface SetNode {
  readonly bits: number;
  readonly kids: readonly (SetNode | undefined)[];
}

export interface PIntSet {
  readonly height: number;
  readonly root: SetNode | undefined;
}

const noKids: readonly (SetNode | undefined)[] = Object.freeze([]);

export const setEmpty: PIntSet = Object.freeze({ height: 0, root: undefined });

function insertAt(node: SetNode | undefined, level: number, value: number): SetNode {
  const slot = Math.floor(value / 2 ** (BITS * level)) & MASK;
  const bits = (node === undefined ? 0 : node.bits) | (1 << slot);
  if (level === 0) return { bits, kids: noKids };
  const kids = node === undefined ? [] : node.kids.slice();
  kids[slot] = insertAt(kids[slot], level - 1, value);
  return { bits, kids };
}

function removeAt(node: SetNode | undefined, level: number, value: number): SetNode | undefined {
  if (node === undefined) return undefined;
  const slot = Math.floor(value / 2 ** (BITS * level)) & MASK;
  if ((node.bits & (1 << slot)) === 0) return node;
  if (level === 0) {
    const bits = node.bits & ~(1 << slot);
    return bits === 0 ? undefined : { bits, kids: noKids };
  }
  const child = removeAt(node.kids[slot], level - 1, value);
  const kids = node.kids.slice();
  kids[slot] = child;
  const bits = child === undefined ? node.bits & ~(1 << slot) : node.bits;
  return bits === 0 ? undefined : { bits, kids };
}

export function setInsert(set: PIntSet, value: number): PIntSet {
  let height = set.height;
  let root = set.root;
  while (value >= 2 ** (BITS * (height + 1))) {
    root = root === undefined ? undefined : { bits: 1, kids: [root] };
    height += 1;
  }
  return Object.freeze({ height, root: insertAt(root, height, value) });
}

export function setRemove(set: PIntSet, value: number): PIntSet {
  if (value >= 2 ** (BITS * (set.height + 1))) return set;
  return Object.freeze({ height: set.height, root: removeAt(set.root, set.height, value) });
}

export function setMin(set: PIntSet): number | undefined {
  let node = set.root;
  if (node === undefined) return undefined;
  let value = 0;
  for (let level = set.height; level >= 0; level -= 1) {
    const slot = 31 - Math.clz32(node.bits & -node.bits);
    value += slot * 2 ** (BITS * level);
    if (level === 0) return value;
    node = node.kids[slot] as SetNode;
  }
  return value;
}

function collect(node: SetNode, level: number, base: number, out: number[]): void {
  for (let slot = 0; slot < WIDTH; slot += 1) {
    if ((node.bits & (1 << slot)) === 0) continue;
    const offset = base + slot * 2 ** (BITS * level);
    if (level === 0) out.push(offset);
    else collect(node.kids[slot] as SetNode, level - 1, offset, out);
  }
}

export function setToArray(set: PIntSet): number[] {
  const out: number[] = [];
  if (set.root !== undefined) collect(set.root, set.height, 0, out);
  return out;
}

export function pairKey(first: string, second: string): string {
  return `${first.length}:${first}${second.length}:${second}`;
}
