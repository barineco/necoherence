// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { runLine } from "./ts_runner.mts";

const logical = { kind: "generated", provenance: "runtime", revision: 0 };
const attempt = { logical, ordinal: 0 };
const configuration = {
  requestBodyLimit: 256,
  responseBodyLimit: 256,
  cancellation: null,
  monotonicClock: null,
};
const instruction = {
  method: "GET",
  target: "http://127.0.0.1/",
  headers: [{ name: "x-a", value: [1] }],
  body: [0, 255],
};

function invoke(value: unknown): Record<string, unknown> {
  return JSON.parse(runLine(JSON.stringify(value))) as Record<string, unknown>;
}

function matchObject(actual: unknown, expected: unknown, path = "$"): void {
  if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), `${path}: array expected`);
    assert.strictEqual(actual.length, expected.length, `${path}: length`);
    expected.forEach((item, index) => matchObject(actual[index], item, `${path}[${index}]`));
    return;
  }
  if (expected !== null && typeof expected === "object") {
    assert.ok(actual !== null && typeof actual === "object" && !Array.isArray(actual), `${path}: object expected`);
    for (const [key, value] of Object.entries(expected)) {
      assert.ok(Object.prototype.hasOwnProperty.call(actual, key), `${path}.${key}: missing`);
      matchObject((actual as Record<string, unknown>)[key], value, `${path}.${key}`);
    }
    return;
  }
  assert.strictEqual(actual, expected, path);
}

describe("network effect runner schema", () => {
  it("decodes byte arrays without changing their numeric domain", () => {
    const result = invoke({
      operation: "prepare",
      state: { attempts: [] },
      input: { attempt, instruction, deadline: null, configuration },
    });

    assert.strictEqual(result.result, "Prepared");
    matchObject(result, {
      prepared: { input: { instruction } },
    });
  });

  it("keeps request provenance scalar inside recorded observations", () => {
    const recordedObservation = {
      tag: "ResponseObservation",
      attempt,
      handle: { value: "unrecorded" },
      sourceSequence: null,
      response: { status: 200, headers: [], body: [] },
      provenance: { tag: "WireObserved" },
      effect: { tag: "Unknown", reason: { tag: "NoResponse" } },
    };
    const state = {
      attempts: [{
        input: { attempt, instruction, deadline: null, configuration },
        chain: { tag: "Root" },
        disposition: { tag: "Prepared" },
        firstDelivery: { delivery: 2, observation: recordedObservation },
        late: [],
      }],
    };
    const result = invoke({ operation: "readNetworkState", state });

    matchObject(result, {
      result: "Rejected",
      failure: {
        tag: "InvalidNetworkState",
        violation: { tag: "DeliveryLogMismatch", attempt },
      },
      state: {
        attempts: [{
          firstDelivery: {
            observation: { attempt: { logical } },
          },
        }],
      },
    });
  });

  it("preserves timeout stage and cause through decode, model, and encode", () => {
    const handle = { value: "timeout-worker" };
    const state = {
      attempts: [{
        input: { attempt, instruction, deadline: null, configuration },
        chain: { tag: "Root" },
        disposition: { tag: "Started", handle },
        firstDelivery: null,
        late: [],
      }],
    };
    const timeout = {
      tag: "Timeout",
      stage: { tag: "ResponseHeaders" },
      cause: { tag: "SocketReported" },
    };
    const result = invoke({
      operation: "observe",
      state,
      observation: {
        tag: "Delivered",
        delivery: 0,
        observation: {
          tag: "FailureObservation",
          attempt,
          handle,
          sourceSequence: null,
          failure: {
            attempt,
            stage: { tag: "ResponseHeaders" },
            configuration,
            cause: timeout,
          },
          effect: { tag: "Unknown", reason: { tag: "HostFailure" } },
        },
      },
    });

    matchObject(result, {
      result: "Terminal",
      settled: {
        terminal: {
          outcome: {
            tag: "Failed",
            failure: {
              stage: { tag: "ResponseHeaders" },
              cause: timeout,
            },
          },
        },
      },
      state: {
        attempts: [{
          disposition: {
            tag: "Settled",
            terminal: {
              outcome: {
                tag: "Failed",
                failure: { cause: timeout },
              },
            },
          },
        }],
      },
    });
  });
});
