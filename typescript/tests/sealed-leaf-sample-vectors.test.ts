// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { sampleValues } from "../src/signature_verification.js";

interface VectorCase {
  readonly id: string;
  readonly sealed: S.TypeSignatureLibrary["nodes"][number]["shape"];
  readonly expected: readonly unknown[];
}
interface Vectors {
  readonly schema: string;
  readonly profile: S.ValueSemanticProfile;
  readonly cases: readonly VectorCase[];
}
const vectorText = readFileSync(new URL("../../comparison/declaration/sealed_leaf_sample_vectors.json", import.meta.url), "utf8");
const vectors = JSON.parse(vectorText) as Vectors;
const exactCases = V.member(V.parseExact(vectorText), "cases");

function sortedExact(value: V.ExactJson): V.ExactJson {
  if (value.tag === "Object") {
    return { tag: "Object", members: [...value.members].sort((a, b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0)
      .map(member => ({ key: member.key, value: sortedExact(member.value) })) };
  }
  if (value.tag === "Array") return { tag: "Array", items: value.items.map(sortedExact) };
  return value;
}

it("loads all 7 Lean sealed leaf sample cases", () => {
  expect(vectors.schema).toBe("sealed-leaf-sample-vectors@1");
  expect(vectors.cases).toHaveLength(7);
});

it.each(vectors.cases.map((testCase, index) => [testCase.id, testCase, index] as const))("%s matches the Lean sample", (_id, testCase, index) => {
  const checked = S.checkLibrary({
    schema: "ncoh-type-signatures@1", identity: "sealed-leaf-samples", revision: "1",
    profile: vectors.profile, nodes: [{ id: "value", shape: testCase.sealed }],
    definitions: [], sources: [], provenance: [], groups: [], annotations: [],
  });
  const root = checked.refs.get("value")!;
  const samples = sampleValues(checked.context, root).values;
  for (const value of samples) expect(() => checked.context.validate(root, value)).not.toThrow();
  if (exactCases?.tag !== "Array") throw new Error("vector cases");
  const expected = V.member(exactCases.items[index]!, "expected")!;
  expect(V.encodeExact(sortedExact({ tag: "Array", items: samples }))).toBe(V.encodeExact(sortedExact(expected)));
});
