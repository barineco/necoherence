// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { capacity, consumed, positiveLimit, reprocess, step, type Consumption } from "../src/transition.js";

describe("step", () => {
  it("settles on the first consumed decision", () => {
    const advance = (state: number): Consumption<number, number> => consumed(state + 1, [state]);
    const limit = positiveLimit(5n);
    const cap = capacity(10n);
    if (!("kind" in limit) || !("kind" in cap)) throw new Error("invalid bounds");
    const result = step(0, "input", advance, limit, cap);
    expect(result).toEqual({ tag: "Settled", state: 1, outputs: [0], applications: 1n });
  });

  it("exhausts the reprocess limit when it never consumes", () => {
    const advance = (state: number): Consumption<number, number> => reprocess(state, []);
    const limit = positiveLimit(3n);
    const cap = capacity(10n);
    if (!("kind" in limit) || !("kind" in cap)) throw new Error("invalid bounds");
    const result = step(0, "input", advance, limit, cap);
    expect(result).toEqual({ tag: "Failed", state: 0, outputs: [], failure: { tag: "ReprocessLimitExhausted", applications: 3n } });
  });

  it("fails when accumulated outputs exceed capacity", () => {
    const advance = (state: number): Consumption<number, number> => consumed(state, [1, 2, 3]);
    const limit = positiveLimit(1n);
    const cap = capacity(2n);
    if (!("kind" in limit) || !("kind" in cap)) throw new Error("invalid bounds");
    const result = step(0, "input", advance, limit, cap);
    expect(result.tag).toBe("Failed");
    if (result.tag === "Failed") expect(result.failure).toEqual({ tag: "CapacityExceeded", capacity: 2n, attempted: 3n });
  });

  it("rejects a non-positive limit", () => {
    const result = positiveLimit(0n);
    expect("tag" in result).toBe(true);
  });

  it("rejects a negative capacity", () => {
    const result = capacity(-1n);
    expect("tag" in result).toBe(true);
  });

  it("fast-check: a settled result never exceeds its declared capacity", () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 5 }), fc.integer({ min: 0, max: 5 }), (limitN, capN) => {
        const advance = (s: number): Consumption<number, number> => consumed(s, Array.from({ length: capN }, (_, i) => i));
        const limit = positiveLimit(BigInt(limitN));
        const cap = capacity(BigInt(capN));
        if (!("kind" in limit) || !("kind" in cap)) return;
        const result = step(0, "in", advance, limit, cap);
        if (result.tag === "Settled") {
          expect(BigInt(result.outputs.length)).toBeLessThanOrEqual(cap.value);
        }
      })
    );
  });
});
