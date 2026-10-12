// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { readFileSync } from "node:fs";
import * as networkEffect from "./network-effect.js";

const OPERATIONS = ["readNetworkState", "prepare", "sendCommand", "cancelCommand", "observeStart", "observe", "annotateEffect", "retry"] as const;
type Operation = (typeof OPERATIONS)[number];
type JsonObject = { readonly [key: string]: unknown };

function object(value: unknown): JsonObject | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
  return value as JsonObject;
}
function has(value: JsonObject, key: string): boolean { return Object.prototype.hasOwnProperty.call(value, key); }
function desurrogate(value: unknown): unknown {
  if (typeof value === "string") {
    let result = "";
    let index = 0;
    while (index < value.length) {
      const code = value.charCodeAt(index);
      const next = value.charCodeAt(index + 1);
      if (code >= 0xd800 && code <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) {
        result += value.slice(index, index + 2);
        index += 2;
        continue;
      }
      result += code >= 0xd800 && code <= 0xdfff ? "\ufffd" : value[index];
      index += 1;
    }
    return result;
  }
  if (Array.isArray(value)) return value.map((item) => desurrogate(item));
  const record = object(value);
  if (record === undefined) return value;
  const output: Record<string, unknown> = {};
  for (const [name, item] of Object.entries(record)) output[name] = desurrogate(item);
  return output;
}
function decodedNode(value: unknown, field = ""): unknown {
  if (field === "sourceSequence") {
    if (value === null) return { tag: "none" };
    if (typeof value === "number" && Number.isInteger(value) && value >= 0) {
      return { tag: "some", value: BigInt(value) };
    }
  }
  if (Array.isArray(value)) return value.map((item) => decodedNode(item));
  const record = object(value);
  if (record === undefined) {
    if (
      [
        "revision",
        "ordinal",
        "limit",
        "value",
        "delivery",
        "requestBodyLimit",
        "responseBodyLimit",
      ].includes(field)
      && typeof value === "number"
      && Number.isInteger(value)
      && value >= 0
    ) return BigInt(value);
    return value;
  }
  const tag = typeof record.tag === "string" ? record.tag : "";
  const output: Record<string, unknown> = {};
  for (const [name, item] of Object.entries(record)) {
    const tagged = object(item);
    if (name === "reason" && typeof tagged?.tag === "string") {
      output.reason = tagged.tag;
      continue;
    }
    if (
      name === "cause"
      && tagged?.tag === "Timeout"
    ) {
      output.cause = decodedNode(item, "cause");
      continue;
    }
    if (
      (name === "stage" || name === "cause")
      && typeof tagged?.tag === "string"
    ) {
      output[name] = tagged.tag;
      continue;
    }
    if (
      name === "provenance"
      && (tag === "Response" || tag === "ResponseObservation")
      && typeof tagged?.tag === "string"
    ) {
      output.provenance = tagged.tag;
      continue;
    }
    if (
      name === "source"
      && (tagged?.tag === "Adapter" || tagged?.tag === "Protocol")
    ) {
      output.source = tagged.tag;
      continue;
    }
    output[name] = decodedNode(item, name);
  }
  return output;
}

function encodedNode(value: unknown, field = ""): unknown {
  if (typeof value === "bigint") return Number(value);
  if (Array.isArray(value)) return value.map((item) => encodedNode(item));
  const record = object(value);
  if (record === undefined) return value;
  const tag = typeof record.tag === "string" ? record.tag : "";
  if (field === "sourceSequence" && tag === "none") return null;
  if (field === "sourceSequence" && tag === "some") {
    return encodedNode(record.value, "value");
  }
  const output: Record<string, unknown> = {};
  for (const [name, item] of Object.entries(record)) {
    if (name === "tag" && field === "result") continue;
    if (name === "sourceSequence") {
      output.sourceSequence = encodedNode(item, "sourceSequence");
      continue;
    }
    if (
      (name === "stage" || name === "cause")
      && typeof item === "string"
    ) {
      output[name] = { tag: item };
      continue;
    }
    if (
      name === "provenance"
      && (tag === "Response" || tag === "ResponseObservation")
      && typeof item === "string"
    ) {
      output.provenance = { tag: item };
      continue;
    }
    if (name === "reason" && typeof item === "string") {
      output.reason = { tag: item };
      continue;
    }
    if (
      name === "source"
      && typeof item === "string"
      && (item === "Adapter" || item === "Protocol")
    ) {
      output.source = { tag: item };
      continue;
    }
    output[name] = encodedNode(item, name);
  }
  return output;
}
function invalid(error: string): string { return JSON.stringify({ error, result: "InvalidInvocation" }); }
function invocation(value: unknown): JsonObject | string {
  const record = object(value);
  if (record === undefined) return invalid("invocation: expected object");
  if (typeof record.operation !== "string" || !OPERATIONS.includes(record.operation as Operation)) return invalid(`operation: unknown value ${String(record.operation)}`);
  if (!has(record, "state")) return invalid("state: missing field");
  if (object(record.state) === undefined) return invalid("attempts: object expected");
  const state = object(record.state) as JsonObject;
  if (!Array.isArray(state.attempts)) return invalid("attempts: expected array");
  return decodedNode(record) as JsonObject;
}
function run(value: JsonObject): unknown {
  const operation = value.operation as Operation;
  const state = value.state as networkEffect.NetworkState;
  let result: unknown;
  switch (operation) {
    case "readNetworkState": result = networkEffect.readNetworkState(state); break;
    case "prepare": result = networkEffect.prepare(state, value.input as networkEffect.AttemptInput); break;
    case "sendCommand": result = networkEffect.sendCommand(state, value.prepared as networkEffect.PreparedAttempt); break;
    case "cancelCommand": result = networkEffect.cancelCommand(state, value.started as networkEffect.StartedAttempt); break;
    case "observeStart": result = networkEffect.observeStart(state, value.prepared as networkEffect.PreparedAttempt, value.observation as networkEffect.StartObservation); break;
    case "observe": result = networkEffect.observe(state, value.observation as networkEffect.HostObservation); break;
    case "annotateEffect": result = networkEffect.annotateEffect(state, value.effect as networkEffect.EffectObservation); break;
    case "retry": result = networkEffect.retry(state, value.request as networkEffect.RetryRequest); break;
  }
  const encoded = encodedNode(result);
  if (object(encoded) !== undefined && typeof (encoded as JsonObject).tag === "string") {
    const resultObject = encoded as Record<string, unknown>;
    resultObject.result = resultObject.tag;
    delete resultObject.tag;
    return resultObject;
  }
  return encoded;
}
export function runLine(line: string): string {
  try {
    const parsed: unknown = desurrogate(JSON.parse(line));
    const decoded = invocation(parsed);
    if (typeof decoded === "string") return decoded;
    return JSON.stringify(run(decoded));
  } catch (error) {
    return invalid(error instanceof Error ? error.message : String(error));
  }
}
if (process.argv[1]?.endsWith("network-effect-runner.js")) process.stdout.write(`${runLine(readFileSync(0, "utf8"))}\n`);
