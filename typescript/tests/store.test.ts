// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { apply as worldApply, lookup, type Command, type ResourceId, type Revision } from "../src/core.js";
import { applyStore, observe, snapshotStore, storeEntries, worldOfStore } from "../src/store.js";

function rid(name: bigint): ResourceId {
  return { kind: "store", name: String(name) };
}

function rev(value: bigint): Revision {
  return { value };
}

function basis(resource: bigint, revision: bigint) {
  return { resource: rid(resource), revision: rev(revision) };
}

function one(resource: bigint, revision: bigint, payload: string) {
  const result = snapshotStore([[rid(resource), rev(revision), payload]]);
  expect(result.tag).toBe("Accepted");
  if (result.tag !== "Accepted") throw new Error(result.failure.path);
  return result.value;
}

const nat = fc.bigInt({ min: 0n, max: 1000n });

describe("store", () => {
  it("observe does not change the store", () => {
    const store = one(0n, 3n, "alpha");
    const before = worldOfStore(store);
    observe(store, rid(0n));
    expect(worldOfStore(store)).toEqual(before);
    expect(storeEntries(store)).toEqual(store.entries);
  });

  it("observe projects to the same lookup as worldOfStore", () => {
    fc.assert(
      fc.property(nat, nat, nat, (resource, revision, other) => {
        const store = one(resource, revision, "payload");
        const observed = observe(store, rid(other));
        const looked = lookup(worldOfStore(store), rid(other));
        if (observed.tag === "Found") {
          expect(looked.tag).toBe("Found");
          if (looked.tag === "Found") expect(looked.revision).toEqual(observed.revision);
        } else {
          expect(looked.tag).toBe("UnknownResource");
        }
      })
    );
  });

  it("apply commutes with World.apply through worldOfStore", () => {
    fc.assert(
      fc.property(nat, nat, (resource, revision) => {
        const store = one(resource, revision, "payload");
        const command: Command<string> = { intent: "next", basis: basis(resource, revision) };
        const storeOutcome = applyStore(store, command);
        const worldOutcome = worldApply(worldOfStore(store), command);
        expect(storeOutcome.tag).toBe(worldOutcome.tag);
        if (storeOutcome.tag === "Applied" && worldOutcome.tag === "Applied") {
          expect(worldOfStore(storeOutcome.value[1])).toEqual(worldOutcome.value[1]);
        }
      })
    );
  });

  it("apply with a basis revision above the store revision is conflicted", () => {
    const store = one(0n, 0n, "payload");
    const outcome = applyStore(store, { intent: "next", basis: basis(0n, 9n) });
    expect(outcome.tag).toBe("Conflicted");
    if (outcome.tag !== "Conflicted") return;
    expect(outcome.conflict.expected).toEqual(rev(9n));
    expect(outcome.conflict.actual).toEqual(rev(0n));
  });
});
