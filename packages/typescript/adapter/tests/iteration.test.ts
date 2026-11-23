// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { immediateOf, requestOf, type Immediate } from "../src/call.js";
import {
  advance,
  closure,
  fold,
  recurse,
  settled,
  type ClosureReq,
  type FoldReq,
  type RecurseReq,
  type StepOutcome,
} from "../src/iteration.js";

describe("fold", () => {
  it("applies the step count times and returns the full trace", () => {
    const step: Immediate<number, number> = immediateOf("test.fold.step", [], (n) => n + 1);
    const req: FoldReq<number> = { step, seed: 0, count: 3n, stepFields: [] };
    const outcome = fold.output(req as unknown as FoldReq<unknown>) as unknown as ReturnType<typeof fold.output>;
    expect(outcome).toEqual({ tag: "FoldTrace", states: [0, 1, 2, 3] });
  });

  it("stops at the first projection failure and reports its position", () => {
    interface Req {
      readonly ready: boolean;
    }
    const step: Immediate<Req, Req> = immediateOf("test.fold.gated", ["ready"], (r) => r);
    const req: FoldReq<Req> = { step, seed: { ready: true }, count: 5n, stepFields: [] };
    const outcome = fold.output(req as unknown as FoldReq<unknown>);
    expect(outcome.tag).toBe("FoldStopped");
    if (outcome.tag === "FoldStopped") {
      expect(outcome.stopped.position).toBe(0n);
    }
  });

  it("fast-check: fold's trace never exceeds count + 1 states", () => {
    fc.assert(
      fc.property(fc.bigInt({ min: 0n, max: 20n }), (count) => {
        const step: Immediate<number, number> = immediateOf("test.fold.inc", [], (n) => n + 1);
        const req: FoldReq<number> = { step, seed: 0, count, stepFields: [] };
        const outcome = fold.output(req as unknown as FoldReq<unknown>);
        if (outcome.tag === "FoldTrace") {
          expect(BigInt(outcome.states.length)).toBeLessThanOrEqual(count + 1n);
        }
      })
    );
  });
});

describe("recurse", () => {
  it("settles once the step reports Settled", () => {
    const step: Immediate<number, StepOutcome<number>> = immediateOf("test.recurse.countdown", [], (n) =>
      n === 0 ? settled(n) : advance(n - 1, BigInt(n))
    );
    const req: RecurseReq<number> = { step, seed: 3, stepFields: [] };
    const outcome = recurse.output(req as unknown as RecurseReq<unknown>);
    expect(outcome).toEqual({ tag: "RecurseSettled", value: 0, steps: 3n });
  });

  it("reports DidNotDecrease when a later measure fails to fall", () => {
    const measures = [5n, 5n];
    let calls = 0;
    const step: Immediate<number, StepOutcome<number>> = immediateOf("test.recurse.flat", [], (n) => {
      const m = measures[calls] ?? 0n;
      calls += 1;
      return advance(n + 1, m);
    });
    const req: RecurseReq<number> = { step, seed: 0, stepFields: [] };
    const outcome = recurse.output(req as unknown as RecurseReq<unknown>);
    expect(outcome.tag).toBe("RecurseDidNotDecrease");
  });

  it("fast-check: a strictly decreasing measure sequence always settles", () => {
    fc.assert(
      fc.property(fc.bigInt({ min: 0n, max: 30n }), (start) => {
        const step: Immediate<bigint, StepOutcome<bigint>> = immediateOf("test.recurse.strict", [], (n) =>
          n === 0n ? settled(n) : advance(n - 1n, n)
        );
        const req: RecurseReq<bigint> = { step, seed: start, stepFields: [] };
        const outcome = recurse.output(req as unknown as RecurseReq<unknown>);
        expect(outcome.tag).toBe("RecurseSettled");
      })
    );
  });
});

describe("closure", () => {
  it("reaches a fixpoint over a finite carrier", () => {
    const carrier = [1, 2, 3, 4];
    const step: Immediate<{ readonly elements: readonly number[] }, readonly number[]> = immediateOf(
      "test.closure.grow",
      [],
      (cs) => {
        const next = new Set(cs.elements);
        for (const e of cs.elements) {
          if (e + 1 <= 4) next.add(e + 1);
        }
        return [...next];
      }
    );
    const req: ClosureReq<number> = { step, carrier, seed: [1], stepFields: [] };
    const outcome = closure.output(req as unknown as ClosureReq<unknown>) as unknown as ReturnType<typeof closure.output>;
    expect(outcome.tag).toBe("ClosureFixpoint");
    if (outcome.tag === "ClosureFixpoint") {
      expect([...outcome.result].sort()).toEqual([1, 2, 3, 4]);
    }
  });

  it("reports a violation when the step leaves the carrier", () => {
    const carrier = [1, 2];
    const step: Immediate<{ readonly elements: readonly number[] }, readonly number[]> = immediateOf(
      "test.closure.escape",
      [],
      () => [1, 2, 99]
    );
    const req: ClosureReq<number> = { step, carrier, seed: [1], stepFields: [] };
    const outcome = closure.output(req as unknown as ClosureReq<unknown>);
    expect(outcome.tag).toBe("ClosureViolation");
  });

  it("fast-check: closure over a fixed finite carrier always halts within carrier length + 1 rounds", () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 8 }), (size) => {
        const carrier = Array.from({ length: size }, (_, i) => i);
        const step: Immediate<{ readonly elements: readonly number[] }, readonly number[]> = immediateOf(
          "test.closure.full",
          [],
          (cs) => {
            const next = new Set(cs.elements);
            const min = Math.min(...cs.elements, size);
            if (min > 0) next.add(min - 1);
            return [...next];
          }
        );
        const req: ClosureReq<number> = { step, carrier, seed: [size - 1], stepFields: [] };
        const outcome = closure.output(req as unknown as ClosureReq<unknown>);
        expect(outcome.tag).toBe("ClosureFixpoint");
        if (outcome.tag === "ClosureFixpoint") {
          expect(outcome.position).toBeLessThanOrEqual(BigInt(size) + 1n);
        }
      })
    );
  });
});
