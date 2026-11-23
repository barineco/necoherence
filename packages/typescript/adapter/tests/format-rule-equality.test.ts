// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as V from "../src/semantic_values.js";

const rules: readonly V.FormatRule[] = [
  { tag: "Literal", value: "a" },
  { tag: "Literal", value: "b" },
  { tag: "Sequence", value: [{ tag: "Literal", value: "a" }] },
  { tag: "Sequence", value: [] },
  { tag: "Optional", value: { tag: "Literal", value: "a" } },
  { tag: "Labels", fields: { separator: ",", min_count: "1", max_count: null, total_max: null, rule: { tag: "Literal", value: "a" } } },
  { tag: "Labels", fields: { separator: ",", min_count: "1", max_count: "2", total_max: null, rule: { tag: "Literal", value: "a" } } },
  { tag: "Bounded", fields: { unit: { tag: "Graphemes" }, maximum: "3", rule: { tag: "Text" } } },
  { tag: "Bounded", fields: { unit: { tag: "Utf8Bytes" }, maximum: "3", rule: { tag: "Text" } } },
  { tag: "AsciiDfa", value: { state_count: "1", initial_state: "0", accepting_states: ["0"], transitions: [] } },
  { tag: "Identifier", fields: { first_alphabet: "a", rest_alphabet: "b", exact_length: null, min_length: "1", max_length: null, forbidden: [] } },
  { tag: "Timestamp", value: { allow_second_60: false, minimum_year: "2000", maximum_year: "2099", rejectUtcYearOutsideRange: true } },
  { tag: "AbsoluteUri", fields: { max_bytes: null } },
  { tag: "AbsoluteUri", fields: { max_bytes: "5" } },
  { tag: "LanguageTag", fields: { grandfathered: ["i-x"] } },
  { tag: "Choice", value: [{ tag: "Text" }] },
  { tag: "Text" },
  { tag: "Not", value: { tag: "Literal", value: "a" } },
];

it("agrees with the structural equality on every pair of format rules", () => {
  for (const left of rules) for (const right of rules) expect(V.formatRuleEqual(left, right), JSON.stringify([left, right])).toBe(V.same(left, right));
});

it("agrees with the structural equality on every pair of format rule lists", () => {
  const lists: readonly (readonly V.FormatRule[])[] = [[], ...rules.map(rule => [rule]), [rules[0]!, rules[0]!]];
  for (const left of lists) for (const right of lists) expect(V.formatRulesEqual(left, right), JSON.stringify([left, right])).toBe(V.same(left, right));
});
