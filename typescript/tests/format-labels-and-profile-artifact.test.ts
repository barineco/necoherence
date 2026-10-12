// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as V from "../src/semantic_values.js";
import { formatRuleSamplesFuel } from "../src/signature_verification.js";

const identifier: V.FormatRule = { tag: "Identifier", fields: { first_alphabet: "a", rest_alphabet: "a", exact_length: null, min_length: "1", max_length: "1", forbidden: [] } };
const labels = (separator: string, minimum: string, rule: V.FormatRule): V.FormatRule => ({ tag: "Labels", fields: { separator, min_count: minimum, max_count: null, total_max: null, rule } });

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
