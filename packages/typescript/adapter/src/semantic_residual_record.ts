// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { canonicalBytes, normalizeResiduals } from "neco-quotient-encoding";
import type { EncodingFailure, JsonValue as Neco, Result } from "neco-quotient-encoding";
import * as S from "./semantic_signatures.js";
import type * as V from "./semantic_values.js";

export const SEMANTIC_RESIDUAL_SCHEMA = "necoherence.semantic-residual.v1";

export type SemanticResidualFailure =
  | { readonly tag: "Encoding"; readonly failure: EncodingFailure }
  | { readonly tag: "Wire"; readonly message: string };

function toNeco(value: unknown): Neco {
  if (value === null) return { kind: "null" };
  if (typeof value === "boolean") return { kind: "bool", value };
  if (typeof value === "string") return { kind: "string", value };
  if (typeof value === "number" || typeof value === "bigint") return { kind: "number", notation: String(value) };
  if (Array.isArray(value)) return { kind: "array", items: value.map(toNeco) };
  const members = value as Record<string, unknown>;
  return { kind: "object", fields: Object.keys(members).map(key => [key, toNeco(members[key])] as const) };
}

function wireToNeco(text: string): Neco {
  return toNeco(JSON.parse(text));
}

function wireFailure(error: unknown): SemanticResidualFailure {
  return { tag: "Wire", message: error instanceof Error ? error.message : String(error) };
}

export function encodeSemanticResidual(
  basis: S.SignatureGenerationBasis,
  typeRef: V.TypeRef,
  value: V.ExactJson,
  obligations: readonly V.SemanticObligation[],
): Result<Uint8Array, SemanticResidualFailure> {
  let basisWire: Neco, typeRefWire: Neco, valueWire: Neco, obligationsWire: Neco;
  try {
    basisWire = wireToNeco(S.encodeGenerationBasisWire(basis));
    typeRefWire = wireToNeco(S.encodeTypeRefWire(typeRef));
    valueWire = wireToNeco(S.encodeExactJsonWire(value));
    obligationsWire = wireToNeco(S.encodeSemanticObligationsWire(obligations));
  } catch (error) {
    return { ok: false, error: wireFailure(error) };
  }
  const items = obligationsWire.kind === "array" ? obligationsWire.items : [obligationsWire];
  const residuals = normalizeResiduals(items);
  if (!residuals.ok) return { ok: false, error: { tag: "Encoding", failure: residuals.error } };
  const record: Neco = {
    kind: "object",
    fields: [
      ["schema", { kind: "string", value: SEMANTIC_RESIDUAL_SCHEMA }],
      ["basis", basisWire],
      ["input", { kind: "object", fields: [["type_ref", typeRefWire], ["value", valueWire]] }],
      ["residuals", { kind: "array", items: residuals.value }],
    ],
  };
  const bytes = canonicalBytes(record);
  return bytes.ok ? bytes : { ok: false, error: { tag: "Encoding", failure: bytes.error } };
}
