// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  apply,
  bump,
  commandOf,
  lookup,
  worldEntries,
  worldOf,
  type Command,
  type Observation,
  type ResourceId,
  type World,
} from "../src/core.js";

function rid(name: bigint): ResourceId {
  return { kind: "test", name: String(name) };
}

function world(pairs: readonly (readonly [bigint, bigint])[]): World {
  return worldOf(pairs.map(([resource, revision]) => [rid(resource), { value: revision }]));
}

function command(resource: bigint, revision: bigint, intent: unknown): Command<unknown> {
  return { intent, basis: { resource: rid(resource), revision: { value: revision } } };
}

const nat = fc.bigInt({ min: 0n, max: 1000n });
const worldArb = fc.uniqueArray(nat, { maxLength: 6 }).chain((resources) =>
  fc.tuple(...resources.map(() => nat)).map((revisions) => world(resources.map((r, i) => [r, revisions[i] as bigint] as const)))
);

describe("outcomeClosure", () => {
  it("apply returns exactly one of the three reachable tags", () => {
    fc.assert(
      fc.property(worldArb, nat, nat, (w, resource, revision) => {
        const outcome = apply(w, command(resource, revision, 0));
        expect(["Applied", "Rejected", "Conflicted"]).toContain(outcome.tag);
      })
    );
  });
});

describe("basisRetention", () => {
  it("commandOf keeps the observation's own basis", () => {
    fc.assert(
      fc.property(nat, nat, nat, (resource, revision, observedAt) => {
        const basis = { resource: rid(resource), revision: { value: revision } };
        const observation: Observation<number> = { payload: 1, basis, observedAt };
        const cmd = commandOf(observation, 2);
        expect(cmd.basis).toBe(basis);
      })
    );
  });
});

describe("staleConflict", () => {
  it("apply conflicts exactly when the basis revision disagrees with the current one", () => {
    fc.assert(
      fc.property(nat, nat, nat, (resource, currentRevision, submittedRevision) => {
        const w = world([[resource, currentRevision]]);
        const outcome = apply(w, command(resource, submittedRevision, 0));
        if (submittedRevision === currentRevision) {
          expect(outcome.tag).toBe("Applied");
        } else {
          expect(outcome.tag).toBe("Conflicted");
        }
      })
    );
  });
});

describe("applyDisjointOrderIndependence", () => {
  it("applying two commands on disjoint resources commutes", () => {
    fc.assert(
      fc.property(nat, nat, nat, nat, (a, b, revA, revB) => {
        fc.pre(a !== b);
        const w = world([
          [a, revA],
          [b, revB],
        ]);
        const cmdA = command(a, revA, "a");
        const cmdB = command(b, revB, "b");

        const ab = apply(w, cmdA);
        expect(ab.tag).toBe("Applied");
        if (ab.tag !== "Applied") return;
        const abThenB = apply(ab.value[1], cmdB);

        const ba = apply(w, cmdB);
        expect(ba.tag).toBe("Applied");
        if (ba.tag !== "Applied") return;
        const baThenA = apply(ba.value[1], cmdA);

        expect(abThenB.tag).toBe("Applied");
        expect(baThenA.tag).toBe("Applied");
        if (abThenB.tag === "Applied" && baThenA.tag === "Applied") {
          expect(abThenB.value[1]).toEqual(baThenA.value[1]);
        }
      })
    );
  });
});

describe("locality", () => {
  it("bump only changes the revision of the targeted resource", () => {
    fc.assert(
      fc.property(worldArb, nat, (w, resource) => {
        const before = worldEntries(w);
        const after = bump(w, rid(resource));
        for (const [rid1, rev1] of before) {
          const found = worldEntries(after).find(([rid2]) => rid2.kind === rid1.kind && rid2.name === rid1.name);
          if (found === undefined) continue;
          if (rid1.name === String(resource)) {
            expect(found[1].value).toBe(rev1.value + 1n);
          } else {
            expect(found[1].value).toBe(rev1.value);
          }
        }
      })
    );
  });

  it("lookup on an untouched resource is unaffected by bumping another", () => {
    fc.assert(
      fc.property(worldArb, nat, nat, (w, target, other) => {
        fc.pre(target !== other);
        const before = lookup(w, rid(other));
        const after = lookup(bump(w, rid(target)), rid(other));
        expect(after).toEqual(before);
      })
    );
  });
});

describe("generated update sequences over worlds with repeated resources", () => {
  it("reads and updates the first entry of a repeated resource, as a list model does", () => {
    const small = fc.integer({ min: 0, max: 5 });
    fc.assert(
      fc.property(
        fc.array(fc.tuple(small, small), { maxLength: 12 }),
        fc.array(fc.tuple(fc.boolean(), small), { maxLength: 30 }),
        (initial, updates) => {
          const model: [bigint, bigint][] = initial.map(([resource, revision]) => [BigInt(resource), BigInt(revision)]);
          let w = world(model);
          for (const [useApply, pick] of updates) {
            const index = model.findIndex(([resource]) => resource === BigInt(pick));
            if (useApply) {
              const outcome = apply(w, command(BigInt(pick), index < 0 ? 0n : (model[index] as [bigint, bigint])[1], 0));
              expect(outcome.tag).toBe(index < 0 ? "Rejected" : "Applied");
              if (outcome.tag === "Applied") w = outcome.value[1];
            } else {
              w = bump(w, rid(BigInt(pick)));
            }
            if (index >= 0) (model[index] as [bigint, bigint])[1] += 1n;
            expect(worldEntries(w).map(([id, rev]) => [id.name, rev.value])).toEqual(model.map(([resource, revision]) => [String(resource), revision]));
            const looked = lookup(w, rid(BigInt(pick)));
            expect(looked.tag === "Found" ? looked.revision.value : undefined).toBe(index < 0 ? undefined : (model[index] as [bigint, bigint])[1]);
          }
        }
      )
    );
  });
});
