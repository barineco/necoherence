// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";

const typeRef = (name: string): V.TypeRef => ({
  source: { repository: "synthetic", revision: "1", path: "types", content_digest: "digest" },
  definition_name: name,
  pointer: [],
} as unknown as V.TypeRef);

it("includes the value type of allowed extra members among the children of a product", () => {
  const child = typeRef("value");
  const shape = {
    tag: "Product",
    value: { fields: [], extras: { tag: "Allow", fields: { key_format: null, value: { type_ref: child, required: false, nullable: false } } } },
  } as unknown as V.TypeShape;
  expect(V.typeChildren(shape)).toEqual([child]);
});

it("canonicalizes every zero spelling to 0", () => {
  expect(S.signatureCanonicalJson(V.parseLossless("[0e11, -0.00, 0E-4294967296, 0]"))).toBe("[0,0,0,0]");
});

it("rejects an unpaired surrogate escape in the exchange text as a syntax failure", () => {
  expect(V.admissionFailure("\"\\ud800\"")).toBe("unpaired Unicode surrogate");
  expect(V.admissionFailure("\"\\udc00\"")).toBe("unpaired Unicode surrogate");
  expect(V.admissionFailure("\"\\ud83d\\u0041\"")).toBe("unpaired Unicode surrogate");
  expect(V.admissionFailure("\"\\ud83d\\ude00\"")).toBeNull();
});

it("rejects an exponent of magnitude 10000 or more with either sign", () => {
  expect(V.admissionFailure("1e42")).toBeNull();
  expect(V.admissionFailure("1e9999")).toBeNull();
  expect(V.admissionFailure("1e10000")).toBe("exponent too large");
  expect(V.admissionFailure("1E+10000")).toBe("exponent too large");
  expect(V.admissionFailure("1e-9999")).toBeNull();
  expect(V.admissionFailure("1e-10000")).toBe("exponent too large");
  expect(V.admissionFailure("1E-10000")).toBe("exponent too large");
  expect(V.admissionFailure("1e-4294967296")).toBe("exponent too large");
  expect(V.admissionFailure("\"1e10000\"")).toBeNull();
  expect(V.admissionFailure("\"e10000\"")).toBeNull();
});

it("reads a zero JSON number in the Lean fromJson form", () => {
  expect(V.parseExact("0")).toEqual({ tag: "Integer", value: "0" });
  expect(V.parseExact("-0")).toEqual({ tag: "Integer", value: "0" });
  expect(V.parseExact("0e11")).toEqual({ tag: "Integer", value: "0" });
  expect(V.parseExact("0.0e1")).toEqual({ tag: "Integer", value: "0" });
  expect(V.parseExact("0.0")).toEqual({ tag: "Decimal", text: "0" });
  expect(V.parseExact("-0.0")).toEqual({ tag: "Decimal", text: "0" });
  expect(V.parseExact("0e-100")).toEqual({ tag: "Decimal", text: "0" });
  expect(V.parseExact("0.000e-100")).toEqual({ tag: "Decimal", text: "0" });
  expect(V.parseExact("1.5")).toEqual({ tag: "Decimal", text: "1.5" });
});

it("reads an integer-valued decimal in the Lean canonical text, without the .0 of its spelling", () => {
  expect(V.parseExact("10.0")).toEqual({ tag: "Decimal", text: "10" });
  expect(V.parseExact("1.0")).toEqual({ tag: "Decimal", text: "1" });
  expect(V.parseExact("-7.0")).toEqual({ tag: "Decimal", text: "-7" });
  expect(V.parseExact("1.50e1")).toEqual({ tag: "Decimal", text: "15" });
  expect(V.parseExact("100e-2")).toEqual({ tag: "Decimal", text: "1" });
  expect(V.parseExact("1e-100")).toEqual({ tag: "Decimal", text: "0.0000000001e-90" });
});

it.each([
  ["0", "0.0"], ["0.0", "0.0"], ["-0.0", "0.0"], ["0e-100", "0.0"], ["10", "10.0"], ["10.0", "10.0"],
  ["-7.0", "-7.0"], ["1.50e1", "15.0"], ["100e-2", "1.0"], ["1.5", "1.5"], ["1e-100", "0.0000000001e-90"],
])("writes the decimal %s in the numberText spelling %s", (source, spelled) => {
  expect(V.numberText(source)).toBe(spelled);
  expect(V.encodeExact({ tag: "Decimal", text: source })).toBe(spelled);
});

it.each([["10.0", "10.0"], ["-7.0", "-7.0"], ["1.50e1", "15.0"], ["100e-2", "1.0"], ["0.0", "0.0"], ["1.5", "1.5"]])("writes the decimal read from %s as %s", (source, spelled) => {
  expect(V.encodeExact(V.parseExact(source))).toBe(spelled);
});

it("rejects a decimal text that is not a JSON number or whose exponent reaches the reader limit when written", () => {
  expect(() => V.numberText("1.0x")).toThrow(V.SemanticEvidenceError);
  expect(() => V.numberText("1e10000")).toThrow(V.SemanticEvidenceError);
});

it("reports the index of a failing array element in the wire path", () => {
  let failure: unknown;
  try { V.wireList(V.wireString)(["ok", 1], "$.items"); } catch (error) { failure = error; }
  expect(failure).toBeInstanceOf(V.WireError);
  expect((failure as V.WireError).failure.path).toBe("$.items[1]");
});

it("escapes control characters other than newline and carriage return as lower-case four-digit units", () => {
  const value = { b: "x\ty", a: "\u0008\u000c\u001b\u0000\u001f\"\\\n\r\u007f\u00e9\u{1f600}" };
  expect(S.signatureCanonicalJson(value)).toBe('{"a":"\\u0008\\u000c\\u001b\\u0000\\u001f\\"\\\\\\n\\r\u007f\u00e9\u{1f600}","b":"x\\u0009y"}');
  expect(S.signatureCanonicalJson({ "k\tey": 0n })).toBe('{"k\\u0009ey":0}');
});

it.each([
  ["[1.50,1e2,1.0,10e-1,0.0,-0.0,1e-20]", "[1.5,100,1,1,0,0,0.0000000001e-10]"],
  ["[-1.0,-2.50,0.5,1.5e1,100e-2,1.10,12.000]", "[-1,-2.5,0.5,15,1,1.1,12]"],
  ["[0.0001,123456789012.5e-3,1.25e-2,5e-1]", "[0.0001,123456789.0125,0.0125,0.5]"],
])("prints the numbers of %s in the Lean compress form", (source, expected) => {
  expect(S.signatureCanonicalJson(V.parseLossless(source))).toBe(expected);
});
