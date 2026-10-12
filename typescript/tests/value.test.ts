// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import {
  applyStore,
  foreignHandle,
  observe,
  snapshotStore,
  snapshotValue,
  storeEntries,
  worldOfStore,
} from "../src/index.js";

function accepted<A>(result: { readonly tag: string; readonly value?: A }): A {
  expect(result.tag).toBe("Accepted");
  if (result.tag !== "Accepted") throw new Error("expected Accepted");
  return result.value as A;
}

describe("owned value admission", () => {
  it("cuts payload, resource, and revision aliases", () => {
    const payload = { nested: { value: 1n }, list: ["before"] };
    const resource = { kind: "file", name: "a" };
    const revision = { value: 2n };
    const store = accepted(snapshotStore([[resource, revision, payload]]));

    payload.nested.value = 9n;
    payload.list[0] = "after";
    resource.name = "changed";
    revision.value = 8n;

    expect(storeEntries(store)).toEqual([
      {
        resource: { kind: "file", name: "a" },
        revision: { value: 2n },
        payload: { nested: { value: 1n }, list: ["before"] },
      },
    ]);
    const observed = observe(store, { kind: "file", name: "a" });
    expect(observed).toEqual({
      tag: "Found",
      revision: { value: 2n },
      payload: { nested: { value: 1n }, list: ["before"] },
    });

    if (observed.tag === "Found") {
      expect(() => {
        (observed.payload as { nested: { value: bigint } }).nested.value = 12n;
      }).toThrow();
    }
    expect(storeEntries(store)[0]?.payload).toEqual({
      nested: { value: 1n },
      list: ["before"],
    });
  });

  it("classifies the closed grammar and explicit foreign handles", () => {
    const getter = {} as { readonly value: bigint };
    Object.defineProperty(getter, "value", { get: () => 1n });
    const proxy = new Proxy({ value: 1n }, { get: () => { throw new Error("proxy read"); } });
    const cycle: { self?: unknown } = {};
    cycle.self = cycle;

    for (const input of [new Map(), new Set(), new Date(), undefined, 1, Symbol("x"), () => 1, cycle]) {
      const result = snapshotValue(input);
      expect(result.tag).toBe("Rejected");
      if (result.tag === "Rejected") expect(result.failure.type).toBe("ValueFailure");
    }
    expect(snapshotValue(getter).tag).toBe("Rejected");
    expect(snapshotValue(proxy).tag).toBe("Rejected");

    const foreign = snapshotValue(foreignHandle({ external: true }, 4n));
    expect(foreign.tag).toBe("Foreign");
    if (foreign.tag === "Foreign") {
      expect(foreign.observedAt).toBe(4n);
      expect(foreign.capability).toEqual({ external: true });
    }
  });

  it("rejects later entry failures without publishing a partial Store", () => {
    const failing = {} as { readonly value: bigint };
    Object.defineProperty(failing, "value", { get: () => { throw new Error("read failed"); } });
    const result = snapshotStore<unknown>([
      [{ kind: "file", name: "good" }, { value: 0n }, "good"],
      [{ kind: "file", name: "bad" }, { value: 0n }, failing],
    ]);

    expect(result.tag).toBe("Rejected");
    if (result.tag === "Rejected") {
      expect(result.failure.path).toBe("$[1].payload.value");
      expect(result.failure.contributingFailures).toHaveLength(1);
    }
  });

  it("separates structured identity and version failures", () => {
    const distinct = snapshotStore([
      [{ kind: "a:b", name: "c" }, { value: 0n }, "first"],
      [{ kind: "a", name: "b:c" }, { value: 0n }, "second"],
    ]);
    expect(distinct.tag).toBe("Accepted");

    const duplicate = snapshotStore([
      [{ kind: "file", name: "a" }, { value: 0n }, "first"],
      [{ kind: "file", name: "a" }, { value: 1n }, "second"],
    ]);
    expect(duplicate.tag).toBe("Rejected");
    if (duplicate.tag === "Rejected") expect(duplicate.failure.tag).toBe("DuplicateResource");

    const revision = { value: 0n };
    const alias = snapshotStore([
      [{ kind: "file", name: "a" }, revision, "first"],
      [{ kind: "file", name: "b" }, revision, "second"],
    ]);
    expect(alias.tag).toBe("Rejected");
    if (alias.tag === "Rejected") expect(alias.failure.tag).toBe("RevisionAlias");

    const negative = snapshotStore([[{ kind: "file", name: "a" }, { value: -1n }, "bad"]]);
    expect(negative.tag).toBe("Rejected");
    if (negative.tag === "Rejected") expect(negative.failure.tag).toBe("InvalidRevision");
  });

  it("keeps Store and World projection branches aligned", () => {
    const store = accepted(snapshotStore([[{ kind: "file", name: "a" }, { value: 0n }, "payload"]]));
    const basis = { resource: { kind: "file", name: "a" }, revision: { value: 0n } };
    const applied = applyStore(store, { intent: "next", basis });
    expect(applied.tag).toBe("Applied");
    if (applied.tag === "Applied") expect(worldOfStore(applied.value[1])).toEqual({ entries: [[{ kind: "file", name: "a" }, { value: 1n }]] });

    const reused = applyStore(store, { intent: "reuse", basis: { resource: store.entries[0]!.resource, revision: store.entries[0]!.revision } });
    expect(reused.tag).toBe("BoundaryFailed");
    if (reused.tag === "BoundaryFailed") expect(reused.failure.tag).toBe("RevisionReuse");
  });
});
