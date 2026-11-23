// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as V from "../src/semantic_values.js";
import { profile } from "./semantic-fixture.js";

const literal = (value: string): V.FormatRule => ({ tag: "Literal", value });
const identifier: V.FormatRule = { tag: "Identifier", fields: { first_alphabet: "ab", rest_alphabet: "ab0", exact_length: null, min_length: "1", max_length: "4", forbidden: ["ab"] } };
const labels = (separator: string, min: string, max: string | null, total: string | null, rule: V.FormatRule): V.FormatRule => ({ tag: "Labels", fields: { separator, min_count: min, max_count: max, total_max: total, rule } });
const dfa: V.FormatRule = { tag: "AsciiDfa", value: { state_count: "2", initial_state: "0", accepting_states: ["1"], transitions: [{ from_state: "0", first: "48", last: "57", to_state: "1" }, { from_state: "1", first: "48", last: "57", to_state: "1" }] } };
const timestamp: V.FormatRule = { tag: "Timestamp", value: { allow_second_60: true, minimum_year: "1970", maximum_year: "2100", rejectUtcYearOutsideRange: true } };

const rules: V.FormatRule[] = [
  literal("ab"),
  literal(""),
  { tag: "Text" },
  { tag: "Sequence", value: [] },
  { tag: "Sequence", value: [literal("a"), { tag: "Text" }, literal("b")] },
  { tag: "Choice", value: [literal("a"), { tag: "Sequence", value: [] }, literal("ab")] },
  { tag: "Optional", value: literal("x") },
  { tag: "Not", value: { tag: "Sequence", value: [literal("a"), { tag: "Text" }] } },
  labels(".", "1", "3", "7", identifier),
  labels(".", "0", null, null, literal("a")),
  labels("", "0", null, null, literal("a")),
  labels("::", "2", "2", "6", { tag: "Text" }),
  { tag: "Bounded", fields: { unit: { tag: "UnicodeScalars" }, maximum: "3", rule: { tag: "Text" } } },
  { tag: "Bounded", fields: { unit: { tag: "Utf8Bytes" }, maximum: "4", rule: literal("é") } },
  { tag: "Bounded", fields: { unit: { tag: "Graphemes" }, maximum: "2", rule: { tag: "Text" } } },
  dfa,
  identifier,
  timestamp,
  { tag: "AbsoluteUri", fields: { max_bytes: "16" } },
  { tag: "LanguageTag", fields: { grandfathered: ["i-klingon"] } },
  { tag: "Sequence", value: [labels(".", "1", null, null, identifier), literal("!"), { tag: "Optional", value: timestamp }] },
];

const texts = ["", "a", "b", "ab", "aab", "a.b", "a..b", ".", "..", "a.ab.b", "x", "é", "😀.é", "a\u0301b", "1.2", "10", "2024-02-29T23:59:59Z", "2024-02-30T00:00:00Z", "1969-12-31T23:59:60+00:00", "2100-12-31T23:59:59-00:00", "2024-06-15T12:00:00.5+01:00", "a!", "ab!", "a.b!"];

it("recognizes the same texts with the span recognizer as the reference formatAccepts", () => {
  for (const rule of rules) {
    for (const value of texts) {
      expect(V.formatAcceptsFast(null, rule, value)).toBe(V.formatAccepts(null, rule, value));
      expect(V.formatAcceptsFast(profile.grapheme_rules as V.GraphemeRules, rule, value)).toBe(V.formatAccepts(profile.grapheme_rules as V.GraphemeRules, rule, value));
    }
  }
});

it("accepts a text through recognizeFormat only when every scalar of the text is a Unicode scalar", () => {
  expect(V.recognizeFormat({ tag: "Text" }, "a\uD800", null)).toBe(false);
  expect(V.recognizeFormat({ tag: "Text" }, "a\u{1F600}", null)).toBe(true);
});

it("keeps the empty separator of a label list rejected by the span recognizer", () => {
  expect(V.recognizeFormat(labels("", "0", null, null, { tag: "Text" }), "a", null)).toBe(false);
  expect(V.recognizeFormat(labels("", "0", null, null, { tag: "Text" }), "", null)).toBe(false);
});
