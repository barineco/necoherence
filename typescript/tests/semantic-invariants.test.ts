// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import fc from "fast-check";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { generation } from "./semantic-fixture.js";

it("preserves accepted strings through exact and generated codec roundtrips", () => {
  const input = generation(), admitted = S.admitSignatureGeneration(input.basis, JSON.stringify(input));
  if (admitted.tag !== "Admitted") throw new Error(JSON.stringify(admitted.failure));
  const codec = admitted.checked.codec("text");
  fc.assert(fc.property(fc.string(), text => {
    const value: V.ExactJson = { tag: "String", value: text };
    expect(codec.decode(codec.encode(value))).toEqual(value);
  }), { seed: 386, numRuns: 64 });
});

it("preserves wrapper and sealed values through general runtime operations", () => {
  const input = generation(), admitted = S.admitSignatureGeneration(input.basis, JSON.stringify(input));
  if (admitted.tag !== "Admitted") throw new Error(JSON.stringify(admitted.failure));
  const profile = admitted.checked.signatures.context.profile;
  expect(V.wrapDecode(profile, "text", V.wrapEncode(profile, "text", "abc1"))).toBe("abc1");
  const sealed = V.withMember("kind", "sealed", { tag: "Object", members: [{ key: "name", value: { tag: "String", value: "x" } }] });
  expect(admitted.checked.codec("sealed").decodeJson(sealed)).toEqual(sealed);
});
