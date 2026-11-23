// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  mapEmpty,
  mapGet,
  mapSet,
  setEmpty,
  setInsert,
  setMin,
  setRemove,
  setToArray,
  vecEmpty,
  vecGet,
  vecPush,
  vecSet,
  vecToArray,
} from "../src/persistent.js";

describe("persistent vector", () => {
  it("matches an array under pushes and replacements across three trie levels", () => {
    let vec = vecEmpty<number>();
    const reference: number[] = [];
    const snapshots: { vec: typeof vec; copy: number[] }[] = [];
    for (let index = 0; index < 34000; index += 1) {
      vec = vecPush(vec, index);
      reference.push(index);
      if (index % 997 === 0) snapshots.push({ vec, copy: [...reference] });
      if (index % 7 === 3) {
        const target = (index * 31) % reference.length;
        vec = vecSet(vec, target, -index);
        reference[target] = -index;
      }
    }
    expect(vecToArray(vec)).toEqual(reference);
    for (let index = 0; index < reference.length; index += 211) {
      expect(vecGet(vec, index)).toBe(reference[index]);
    }
    for (const { vec: older, copy } of snapshots) {
      expect(vecToArray(older)).toEqual(copy);
    }
  });
});

describe("persistent map", () => {
  it("matches a Map for string keys and keeps earlier versions", () => {
    fc.assert(
      fc.property(fc.array(fc.tuple(fc.string(), fc.integer()), { maxLength: 300 }), (pairs) => {
        let map = mapEmpty<number>();
        const reference = new Map<string, number>();
        const versions: { map: typeof map; copy: Map<string, number> }[] = [];
        for (const [key, value] of pairs) {
          map = mapSet(map, key, value);
          reference.set(key, value);
          versions.push({ map, copy: new Map(reference) });
        }
        for (const { map: version, copy } of versions) {
          for (const [key, value] of copy) expect(mapGet(version, key)).toBe(value);
        }
        expect(mapGet(map, "\u0000absent")).toBeUndefined();
      })
    );
  });

  it("separates keys that share a long common prefix", () => {
    let map = mapEmpty<number>();
    for (let index = 0; index < 5000; index += 1) map = mapSet(map, `key-${index}`, index);
    for (let index = 0; index < 5000; index += 1) expect(mapGet(map, `key-${index}`)).toBe(index);
  });
});

describe("persistent integer set", () => {
  it("matches a Set for insertions, removals and the minimum", () => {
    fc.assert(
      fc.property(
        fc.array(fc.tuple(fc.boolean(), fc.integer({ min: 0, max: 100000 })), { maxLength: 400 }),
        (operations) => {
          let set = setEmpty;
          const reference = new Set<number>();
          for (const [insert, value] of operations) {
            set = insert ? setInsert(set, value) : setRemove(set, value);
            if (insert) reference.add(value);
            else reference.delete(value);
            const sorted = [...reference].sort((a, b) => a - b);
            expect(setMin(set)).toBe(sorted[0]);
          }
          expect(setToArray(set)).toEqual([...reference].sort((a, b) => a - b));
        }
      )
    );
  });
});
