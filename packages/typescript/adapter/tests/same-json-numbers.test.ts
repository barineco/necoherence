// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";

const sameNumberSpellings: readonly (readonly [string, string])[] = [
  ["10", "10.0"],
  ["10", "1e1"],
  ["10.0", "1e1"],
  ["1", "1.0e0"],
  ["0", "0.0"],
  ["0", "-0.0"],
  ["100e-2", "1"],
  ["1.5", "1.50"],
];

const differentValues: readonly (readonly [string, string])[] = [
  ["10", "10.5"],
  ["1", "true"],
  ["0", "null"],
  ["1.5", "1.6"],
];

describe("sameJson on numbers", () => {
  it.each(sameNumberSpellings)("treats %s and %s as the same JSON value as the Lean sameJson does", (left, right) => {
    expect(S.sameJson(V.parseLossless(left), V.parseLossless(right))).toBe(true);
    expect(S.sameJson(V.parseLossless(right), V.parseLossless(left))).toBe(true);
  });

  it.each(differentValues)("keeps %s and %s apart", (left, right) => {
    expect(S.sameJson(V.parseLossless(left), V.parseLossless(right))).toBe(false);
  });

  it("compares numbers nested in objects and arrays by value", () => {
    expect(S.sameJson(V.parseLossless('{"a":[10.0,{"b":1.50}]}'), V.parseLossless('{"a":[10,{"b":1.5}]}'))).toBe(true);
    expect(S.sameJson(V.parseLossless('{"a":[10.0,{"b":1.50}]}'), V.parseLossless('{"a":[10,{"b":1.6}]}'))).toBe(false);
  });
});
