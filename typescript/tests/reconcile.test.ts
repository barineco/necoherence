// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { bump, commandOf, worldOf, type ResourceId, type World } from "../src/core.js";
import { noBasis, withBasis, type BasisState } from "../src/record.js";
import { applyStore, snapshotStore, worldOfStore } from "../src/store.js";
import { coherent, reconcile } from "../src/reconcile.js";

function rid(kind: string, name: string): ResourceId {
  return { kind, name };
}

function basis(resource: ResourceId, revision: bigint) {
  return { resource, revision: { value: revision } };
}

function world(pairs: readonly (readonly [ResourceId, bigint])[]): World {
  return worldOf(pairs.map(([resource, revision]) => [resource, { value: revision }]));
}

describe("reconcile", () => {
  it("matching history reconciles with no divergence", () => {
    const a = rid("file", "a");
    const bases = [withBasis(basis(a, 3n))];
    const reconciliation = reconcile(bases, world([[a, 3n]]), 0n);

    expect(reconciliation.divergences).toEqual([]);
    expect(coherent(reconciliation)).toBe(true);
  });

  it("one step ahead is coherent", () => {
    const a = rid("file", "a");
    const bases = [withBasis(basis(a, 3n))];
    const reconciliation = reconcile(bases, world([[a, 4n]]), 0n);

    expect(reconciliation.divergences).toEqual([]);
    expect(coherent(reconciliation)).toBe(true);
  });

  it("a detour write through store is seen as world ahead", () => {
    const a = rid("file", "a");
    const storeResult = snapshotStore([[a, { value: 0n }, "payload"]]);
    expect(storeResult.tag).toBe("Accepted");
    if (storeResult.tag !== "Accepted") throw new Error(storeResult.failure.path);
    const store = storeResult.value;
    const observation = { payload: "payload", basis: basis(a, 0n), observedAt: 0n };
    const command = commandOf(observation, "next");
    const outcome = applyStore(store, command);
    expect(outcome.tag).toBe("Applied");
    if (outcome.tag !== "Applied") return;

    const bases: BasisState[] = [withBasis(command.basis)];
    const detouredWorld = bump(worldOfStore(outcome.value[1]), a);
    const reconciliation = reconcile(bases, detouredWorld, 0n);

    expect(reconciliation.divergences).toEqual([{ tag: "WorldAhead", resource: a, recorded: { value: 0n }, actual: { value: 2n } }]);
    expect(coherent(reconciliation)).toBe(false);
  });

  it("world behind the recorded revision is a divergence", () => {
    const a = rid("file", "a");
    const bases = [withBasis(basis(a, 5n))];
    const reconciliation = reconcile(bases, world([[a, 3n]]), 0n);

    expect(reconciliation.divergences).toEqual([{ tag: "WorldBehind", resource: a, recorded: { value: 5n }, actual: { value: 3n } }]);
  });

  it("a resource absent from the world is unknown to world", () => {
    const a = rid("file", "a");
    const bases = [withBasis(basis(a, 1n))];
    const reconciliation = reconcile(bases, world([]), 0n);

    expect(reconciliation.divergences).toEqual([{ tag: "UnknownToWorld", resource: a, recorded: { value: 1n } }]);
  });

  it("a resource in the world but not recorded is not a divergence", () => {
    const a = rid("file", "a");
    const b = rid("file", "b");
    const bases = [withBasis(basis(a, 1n))];
    const reconciliation = reconcile(
      bases,
      world([
        [a, 1n],
        [b, 9n],
      ]),
      0n
    );

    expect(reconciliation.divergences).toEqual([]);
  });

  it("unbased and dropped counts make the reconciliation incoherent", () => {
    const a = rid("file", "a");
    const bases = [withBasis(basis(a, 1n)), noBasis()];
    const reconciliation = reconcile(bases, world([[a, 1n]]), 2n);

    expect(reconciliation.unbased).toBe(1n);
    expect(reconciliation.dropped).toBe(2n);
    expect(coherent(reconciliation)).toBe(false);
  });

  it("divergence order follows first appearance of the resource", () => {
    const a = rid("file", "a");
    const b = rid("file", "b");
    const bases = [withBasis(basis(b, 5n)), withBasis(basis(a, 5n))];
    const reconciliation = reconcile(bases, world([]), 0n);

    expect(reconciliation.divergences).toEqual([
      { tag: "UnknownToWorld", resource: b, recorded: { value: 5n } },
      { tag: "UnknownToWorld", resource: a, recorded: { value: 5n } },
    ]);
  });

  it("fast-check: coherent holds exactly when there are no divergences, unbased, or dropped entries", () => {
    const resourceNames = ["a", "b", "c"];
    const basisArb = fc
      .tuple(fc.constantFrom(...resourceNames), fc.nat({ max: 5 }))
      .map(([name, revision]) => withBasis(basis(rid("file", name), BigInt(revision))));
    fc.assert(
      fc.property(fc.array(fc.oneof(basisArb, fc.constant(noBasis())), { maxLength: 6 }), fc.nat({ max: 3 }), (bases, dropped) => {
        const w = world(resourceNames.map((name) => [rid("file", name), 0n] as const));
        const reconciliation = reconcile(bases, w, BigInt(dropped));
        const expected = reconciliation.divergences.length === 0 && reconciliation.unbased === 0n && reconciliation.dropped === 0n;
        expect(coherent(reconciliation)).toBe(expected);
      })
    );
  });

  it("fast-check: reconcile is independent of input order", () => {
    const resourceNames = ["a", "b", "c"];
    const basisArb = fc
      .tuple(fc.constantFrom(...resourceNames), fc.nat({ max: 5 }))
      .map(([name, revision]) => withBasis(basis(rid("file", name), BigInt(revision))));
    fc.assert(
      fc.property(fc.array(basisArb, { maxLength: 6 }), (bases) => {
        const w = world(resourceNames.map((name) => [rid("file", name), 1n] as const));
        const shuffled = [...bases].reverse();
        const original = reconcile(bases, w, 0n);
        const permuted = reconcile(shuffled, w, 0n);
        const sortKey = (d: { readonly resource: ResourceId }) => `${d.resource.kind}:${d.resource.name}`;
        expect([...original.divergences].sort((x, y) => sortKey(x).localeCompare(sortKey(y)))).toEqual(
          [...permuted.divergences].sort((x, y) => sortKey(x).localeCompare(sortKey(y)))
        );
        expect(original.unbased).toBe(permuted.unbased);
      })
    );
  });
});
