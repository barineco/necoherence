// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import fc from "fast-check";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { generation } from "./semantic-fixture.js";

it("preserves accepted strings through exact and generated codec roundtrips", () => {
  const input = generation(), admitted = S.admitSignatureGeneration(S.expectedSignatureBasis(input), JSON.stringify(input));
  if (admitted.tag !== "Admitted") throw new Error(JSON.stringify(admitted.failure));
  const codec = admitted.checked.codec("text");
  fc.assert(fc.property(fc.string(), text => {
    const value: V.ExactJson = { tag: "String", value: text };
    expect(codec.decode(codec.encode(value))).toEqual(value);
  }), { seed: 386, numRuns: 64 });
});

it("preserves wrapper and sealed values through general runtime operations", () => {
  const input = generation(), admitted = S.admitSignatureGeneration(S.expectedSignatureBasis(input), JSON.stringify(input));
  if (admitted.tag !== "Admitted") throw new Error(JSON.stringify(admitted.failure));
  const profile = admitted.checked.signatures.context.profile;
  expect(V.wrapDecode(admitted.checked.signatures.context.prepared, "text", V.wrapEncode(profile, "text", "abc1"))).toBe("abc1");
  const sealed = V.withMember("kind", "sealed", { tag: "Object", members: [{ key: "name", value: { tag: "String", value: "x" } }] });
  expect(admitted.checked.codec("sealed").decodeJson(sealed)).toEqual(sealed);
});

it("sets the member first, replaces a differing member, and leaves a non-object unchanged", () => {
  const object: V.ExactJson = { tag: "Object", members: [{ key: "name", value: { tag: "String", value: "x" } }, { key: "kind", value: { tag: "String", value: "other" } }] };
  expect(V.withMember("kind", "sealed", object)).toEqual({ tag: "Object", members: [{ key: "kind", value: { tag: "String", value: "sealed" } }, { key: "name", value: { tag: "String", value: "x" } }] });
  expect(V.withMember("kind", "sealed", { tag: "Null" })).toEqual({ tag: "Null" });
});
