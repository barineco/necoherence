// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import gleam/string
import necoherence/semantic_types as types

pub fn profile_ref() -> types.ProfileRef {
  types.ProfileRef("test-profile", "4", string.repeat("a", 64))
}

pub fn source() -> types.SourceRef {
  types.SourceRef(
    "test",
    "4",
    "types.json",
    string.repeat("b", 64),
    "test",
    None,
  )
}

pub fn reference(name: String) -> types.TypeRef {
  types.TypeRef(source(), name, [name])
}

pub fn occurrence() -> types.OccurrenceRef {
  types.OccurrenceRef(source(), [])
}

pub fn profile() -> types.SemanticProfile {
  let reference = profile_ref()
  types.SemanticProfile(
    reference,
    [],
    [
      types.IntegerDomainBinding("integer", reference, types.Unbounded, [
        types.Number,
        types.IntegralDecimal,
        types.DecimalString,
      ]),
    ],
    "integer",
    types.NumberModel(True),
    None,
    [
      types.FormatBinding("text", reference, types.Text),
      types.FormatBinding("not-x", reference, types.Not(types.Literal("x"))),
      types.FormatBinding("key-x", reference, types.Literal("x")),
    ],
    Some(types.BytesPolicy(reference, True, types.Either, True, Some("bytes"))),
    [
      types.Wrapper("bytes", "bytes", types.WrapperBytes),
      types.Wrapper("text", "text", types.WrapperText(None)),
    ],
    Some(
      types.TagModel("tag", None, [
        types.SealedForm("sealed", [], types.SealedReject),
      ]),
    ),
  )
}

pub fn graph(nodes: List(types.TypeNode)) -> types.SemanticGraph {
  types.SemanticGraph(profile(), nodes, [source()])
}

pub fn node(name: String, shape: types.TypeShape) -> types.TypeNode {
  types.TypeNode(reference(name), shape, None, [], [])
}

pub fn field(
  name: String,
  type_name: String,
  required: Bool,
  nullable: Bool,
) -> types.FieldSpec {
  types.FieldSpec(
    name,
    types.SlotContract(reference(type_name), required, nullable),
    occurrence(),
  )
}

pub fn string_spec(format: option.Option(types.FormatUse)) -> types.StringSpec {
  types.StringSpec(format, [], None, None, None, [], None)
}
