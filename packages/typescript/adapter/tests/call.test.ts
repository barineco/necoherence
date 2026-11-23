// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { boundaryDiagnosis, deferredOf, immediateOf, io, issue, projectionFailed, requestOf } from "../src/call.js";

interface GreetReq {
  readonly name: string;
}

function greetOutput(req: GreetReq): string {
  return `hello ${req.name}`;
}

describe("io", () => {
  it("outputs when the input is satisfied", () => {
    const greet = immediateOf<GreetReq, string>("test.greet", ["name"], greetOutput);
    const result = io(greet, requestOf({ name: "world" }, ["name"]));
    expect(result).toEqual({ tag: "Ok", value: "hello world" });
  });

  describe("ioProjectsByFieldName", () => {
    it("ignores extra attributes beyond the declared fields", () => {
      const greet = immediateOf<GreetReq, string>("test.greet", ["name"], greetOutput);
      const result = io(greet, requestOf({ name: "world" }, ["name", "extra"]));
      expect(result).toEqual({ tag: "Ok", value: "hello world" });
    });

    it("reports every missing field, not just the first", () => {
      interface TwoFieldReq {
        readonly a: number;
        readonly b: number;
      }
      const both = immediateOf<TwoFieldReq, number>("test.both", ["a", "b"], (req) => req.a + req.b);
      const result = io(both, requestOf({ a: 1, b: 2 }, []));
      expect(result.tag).toBe("Failed");
      if (result.tag === "Failed") {
        expect(result.failure.fields).toEqual(["a", "b"]);
      }
    });

    it("fast-check: io fails exactly when the field set omits a required name", () => {
      fc.assert(
        fc.property(fc.array(fc.string(), { maxLength: 5 }), fc.array(fc.string(), { maxLength: 5 }), (required, present) => {
          const f = immediateOf<Record<string, number>, number>("test.arbitrary", required, () => 0);
          const result = io(f, requestOf({}, present));
          const missing = required.filter((name) => !present.includes(name));
          if (missing.length === 0) {
            expect(result.tag).toBe("Ok");
          } else {
            expect(result.tag).toBe("Failed");
          }
        })
      );
    });
  });
});

describe("issue", () => {
  it("outputs a slot when the input is satisfied", () => {
    const greet = deferredOf<GreetReq, string>("test.greet.deferred", ["name"], greetOutput);
    const result = issue(greet, requestOf({ name: "world" }, ["name"]));
    expect(result).toEqual({ tag: "Ok", value: "hello world" });
  });

  it("fails with the declaration identity when a field is missing", () => {
    const greet = deferredOf<GreetReq, string>("test.greet.deferred", ["name"], greetOutput);
    const result = issue(greet, requestOf({ name: "" }, []));
    expect(result).toEqual({ tag: "Failed", failure: projectionFailed("test.greet.deferred", ["name"]) });
  });
});

describe("boundaryDiagnosis", () => {
  it("carries outbound, expectation, and observed values", () => {
    const diagnosis = boundaryDiagnosis("query", "shape", "seen");
    expect(diagnosis).toEqual({ outbound: "query", expectation: "shape", observed: "seen" });
  });
});
