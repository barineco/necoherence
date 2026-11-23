// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as V from "../src/semantic_values.js";

const uri = (maximum: string | null): V.FormatRule => ({ tag: "AbsoluteUri", fields: { max_bytes: maximum } });
const language = (grandfathered: readonly string[]): V.FormatRule => ({ tag: "LanguageTag", fields: { grandfathered } });

it("requires the URI syntax when no length bound is declared", () => {
  expect(V.recognizeFormat(uri(null), "a", null)).toBe(false);
  expect(V.recognizeFormat(uri(null), "urn:x", null)).toBe(true);
  expect(V.recognizeFormat(uri("4"), "urn:x", null)).toBe(false);
});

it("rejects an IPv6 host with an empty group or a dotted group before the last group", () => {
  for (const text of ["http://[:::1]/", "http://[1:::2]/", "http://[:1::]/", "http://[1.2.3.4:1.2.3.4:1.2.3.4:1.2.3.4]/"]) {
    expect(V.recognizeFormat(uri(null), text, null), text).toBe(false);
  }
  for (const text of ["http://[::1]:80/", "http://[::]/", "http://[::1.2.3.4]/", "http://[1:2:3:4:5:6:1.2.3.4]/"]) {
    expect(V.recognizeFormat(uri(null), text, null), text).toBe(true);
  }
});

it("compares grandfathered language tags with ASCII case folding only", () => {
  expect(V.recognizeFormat(language(["\u212A"]), "k", null)).toBe(false);
  expect(V.recognizeFormat(language(["i-klingon"]), "I-Klingon", null)).toBe(true);
});

it("accepts the empty text only when the grandfathered list contains it, as the Lean definition does", () => {
  expect(V.recognizeFormat(language([""]), "", null)).toBe(true);
  expect(V.recognizeFormat(language([]), "", null)).toBe(false);
});
