// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { worldOf, type Command } from "../src/core.js";
import { digestsEntries, digestsOf, externalFileStateFiles, externalFileStateOf, externalFileStateReadFailures, externalFileStateWriteFailures, lookupDigest, normalizePath, read, replace, setDigest, track, type Digests, type ExternalFileState, type ReplaceContents } from "../src/file-effect.js";

const emptyState: ExternalFileState = externalFileStateOf([], [], []);

describe("normalizePath", () => {
  it("drops empty and dot segments and pops on double-dot", () => {
    const p = normalizePath(true, ["a", "", ".", "b", "..", "c"]);
    expect(p).toEqual({ root: true, segments: ["a", "c"] });
  });

  it("fast-check: normalizePath is idempotent", () => {
    fc.assert(
      fc.property(fc.boolean(), fc.array(fc.constantFrom("a", "b", "c", "", ".", "..")), (root, raw) => {
        const once = normalizePath(root, raw);
        const twice = normalizePath(root, once.segments);
        expect(twice).toEqual(once);
      })
    );
  });
});

describe("track", () => {
  it("always applies and registers a fresh path at revision zero", () => {
    const path = normalizePath(true, ["a"]);
    const result = track({ path, world: worldOf([]), observedAt: 0n });
    expect(result.tag).toBe("Applied");
    expect(result.value.observation.payload.value).toBe(0n);
  });
});

describe("read", () => {
  it("rejects an unobserved path", () => {
    const path = normalizePath(true, ["missing"]);
    const result = read({ path, world: worldOf([]), digests: digestsOf([]), state: emptyState, observedAt: 0n });
    expect(result.tag).toBe("Rejected");
  });

  it("boundary-fails on a declared read failure", () => {
    const path = normalizePath(true, ["a"]);
    const state: ExternalFileState = externalFileStateOf([], [path], []);
    const result = read({ path, world: worldOf([]), digests: digestsOf([]), state, observedAt: 0n });
    expect(result.tag).toBe("BoundaryFailed");
  });
});

describe("digests", () => {
  it("setDigest then lookupDigest returns the new digest, for any prior entries", () => {
    fc.assert(
      fc.property(fc.array(fc.tuple(fc.string(), fc.string()), { maxLength: 5 }), fc.string(), fc.string(), (prior, name, digestValue) => {
        const resource = { kind: "file", name };
        const initial = digestsOf(prior.map(([n, d]) => [{ kind: "file", name: n }, { value: d }] as const));
        const digests = setDigest(initial, resource, { value: digestValue });
        const found = lookupDigest(digests, resource);
        expect(found).toEqual({ tag: "Found", digest: { value: digestValue } });
      })
    );
  });
});

describe("replace", () => {
  it("atomically replaces the record once every layer passes", () => {
    const path = normalizePath(true, ["a"]);
    const resource = { kind: "file", name: "/a" };
    const world = worldOf([[resource, { value: 0n }]]);
    const digests = digestsOf([[resource, { value: "old" }] as const]);
    const state: ExternalFileState = externalFileStateOf([[path, { digest: { value: "old" }, bytes: [1, 2, 3] }]], [], []);
    const intent: ReplaceContents = { newContents: [4, 5], newDigest: { value: "new" } };
    const command: Command<ReplaceContents> = { intent, basis: { resource, revision: { value: 0n } } };
    const result = replace({ command, path, world, digests, state, observedAt: 1n });
    expect(result.tag).toBe("Applied");
    if (result.tag === "Applied") {
      expect(externalFileStateFiles(result.value.state)[0]?.[1]).toEqual({ digest: { value: "new" }, bytes: [4, 5] });
    }
  });

  it("conflicts on a stale basis revision", () => {
    const path = normalizePath(true, ["a"]);
    const resource = { kind: "file", name: "/a" };
    const world = worldOf([[resource, { value: 1n }]]);
    const digests = digestsOf([[resource, { value: "old" }] as const]);
    const state: ExternalFileState = externalFileStateOf([[path, { digest: { value: "old" }, bytes: [] }]], [], []);
    const intent: ReplaceContents = { newContents: [], newDigest: { value: "new" } };
    const command: Command<ReplaceContents> = { intent, basis: { resource, revision: { value: 0n } } };
    const result = replace({ command, path, world, digests, state, observedAt: 1n });
    expect(result.tag).toBe("Conflicted");
  });

  it("rejects a resource/path mismatch before touching state", () => {
    const path = normalizePath(true, ["a"]);
    const mismatchedResource = { kind: "file", name: "/other" };
    const intent: ReplaceContents = { newContents: [], newDigest: { value: "new" } };
    const command: Command<ReplaceContents> = { intent, basis: { resource: mismatchedResource, revision: { value: 0n } } };
    const result = replace({ command, path, world: worldOf([]), digests: digestsOf([]), state: emptyState, observedAt: 0n });
    expect(result.tag).toBe("Rejected");
    if (result.tag === "Rejected") expect(result.rejection.tag).toBe("ResourcePathMismatch");
  });
});

describe("opaque file state and digests", () => {
  const path = (name: string) => normalizePath(true, [name]);
  const record = (value: string) => ({ digest: { value }, bytes: [1] });

  it("readers return the ordered parts the state was built from", () => {
    const state = externalFileStateOf([[path("a"), record("1")], [path("b"), record("2")]], [path("r")], [path("w")]);
    expect(externalFileStateFiles(state)).toEqual([[path("a"), record("1")], [path("b"), record("2")]]);
    expect(externalFileStateReadFailures(state)).toEqual([path("r")]);
    expect(externalFileStateWriteFailures(state)).toEqual([path("w")]);
    expect(digestsEntries(digestsOf([[{ kind: "file", name: "/a" }, { value: "d" }]]))).toEqual([[{ kind: "file", name: "/a" }, { value: "d" }]]);
  });

  it("replace appends nothing and updates one file, leaving the given state unchanged", () => {
    const a = path("a");
    const b = path("b");
    const resourceB = { kind: "file", name: "/b" };
    const state = externalFileStateOf([[a, record("1")], [b, record("2")]], [], []);
    const digests = digestsOf([[{ kind: "file", name: "/a" }, { value: "1" }], [resourceB, { value: "2" }]]);
    const world = worldOf([[{ kind: "file", name: "/a" }, { value: 0n }], [resourceB, { value: 0n }]]);
    const command: Command<ReplaceContents> = { intent: { newContents: [9], newDigest: { value: "3" } }, basis: { resource: resourceB, revision: { value: 0n } } };
    const result = replace({ command, path: b, world, digests, state, observedAt: 1n });
    if (result.tag !== "Applied") throw new Error("applied expected");
    expect(externalFileStateFiles(result.value.state)).toEqual([[a, record("1")], [b, { digest: { value: "3" }, bytes: [9] }]]);
    expect(externalFileStateFiles(state)).toEqual([[a, record("1")], [b, record("2")]]);
    expect(digestsEntries(result.value.digests)).toEqual([[{ kind: "file", name: "/a" }, { value: "1" }], [resourceB, { value: "3" }]]);
    expect(digestsEntries(digests)[1]).toEqual([resourceB, { value: "2" }]);
  });

  it("a state built with a repeated path updates every matching entry and finds the first", () => {
    const a = path("a");
    const resource = { kind: "file", name: "/a" };
    const state = externalFileStateOf([[a, record("1")], [a, record("2")]], [], []);
    const digests = digestsOf([[resource, { value: "1" }], [resource, { value: "2" }]]);
    const read1 = read({ path: a, world: worldOf([[resource, { value: 0n }]]), digests, state, observedAt: 0n });
    if (read1.tag !== "Applied") throw new Error("applied expected");
    expect(read1.value.observation.payload.digest).toEqual({ value: "1" });
    expect(digestsEntries(setDigest(digests, resource, { value: "9" }))).toEqual([[resource, { value: "9" }], [resource, { value: "9" }]]);
  });
});

// Test-only host adapter. The exported File effect stays a pure transition.
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";

function hostDigest(bytes: Uint8Array) { return { value: createHash("sha256").update(bytes).digest("hex") }; }
class HostAdapter {
  constructor(readonly root: string, readonly failWrites = false) {}
  path(raw: string) { const host = resolve(raw.startsWith(sep) ? raw : join(this.root, raw)); return normalizePath(true, host.split(sep).filter(Boolean)); }
  host(path: ReturnType<typeof normalizePath>) { return join(sep, ...path.segments); }
  state(path: ReturnType<typeof normalizePath>): ExternalFileState {
    try { const bytes = readFileSync(this.host(path)); return externalFileStateOf([[path, { digest: hostDigest(bytes), bytes: [...bytes] }]], [], []); }
    catch (error: unknown) { return (error as NodeJS.ErrnoException).code === "ENOENT" ? emptyState : externalFileStateOf([], [path], []); }
  }
  replaceHost(command: Command<ReplaceContents>, path: ReturnType<typeof normalizePath>, world: ReturnType<typeof worldOf>, digests: Digests) {
    const state = this.state(path); const result = replace({ command, path, world, digests, state: this.failWrites ? externalFileStateOf(externalFileStateFiles(state), externalFileStateReadFailures(state), [path]) : state, observedAt: 8n });
    if (result.tag !== "Applied") return result;
    const target = this.host(path); const temporary = target + ".necoherence-tmp";
    try { writeFileSync(temporary, Uint8Array.from(result.value.observation.payload.contents)); renameSync(temporary, target); return result; }
    catch { return { tag: "BoundaryFailed" as const, failure: { path } }; }
  }
}

describe("host File effect adapter", () => {
  it("generates all real-host states with coverage assertions", () => {
    const root = mkdtempSync(join(tmpdir(), "necoherence-file-"));
    try {
      mkdirSync(join(root, "nested")); const target = join(root, "nested", "item"); writeFileSync(target, "before");
      const adapter = new HostAdapter(root); const path = adapter.path("nested/item");
      expect(path).toEqual(adapter.path(target)); expect(path).toEqual(adapter.path("nested/x/../item"));
      const coverage = new Set(["paths"]);
      const tracked = track({ path, world: worldOf([]), observedAt: 0n });
      const observed = read({ path, world: tracked.value.world, digests: digestsOf([]), state: adapter.state(path), observedAt: 1n });
      if (observed.tag !== "Applied") throw new Error("read"); coverage.add("registered");
      expect(read({ path: adapter.path("missing"), world: worldOf([]), digests: digestsOf([]), state: emptyState, observedAt: 2n }).tag).toBe("Rejected"); coverage.add("missing");
      const onlyTracked = track({ path, world: worldOf([]), observedAt: 3n });
      expect(adapter.replaceHost({ intent: { newContents: [1], newDigest: { value: "x" } }, basis: onlyTracked.value.observation.basis }, path, onlyTracked.value.world, digestsOf([])).tag).toBe("Rejected"); coverage.add("unobserved");
      writeFileSync(target, "changed");
      expect(adapter.replaceHost({ intent: { newContents: [2], newDigest: { value: "new" } }, basis: observed.value.observation.basis }, path, observed.value.world, observed.value.digests).tag).toBe("Conflicted"); coverage.add("changed");
      const current = read({ path, world: observed.value.world, digests: observed.value.digests, state: adapter.state(path), observedAt: 6n }); if (current.tag !== "Applied") throw new Error("read");
      expect(new HostAdapter(root, true).replaceHost({ intent: { newContents: [3], newDigest: { value: "blocked" } }, basis: current.value.observation.basis }, path, current.value.world, current.value.digests).tag).toBe("BoundaryFailed"); coverage.add("write-failure");
      expect(adapter.replaceHost({ intent: { newContents: [4], newDigest: { value: "atomic" } }, basis: current.value.observation.basis }, path, current.value.world, current.value.digests).tag).toBe("Applied"); expect(readFileSync(target)).toEqual(Buffer.from([4])); coverage.add("atomic");
      expect(coverage).toEqual(new Set(["paths", "registered", "missing", "unobserved", "changed", "write-failure", "atomic"]));
    } finally { rmSync(root, { recursive: true, force: true }); }
  });
});
