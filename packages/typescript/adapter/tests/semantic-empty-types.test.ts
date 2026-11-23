// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import { emptyTypes, verifyEmptyTypes } from "../src/semantic_empty_types.js";
import * as V from "../src/semantic_values.js";

const digest = "b".repeat(64);
const source: V.SourceRef = { repository: "synthetic", revision: "1", path: "types", content_digest: digest, document_id: "semantic-inclusion" };
const profileRef: V.ProfileRef = { identity: "semantic-inclusion", revision: "1", content_digest: digest };
const ref = (name: string): V.TypeRef => ({ source, definition_name: name, pointer: [] });
const node = (name: string, shape: V.TypeShape): V.TypeNode => ({ reference: ref(name), shape, description: null, attributes: [], extensions: [] });
const string = (constant: string | null = null, format: V.FormatUse | null = null, maximum: string | null = null): V.TypeShape => ({
  tag: "String",
  value: { format, lengths: maximum === null ? [] : [{ unit: { tag: "UnicodeScalars" }, minimum: null, maximum }], wrapper: null, const_value: constant, enum_values: null, examples: [], default_value: null },
});
const integer = (maximum: string | null): V.TypeShape => ({ tag: "Integer", value: { domain: "natural", minimum: "0", maximum, const_value: null, enum_values: null, default_value: null } });
const profile: V.VersionedSemanticProfile = {
  reference: profileRef,
  source_refs: [source],
  integer_domains: [{ name: "natural", reference: profileRef, range: { tag: "Inclusive", fields: { minimum: "0", maximum: "100" } }, forms: [{ tag: "Number" }] }],
  default_integer_domain: "natural",
  numbers: { decimals: true },
  grapheme_rules: null,
  format_bindings: [{ name: "only-y", reference: profileRef, rule: { tag: "Literal", value: "y" } }],
  bytes_policy: { reference: profileRef, padding_optional: true, alphabet: { tag: "Standard" }, strict_pad_bits: true, wrapper: "bytes" },
  wrappers: [{ name: "bytes", key: "bytes", payload: { tag: "Bytes" } }],
  tag: { key: "tag", format: null, sealed: [] },
};
const context = (nodes: readonly V.TypeNode[]): V.ValueContext => new V.ValueContext({ profile, nodes }, [source]);

it("does not classify an empty integer interval or an unrestricted string as empty", () => {
  const valueContext = context([
    node("integer", { tag: "Integer", value: { domain: "natural", minimum: "2", maximum: "1", const_value: null, enum_values: null, default_value: null } }),
    node("string", string()),
    node("empty-string", string("x", { tag: "Named", value: "only-y" })),
  ]);
  expect(emptyTypes(valueContext).map(reference => reference.definition_name)).toEqual(["empty-string"]);
  expect(verifyEmptyTypes(valueContext, [ref("empty-string")]).tag).toBe("Ok");
  expect(verifyEmptyTypes(valueContext, [ref("integer")])).toMatchObject({ tag: "Failed", failure: { tag: "ForgedEmptiness" } });
  expect(verifyEmptyTypes(valueContext, [ref("string")])).toMatchObject({ tag: "Failed", failure: { tag: "ForgedEmptiness" } });
});

it("does not classify a string whose undefined format leaves its finite values unconstrained as empty", () => {
  const valueContext = context([node("missing", string("a", { tag: "Named", value: "missing" }))]);
  expect(emptyTypes(valueContext)).toEqual([]);
  expect(verifyEmptyTypes(valueContext, [ref("missing")])).toMatchObject({ tag: "Failed", failure: { tag: "ForgedEmptiness" } });
});
