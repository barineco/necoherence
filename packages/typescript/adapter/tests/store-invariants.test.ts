// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { applyStore, observe, snapshotStore, storeEntries, worldOfStore } from "../src/store.js";
import { lookup, worldEntries } from "../src/core.js";

const resource = (index: number) => ({ kind: "k", name: `r${index}` });

describe("store after generated update sequences", () => {
  it("agrees with a reference model on payloads and revisions, and keeps the entry order", () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 40 }),
        fc.array(fc.record({ pick: fc.nat(60), stale: fc.boolean() }), { maxLength: 80 }),
        (size, updates) => {
          const admitted = snapshotStore<string>(Array.from({ length: size }, (_, index) => [resource(index), { value: 0n }, `initial-${index}`] as const));
          if (admitted.tag !== "Accepted") throw new Error("store rejected");
          let store = admitted.value;
          const revisions = new Map<number, bigint>(Array.from({ length: size }, (_, index) => [index, 0n]));
          const payloads = new Map<number, string>(Array.from({ length: size }, (_, index) => [index, `initial-${index}`]));
          updates.forEach((update, step) => {
            const target = update.pick % (size + 5);
            const known = revisions.get(target);
            const basisRevision = known === undefined ? 0n : update.stale ? known + 1n : known;
            const outcome = applyStore(store, { intent: `step-${step}`, basis: { resource: resource(target), revision: { value: basisRevision } } });
            if (known === undefined) expect(outcome.tag).toBe("Rejected");
            else if (update.stale) expect(outcome.tag).toBe("Conflicted");
            else {
              expect(outcome.tag).toBe("Applied");
              if (outcome.tag === "Applied") store = outcome.value[1];
              revisions.set(target, known + 1n);
              payloads.set(target, `step-${step}`);
            }
          });
          const entries = storeEntries(store);
          expect(entries.map((entry) => entry.resource.name)).toEqual(Array.from({ length: size }, (_, index) => `r${index}`));
          for (let index = 0; index < size; index += 1) {
            const seen = observe(store, resource(index));
            expect(seen.tag).toBe("Found");
            if (seen.tag === "Found") {
              expect(seen.revision.value).toBe(revisions.get(index));
              expect(seen.payload).toBe(payloads.get(index));
            }
            const found = lookup(worldOfStore(store), resource(index));
            expect(found.tag === "Found" && found.revision.value).toBe(revisions.get(index));
          }
          expect(worldEntries(worldOfStore(store)).map(([id]) => id.name)).toEqual(entries.map((entry) => entry.resource.name));
        }
      )
    );
  });
});
