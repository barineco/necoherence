// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import { readFileSync } from "node:fs";
import * as V from "../src/semantic_values.js";
import { formatRuleSamplesFuel } from "../src/signature_verification.js";

const identifier: V.FormatRule = { tag: "Identifier", fields: { first_alphabet: "a", rest_alphabet: "a", exact_length: null, min_length: "1", max_length: "1", forbidden: [] } };
const labels = (separator: string, minimum: string, rule: V.FormatRule): V.FormatRule => ({ tag: "Labels", fields: { separator, min_count: minimum, max_count: null, total_max: null, rule } });

it("accepts AT Protocol URIs with DID authorities and rejects missing schemes or whitespace", () => {
  const profile = JSON.parse(readFileSync("../presets/atproto-data-model/profile.json", "utf8")) as V.VersionedSemanticProfile;
  const rule = profile.format_bindings.find(binding => binding.name === "uri")!.rule;
  expect(V.recognizeFormat(rule, "at://did:plc:ymdqgzoop3puhkbwrd7njbke/app.bsky.actor.profile/self")).toBe(true);
  expect(V.recognizeFormat(rule, "https://example.com/has space")).toBe(false);
  expect(V.recognizeFormat(rule, "example.com/path")).toBe(false);
});

it("splits and samples labels with the whole separator", () => {
  const rule = labels("::", "2", identifier);
  expect(V.recognizeFormat(rule, "a::a")).toBe(true);
  expect(V.recognizeFormat(rule, "a:a")).toBe(false);
  expect(formatRuleSamplesFuel(32n, 8n, rule)).toContain("a::a");
});

it("samples a minimum of zero as one accepted label", () => {
  const rule = labels("::", "0", { tag: "Literal", value: "qq" });
  expect(formatRuleSamplesFuel(32n, 8n, rule)).toEqual(["qq"]);
});

it("samples bounded absolute URI and sequence rules", () => {
  const uri: V.FormatRule = { tag: "AbsoluteUri", fields: { max_bytes: "2" } };
  const sequence: V.FormatRule = { tag: "Sequence", value: [{ tag: "Literal", value: "x" }, { tag: "Optional", value: { tag: "Literal", value: "y" } }] };
  expect(formatRuleSamplesFuel(32n, 8n, uri)).toContain("a:");
  expect(formatRuleSamplesFuel(32n, 8n, sequence).every(value => V.recognizeFormat(sequence, value))).toBe(true);
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
    for (const rule of rules) expect(V.recognizeFormat(rule, text)).toBe(["!", "a!", "😀!", "a😀!"].includes(text));
  }
  expect(V.recognizeFormat(sequence([]), "")).toBe(true);
  expect(V.recognizeFormat(sequence([]), "a")).toBe(false);
  const negated = sequence([literal("["), { tag: "Not", value: sequence([literal("a"), literal("😀")]) }, literal("]")]);
  expect(V.recognizeFormat(negated, "[]")).toBe(true);
  expect(V.recognizeFormat(negated, "[😀]")).toBe(true);
  expect(V.recognizeFormat(negated, "[a😀]")).toBe(false);
});

it("preserves scalar offsets for sequences within labels and bounds", () => {
  const literal = (value: string): V.FormatRule => ({ tag: "Literal", value });
  const child: V.FormatRule = { tag: "Sequence", value: [{ tag: "Optional", value: literal("a") }, literal("😀")] };
  const inner: V.FormatRule = { tag: "Labels", fields: { separator: "🔹", min_count: "2", max_count: "2", total_max: "4", rule: child } };
  const rule: V.FormatRule = { tag: "Sequence", value: [literal("["), inner, literal("]")] };
  for (const [text, expected] of [["[😀🔹a😀]", true], ["[a😀🔹😀]", true], ["[😀🔹b😀]", false], ["[😀🔹😀🔹😀]", false], ["[a😀🔹a😀]", false]] as const) {
    expect(V.recognizeFormat(rule, text)).toBe(expected);
  }
  const bounded = (maximum: string): V.FormatRule => ({ tag: "Bounded", fields: { unit: { tag: "Utf8Bytes" }, maximum, rule } });
  expect(V.recognizeFormat(bounded("15"), "[😀🔹a😀]")).toBe(true);
  expect(V.recognizeFormat(bounded("14"), "[😀🔹a😀]")).toBe(false);
});

it("preserves acceptance and rejection for a flat sequence with 600 parts", () => {
  const parts: V.FormatRule[] = Array.from({ length: 600 }, () => ({ tag: "Literal", value: "" }));
  const rule: V.FormatRule = { tag: "Sequence", value: parts };
  expect(V.recognizeFormat(rule, "")).toBe(true);
  expect(V.recognizeFormat(rule, "x")).toBe(false);
  const suffix: V.FormatRule = { tag: "Sequence", value: [...parts, { tag: "Literal", value: "x" }] };
  expect(V.recognizeFormat(suffix, "x")).toBe(true);
  expect(V.recognizeFormat(suffix, "")).toBe(false);
});
