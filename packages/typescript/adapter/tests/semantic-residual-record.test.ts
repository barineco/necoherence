// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { decodeCanonical } from "neco-quotient-encoding";
import { expect, it } from "vitest";
import { SEMANTIC_RESIDUAL_SCHEMA, encodeSemanticResidual } from "../src/semantic_residual_record.js";
import type * as S from "../src/semantic_signatures.js";
import type * as V from "../src/semantic_values.js";

const digest = "d".repeat(64);
const profile: V.ProfileRef = { identity: "residual-test", revision: "2", content_digest: digest };
const source: V.SourceRef = { repository: "residual-test", revision: "2", path: "types", content_digest: digest, document_id: "doc", declared_revision: null };
const ref = (name: string): V.TypeRef => ({ source, definition_name: name, pointer: [] });
const basis: S.SignatureGenerationBasis = {
  signature_schema: "ncoh-type-signatures@1", library_identity: "residual-test", library_revision: "2", profile,
  graph_sha256: "1".repeat(64), provenance_sha256: "2".repeat(64), metadata_sha256: "3".repeat(64),
  problem_sha256: null, observations_sha256: null, entrypoints_sha256: "6".repeat(64),
};
const value: V.ExactJson = {
  tag: "Object",
  members: [
    { key: "count", value: { tag: "Integer", value: "12345678901234567890" } },
    { key: "nested", value: { tag: "Array", items: [{ tag: "Integer", value: "-7" }, { tag: "Decimal", text: "1.50" }, { tag: "Object", members: [{ key: "deep", value: { tag: "Integer", value: "0" } }] }] } },
  ],
};
const obligation = (reason: V.SemanticReason, path: readonly V.PathStep[]): V.SemanticObligation => ({
  type_ref: ref("subject"), origin: { source, pointer: ["subject"] }, value_path: path, profile, reason,
});
const first = obligation({ tag: "OpaqueType", value: "external" }, [{ tag: "Field", value: "nested" }, { tag: "Index", value: "3" }]);
const second = obligation({ tag: "MissingGraphemeRules" }, [{ tag: "Field", value: "count" }]);
const third = obligation({ tag: "UnknownFormat", value: "uri" }, []);

function encoded(obligations: readonly V.SemanticObligation[]): Uint8Array {
  const result = encodeSemanticResidual(basis, ref("subject"), value, obligations);
  if (!result.ok) throw new Error(JSON.stringify(result.error));
  return result.value;
}

function hasNumber(node: unknown): boolean {
  if (typeof node === "number") return true;
  if (Array.isArray(node)) return node.some(hasNumber);
  if (node !== null && typeof node === "object") return Object.values(node).some(hasNumber);
  return false;
}

it("義務の列の順序と重複が bytes を変えない", () => {
  const base = encoded([first, second, third]);
  expect(encoded([third, second, first])).toEqual(base);
  expect(encoded([first, second, third, first, second])).toEqual(base);
});

it("書き出した bytes が 4 つの欄を持つ正規の記録として読める", () => {
  const bytes = encoded([first, second, third, second]);
  const decoded = decodeCanonical(bytes);
  if (!decoded.ok) throw new Error(JSON.stringify(decoded.error));
  expect(decoded.value.kind).toBe("object");
  if (decoded.value.kind !== "object") return;
  expect(decoded.value.fields.map(([key]) => key).sort()).toEqual(["basis", "input", "residuals", "schema"]);
  const record = JSON.parse(new TextDecoder().decode(bytes));
  expect(record.schema).toBe(SEMANTIC_RESIDUAL_SCHEMA);
  expect(record.residuals).toHaveLength(3);
});

it("値の欄が tag 付きの record で書かれ JSON の数値を含まない", () => {
  const record = JSON.parse(new TextDecoder().decode(encoded([first, second])));
  expect(record.input.value).toEqual({
    tag: "Object",
    members: [
      { key: "count", value: { tag: "Integer", value: "12345678901234567890" } },
      { key: "nested", value: { tag: "Array", items: [{ tag: "Integer", value: "-7" }, { tag: "Decimal", text: "1.50" }, { tag: "Object", members: [{ key: "deep", value: { tag: "Integer", value: "0" } }] }] } },
    ],
  });
  expect(record.residuals.some((item: { value_path: unknown }) => JSON.stringify(item.value_path).includes("\"Index\",\"value\":\"3\""))).toBe(true);
  for (const item of record.residuals) expect(Object.keys(item).sort()).toEqual(["origin", "profile", "reason", "type_ref", "value_path"]);
  expect(hasNumber(record)).toBe(false);
});
