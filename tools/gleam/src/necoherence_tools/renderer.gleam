// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import necoherence/exact_json as kdl
import necoherence/semantic_composition as composition
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types

pub type RenderFailure {
  MissingType(reference: types.TypeRef)
  UnsupportedType(reference: types.TypeRef)
  UnsupportedEffect(reference: composition.FunctionRef)
  InvalidSurface(condition: String)
  Signature(failure: signatures.Failure)
  IdentifierCollision(
    namespace: IdentifierNamespace,
    name: String,
    first: IdentifierOrigin,
    second: IdentifierOrigin,
  )
}

pub type IdentifierNamespace {
  TypeNamespace
  ConstructorNamespace
  ValueNamespace
  LabelNamespace(owner: String)
}

pub type IdentifierRole {
  TypeRole
  ConstructorRole
  ValueRole
  FieldRole
  PortRole
  SignatureRole
}

pub type SignatureTypeSurface {
  ValueAlias
  InputType
  OutcomeType
  BindingAlias
}

pub type SignatureConstructorSurface {
  InputConstructor
}

pub type SignatureValueSurface {
  IdentityConstant
  DecodeValue
  EncodeValue
  SymbolConstant
  OutcomeIdHelper
  ValidateInput
  ValidateOutcome
  ToOutcome
  FromOutcome
  EncodeOutcome
  DecodeOutcome
  CallOperation
}

pub type IdentifierOrigin {
  TypeOrigin(reference: types.TypeRef)
  TypeConstructorOrigin(reference: types.TypeRef, identifier: String)
  TypeValueOrigin(reference: types.TypeRef, identifier: String)
  FieldOrigin(owner: types.TypeRef, wire_name: String)
  UnionBranchOrigin(
    owner: types.TypeRef,
    wire_tag: String,
    target: types.TypeRef,
  )
  SignatureTypeOrigin(
    id: String,
    wire_identity: String,
    surface: SignatureTypeSurface,
  )
  SignatureConstructorOrigin(
    id: String,
    wire_identity: String,
    surface: SignatureConstructorSurface,
  )
  SignatureValueOrigin(
    id: String,
    wire_identity: String,
    surface: SignatureValueSurface,
  )
  InputPortOrigin(signature_id: String, port_id: String)
  OutcomeConstructorOrigin(
    id: String,
    wire_identity: String,
    outcome_id: String,
  )
  OutcomePortOrigin(id: String, outcome_id: String, port_id: String)
  ReservedOrigin(role: IdentifierRole, identifier: String)
}

type Names =
  Dict(types.TypeRef, String)

fn quote(value: String) -> String {
  let body =
    value
    |> string.to_utf_codepoints
    |> list.map(fn(point) {
      let code = string.utf_codepoint_to_int(point)
      case code {
        0x5c -> "\\\\"
        0x22 -> "\\\""
        0x0a -> "\\n"
        0x0d -> "\\r"
        0x09 -> "\\t"
        _ if code < 0x20 || code == 0x7f -> "\\u{" <> int.to_base16(code) <> "}"
        _ -> string.from_utf_codepoints([point])
      }
    })
    |> string.concat
  "\"" <> body <> "\""
}

fn boolean(value: Bool) -> String {
  case value {
    True -> "True"
    False -> "False"
  }
}

fn profile_ref_literal(profile: types.ProfileRef) -> String {
  let types.ProfileRef(identity, revision, content_digest) = profile
  "types.ProfileRef("
  <> string.join(list.map([identity, revision, content_digest], quote), ", ")
  <> ")"
}

fn generation_requirement_literal(
  requirement: signatures.GenerationRequirement,
) -> String {
  "signatures.GenerationRequirement("
  <> string.join(
    [
      quote(requirement.signature_schema),
      quote(requirement.library_identity),
      quote(requirement.library_revision),
      profile_ref_literal(requirement.profile),
      quote(requirement.graph_sha256),
      quote(requirement.provenance_sha256),
      quote(requirement.metadata_sha256),
      case requirement.problem_sha256 {
        None -> "None"
        Some(value) -> "Some(" <> quote(value) <> ")"
      },
      quote(requirement.entrypoints_sha256),
    ],
    ", ",
  )
  <> ")"
}

fn source_literal(source: types.SourceRef) -> String {
  "types.SourceRef("
  <> string.join(
    [
      quote(source.repository),
      quote(source.revision),
      quote(source.path),
      quote(source.content_digest),
      quote(source.document_id),
      case source.declared_revision {
        None -> "None"
        Some(revision) -> "Some(" <> int.to_string(revision) <> ")"
      },
    ],
    ", ",
  )
  <> ")"
}

fn reference_literal(reference: types.TypeRef) -> String {
  "types.TypeRef("
  <> source_literal(reference.source)
  <> ", "
  <> quote(reference.definition_name)
  <> ", ["
  <> string.join(list.map(reference.pointer, quote), ", ")
  <> "])"
}

fn name(
  names: Names,
  reference: types.TypeRef,
) -> Result(String, RenderFailure) {
  result.map_error(dict.get(names, reference), fn(_) { MissingType(reference) })
}

fn lower(name: String) -> String {
  string.lowercase(name)
}

fn ascii_alphanumeric(code: Int) -> Bool {
  code >= 0x30
  && code <= 0x39
  || code >= 0x41
  && code <= 0x5a
  || code >= 0x61
  && code <= 0x7a
}

fn padded_hex(value: Int, width: Int) -> String {
  let encoded = int.to_base16(value) |> string.lowercase
  string.repeat("0", int.max(0, width - string.length(encoded))) <> encoded
}

fn identifier_tokens(value: String) -> List(String) {
  let state =
    list.fold(string.to_utf_codepoints(value), #([], "", []), fn(state, point) {
      let code = string.utf_codepoint_to_int(point)
      case ascii_alphanumeric(code) {
        True -> #(
          state.0,
          state.1 <> string.from_utf_codepoints([point]),
          state.2,
        )
        False if code > 0x7f -> #(
          [
            "u" <> padded_hex(code, 6),
            ..case state.1 {
              "" -> state.0
              _ -> [state.1, ..state.0]
            }
          ],
          "",
          state.2,
        )
        False -> #(
          case state.1 {
            "" -> state.0
            _ -> [state.1, ..state.0]
          },
          "",
          ["x" <> padded_hex(code, 2), ..state.2],
        )
      }
    })
  let tokens = case state.1 {
    "" -> state.0
    _ -> [state.1, ..state.0]
  }
  case list.reverse(tokens) {
    [] -> list.reverse(state.2)
    tokens -> tokens
  }
}

fn upper_token(token: String) -> String {
  case string.to_utf_codepoints(token) {
    [first, ..rest] ->
      string.uppercase(string.from_utf_codepoints([first]))
      <> string.from_utf_codepoints(rest)
    [] -> ""
  }
}

pub fn upper_identifier(identity: String, role: String) -> String {
  let rendered =
    string.concat(list.map(identifier_tokens(identity), upper_token))
  case string.to_utf_codepoints(rendered) {
    [first, ..] -> {
      let code = string.utf_codepoint_to_int(first)
      case code >= 0x30 && code <= 0x39 {
        True -> role <> rendered
        False -> rendered
      }
    }
    _ -> rendered
  }
}

fn gleam_keyword(name: String) -> Bool {
  list.contains(
    [
      "as", "assert", "auto", "case", "const", "delegate", "derive", "echo",
      "else", "fn", "if", "implement", "import", "let", "macro", "opaque",
      "panic", "pub", "test", "todo", "type", "use",
    ],
    name,
  )
}

pub fn lower_identifier(identity: String, role: String) -> String {
  let rendered =
    identifier_tokens(identity)
    |> list.map(string.lowercase)
    |> string.join("_")
  case string.to_utf_codepoints(rendered) {
    [first, ..] -> {
      let code = string.utf_codepoint_to_int(first)
      case code >= 0x30 && code <= 0x39 {
        True -> role <> "_" <> rendered
        False ->
          case gleam_keyword(rendered) {
            True -> role <> "_" <> rendered
            False -> rendered
          }
      }
    }
    _ -> rendered
  }
}

fn type_identity(reference: types.TypeRef) -> String {
  let relative = case reference.pointer {
    [first, ..rest] if first == reference.definition_name -> rest
    pointer -> pointer
  }
  string.join([reference.definition_name, ..relative], ".")
}

pub fn type_codec_identifier(reference: types.TypeRef) -> String {
  lower(upper_identifier(type_identity(reference), "Type"))
}

fn unique_identifiers(
  entries: List(#(IdentifierNamespace, String, IdentifierOrigin)),
) -> Result(Nil, RenderFailure) {
  let checked =
    list.try_fold(entries, dict.new(), fn(seen, entry) {
      let key = #(entry.0, entry.1)
      case dict.get(seen, key) {
        Error(_) -> Ok(dict.insert(seen, key, entry.2))
        Ok(first) ->
          Error(IdentifierCollision(entry.0, entry.1, first, entry.2))
      }
    })
  result.map(checked, fn(_) { Nil })
}

fn ref_name(name: String) -> String {
  "ref_" <> lower(name)
}

fn pack(name: String, value: String) -> String {
  "pack_" <> lower(name) <> "(context, " <> value <> ")"
}

fn unpack(name: String, value: String) -> String {
  "unpack_" <> lower(name) <> "(context, " <> value <> ")"
}

fn scalar_payload(shape: types.TypeShape) -> String {
  case shape {
    types.BooleanShape(_) -> "Bool"
    types.IntegerShape(_) -> "Int"
    types.DecimalShape(_) -> "String"
    types.StringShape(_) -> "String"
    types.BytesShape(_) | types.RawBodyShape(_) -> "List(Int)"
    types.UnknownShape(_) -> "kdl.JsonValue"
    types.UnitShape -> "Nil"
    _ -> ""
  }
}

fn shape_default(shape: types.TypeShape) -> Option(kdl.JsonValue) {
  case shape {
    types.BooleanShape(spec) ->
      option.map(spec.default_value, kdl.JsonValueBool)
    types.IntegerShape(spec) -> option.map(spec.default_value, kdl.JsonValueNum)
    types.StringShape(spec) -> option.map(spec.default_value, kdl.JsonValueStr)
    _ -> None
  }
}

fn render_type(
  node: types.TypeNode,
  type_name: String,
  names: Names,
) -> Result(List(String), RenderFailure) {
  use shape <- result.try(case node.shape {
    types.ProductShape(spec) -> render_product(type_name, spec, names)
    types.ArrayShape(spec) -> render_array(type_name, spec, names)
    types.AliasShape(target, _) -> render_alias(type_name, target, names)
    types.TaggedUnionShape(spec) -> render_union(type_name, spec, names)
    types.Never -> Ok(render_never(type_name))
    types.SealedShape(tag, _) -> Ok(render_sealed(type_name, tag))
    types.OpaqueShape(_) -> Error(UnsupportedType(node.reference))
    shape -> Ok(render_scalar(type_name, shape))
  })
  let function_name = lower(type_name)
  let payload_type = shape.0
  let wire_field = case node.shape {
    types.BytesShape(_) | types.RawBodyShape(_) -> ", wire: Option(String)"
    types.ProductShape(_) -> ", member_order: List(String)"
    _ -> ""
  }
  let wire_argument = case node.shape {
    types.BytesShape(_) | types.RawBodyShape(_) -> ", None"
    types.ProductShape(_) -> ", []"
    _ -> ""
  }
  use default <- result.try(case shape_default(node.shape) {
    None -> Ok([])
    Some(value) -> {
      use literal <- result.try(scalar_literal(value, node.reference))
      Ok([
        "pub fn default_"
        <> function_name
        <> "(context: Context) -> Result("
        <> type_name
        <> ", ValueFailure) { new_"
        <> function_name
        <> "(context, "
        <> literal
        <> ") }",
      ])
    }
  })
  let common = [
    "pub const "
      <> ref_name(type_name)
      <> ": types.TypeRef = "
      <> reference_literal(node.reference),
    "pub opaque type "
      <> type_name
      <> " { "
      <> type_name
      <> "(value: "
      <> payload_type
      <> wire_field
      <> ") }",
    "pub fn value_"
      <> function_name
      <> "(value: "
      <> type_name
      <> ") -> "
      <> payload_type
      <> " { value.value }",
    "pub fn new_"
      <> function_name
      <> "(context: Context, value: "
      <> payload_type
      <> ") -> Result("
      <> type_name
      <> ", ValueFailure) {",
    "  let wrapped = " <> type_name <> "(value" <> wire_argument <> ")",
    "  use raw <- result.try(" <> pack(type_name, "wrapped") <> ")",
    "  use _ <- result.try(runtime.validate_value(graph(context), "
      <> ref_name(type_name)
      <> ", raw))",
    "  Ok(wrapped)",
    "}",
    "pub fn from_value_"
      <> function_name
      <> "(context: Context, value: kdl.JsonValue) -> Result("
      <> type_name
      <> ", ValueFailure) {",
    "  use _ <- result.try(runtime.validate_value(graph(context), "
      <> ref_name(type_name)
      <> ", value))",
    "  " <> unpack(type_name, "value"),
    "}",
    "pub fn to_value_"
      <> function_name
      <> "(context: Context, value: "
      <> type_name
      <> ") -> Result(kdl.JsonValue, ValueFailure) {",
    "  use raw <- result.try(" <> pack(type_name, "value") <> ")",
    "  use _ <- result.try(runtime.validate_value(graph(context), "
      <> ref_name(type_name)
      <> ", raw))",
    "  Ok(raw)",
    "}",
    "pub fn decode_"
      <> function_name
      <> "(context: Context, wire: String) -> Result("
      <> type_name
      <> ", ValueFailure) {",
    "  use raw <- result.try(result.map_error(values.parse_wire(wire), fn(failure) { runtime.Wire("
      <> ref_name(type_name)
      <> ", failure) }))",
    "  from_value_" <> function_name <> "(context, raw)",
    "}",
    "pub fn encode_"
      <> function_name
      <> "(context: Context, value: "
      <> type_name
      <> ") -> Result(String, ValueFailure) {",
    "  use raw <- result.try(to_value_" <> function_name <> "(context, value))",
    "  result.map_error(values.encode_wire(raw), fn(failure) { runtime.Wire("
      <> ref_name(type_name)
      <> ", failure) })",
    "}",
    "pub fn with_defaults_"
      <> function_name
      <> "(context: Context, wire: String) -> Result("
      <> type_name
      <> ", ValueFailure) {",
    "  use raw <- result.try(result.map_error(values.parse_unique_wire(wire), fn(failure) { runtime.Wire("
      <> ref_name(type_name)
      <> ", failure) }))",
    "  use defaulted <- result.try(result.map_error(validation.materialize_defaults(graph(context), "
      <> ref_name(type_name)
      <> ", raw), runtime.Constraint))",
    "  " <> unpack(type_name, "validation.defaulted_value(defaulted)"),
    "}",
  ]
  Ok(list.flatten([[""], shape.1, common, shape.2, default, [""]]))
}

fn scalar_literal(
  value: kdl.JsonValue,
  reference: types.TypeRef,
) -> Result(String, RenderFailure) {
  case value {
    kdl.JsonValueBool(flag) -> Ok(boolean(flag))
    kdl.JsonValueNum(number) -> Ok(int.to_string(number))
    kdl.JsonValueStr(text) -> Ok(quote(text))
    _ -> Error(UnsupportedType(reference))
  }
}

fn render_scalar(
  type_name: String,
  shape: types.TypeShape,
) -> #(String, List(String), List(String)) {
  let function_name = lower(type_name)
  let encoded = case shape {
    types.BooleanShape(_) -> "Ok(kdl.JsonValueBool(value.value))"
    types.IntegerShape(_) -> "Ok(kdl.JsonValueNum(value.value))"
    types.DecimalShape(_) -> "Ok(kdl.JsonValueDec(value.value))"
    types.StringShape(spec) ->
      case spec.wrapper {
        None -> "Ok(kdl.JsonValueStr(value.value))"
        Some(wrapper) ->
          "result.map_error(runtime.wrap_encode(graph(context).profile, "
          <> quote(wrapper)
          <> ", kdl.JsonValueStr(value.value)), fn(_) { runtime.Representation("
          <> ref_name(type_name)
          <> ", \"wrapper encode\") })"
      }
    types.BytesShape(_) | types.RawBodyShape(_) ->
      "use encoded <- result.try(case value.wire { Some(text) -> Ok(text) None -> result.map_error(native.encode_bytes(value.value), fn(_) { runtime.Representation("
      <> ref_name(type_name)
      <> ", \"byte outside 0..255\") }) }) case graph(context).profile.bytes_policy { Some(types.BytesPolicy(wrapper: Some(name), ..)) -> result.map_error(runtime.wrap_encode(graph(context).profile, name, kdl.JsonValueStr(encoded)), fn(_) { runtime.Representation("
      <> ref_name(type_name)
      <> ", \"wrapper encode\") }) _ -> Ok(kdl.JsonValueStr(encoded)) }"
    types.UnitShape -> "Ok(kdl.JsonValueNull)"
    types.UnknownShape(_) -> "Ok(value.value)"
    _ -> "representation(" <> ref_name(type_name) <> ")"
  }
  let decoded = case shape {
    types.BooleanShape(_) ->
      "case value { kdl.JsonValueBool(value) -> Ok("
      <> type_name
      <> "(value)) _ -> representation("
      <> ref_name(type_name)
      <> ") }"
    types.IntegerShape(_) ->
      "case value { kdl.JsonValueNum(value) -> Ok("
      <> type_name
      <> "(value)) _ -> representation("
      <> ref_name(type_name)
      <> ") }"
    types.DecimalShape(_) ->
      "case value { kdl.JsonValueDec(value) -> Ok("
      <> type_name
      <> "(value)) _ -> representation("
      <> ref_name(type_name)
      <> ") }"
    types.StringShape(spec) ->
      case spec.wrapper {
        None ->
          "case value { kdl.JsonValueStr(value) -> Ok("
          <> type_name
          <> "(value)) _ -> representation("
          <> ref_name(type_name)
          <> ") }"
        Some(wrapper) ->
          "use payload <- result.try(result.map_error(runtime.wrap_decode(graph(context).profile, "
          <> quote(wrapper)
          <> ", value), fn(_) { runtime.Representation("
          <> ref_name(type_name)
          <> ", \"wrapper decode\") })) case payload { kdl.JsonValueStr(text) -> Ok("
          <> type_name
          <> "(text)) _ -> representation("
          <> ref_name(type_name)
          <> ") }"
      }
    types.BytesShape(_) | types.RawBodyShape(_) ->
      "use payload <- result.try(case graph(context).profile.bytes_policy { Some(types.BytesPolicy(wrapper: Some(name), ..)) -> result.map_error(runtime.wrap_decode(graph(context).profile, name, value), fn(_) { runtime.Representation("
      <> ref_name(type_name)
      <> ", \"wrapper decode\") }) _ -> Ok(value) }) case payload { kdl.JsonValueStr(text) -> { use bytes <- result.try(result.map_error(native.decode_bytes(text), fn(_) { runtime.Representation("
      <> ref_name(type_name)
      <> ", \"invalid base64\") })) Ok("
      <> type_name
      <> "(bytes, Some(text))) } _ -> representation("
      <> ref_name(type_name)
      <> ") }"
    types.UnitShape ->
      "case value { kdl.JsonValueNull -> Ok("
      <> type_name
      <> "(Nil)) _ -> representation("
      <> ref_name(type_name)
      <> ") }"
    types.UnknownShape(_) -> "Ok(" <> type_name <> "(value))"
    _ -> "representation(" <> ref_name(type_name) <> ")"
  }
  #(scalar_payload(shape), [], [
    "fn pack_"
      <> function_name
      <> "(context: Context, value: "
      <> type_name
      <> ") -> Result(kdl.JsonValue, ValueFailure) { "
      <> encoded
      <> " }",
    "fn unpack_"
      <> function_name
      <> "(context: Context, value: kdl.JsonValue) -> Result("
      <> type_name
      <> ", ValueFailure) { "
      <> decoded
      <> " }",
  ])
}

fn render_never(type_name: String) -> #(String, List(String), List(String)) {
  let payload = type_name <> "Payload"
  #(payload, ["pub type " <> payload <> " {}"], [
    "fn pack_"
      <> lower(type_name)
      <> "(_context: Context, _value: "
      <> type_name
      <> ") -> Result(kdl.JsonValue, ValueFailure) { Error(runtime.Representation("
      <> ref_name(type_name)
      <> ", \"Uninhabited\")) }",
    "fn unpack_"
      <> lower(type_name)
      <> "(_context: Context, _value: kdl.JsonValue) -> Result("
      <> type_name
      <> ", ValueFailure) { Error(runtime.Representation("
      <> ref_name(type_name)
      <> ", \"Uninhabited\")) }",
  ])
}

fn render_sealed(
  type_name: String,
  tag: String,
) -> #(String, List(String), List(String)) {
  #("kdl.JsonValue", [], [
    "fn pack_"
      <> lower(type_name)
      <> "(context: Context, value: "
      <> type_name
      <> ") -> Result(kdl.JsonValue, ValueFailure) { use model <- result.try(case graph(context).profile.tag { Some(model) -> Ok(model) None -> Error(runtime.Representation("
      <> ref_name(type_name)
      <> ", \"tag model\")) }) result.map_error(runtime.with_member(model.key, "
      <> quote(tag)
      <> ", value.value), fn(_) { runtime.Representation("
      <> ref_name(type_name)
      <> ", \"sealed encode\") }) }",
    "fn unpack_"
      <> lower(type_name)
      <> "(_context: Context, value: kdl.JsonValue) -> Result("
      <> type_name
      <> ", ValueFailure) { Ok("
      <> type_name
      <> "(value)) }",
  ])
}

fn render_product(
  type_name: String,
  spec: types.ProductSpec,
  names: Names,
) -> Result(#(String, List(String), List(String)), RenderFailure) {
  use fields <- result.try(
    list.try_map(spec.fields, fn(field) {
      use child <- result.try(name(names, field.slot.type_ref))
      Ok(#(field, lower_identifier(field.wire_name, "field"), child))
    }),
  )
  let payload = type_name <> "Payload"
  let declaration = [
    "pub type " <> payload <> " {",
    "  "
      <> payload
      <> "("
      <> string.join(
      list.append(
        list.map(fields, fn(field) {
          field.1 <> ": types.SlotValue(" <> field.2 <> ")"
        }),
        ["extras: List(#(String, kdl.JsonValue))"],
      ),
      ", ",
    )
      <> ")",
    "}",
  ]
  let pack_fields =
    list.map(fields, fn(field) {
      "  use "
      <> field.1
      <> "_slot <- result.try(runtime.map_slot(value.value."
      <> field.1
      <> ", fn(item) { "
      <> pack(field.2, "item")
      <> " }))"
    })
  let packed =
    "  Ok(kdl.JsonValueObj(runtime.ordered_members(list.flatten(["
    <> string.join(
      list.append(
        list.map(fields, fn(field) {
          "runtime.slot_members("
          <> quote(field.0.wire_name)
          <> ", "
          <> field.1
          <> "_slot"
          <> ")"
        }),
        ["value.value.extras"],
      ),
      ", ",
    )
    <> "]), value.member_order)))"
  let unpack_fields =
    list.map(fields, fn(field) {
      "      use "
      <> field.1
      <> "_slot <- result.try(runtime.map_slot(runtime.member_slot(members, "
      <> quote(field.0.wire_name)
      <> "), fn(item) { "
      <> unpack(field.2, "item")
      <> " }))"
    })
  let extras =
    "      let extras = list.filter(members, fn(member) { !list.contains(["
    <> string.join(
      list.map(spec.fields, fn(field) { quote(field.wire_name) }),
      ", ",
    )
    <> "], member.0) })"
  let construct =
    "      Ok("
    <> type_name
    <> "("
    <> payload
    <> "("
    <> string.join(
      list.append(list.map(fields, fn(field) { field.1 <> "_slot" }), ["extras"]),
      ", ",
    )
    <> "), list.map(members, fn(member) { member.0 })))"
  Ok(#(
    payload,
    declaration,
    list.flatten([
      [
        "fn pack_"
        <> lower(type_name)
        <> "(context: Context, value: "
        <> type_name
        <> ") -> Result(kdl.JsonValue, ValueFailure) {",
      ],
      pack_fields,
      [
        packed,
        "}",
        "fn unpack_"
          <> lower(type_name)
          <> "(context: Context, value: kdl.JsonValue) -> Result("
          <> type_name
          <> ", ValueFailure) {",
        "  case value {",
        "    kdl.JsonValueObj(members) -> {",
      ],
      unpack_fields,
      [
        extras,
        construct,
        "    }",
        "    _ -> representation(" <> ref_name(type_name) <> ")",
        "  }",
        "}",
      ],
    ]),
  ))
}

fn render_array(
  type_name: String,
  spec: types.ArraySpec,
  names: Names,
) -> Result(#(String, List(String), List(String)), RenderFailure) {
  use child <- result.try(name(names, spec.item.type_ref))
  Ok(
    #("List(" <> child <> ")", [], [
      "fn pack_"
        <> lower(type_name)
        <> "(context: Context, value: "
        <> type_name
        <> ") -> Result(kdl.JsonValue, ValueFailure) { result.map(list.try_map(value.value, fn(item) { "
        <> pack(child, "item")
        <> " }), kdl.JsonValueArr) }",
      "fn unpack_"
        <> lower(type_name)
        <> "(context: Context, value: kdl.JsonValue) -> Result("
        <> type_name
        <> ", ValueFailure) { case value { kdl.JsonValueArr(items) -> result.map(list.try_map(items, fn(item) { "
        <> unpack(child, "item")
        <> " }), "
        <> type_name
        <> ") _ -> representation("
        <> ref_name(type_name)
        <> ") } }",
    ]),
  )
}

fn render_alias(
  type_name: String,
  target: types.TypeRef,
  names: Names,
) -> Result(#(String, List(String), List(String)), RenderFailure) {
  use child <- result.try(name(names, target))
  Ok(
    #(child, [], [
      "fn pack_"
        <> lower(type_name)
        <> "(context: Context, value: "
        <> type_name
        <> ") -> Result(kdl.JsonValue, ValueFailure) { "
        <> pack(child, "value.value")
        <> " }",
      "fn unpack_"
        <> lower(type_name)
        <> "(context: Context, value: kdl.JsonValue) -> Result("
        <> type_name
        <> ", ValueFailure) { result.map("
        <> unpack(child, "value")
        <> ", "
        <> type_name
        <> ") }",
    ]),
  )
}

fn value_kind_literal(kind: types.ValueKind) -> String {
  case kind {
    types.NullKind -> "types.NullKind"
    types.BooleanKind -> "types.BooleanKind"
    types.NumberKind -> "types.NumberKind"
    types.StringKind -> "types.StringKind"
    types.ArrayKind -> "types.ArrayKind"
    types.ObjectKind -> "types.ObjectKind"
  }
}

fn selector_literal(selector: types.BranchSelector) -> String {
  case selector {
    types.InternalTag -> "types.InternalTag"
    types.MemberShape(tests) ->
      "types.MemberShape(["
      <> string.join(
        list.map(tests, fn(item) {
          "#("
          <> quote(item.0)
          <> ", "
          <> case item.1 {
            types.AbsentMember -> "types.AbsentMember"
            types.FormatMember(name) ->
              "types.FormatMember(" <> quote(name) <> ")"
          }
          <> ")"
        }),
        ", ",
      )
      <> "])"
    types.Kind(kind) -> "types.Kind(" <> value_kind_literal(kind) <> ")"
    types.Otherwise -> "types.Otherwise"
  }
}

fn render_union(
  type_name: String,
  spec: types.UnionSpec,
  names: Names,
) -> Result(#(String, List(String), List(String)), RenderFailure) {
  use branches <- result.try(
    list.try_map(spec.branches, fn(branch) {
      use child <- result.try(name(names, branch.target))
      Ok(#(branch, upper_identifier(branch.wire_tag, "Variant"), child))
    }),
  )
  let payload = type_name <> "Payload"
  let declarations =
    list.flatten([
      ["pub type " <> payload <> " {"],
      list.map(branches, fn(branch) {
        "  " <> type_name <> branch.1 <> "(value: " <> branch.2 <> ")"
      }),
      [],
      ["}"],
    ])
  let pack_branches =
    list.map(branches, fn(branch) {
      let encoded = case branch.0.selector {
        types.InternalTag ->
          "runtime.tag_object(graph(context).profile, "
          <> ref_name(type_name)
          <> ", payload, "
          <> quote(branch.0.wire_tag)
          <> ")"
        _ -> "Ok(payload)"
      }
      "    "
      <> type_name
      <> branch.1
      <> "(value) -> { use payload <- result.try("
      <> pack(branch.2, "value")
      <> ") "
      <> encoded
      <> " }"
    })
  let selectors =
    "["
    <> string.join(
      list.map(branches, fn(branch) {
        "#("
        <> quote(branch.0.wire_tag)
        <> ", "
        <> selector_literal(branch.0.selector)
        <> ")"
      }),
      ", ",
    )
    <> "]"
  let unpack_branches =
    list.index_map(branches, fn(branch, index) {
      let child_value = "value"
      "    Ok("
      <> int.to_string(index)
      <> ") -> result.map("
      <> unpack(branch.2, child_value)
      <> ", fn(child) { "
      <> type_name
      <> "("
      <> type_name
      <> branch.1
      <> "(child)) })"
    })
  let functions =
    list.flatten([
      [
        "fn pack_"
          <> lower(type_name)
          <> "(context: Context, value: "
          <> type_name
          <> ") -> Result(kdl.JsonValue, ValueFailure) {",
        "  case value.value {",
      ],
      pack_branches,
      [
        "  }",
        "}",
        "fn unpack_"
          <> lower(type_name)
          <> "(context: Context, value: kdl.JsonValue) -> Result("
          <> type_name
          <> ", ValueFailure) {",
        "  case runtime.select_branch(graph(context).profile, "
          <> selectors
          <> ", value) {",
      ],
      unpack_branches,
      [
        "    _ -> representation(" <> ref_name(type_name) <> ")",
        "  }",
        "}",
      ],
    ])
  Ok(#(payload, declarations, functions))
}

fn concrete_identifier_entries(
  named: List(#(types.TypeNode, String)),
) -> List(#(IdentifierNamespace, String, IdentifierOrigin)) {
  list.flat_map(named, fn(entry) {
    let node = entry.0
    let type_name = entry.1
    let base = lower(type_name)
    let values =
      list.map(
        list.flatten([
          [
            ref_name(type_name),
            "value_" <> base,
            "new_" <> base,
            "from_value_" <> base,
            "to_value_" <> base,
            "decode_" <> base,
            "encode_" <> base,
            "with_defaults_" <> base,
            "pack_" <> base,
            "unpack_" <> base,
          ],
          [],
          case shape_default(node.shape) {
            None -> []
            Some(_) -> ["default_" <> base]
          },
        ]),
        fn(identifier) {
          #(
            ValueNamespace,
            identifier,
            TypeValueOrigin(node.reference, identifier),
          )
        },
      )
    let payload = type_name <> "Payload"
    let shaped = case node.shape {
      types.ProductShape(spec) ->
        list.flatten([
          [
            #(TypeNamespace, payload, TypeOrigin(node.reference)),
            #(
              ConstructorNamespace,
              payload,
              TypeConstructorOrigin(node.reference, payload),
            ),
            #(
              LabelNamespace(payload),
              "extras",
              ReservedOrigin(FieldRole, "extras"),
            ),
          ],
          list.map(spec.fields, fn(field) {
            #(
              LabelNamespace(payload),
              lower_identifier(field.wire_name, "field"),
              FieldOrigin(node.reference, field.wire_name),
            )
          }),
        ])
      types.TaggedUnionShape(spec) -> [
        #(TypeNamespace, payload, TypeOrigin(node.reference)),
        ..list.append(
          list.flat_map(spec.branches, fn(branch) {
            let identifier =
              type_name <> upper_identifier(branch.wire_tag, "Variant")
            [
              #(
                ConstructorNamespace,
                identifier,
                UnionBranchOrigin(
                  node.reference,
                  branch.wire_tag,
                  branch.target,
                ),
              ),
              #(
                LabelNamespace(identifier),
                "value",
                ReservedOrigin(FieldRole, "value"),
              ),
            ]
          }),
          [],
        )
      ]
      _ -> []
    }
    list.flatten([
      [
        #(TypeNamespace, type_name, TypeOrigin(node.reference)),
        #(
          ConstructorNamespace,
          type_name,
          TypeConstructorOrigin(node.reference, type_name),
        ),
        #(
          LabelNamespace(type_name),
          "value",
          ReservedOrigin(FieldRole, "value"),
        ),
      ],
      case node.shape {
        types.BytesShape(_) | types.RawBodyShape(_) -> [
          #(
            LabelNamespace(type_name),
            "wire",
            ReservedOrigin(FieldRole, "wire"),
          ),
        ]
        _ -> []
      },
      shaped,
      values,
    ])
  })
}

fn signature_identifier_entries(
  library: signatures.AdmittedLibrary,
  definitions: List(signatures.SignatureDefinition),
  names: Names,
) -> Result(
  List(#(IdentifierNamespace, String, IdentifierOrigin)),
  RenderFailure,
) {
  use entries <- result.try(
    list.try_map(definitions, fn(definition) {
      let upper = upper_identifier(definition.wire_identity, "Signature")
      let signature_name =
        lower_identifier(definition.wire_identity, "signature")
      case definition.shape {
        signatures.Value(id) | signatures.Message(id) -> {
          use child_ref <- result.try(Ok(signatures.type_ref(library, id)))
          use child <- result.try(name(names, child_ref))
          let types = case upper == child {
            True -> []
            False -> [
              #(
                TypeNamespace,
                upper,
                SignatureTypeOrigin(
                  definition.id,
                  definition.wire_identity,
                  ValueAlias,
                ),
              ),
            ]
          }
          let codecs = case signature_name == lower(child) {
            True -> []
            False -> [
              #(
                ValueNamespace,
                "decode_" <> signature_name,
                SignatureValueOrigin(
                  definition.id,
                  definition.wire_identity,
                  DecodeValue,
                ),
              ),
              #(
                ValueNamespace,
                "encode_" <> signature_name,
                SignatureValueOrigin(
                  definition.id,
                  definition.wire_identity,
                  EncodeValue,
                ),
              ),
            ]
          }
          Ok([
            #(
              ValueNamespace,
              signature_name <> "_identity",
              SignatureValueOrigin(
                definition.id,
                definition.wire_identity,
                IdentityConstant,
              ),
            ),
            ..list.append(types, codecs)
          ])
        }
        signatures.Symbol(_) ->
          Ok([
            #(
              ValueNamespace,
              signature_name,
              SignatureValueOrigin(
                definition.id,
                definition.wire_identity,
                SymbolConstant,
              ),
            ),
          ])
        signatures.Operation(operation) -> {
          let input_type = upper <> "Input"
          let outcome_type = upper <> "Outcome"
          let type_entries = [
            #(
              TypeNamespace,
              input_type,
              SignatureTypeOrigin(
                definition.id,
                definition.wire_identity,
                InputType,
              ),
            ),
            #(
              TypeNamespace,
              outcome_type,
              SignatureTypeOrigin(
                definition.id,
                definition.wire_identity,
                OutcomeType,
              ),
            ),
            #(
              ConstructorNamespace,
              input_type,
              SignatureConstructorOrigin(
                definition.id,
                definition.wire_identity,
                InputConstructor,
              ),
            ),
            ..case operation.effect {
              types.HttpRequestResponse -> [
                #(
                  TypeNamespace,
                  upper <> "Binding",
                  SignatureTypeOrigin(
                    definition.id,
                    definition.wire_identity,
                    BindingAlias,
                  ),
                ),
              ]
              _ -> []
            }
          ]
          let input_labels =
            list.map(operation.inputs, fn(port) {
              #(
                LabelNamespace(input_type),
                lower_identifier(port.id.value, "port"),
                InputPortOrigin(definition.id, port.id.value),
              )
            })
          let outcomes =
            list.flat_map(operation.outcomes, fn(outcome) {
              let constructor =
                outcome_type
                <> upper_identifier(outcome.contract.id.value, "Variant")
              [
                #(
                  ConstructorNamespace,
                  constructor,
                  OutcomeConstructorOrigin(
                    definition.id,
                    definition.wire_identity,
                    outcome.contract.id.value,
                  ),
                ),
                ..list.map(outcome.contract.value_ports, fn(port) {
                  #(
                    LabelNamespace(constructor),
                    lower_identifier(port.id.value, "port"),
                    OutcomePortOrigin(
                      definition.id,
                      outcome.contract.id.value,
                      port.id.value,
                    ),
                  )
                })
              ]
            })
          let value_surfaces = [
            #(signature_name <> "_identity", IdentityConstant),
            #(signature_name <> "_outcome_id", OutcomeIdHelper),
            #("validate_" <> signature_name <> "_input", ValidateInput),
            #("validate_" <> signature_name <> "_outcome", ValidateOutcome),
            #("to_outcome_" <> signature_name, ToOutcome),
            #("from_outcome_" <> signature_name, FromOutcome),
            #("encode_" <> signature_name <> "_outcome", EncodeOutcome),
            #("decode_" <> signature_name <> "_outcome", DecodeOutcome),
            ..case operation.effect {
              types.HttpRequestResponse -> [
                #("call_" <> signature_name, CallOperation),
              ]
              _ -> []
            }
          ]
          Ok(
            list.flatten([
              type_entries,
              input_labels,
              outcomes,
              list.map(value_surfaces, fn(surface) {
                #(
                  ValueNamespace,
                  surface.0,
                  SignatureValueOrigin(
                    definition.id,
                    definition.wire_identity,
                    surface.1,
                  ),
                )
              }),
            ]),
          )
        }
      }
    }),
  )
  Ok(list.flatten(entries))
}

fn reserved_identifier_entries() -> List(
  #(IdentifierNamespace, String, IdentifierOrigin),
) {
  list.flatten([
    list.map(
      [
        "Option",
        "Result",
        "List",
        "String",
        "Int",
        "Bool",
        "Nil",
        "ValueFailure",
        "Context",
      ],
      fn(identifier) {
        #(TypeNamespace, identifier, ReservedOrigin(TypeRole, identifier))
      },
    ),
    list.map(
      ["None", "Some", "Ok", "Error", "True", "False", "Context"],
      fn(identifier) {
        #(
          ConstructorNamespace,
          identifier,
          ReservedOrigin(ConstructorRole, identifier),
        )
      },
    ),
    list.map(
      [
        "required_generation",
        "initialize",
        "graph",
        "representation",
        "annotations",
        "groups",
        "checked_generation",
        "start",
        "resume",
      ],
      fn(identifier) {
        #(ValueNamespace, identifier, ReservedOrigin(ValueRole, identifier))
      },
    ),
    [
      #(
        LabelNamespace("Context"),
        "checked",
        ReservedOrigin(FieldRole, "checked"),
      ),
    ],
  ])
}

pub fn render_generation(
  expected: String,
  input: String,
) -> Result(String, RenderFailure) {
  use checked <- result.try(
    signatures.admit_generation(expected, input) |> result.map_error(Signature),
  )
  render_signatures(checked)
}

pub fn render_signatures(
  checked: signatures.CheckedGeneration,
) -> Result(String, RenderFailure) {
  let graph = signatures.checked_graph(checked)
  let required = signatures.generation_requirement(checked)
  let nodes =
    list.sort(graph.nodes, fn(a, b) {
      string.compare(a.reference.definition_name, b.reference.definition_name)
    })
  let named =
    list.map(nodes, fn(node) {
      #(node, upper_identifier(type_identity(node.reference), "Type"))
    })
  let names =
    dict.from_list(list.map(named, fn(entry) { #(entry.0.reference, entry.1) }))
  let library = signatures.checked_library(checked)
  let definitions =
    list.sort(signatures.generated_definitions(checked), fn(a, b) {
      string.compare(a.id, b.id)
    })
  use signature_entries <- result.try(signature_identifier_entries(
    library,
    definitions,
    names,
  ))
  use _ <- result.try(
    unique_identifiers(list.append(
      list.append(
        concrete_identifier_entries(named),
        reserved_identifier_entries(),
      ),
      signature_entries,
    )),
  )
  use sections <- result.try(
    list.try_map(named, fn(entry) { render_type(entry.0, entry.1, names) }),
  )
  use declarations <- result.try(
    list.try_map(definitions, fn(definition) {
      render_signature_definition(library, definition, names)
    }),
  )
  let header = [
    "// SPDX-License-Identifier: MIT",
    "import gleam/option.{type Option, None, Some}",
    "import gleam/result",
    "import gleam/list",
    "import necoherence/exact_json as kdl",
    "import necoherence/semantic_types as types",
    "import necoherence/semantic_composition as composition",
    "import necoherence/semantic_signatures as signatures",
    "import necoherence/semantic_generation_runtime as runtime",
    "import necoherence/semantic_generation_values as values",
    "import necoherence/semantic_validation as validation",
    "import necoherence/semantic_generation_native as native",
    "import necoherence/semantic_signature_http as http",
    "import necoherence/semantic_generation_http as http_result",
    "import necoherence/network_effect as network",
    "pub type ValueFailure = runtime.ValueFailure",
    "fn required_generation() -> signatures.GenerationRequirement { "
      <> generation_requirement_literal(required)
      <> " }",
    "pub opaque type Context { Context(checked: signatures.CheckedGeneration) }",
    "pub fn initialize(checked: signatures.CheckedGeneration) -> Result(Context, signatures.GenerationMismatch) {",
    "  use checked <- result.try(signatures.require_generation(required_generation(), checked))",
    "  Ok(Context(checked))",
    "}",
    "fn graph(context: Context) -> types.SemanticGraph { signatures.checked_graph(context.checked) }",
    "fn representation(reference: types.TypeRef) -> Result(a, ValueFailure) { Error(runtime.Representation(reference, \"generated value representation\")) }",
    "pub fn annotations(context: Context, target: signatures.Target) -> List(signatures.Annotation) { signatures.annotations(signatures.checked_library(context.checked), target) }",
    "pub fn groups(context: Context) -> List(signatures.DefinitionGroup) { signatures.groups(signatures.checked_library(context.checked)) }",
    "pub fn checked_generation(context: Context) -> signatures.CheckedGeneration { context.checked }",
    "pub fn start(context: Context, arguments: List(#(composition.InputId, types.SlotValue(kdl.JsonValue))), providers: List(runtime.Provider), state: network.NetworkState) -> Result(runtime.Progress, runtime.RunFailure) { signatures.start_generation(context.checked, arguments, providers, state) }",
    "pub fn resume(execution: runtime.Execution) -> Result(runtime.Progress, runtime.RunFailure) { runtime.resume(execution) }",
  ]
  Ok(
    string.join(
      list.flatten([header, list.flatten(sections), list.flatten(declarations)]),
      "\n",
    )
    <> "\n",
  )
}

fn render_signature_definition(
  library: signatures.AdmittedLibrary,
  definition: signatures.SignatureDefinition,
  names: Names,
) -> Result(List(String), RenderFailure) {
  let prefix = upper_identifier(definition.wire_identity, "Signature")
  let function = lower_identifier(definition.wire_identity, "signature")
  case definition.shape {
    signatures.Value(id) | signatures.Message(id) -> {
      use child <- result.try(name(names, signatures.type_ref(library, id)))
      let alias = case prefix == child {
        True -> []
        False -> ["pub type " <> prefix <> " = " <> child]
      }
      let codecs = case function == lower(child) {
        True -> []
        False -> [
          "pub fn decode_"
            <> function
            <> "(context: Context, wire: String) -> Result("
            <> child
            <> ", ValueFailure) { decode_"
            <> lower(child)
            <> "(context, wire) }",
          "pub fn encode_"
            <> function
            <> "(context: Context, value: "
            <> child
            <> ") -> Result(String, ValueFailure) { encode_"
            <> lower(child)
            <> "(context, value) }",
        ]
      }
      Ok(
        list.flatten([
          alias,
          [
            "pub const "
            <> function
            <> "_identity = "
            <> quote(definition.wire_identity),
          ],
          codecs,
        ]),
      )
    }
    signatures.Symbol(symbol) ->
      Ok(["pub const " <> function <> ": String = " <> quote(symbol)])
    signatures.Operation(operation) -> {
      use inputs <- result.try(
        list.try_map(operation.inputs, fn(port) {
          use child <- result.try(name(names, port.contract.type_ref))
          Ok(#(port, lower_identifier(port.id.value, "port"), child))
        }),
      )
      use outcomes <- result.try(
        list.try_map(operation.outcomes, fn(outcome) {
          use ports <- result.try(
            list.try_map(outcome.contract.value_ports, fn(port) {
              use child <- result.try(name(names, port.contract.type_ref))
              Ok(#(port, lower_identifier(port.id.value, "port"), child))
            }),
          )
          Ok(#(
            outcome,
            upper_identifier(outcome.contract.id.value, "Variant"),
            ports,
          ))
        }),
      )
      let input_args =
        string.join(
          list.map(inputs, fn(port) {
            port.1 <> ": types.SlotValue(" <> port.2 <> ")"
          }),
          ", ",
        )
      let declarations =
        list.flatten([
          [
            "pub const "
              <> function
              <> "_identity = "
              <> quote(definition.wire_identity),
            "pub type "
              <> prefix
              <> "Input { "
              <> prefix
              <> "Input"
              <> case inputs {
              [] -> ""
              _ -> "(" <> input_args <> ")"
            }
              <> " }",
            "pub type " <> prefix <> "Outcome {",
          ],
          list.map(outcomes, fn(outcome) {
            let args =
              string.join(
                list.map(outcome.2, fn(port) {
                  port.1 <> ": types.SlotValue(" <> port.2 <> ")"
                }),
                ", ",
              )
            "  "
            <> prefix
            <> "Outcome"
            <> outcome.1
            <> case outcome.2 {
              [] -> ""
              _ -> "(" <> args <> ")"
            }
          }),
          [
            "}",
            "pub fn "
              <> function
              <> "_outcome_id(value: "
              <> prefix
              <> "Outcome) -> String { case value {",
          ],
          list.map(outcomes, fn(outcome) {
            "  "
            <> prefix
            <> "Outcome"
            <> outcome.1
            <> case outcome.2 {
              [] -> ""
              _ ->
                "("
                <> string.join(list.map(outcome.2, fn(_) { "_" }), ", ")
                <> ")"
            }
            <> " -> "
            <> quote(outcome.0.contract.id.value)
          }),
          ["} }"],
        ])
      let validate_input =
        list.flatten([
          [
            "pub fn validate_"
            <> function
            <> "_input(context: Context, input: "
            <> prefix
            <> "Input) -> Result(Nil, ValueFailure) {",
          ],
          list.flat_map(inputs, fn(port) {
            let variable = port.1
            [
              "  use "
                <> variable
                <> " <- result.try(runtime.map_slot(input."
                <> variable
                <> ", fn(item) { pack_"
                <> lower(port.2)
                <> "(context, item) }))",
              "  use _ <- result.try(result.map_error(validation.validate_slot(graph(context), types.SlotContract("
                <> ref_name(port.2)
                <> ", "
                <> boolean(port.0.contract.required)
                <> ", "
                <> boolean(port.0.contract.nullable)
                <> "), "
                <> variable
                <> "), runtime.Constraint))",
            ]
          }),
          ["  Ok(Nil)", "}"],
        ])
      let validate_outcome =
        list.flatten([
          [
            "pub fn validate_"
              <> function
              <> "_outcome(context: Context, output: "
              <> prefix
              <> "Outcome) -> Result(Nil, ValueFailure) {",
            "  case output {",
          ],
          list.flat_map(outcomes, fn(outcome) {
            let variables = list.map(outcome.2, fn(port) { port.1 })
            let pattern =
              prefix
              <> "Outcome"
              <> outcome.1
              <> case variables {
                [] -> ""
                _ -> "(" <> string.join(variables, ", ") <> ")"
              }
            list.flatten([
              ["    " <> pattern <> " -> {"],
              list.flat_map(outcome.2, fn(port) {
                let variable = port.1
                [
                  "      use "
                    <> variable
                    <> " <- result.try(runtime.map_slot("
                    <> variable
                    <> ", fn(item) { pack_"
                    <> lower(port.2)
                    <> "(context, item) }))",
                  "      use _ <- result.try(result.map_error(validation.validate_slot(graph(context), types.SlotContract("
                    <> ref_name(port.2)
                    <> ", "
                    <> boolean(port.0.contract.required)
                    <> ", "
                    <> boolean(port.0.contract.nullable)
                    <> "), "
                    <> variable
                    <> "), runtime.Constraint))",
                ]
              }),
              ["      Ok(Nil)", "    }"],
            ])
          }),
          ["  }", "}"],
        ])
      let encode =
        list.flatten([
          [
            "pub fn to_outcome_"
              <> function
              <> "(context: Context, output: "
              <> prefix
              <> "Outcome) -> Result(runtime.OutcomeValues, signatures.Failure) {",
            "  use _ <- result.try(result.map_error(validate_"
              <> function
              <> "_outcome(context, output), signatures.Codec))",
            "  case output {",
          ],
          list.flat_map(outcomes, fn(outcome) {
            let variables = list.map(outcome.2, fn(port) { port.1 })
            let pattern =
              prefix
              <> "Outcome"
              <> outcome.1
              <> case variables {
                [] -> ""
                _ -> "(" <> string.join(variables, ", ") <> ")"
              }
            list.flatten([
              ["    " <> pattern <> " -> {"],
              list.map(outcome.2, fn(port) {
                let variable = port.1
                "      use "
                <> variable
                <> " <- result.try(result.map_error(runtime.map_slot("
                <> variable
                <> ", fn(item) { pack_"
                <> lower(port.2)
                <> "(context, item) }), signatures.Codec))"
              }),
              [
                "      Ok(runtime.OutcomeValues(composition.OutcomeId("
                  <> quote(outcome.0.contract.id.value)
                  <> "), ["
                  <> string.join(
                  list.map(outcome.2, fn(port) {
                    "#(composition.PortId("
                    <> quote(port.0.id.value)
                    <> "), "
                    <> port.1
                    <> ")"
                  }),
                  ", ",
                )
                  <> "]))",
                "    }",
              ],
            ])
          }),
          ["  }", "}"],
        ])
      let decode =
        list.flatten([
          [
            "pub fn from_outcome_"
              <> function
              <> "(context: Context, output: runtime.OutcomeValues) -> Result("
              <> prefix
              <> "Outcome, signatures.Failure) {",
            "  use _ <- result.try(signatures.validate_outcome(context.checked, "
              <> quote(definition.id)
              <> ", output))",
            "  case output.outcome {",
          ],
          list.flat_map(outcomes, fn(outcome) {
            let variables = list.map(outcome.2, fn(port) { port.1 })
            list.flatten([
              [
                "    composition.OutcomeId("
                <> quote(outcome.0.contract.id.value)
                <> ") -> {",
              ],
              list.flat_map(outcome.2, fn(port) {
                let variable = port.1
                [
                  "      use "
                    <> variable
                    <> " <- result.try(result.map_error(list.key_find(output.values, composition.PortId("
                    <> quote(port.0.id.value)
                    <> ")), fn(_) { signatures.Invalid(\"missing outcome port\") }))",
                  "      use "
                    <> variable
                    <> " <- result.try(result.map_error(runtime.map_slot("
                    <> variable
                    <> ", fn(item) { unpack_"
                    <> lower(port.2)
                    <> "(context, item) }), signatures.Codec))",
                ]
              }),
              [
                "      Ok("
                  <> prefix
                  <> "Outcome"
                  <> outcome.1
                  <> case variables {
                  [] -> ""
                  _ -> "(" <> string.join(variables, ", ") <> ")"
                }
                  <> ")",
                "    }",
              ],
            ])
          }),
          [
            "    _ -> Error(signatures.Invalid(\"undeclared outcome\"))",
            "  }",
            "}",
          ],
          [
            "pub fn encode_"
              <> function
              <> "_outcome(context: Context, output: "
              <> prefix
              <> "Outcome) -> Result(String, signatures.Failure) {",
            "  use output <- result.try(to_outcome_"
              <> function
              <> "(context, output))",
            "  signatures.encode_outcome(context.checked, "
              <> quote(definition.id)
              <> ", output)",
            "}",
            "pub fn decode_"
              <> function
              <> "_outcome(context: Context, wire: String) -> Result("
              <> prefix
              <> "Outcome, signatures.Failure) {",
            "  use output <- result.try(signatures.decode_outcome(context.checked, "
              <> quote(definition.id)
              <> ", wire))",
            "  from_outcome_" <> function <> "(context, output)",
            "}",
          ],
        ])
      let external_ids =
        list.filter_map(operation.outcomes, fn(outcome) {
          case outcome.cause {
            signatures.ExternalCondition(_) ->
              Ok(quote(outcome.contract.id.value))
            _ -> Error(Nil)
          }
        })
      let http = case operation.effect {
        types.DataOnly -> []
        types.HttpRequestResponse -> [
          "pub type "
            <> prefix
            <> "Binding = http.Binding("
            <> prefix
            <> "Input, "
            <> prefix
            <> "Outcome)",
          "pub fn call_"
            <> function
            <> "(context: Context, input: "
            <> prefix
            <> "Input, binding: "
            <> prefix
            <> "Binding, state: network.NetworkState) -> http_result.Outcome("
            <> prefix
            <> "Outcome) {",
          "  case validate_" <> function <> "_input(context, input) {",
          "    Error(failure) -> http_result.Failed(state, http_result.Callback(runtime.CallbackValue(failure)))",
          "    Ok(_) -> http.call(state, input, binding, fn(value) { result.map_error(validate_"
            <> function
            <> "_outcome(context, value), runtime.CallbackValue) }, fn(value) { list.contains(["
            <> string.join(external_ids, ", ")
            <> "], "
            <> function
            <> "_outcome_id(value)) })",
          "  }",
          "}",
        ]
      }
      Ok(
        list.flatten([
          declarations,
          validate_input,
          validate_outcome,
          encode,
          decode,
          http,
        ]),
      )
    }
  }
}
