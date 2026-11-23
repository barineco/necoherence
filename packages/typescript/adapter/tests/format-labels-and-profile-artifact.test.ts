// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import { readFileSync } from "node:fs";
import * as V from "../src/semantic_values.js";

const identifier: V.FormatRule = { tag: "Identifier", fields: { first_alphabet: "a", rest_alphabet: "a", exact_length: null, min_length: "1", max_length: "1", forbidden: [] } };
const labels = (separator: string, minimum: string, rule: V.FormatRule): V.FormatRule => ({ tag: "Labels", fields: { separator, min_count: minimum, max_count: null, total_max: null, rule } });

it("accepts AT Protocol URIs with DID authorities and rejects missing schemes or whitespace", () => {
  const profile = JSON.parse(readFileSync("../../../verification/presets/atproto-data-model/profile.json", "utf8")) as V.VersionedSemanticProfile;
  const rule = profile.format_bindings.find(binding => binding.name === "uri")!.rule;
  expect(V.recognizeFormat(rule, "at://did:plc:ymdqgzoop3puhkbwrd7njbke/app.bsky.actor.profile/self", null)).toBe(true);
  expect(V.recognizeFormat(rule, "https://example.com/has space", null)).toBe(false);
  expect(V.recognizeFormat(rule, "example.com/path", null)).toBe(false);
});

it("preserves concatenation under sequence grouping and empty parts", () => {
  const literal = (value: string): V.FormatRule => ({ tag: "Literal", value });
  const sequence = (value: readonly V.FormatRule[]): V.FormatRule => ({ tag: "Sequence", value });
  const first: V.FormatRule = { tag: "Choice", value: [literal(""), literal("a")] };
  const second: V.FormatRule = { tag: "Optional", value: literal("😀") };
  const third = literal("!");
  const rules = [
    sequence([first, second, third]),
    sequence([sequence([first, second]), third]),
    sequence([first, sequence([second, third])]),
    sequence([sequence([]), first, second, sequence([third]), sequence([])]),
  ];
  for (const text of ["", "!", "a!", "😀!", "a😀!", "aa!", "😀a!", "a😀", "x!"]) {
    for (const rule of rules) expect(V.recognizeFormat(rule, text, null)).toBe(["!", "a!", "😀!", "a😀!"].includes(text));
  }
  expect(V.recognizeFormat(sequence([]), "", null)).toBe(true);
  expect(V.recognizeFormat(sequence([]), "a", null)).toBe(false);
  const negated = sequence([literal("["), { tag: "Not", value: sequence([literal("a"), literal("😀")]) }, literal("]")]);
  expect(V.recognizeFormat(negated, "[]", null)).toBe(true);
  expect(V.recognizeFormat(negated, "[😀]", null)).toBe(true);
  expect(V.recognizeFormat(negated, "[a😀]", null)).toBe(false);
});

it("preserves scalar offsets for sequences within labels and bounds", () => {
  const literal = (value: string): V.FormatRule => ({ tag: "Literal", value });
  const child: V.FormatRule = { tag: "Sequence", value: [{ tag: "Optional", value: literal("a") }, literal("😀")] };
  const inner: V.FormatRule = { tag: "Labels", fields: { separator: "🔹", min_count: "2", max_count: "2", total_max: "4", rule: child } };
  const rule: V.FormatRule = { tag: "Sequence", value: [literal("["), inner, literal("]")] };
  for (const [text, expected] of [["[😀🔹a😀]", true], ["[a😀🔹😀]", true], ["[😀🔹b😀]", false], ["[😀🔹😀🔹😀]", false], ["[a😀🔹a😀]", false]] as const) {
    expect(V.recognizeFormat(rule, text, null)).toBe(expected);
  }
  const bounded = (maximum: string): V.FormatRule => ({ tag: "Bounded", fields: { unit: { tag: "Utf8Bytes" }, maximum, rule } });
  expect(V.recognizeFormat(bounded("15"), "[😀🔹a😀]", null)).toBe(true);
  expect(V.recognizeFormat(bounded("14"), "[😀🔹a😀]", null)).toBe(false);
});

it("preserves acceptance and rejection for a flat sequence with 600 parts", () => {
  const parts: V.FormatRule[] = Array.from({ length: 600 }, () => ({ tag: "Literal", value: "" }));
  const rule: V.FormatRule = { tag: "Sequence", value: parts };
  expect(V.recognizeFormat(rule, "", null)).toBe(true);
  expect(V.recognizeFormat(rule, "x", null)).toBe(false);
  const suffix: V.FormatRule = { tag: "Sequence", value: [...parts, { tag: "Literal", value: "x" }] };
  expect(V.recognizeFormat(suffix, "x", null)).toBe(true);
  expect(V.recognizeFormat(suffix, "", null)).toBe(false);
});
