// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import type { NetworkFailure } from "../../packages/typescript/adapter/src/network-effect.js";

function structured(value: unknown): unknown {
  if (typeof value === "bigint") return Number(value);
  if (value instanceof Uint8Array) return Array.from(value);
  if (Array.isArray(value)) return value.map(structured);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([name, member]) => [name, structured(member)]));
  }
  return value;
}

export function networkFailureJson(value: NetworkFailure): unknown {
  return structured(value);
}
