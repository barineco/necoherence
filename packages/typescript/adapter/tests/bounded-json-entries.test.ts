// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { generation } from "./semantic-fixture.js";

const exponentFailure: V.WireFailure = { tag: "Syntax", path: "$", value: "exponent too large" };
// The unknown member is a wire failure, so the exponent failure appears only when the check runs before the wire decode.
const text = '{"unknown":1e10000}';

function wireFailureOf(action: () => unknown): V.WireFailure {
  try { action(); } catch (error) {
    expect(error).toBeInstanceOf(V.WireError);
    return (error as V.WireError).failure;
  }
  throw new Error("wire failure expected");
}

const input = generation();
const admitted = S.admitSignatureGeneration(S.expectedSignatureBasis(input), JSON.stringify(input));
if (admitted.tag !== "Admitted") throw new Error("generation admission expected");
const codec = admitted.checked.codec("integer");

it.each<[string, (value: string) => unknown]>([
  ["profile", value => S.decodeProfileJson(value)],
  ["library", value => S.decodeLibraryJson(value)],
  ["generation basis", value => S.decodeGenerationBasisJson(value)],
  ["diagnostic", value => S.decodeDiagnosticJson(value)],
  ["codec", value => codec.decode(value)],
])("rejects an exponent of 10000 in the %s entry before the wire decode", (_name, decode) => {
  expect(wireFailureOf(() => decode(text))).toEqual(exponentFailure);
});

it("reports the exponent failure of a generation input as its JSON failure", () => {
  expect(S.decodeGenerationInput(text)).toEqual({ tag: "Failed", failure: { tag: "Json", value: exponentFailure } });
  expect(S.admitSignatureGeneration(S.expectedSignatureBasis(input), text)).toEqual({ tag: "Failed", failure: { tag: "Decode", value: { tag: "Json", value: exponentFailure } } });
});

it("reads an exponent of 9999 and a quoted exponent of 10000 as ordinary members", () => {
  expect(wireFailureOf(() => S.decodeLibraryJson('{"unknown":1e9999}')).tag).toBe("UnknownField");
  expect(wireFailureOf(() => S.decodeLibraryJson('{"unknown":"1e10000"}')).tag).toBe("UnknownField");
});

it.each([
  ["a lone high surrogate", '{"unknown":"\\ud800"}'],
  ["a lone low surrogate", '{"unknown":"\\udc00"}'],
  ["a high surrogate followed by a non-surrogate escape", '{"unknown":"\\ud83d\\u0041"}'],
])("rejects %s in the profile entry before the wire decode", (_name, surrogateText) => {
  expect(wireFailureOf(() => S.decodeProfileJson(surrogateText))).toEqual({ tag: "Syntax", path: "$", value: "unpaired Unicode surrogate" });
});

it("reads a surrogate pair in the profile entry as an ordinary member", () => {
  expect(wireFailureOf(() => S.decodeProfileJson('{"unknown":"\\ud83d\\ude00"}'))).toEqual({ tag: "UnknownField", path: "$.unknown", value: "unknown" });
});

const duplicateFailure = (key: string): V.WireFailure => ({ tag: "Syntax", path: "$", value: `duplicate object key: ${key}` });

it.each([
  ["a top-level key", '{"a":1,"a":2}', "a"],
  ["a nested key", '{"child":{"flag":true,"flag":false}}', "flag"],
  ["a key whose second occurrence is escaped", '{"flag":true,"\\u0066lag":false}', "flag"],
  ["a key inside an array element", '{"items":[{"y":1,"\\u0079":2}]}', "y"],
])("rejects %s written twice in the profile entry at the parse", (_name, text, key) => {
  expect(wireFailureOf(() => S.decodeProfileJson(text))).toEqual(duplicateFailure(key));
});

it.each<[string, (value: string) => unknown]>([
  ["library", value => S.decodeLibraryJson(value)],
  ["generation basis", value => S.decodeGenerationBasisJson(value)],
  ["diagnostic", value => S.decodeDiagnosticJson(value)],
  ["codec", value => codec.decode(value)],
  ["codec with defaults", value => codec.decodeWithDefaults(value)],
])("rejects a duplicate key in the %s entry at the parse", (_name, decode) => {
  expect(wireFailureOf(() => decode('{"a":1,"a":2}'))).toEqual(duplicateFailure("a"));
});

it("reports the duplicate key of a generation input as its JSON failure", () => {
  expect(S.decodeGenerationInput('{"a":1,"a":2}')).toEqual({ tag: "Failed", failure: { tag: "Json", value: duplicateFailure("a") } });
});

it("rejects a duplicate key of a bounded exact read as a syntax failure rather than a semantic failure", () => {
  expect(wireFailureOf(() => V.boundedParseExact('{"x":[{"y":1,"\\u0079":2}]}'))).toEqual(duplicateFailure("y"));
  expect(() => V.boundedParseExact('{"a":1,"a":2}')).toThrow(V.WireError);
});
