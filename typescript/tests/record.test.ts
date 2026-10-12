// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import type { ResourceId } from "../src/core.js";
import { hasEdge, recordOf, recordOnBasis } from "../src/record.js";

function rid(name: bigint): ResourceId {
  return { kind: "core", name: String(name) };
}

function basis(resource: bigint, revision: bigint) {
  return { resource: rid(resource), revision: { value: revision } };
}

const nat = fc.bigInt({ min: 0n, max: 1000n });

describe("record", () => {
  it("holds declaration, input, and product", () => {
    const held = recordOf("example.greet", "world", "hello world");
    expect(held.declaration).toBe("example.greet");
    expect(held.input).toBe("world");
    expect(held.product).toBe("hello world");
    expect(held.basis).toEqual({ tag: "NoBasis" });
  });

  it("recordOnBasis carries the supplied basis", () => {
    fc.assert(
      fc.property(nat, nat, (resource, revision) => {
        const b = basis(resource, revision);
        const held = recordOnBasis("example.write", "in", "out", b);
        expect(held.basis).toEqual({ tag: "WithBasis", basis: b });
      })
    );
  });

  it("hasEdge is false whenever either record has no basis", () => {
    const noBasisRecord = recordOf("a", 1, 2);
    const withBasisRecord = recordOnBasis("b", 1, 2, basis(0n, 0n));
    expect(hasEdge(noBasisRecord, withBasisRecord)).toBe(false);
    expect(hasEdge(withBasisRecord, noBasisRecord)).toBe(false);
  });

  it("hasEdge holds exactly when both records share the same resource", () => {
    fc.assert(
      fc.property(nat, nat, nat, nat, (resourceA, revisionA, resourceB, revisionB) => {
        const earlier = recordOnBasis("a", 1, 2, basis(resourceA, revisionA));
        const later = recordOnBasis("b", 1, 2, basis(resourceB, revisionB));
        expect(hasEdge(earlier, later)).toBe(resourceA === resourceB);
      })
    );
  });
});
