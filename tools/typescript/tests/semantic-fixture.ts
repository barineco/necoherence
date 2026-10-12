// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { semanticSignatures as S } from "necoherence";

const digest = "a".repeat(64), reference = { identity: "tools-test", revision: "4", content_digest: digest };
const source = { repository: "fixture", revision: "4", path: "signature.json", content_digest: digest };
const origin = { source, locator: ["operation"] };
export function library(): S.TypeSignatureLibrary {
  return {
    schema: "ncoh-type-signatures@1", identity: "tools-test", revision: "4",
    profile: {
      reference, source_refs: [], integer_domains: [{ name: "integer", reference, range: { tag: "Unbounded" }, forms: [{ tag: "Number" }] }],
      default_integer_domain: "integer", numbers: { decimals: true }, grapheme_rules: null,
      format_bindings: [], bytes_policy: null, wrappers: [], tag: null,
    },
    sources: [source], provenance: [], groups: [],
    annotations: [
      { target: { tag: "Library" }, key: "complete", value: { tag: "Object", members: [{ key: "integer", value: { tag: "Integer", value: "9007199254740993" } }, { key: "decimal", value: { tag: "Decimal", text: "1.000000000000000000001" } }] } },
      { target: { tag: "Outcome", fields: { definition: "request", outcome: "external" } }, key: "detail", value: { tag: "Integer", value: "9007199254740993" } },
    ],
    nodes: [
      { id: "text", shape: { tag: "String", value: { format: null, lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null } } },
      { id: "truth", shape: { tag: "Boolean", value: { const_value: null, default_value: null } } },
      { id: "unit", shape: { tag: "Unit" } },
      { id: "product", shape: { tag: "Product", value: { fields: [], extras: { tag: "Reject" } } } },
    ],
    definitions: [
      { id: "text", wire_identity: "Text", shape: { tag: "Value", value: "text" } },
      { id: "truth", wire_identity: "Truth", shape: { tag: "Value", value: "truth" } },
      { id: "product", wire_identity: "Product", shape: { tag: "Value", value: "product" } },
      { id: "request", wire_identity: "Request", shape: { tag: "Operation", value: {
        effect: { tag: "HttpRequestResponse" }, inputs: [],
        outcomes: [
          { id: "ok", form: { tag: "Success" }, cause: { tag: "ValueContract", fields: { origin } }, value_ports: [{ id: "value", contract: { type_id: "unit", required: true, nullable: false } }], produced_resources: [] },
          { id: "external", form: { tag: "DeclaredFailure" }, cause: { tag: "ExternalCondition", fields: { specification: origin } }, value_ports: [{ id: "reason", contract: { type_id: "unit", required: true, nullable: false } }], produced_resources: [] },
        ],
      } } },
    ],
  };
}
export function generation(): S.SignatureGenerationInput {
  const signatures = library(), entrypoints = [{ identity: "Text", definition: "text" }, { identity: "Truth", definition: "truth" }, { identity: "Product", definition: "product" }, { identity: "Request", definition: "request" }];
  return { schema: "ncoh-checked-generation@4", basis: S.signatureBasis(signatures, entrypoints), signatures, composition: null, entrypoints };
}
