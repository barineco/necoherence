// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { generation, library } from "./semantic-fixture.js";

it("admits @4 and preserves exact codec roundtrips", () => {
  const input = generation(), admitted = S.admitSignatureGeneration(input.basis, JSON.stringify(input));
  expect(admitted.tag).toBe("Admitted");
  if (admitted.tag !== "Admitted") return;
  const integer: V.ExactJson = { tag: "String", value: "900719925474099312345" };
  const codec = admitted.checked.codec("integer");
  expect(codec.decode(codec.encode(integer))).toEqual(integer);
});

it("rejects @3 and altered generation bases", () => {
  const input = generation();
  expect(S.admitSignatureGeneration(input.basis, JSON.stringify({ ...input, schema: "ncoh-checked-generation@3" }))).toMatchObject({ tag: "Failed", failure: { tag: "UnsupportedSchema" } });
  expect(S.admitSignatureGeneration({ ...input.basis, graph_sha256: "0".repeat(64) }, JSON.stringify(input))).toMatchObject({ tag: "Failed", failure: { tag: "BasisMismatch" } });
});

it("preserves graph and metadata digest invariants", () => {
  const input = library();
  const reordered = { ...input, nodes: [...input.nodes].reverse() };
  const annotated = { ...input, annotations: [{ target: { tag: "Library" as const }, key: "description", value: { tag: "String" as const, value: "changed" } }] };
  expect(S.signatureBasis(reordered, generation(reordered).entrypoints).graph_sha256).toBe(S.signatureBasis(input, generation(input).entrypoints).graph_sha256);
  expect(S.signatureBasis(annotated, generation(annotated).entrypoints).metadata_sha256).not.toBe(S.signatureBasis(input, generation(input).entrypoints).metadata_sha256);
});
