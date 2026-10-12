// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { execFileSync } from "node:child_process";
import { expect, it } from "vitest";
import * as S from "../src/semantic_values.js";

it("preserves exact integer, decimal spelling and numeric object keys", () => {
  const wire = '{"10":9007199254740993,"2":-123456789012345678901234567890,"fraction":1.2300e+99}';
  const exact = S.parseExact(wire);
  expect(exact.tag).toBe("Object");
  if (exact.tag !== "Object") throw new Error("object required");
  expect(exact.members.map(m => m.key)).toEqual(["10", "2", "fraction"]);
  expect(S.encodeExact(exact)).toBe(wire);
  expect(S.toExact(S.fromExact({ tag: "Decimal", text: "12" }))).toEqual({ tag: "Decimal", text: "12" });
});

it("rejects ambiguous JSON syntax and non-JSON values before semantic validation", () => {
  for (const wire of ['{"a":1,"a":2}', '{"a":1,}', '{/*x*/"a":1}']) expect(() => S.parseExact(wire)).toThrow(S.SemanticEvidenceError);
  type Recursive = { self?: Recursive };
  const cycle: Recursive = {};
  cycle.self = cycle;
  for (const value of [cycle, new Date(), 9007199254740992]) expect(() => S.toExact(value)).toThrow(S.SemanticEvidenceError);
  const standard: S.BytesPolicy = { reference: { identity: "test", revision: "1", content_digest: "a" }, padding_optional: true, alphabet: { tag: "Standard" }, strict_pad_bits: true, wrapper: null };
  expect(S.base64Encode(Uint8Array.from([0, 255, 128]), standard)).toBe("AP+A");
  expect(S.base64Decode("AP+A", standard)).toEqual(Uint8Array.from([0, 255, 128]));
  expect(S.base64Decode("AB", standard)).toBeNull();
});

it("applies the bytes policy to base64 decoding and encoding", () => {
  const reference: S.ProfileRef = { identity: "test", revision: "1", content_digest: "a" };
  const policy = (alphabet: S.BytesAlphabet["tag"], strict_pad_bits = true, padding_optional = true): S.BytesPolicy => ({
    reference, alphabet: { tag: alphabet }, strict_pad_bits, padding_optional, wrapper: null,
  });
  const bytes = Uint8Array.from([251, 255]);
  const standard = policy("Standard"), urlSafe = policy("UrlSafe"), either = policy("Either");

  expect(S.base64Encode(bytes, standard)).toBe("+/8=");
  expect(S.base64Encode(bytes, urlSafe)).toBe("-_8=");
  expect(S.base64Encode(bytes, either)).toBe("+/8=");
  expect(S.base64Decode("+/8=", standard)).toEqual(bytes);
  expect(S.base64Decode("-_8=", standard)).toBeNull();
  expect(S.base64Decode("-_8=", urlSafe)).toEqual(bytes);
  expect(S.base64Decode("+/8=", urlSafe)).toBeNull();
  for (const text of ["+/8=", "-_8=", "+_8=", "-/8="]) expect(S.base64Decode(text, either)).not.toBeNull();

  expect(S.base64Decode("+/8", policy("Standard", true, false))).toBeNull();
  expect(S.base64Decode("+/8=", policy("Standard", true, false))).toEqual(bytes);
  expect(S.base64Decode("AB==", policy("Standard", true))).toBeNull();
  expect(S.base64Decode("AB==", policy("Standard", false))).toEqual(Uint8Array.from([0]));
});

it("executes value-profile format recognizers independently of declaration readers", () => {
  expect(() => execFileSync(process.execPath, ["--input-type=module", "-e", 'import { checkFormats } from "./tests/semantic-formats.mjs"; checkFormats();'], { encoding: "utf8" })).not.toThrow();
});
