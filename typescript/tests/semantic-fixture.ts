// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";

export const digest = "a".repeat(64);
export const reference: V.ProfileRef = { identity: "semantic-test", revision: "4", content_digest: digest };
export const source: V.SourceRef = { repository: "semantic-test", revision: "4", path: "types", content_digest: digest, document_id: "" };
export const sourceIdentity: V.SourceIdentity = { repository: source.repository, revision: source.revision, path: source.path, content_digest: source.content_digest };
export const profile: S.ValueSemanticProfile & V.VersionedSemanticProfile = {
  reference, source_refs: [sourceIdentity],
  integer_domains: [{ name: "integer", reference, range: { tag: "Unbounded" }, forms: [{ tag: "Number" }, { tag: "DecimalString" }] }],
  default_integer_domain: "integer", numbers: { decimals: true },
  grapheme_rules: {
    reference,
    component: { unicode_version: "15.1.0", uax29_revision: "45", cluster_profile: "extended" },
    table_sha256: digest,
    sources: [],
    properties: [{ first: "769", last: "769", property: { tag: "Extend" } }],
    extended_pictographic: [], indic_conjunct: [],
  },
  format_bindings: [
    { name: "identifier", reference, rule: { tag: "Identifier", fields: { first_alphabet: "abcdefghijklmnopqrstuvwxyz", rest_alphabet: "abcdefghijklmnopqrstuvwxyz0123456789", exact_length: null, min_length: "1", max_length: null, forbidden: [] } } },
    { name: "text", reference, rule: { tag: "Text" } },
  ],
  bytes_policy: { reference, padding_optional: true, alphabet: { tag: "Standard" }, strict_pad_bits: true, wrapper: "bytes" },
  wrappers: [{ name: "bytes", key: "binary", payload: { tag: "Bytes" } }, { name: "text", key: "wrapped", payload: { tag: "Text", value: "identifier" } }],
  tag: { key: "kind", format: "identifier", sealed: [{ tag: "sealed", fields: [{ key: "name", required: true, leaf: { tag: "String", value: stringSpec() } }], extras: { tag: "Reject" } }] },
};
export function stringSpec(format: V.FormatUse | null = null): V.StringSpec {
  return { format, lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null };
}
export function library(): S.TypeSignatureLibrary {
  return {
    schema: "ncoh-type-signatures@1", identity: "semantic-test", revision: "4", profile,
    sources: [], provenance: [], groups: [], annotations: [],
    nodes: [
      { id: "text", shape: { tag: "String", value: stringSpec() } },
      { id: "integer", shape: { tag: "Integer", value: { domain: null, minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null } } },
      { id: "sealed", shape: { tag: "Sealed", fields: { tag: "sealed", refinements: [] } } },
      { id: "union", shape: { tag: "TaggedUnion", value: { branches: [{ target: "sealed", wire_tag: "sealed", selector: { tag: "InternalTag" } }] } } },
    ],
    definitions: [
      { id: "text", wire_identity: "Text", shape: { tag: "Value", value: "text" } },
      { id: "integer", wire_identity: "Integer", shape: { tag: "Value", value: "integer" } },
      { id: "sealed", wire_identity: "Sealed", shape: { tag: "Value", value: "sealed" } },
      { id: "union", wire_identity: "Union", shape: { tag: "Value", value: "union" } },
    ],
  };
}
export function generation(subject = library()): S.SignatureGenerationInput {
  const entrypoints = subject.definitions.map(definition => ({ identity: definition.wire_identity, definition: definition.id }));
  return { schema: "ncoh-checked-generation@4", basis: S.signatureBasis(subject, entrypoints), signatures: subject, composition: null, entrypoints };
}
