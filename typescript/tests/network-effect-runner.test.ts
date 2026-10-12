// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import { runLine } from "../src/network-effect-runner.js";

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

describe("network effect runner schema", () => {
  it("decodes byte arrays without changing their numeric domain", () => {
    const result = invoke({
      operation: "prepare",
      state: { attempts: [] },
      input: { attempt, instruction, deadline: null, configuration },
    });

    expect(result.result).toBe("Prepared");
    expect(result).toMatchObject({
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
        lineage: { tag: "Root" },
        disposition: { tag: "Prepared" },
        firstDelivery: { delivery: 2, observation: recordedObservation },
        late: [],
      }],
    };
    const result = invoke({ operation: "readNetworkState", state });

    expect(result).toMatchObject({
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
        lineage: { tag: "Root" },
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

    expect(result).toMatchObject({
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
