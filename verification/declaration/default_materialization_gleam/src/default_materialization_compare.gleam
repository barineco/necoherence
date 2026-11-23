// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

@external(erlang, "necoherence_semantic_invariant_runner_ffi", "read_line")
fn read_line() -> String

type WireFailure {
  UnknownFieldFailure(path: String, field: String)
  UnknownTagFailure(path: String, tag: String)
  SyntaxFailure(path: String, message: String)
}

fn classification(failure: WireFailure) -> String {
  case failure {
    UnknownFieldFailure(..) -> "UnknownField"
    UnknownTagFailure(..) -> "UnknownTag"
    SyntaxFailure(..) -> "Syntax"
  }
}

fn failure_path(failure: WireFailure) -> String {
  case failure {
    UnknownFieldFailure(path, _)
    | UnknownTagFailure(path, _)
    | SyntaxFailure(path, _) -> path
  }
}

fn prepend(segment: String, failure: WireFailure) -> WireFailure {
  case failure {
    UnknownFieldFailure(path, name) ->
      UnknownFieldFailure(segment <> string.drop_start(path, 1), name)
    UnknownTagFailure(path, tag) ->
      UnknownTagFailure(segment <> string.drop_start(path, 1), tag)
    SyntaxFailure(path, message) ->
      SyntaxFailure(segment <> string.drop_start(path, 1), message)
  }
}

fn from_decode(failure: decode.DecodeFailure) -> WireFailure {
  let path = decode.failure_path(failure)
  case failure {
    decode.UnknownField(_, name) -> UnknownFieldFailure(path, name)
    decode.UnknownTag(_, tag) -> UnknownTagFailure(path, tag)
    decode.SyntaxFailure(_, reason) -> SyntaxFailure(path, reason)
    decode.ProfileFailure(_) -> SyntaxFailure(path, "profile failure")
    decode.CompositionFailure(_) -> SyntaxFailure(path, "composition failure")
  }
}

fn keys(
  value: json.JsonValue,
  names: List(String),
) -> Result(Nil, WireFailure) {
  case value {
    json.JsonValueObj(members) -> {
      let actual = list.map(members, fn(member) { member.0 })
      let unknown =
        actual
        |> list.sort(string.compare)
        |> list.find(fn(key) { !list.contains(names, key) })
      case unknown {
        Ok(key) -> Error(UnknownFieldFailure("$." <> key, key))
        Error(_) ->
          case list.find(names, fn(key) { !list.contains(actual, key) }) {
            Ok(key) -> Error(SyntaxFailure("$." <> key, "missing field"))
            Error(_) -> Ok(Nil)
          }
      }
    }
    _ -> Error(SyntaxFailure("$", "object required"))
  }
}

fn field(
  value: json.JsonValue,
  key: String,
) -> Result(json.JsonValue, WireFailure) {
  case value {
    json.JsonValueObj(members) ->
      list.key_find(members, key)
      |> result.map_error(fn(_) { SyntaxFailure("$." <> key, "missing field") })
    _ -> Error(SyntaxFailure("$." <> key, "object required"))
  }
}

fn with_field(
  value: json.JsonValue,
  key: String,
  decoder: fn(json.JsonValue) -> Result(a, WireFailure),
) -> Result(a, WireFailure) {
  use found <- result.try(field(value, key))
  decoder(found)
  |> result.map_error(fn(failure) { prepend("$." <> key, failure) })
}

fn text(value: json.JsonValue) -> Result(String, WireFailure) {
  case value {
    json.JsonValueStr(value) -> Ok(value)
    _ -> Error(SyntaxFailure("$", "string required"))
  }
}

fn boolean(value: json.JsonValue) -> Result(Bool, WireFailure) {
  case value {
    json.JsonValueBool(value) -> Ok(value)
    _ -> Error(SyntaxFailure("$", "boolean required"))
  }
}

fn array(value: json.JsonValue) -> Result(List(json.JsonValue), WireFailure) {
  case value {
    json.JsonValueArr(value) -> Ok(value)
    _ -> Error(SyntaxFailure("$", "array required"))
  }
}

fn items(
  value: json.JsonValue,
  decoder: fn(json.JsonValue) -> Result(a, WireFailure),
) -> Result(List(a), WireFailure) {
  use raw <- result.try(array(value))
  raw
  |> list.index_map(fn(item, index) { #(item, index) })
  |> list.try_map(fn(entry) {
    decoder(entry.0)
    |> result.map_error(fn(failure) {
      prepend("$[" <> int.to_string(entry.1) <> "]", failure)
    })
  })
}

fn decoded(
  value: json.JsonValue,
  decoder: fn(json.JsonValue) -> Result(a, decode.DecodeFailure),
) -> Result(a, WireFailure) {
  decoder(value) |> result.map_error(from_decode)
}

fn encoded(value, encoder) {
  encoder(value) |> result.map_error(string.inspect)
}

fn type_ref(value: json.JsonValue) -> Result(types.TypeRef, WireFailure) {
  decoded(value, decode.decode_type_ref)
}

fn source_ref(value: json.JsonValue) -> Result(types.SourceRef, WireFailure) {
  decoded(value, decode.decode_source_ref)
}

fn slot_contract(
  value: json.JsonValue,
) -> Result(types.SlotContract, WireFailure) {
  decoded(value, decode.decode_slot_contract)
}

fn element_contract(
  value: json.JsonValue,
) -> Result(types.ElementContract, WireFailure) {
  use _ <- result.try(keys(value, ["type_ref", "nullable"]))
  use reference <- result.try(with_field(value, "type_ref", type_ref))
  use nullable <- result.try(with_field(value, "nullable", boolean))
  Ok(types.ElementContract(reference, nullable))
}

fn occurrence_ref(
  value: json.JsonValue,
) -> Result(types.OccurrenceRef, WireFailure) {
  use _ <- result.try(keys(value, ["source", "pointer"]))
  use source <- result.try(with_field(value, "source", source_ref))
  use pointer <- result.try(
    with_field(value, "pointer", fn(pointer_value) {
      items(pointer_value, text)
    }),
  )
  Ok(types.OccurrenceRef(source, pointer))
}

fn field_spec(value: json.JsonValue) -> Result(types.FieldSpec, WireFailure) {
  use _ <- result.try(keys(value, ["wire_name", "slot", "origin"]))
  use name <- result.try(with_field(value, "wire_name", text))
  use slot <- result.try(with_field(value, "slot", slot_contract))
  use origin <- result.try(with_field(value, "origin", occurrence_ref))
  Ok(types.FieldSpec(name, slot, origin))
}

fn allow_members(
  value: json.JsonValue,
) -> Result(types.ExtraMembers, WireFailure) {
  use _ <- result.try(keys(value, ["key_format", "value"]))
  use key <- result.try(
    with_field(value, "key_format", fn(key_value) {
      case key_value {
        json.JsonValueNull -> Ok(None)
        _ -> decoded(key_value, decode.decode_format_use) |> result.map(Some)
      }
    }),
  )
  use element <- result.try(with_field(value, "value", element_contract))
  Ok(types.AllowExtras(key, element))
}

fn extra_members(
  value: json.JsonValue,
) -> Result(types.ExtraMembers, WireFailure) {
  use tag <- result.try(with_field(value, "tag", text))
  case tag {
    "Reject" -> {
      use _ <- result.try(keys(value, ["tag"]))
      Ok(types.RejectExtras)
    }
    "Allow" -> {
      use _ <- result.try(keys(value, ["tag", "fields"]))
      with_field(value, "fields", allow_members)
    }
    other -> Error(UnknownTagFailure("$.tag", other))
  }
}

fn union_selector(
  value: json.JsonValue,
) -> Result(types.BranchSelector, WireFailure) {
  signatures.decode_branch_selector(value)
  |> result.map_error(fn(failure) {
    case failure {
      signatures.Wire(decode_failure) -> from_decode(decode_failure)
      _ -> SyntaxFailure("$", "branch selector failure")
    }
  })
}

fn union_branch(
  value: json.JsonValue,
) -> Result(types.UnionBranch, WireFailure) {
  use _ <- result.try(keys(value, ["target", "wire_tag", "selector", "origin"]))
  use target <- result.try(with_field(value, "target", type_ref))
  use wire_tag <- result.try(with_field(value, "wire_tag", text))
  use selector <- result.try(with_field(value, "selector", union_selector))
  use origin <- result.try(with_field(value, "origin", occurrence_ref))
  Ok(types.UnionBranch(target, wire_tag, selector, origin))
}

fn tagged_union(value: json.JsonValue) -> Result(types.UnionSpec, WireFailure) {
  use _ <- result.try(keys(value, ["branches"]))
  use branches <- result.try(
    with_field(value, "branches", fn(branches_value) {
      items(branches_value, union_branch)
    }),
  )
  Ok(types.UnionSpec(branches))
}

fn product_spec(
  value: json.JsonValue,
) -> Result(types.ProductSpec, WireFailure) {
  use _ <- result.try(keys(value, ["fields", "extras"]))
  use fields <- result.try(
    with_field(value, "fields", fn(fields_value) {
      items(fields_value, field_spec)
    }),
  )
  use extras <- result.try(with_field(value, "extras", extra_members))
  Ok(types.ProductSpec(fields, extras))
}

fn alias_shape(value: json.JsonValue) -> Result(types.TypeShape, WireFailure) {
  use _ <- result.try(keys(value, ["target", "reference_text"]))
  use target <- result.try(with_field(value, "target", type_ref))
  use reference_text <- result.try(with_field(value, "reference_text", text))
  Ok(types.AliasShape(target, reference_text))
}

fn unknown_kind(value: json.JsonValue) -> Result(types.TypeShape, WireFailure) {
  use kind <- result.try(with_field(value, "tag", text))
  case kind {
    "Any" -> {
      use _ <- result.try(keys(value, ["tag"]))
      Ok(types.UnknownShape(types.AnyValue))
    }
    "OrdinaryObject" -> {
      use _ <- result.try(keys(value, ["tag"]))
      Ok(types.UnknownShape(types.OrdinaryObject))
    }
    other -> Error(UnknownTagFailure("$.tag", other))
  }
}

fn decimal_spec(
  value: json.JsonValue,
) -> Result(types.DecimalSpec, decode.DecodeFailure) {
  case signatures.decode_decimal_spec(value) {
    Ok(spec) -> Ok(spec)
    Error(signatures.Wire(failure)) -> Error(failure)
    Error(signatures.Codec(_))
    | Error(signatures.Json(_))
    | Error(signatures.LibraryRejected(_)) ->
      Error(decode.SyntaxFailure([], "decimal spec"))
  }
}

fn valued(
  value: json.JsonValue,
  decoder: fn(json.JsonValue) -> Result(a, decode.DecodeFailure),
  build: fn(a) -> types.TypeShape,
) -> Result(types.TypeShape, WireFailure) {
  use _ <- result.try(keys(value, ["tag", "value"]))
  with_field(value, "value", fn(payload) { decoded(payload, decoder) })
  |> result.map(build)
}

fn type_shape(value: json.JsonValue) -> Result(types.TypeShape, WireFailure) {
  use tag <- result.try(with_field(value, "tag", text))
  case tag {
    "Boolean" -> valued(value, decode.decode_boolean_spec, types.BooleanShape)
    "Integer" -> valued(value, decode.decode_integer_spec, types.IntegerShape)
    "Decimal" -> valued(value, decimal_spec, types.DecimalShape)
    "String" -> valued(value, decode.decode_string_spec, types.StringShape)
    "Array" -> valued(value, decode.decode_array_spec, types.ArrayShape)
    "Product" -> {
      use _ <- result.try(keys(value, ["tag", "value"]))
      with_field(value, "value", product_spec)
      |> result.map(types.ProductShape)
    }
    "Alias" -> {
      use _ <- result.try(keys(value, ["tag", "fields"]))
      with_field(value, "fields", alias_shape)
    }
    "TaggedUnion" -> {
      use _ <- result.try(keys(value, ["tag", "value"]))
      with_field(value, "value", tagged_union)
      |> result.map(types.TaggedUnionShape)
    }
    "Unknown" -> {
      use _ <- result.try(keys(value, ["tag", "value"]))
      with_field(value, "value", unknown_kind)
    }
    "Unit" -> {
      use _ <- result.try(keys(value, ["tag"]))
      Ok(types.UnitShape)
    }
    "Never" -> {
      use _ <- result.try(keys(value, ["tag"]))
      Ok(types.Never)
    }
    other -> Error(UnknownTagFailure("$.tag", other))
  }
}

fn type_node(value: json.JsonValue) -> Result(types.TypeNode, WireFailure) {
  use _ <- result.try(
    keys(value, [
      "reference",
      "shape",
      "description",
      "attributes",
      "extensions",
    ]),
  )
  use reference <- result.try(with_field(value, "reference", type_ref))
  use shape <- result.try(with_field(value, "shape", type_shape))
  use description <- result.try(
    with_field(value, "description", fn(description_value) {
      case description_value {
        json.JsonValueNull -> Ok(None)
        _ -> text(description_value) |> result.map(Some)
      }
    }),
  )
  use attributes <- result.try(
    with_field(value, "attributes", fn(attributes_value) {
      items(attributes_value, occurrence_ref)
    }),
  )
  use extensions <- result.try(
    with_field(value, "extensions", fn(extensions_value) {
      items(extensions_value, occurrence_ref)
    }),
  )
  Ok(types.TypeNode(reference, shape, description, attributes, extensions))
}

fn semantic_graph(
  value: json.JsonValue,
) -> Result(types.SemanticGraph, WireFailure) {
  use _ <- result.try(keys(value, ["profile", "nodes", "source_refs"]))
  use profile <- result.try(
    with_field(value, "profile", fn(profile_value) {
      decoded(profile_value, decode.decode_semantic_profile)
    }),
  )
  use nodes <- result.try(
    with_field(value, "nodes", fn(nodes_value) { items(nodes_value, type_node) }),
  )
  use sources <- result.try(
    with_field(value, "source_refs", fn(sources_value) {
      items(sources_value, source_ref)
    }),
  )
  Ok(types.SemanticGraph(profile, nodes, sources))
}

fn str(value: String) {
  json.JsonValueStr(value)
}

fn obj(value) {
  json.JsonValueObj(value)
}

fn arr(value) {
  json.JsonValueArr(value)
}

fn source_json(source: types.SourceRef) {
  obj([
    #("repository", str(source.repository)),
    #("revision", str(source.revision)),
    #("path", str(source.path)),
    #("content_digest", str(source.content_digest)),
    #("document_id", str(source.document_id)),
    #("declared_revision", case source.declared_revision {
      None -> json.JsonValueNull
      Some(value) -> str(int.to_string(value))
    }),
  ])
}

fn ref_json(reference: types.TypeRef) {
  obj([
    #("source", source_json(reference.source)),
    #("definition_name", str(reference.definition_name)),
    #("pointer", arr(list.map(reference.pointer, str))),
  ])
}

fn origin_json(origin: types.OccurrenceRef) {
  obj([
    #("source", source_json(origin.source)),
    #("pointer", arr(list.map(origin.pointer, str))),
  ])
}

fn path_json(path: types.ValuePath) {
  arr(
    list.map(path, fn(step) {
      let #(tag, value) = case step {
        types.Field(name) -> #("Field", name)
        types.Index(index) -> #("Index", int.to_string(index))
        types.Variant(tag) -> #("Variant", tag)
      }
      obj([#("tag", str(tag)), #("value", str(value))])
    }),
  )
}

fn reason_json(reason: types.SemanticReason) {
  let #(tag, value) = case reason {
    types.UnknownFormatReason(name) -> #("UnknownFormat", Some(name))
    types.MissingGraphemeRulesReason -> #("MissingGraphemeRules", None)
    types.MissingBytesPolicyReason -> #("MissingBytesPolicy", None)
    types.UnknownIntegerDomainReason(name) -> #(
      "UnknownIntegerDomain",
      Some(name),
    )
    types.UnknownWrapperReason(name) -> #("UnknownWrapper", Some(name))
    types.WrapperPayloadReason(name) -> #("WrapperPayload", Some(name))
    types.UnknownSealedTagReason(tag) -> #("UnknownSealedTag", Some(tag))
    types.DecimalNotAdmittedReason -> #("DecimalNotAdmitted", None)
    types.IntegerBoundReason -> #("IntegerBound", None)
    types.OpaqueTypeReason(name) -> #("OpaqueType", Some(name))
    types.MissingTagModelReason -> #("MissingTagModel", None)
    types.UnresolvedTypeReason -> #("UnresolvedType", None)
    types.MembershipBoundReason -> #("MembershipBound", None)
    types.UninterpretedExtensionReason(key) -> #(
      "UninterpretedExtension",
      Some(key),
    )
    types.InvalidProfileReason(condition) -> #(
      "InvalidProfile",
      Some(condition),
    )
    types.CertificateMismatchReason(condition) -> #(
      "CertificateMismatch",
      Some(condition),
    )
    types.ProjectionUnavailableReason(condition) -> #(
      "ProjectionUnavailable",
      Some(condition),
    )
  }
  obj(
    list.append([#("tag", str(tag))], case value {
      Some(value) -> [#("value", str(value))]
      None -> []
    }),
  )
}

fn application_json(
  application: validation.DefaultApplication,
) -> Result(json.JsonValue, String) {
  use value <- result.try(encoded(application.value, values.encode_exact))
  Ok(
    obj([
      #("value_path", path_json(application.value_path)),
      #("type_ref", ref_json(application.type_ref)),
      #("origin", origin_json(application.origin)),
      #("value", value),
    ]),
  )
}

fn applications_json(applications) {
  list.try_map(applications, application_json) |> result.map(arr)
}

fn input_field(
  value: json.JsonValue,
  key: String,
) -> Result(json.JsonValue, String) {
  case value {
    json.JsonValueObj(members) ->
      list.key_find(members, key)
      |> result.map_error(fn(_) { "field: " <> key })
    _ -> Error("object")
  }
}

fn input_text(value: json.JsonValue) -> Result(String, String) {
  case value {
    json.JsonValueStr(value) -> Ok(value)
    _ -> Error("text")
  }
}

fn decode_case(
  input: json.JsonValue,
) -> Result(
  #(types.SemanticGraph, types.TypeRef, json.JsonValue, Bool),
  WireFailure,
) {
  use graph <- result.try(with_field(input, "graph", semantic_graph))
  use reference <- result.try(with_field(input, "reference", type_ref))
  use before <- result.try(
    with_field(input, "before", fn(before_value) {
      decoded(before_value, decode.decode_exact)
    }),
  )
  use tamper <- result.try(with_field(input, "tamper", boolean))
  Ok(#(graph, reference, before, tamper))
}

fn wire_row(id: json.JsonValue, failure: WireFailure) -> json.JsonValue {
  obj([
    #("id", id),
    #("status", str("Wire")),
    #("classification", str(classification(failure))),
    #("path", str(failure_path(failure))),
  ])
}

fn evaluate(input: json.JsonValue) -> Result(json.JsonValue, String) {
  use id <- result.try(input_field(input, "id"))
  case decode_case(input) {
    Error(failure) -> Ok(wire_row(id, failure))
    Ok(#(graph, reference, before, tamper)) ->
      evaluate_decoded(input, id, graph, reference, before, tamper)
  }
}

fn codec_row(
  id: json.JsonValue,
  failure: values.ValueCodecFailure,
) -> json.JsonValue {
  let classification = case failure {
    values.DuplicateField(_) -> "DuplicateField"
    values.InvalidSyntax
    | values.InvalidExactValue
    | values.ExponentTooLarge
    | values.UnpairedSurrogate -> "Syntax"
  }
  obj([
    #("id", id),
    #("status", str("Wire")),
    #("classification", str(classification)),
    #("path", str("$")),
  ])
}

fn spelling(value: json.JsonValue) -> Result(String, String) {
  values.json_spelling(value) |> result.map_error(string.inspect)
}

fn wire_check(
  input: json.JsonValue,
  before: json.JsonValue,
) -> Result(Result(json.JsonValue, values.ValueCodecFailure), String) {
  case input_field(input, "wire") {
    Error(_) -> Ok(Ok(before))
    Ok(wire) -> {
      use text <- result.try(input_text(wire))
      case values.unique_members(before) {
        Error(failure) -> Ok(Error(failure))
        Ok(Nil) ->
          case values.parse_wire(text) {
            Error(failure) -> Ok(Error(failure))
            Ok(parsed) -> {
              use before_spelling <- result.try(spelling(before))
              use parsed_spelling <- result.try(spelling(parsed))
              case parsed_spelling == before_spelling {
                True -> Ok(Ok(parsed))
                False -> Error("wire and exact input differ")
              }
            }
          }
      }
    }
  }
}

fn evaluate_decoded(
  input: json.JsonValue,
  id: json.JsonValue,
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  before: json.JsonValue,
  tamper: Bool,
) -> Result(json.JsonValue, String) {
  case wire_check(input, before) {
    Error(reason) -> Error(reason)
    Ok(Error(failure)) -> Ok(codec_row(id, failure))
    Ok(Ok(decoded)) ->
      materialized_row(id, graph, reference, before, decoded, tamper)
  }
}

fn materialized_row(
  id: json.JsonValue,
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  before: json.JsonValue,
  decoded: json.JsonValue,
  tamper: Bool,
) -> Result(json.JsonValue, String) {
  let prepared = validation.prepare(graph)
  case validation.materialize_defaults(prepared, reference, decoded) {
    Ok(defaulted) -> {
      let value = validation.defaulted_value(defaulted)
      let applications = validation.defaulted_value_applications(defaulted)
      use second <- result.try(
        validation.materialize_defaults(prepared, reference, value)
        |> result.map_error(string.inspect),
      )
      use after <- result.try(encoded(value, values.encode_exact))
      use apps_json <- result.try(applications_json(applications))
      use second_value <- result.try(encoded(
        validation.defaulted_value(second),
        values.encode_exact,
      ))
      use second_applications <- result.try(
        applications_json(validation.defaulted_value_applications(second)),
      )
      use before_json <- result.try(encoded(before, values.encode_exact))
      let row = [
        #("id", id),
        #("status", str("Accepted")),
        #("value", after),
        #("applications", apps_json),
        #("second_value", second_value),
        #("second_applications", second_applications),
        #("input", before_json),
      ]
      case tamper, applications {
        True, [first, ..rest] -> {
          let source =
            types.SourceRef(
              ..first.type_ref.source,
              document_id: first.type_ref.source.document_id <> "-forged",
            )
          let forged = [
            validation.DefaultApplication(
              ..first,
              type_ref: types.TypeRef(..first.type_ref, source: source),
            ),
            validation.DefaultApplication(
              ..first,
              origin: types.OccurrenceRef(
                ..first.origin,
                pointer: list.append(first.origin.pointer, ["forged"]),
              ),
            ),
            validation.DefaultApplication(
              ..first,
              value_path: list.append(first.value_path, [types.Field("forged")]),
            ),
            validation.DefaultApplication(
              ..first,
              value: json.JsonValueBool(True),
            ),
          ]
          let checks =
            list.map(forged, fn(item) {
              json.JsonValueBool(
                validation.check_default_applications(prepared, before, value, [
                  item,
                  ..rest
                ]),
              )
            })
          Ok(obj(list.append(row, [#("certificates", arr(checks))])))
        }
        False, _ -> Ok(obj(row))
        True, [] -> Error("application required for certificate probe")
      }
    }
    Error(validation.Rejected(failure)) -> {
      use definition_ref <- result.try(encoded(
        types.DefinitionRef(
          failure.type_ref.source,
          failure.type_ref.definition_name,
        ),
        decode.encode_definition_ref,
      ))
      use condition <- result.try(encoded(
        failure.condition,
        decode.encode_value_condition,
      ))
      use observed <- result.try(encoded(
        failure.observed,
        decode.encode_slot_value,
      ))
      Ok(
        obj([
          #("id", id),
          #("status", str("Rejected")),
          #("type_ref", ref_json(failure.type_ref)),
          #("definition_ref", definition_ref),
          #("origin", origin_json(failure.origin)),
          #("value_path", path_json(failure.value_path)),
          #("condition", condition),
          #("observed", observed),
          #("reference_trace", arr(list.map(failure.reference_trace, ref_json))),
        ]),
      )
    }
    Error(validation.Unresolved(obligations)) ->
      Ok(
        obj([
          #("id", id),
          #("status", str("Unresolved")),
          #(
            "obligations",
            arr(
              list.map(obligations, fn(obligation) {
                obj([
                  #("type_ref", ref_json(obligation.type_ref)),
                  #("origin", origin_json(obligation.origin)),
                  #("value_path", path_json(obligation.value_path)),
                  #(
                    "profile",
                    obj([
                      #("identity", str(obligation.profile.identity)),
                      #("revision", str(obligation.profile.revision)),
                      #(
                        "content_digest",
                        str(obligation.profile.content_digest),
                      ),
                    ]),
                  ),
                  #("reason", reason_json(obligation.reason)),
                ])
              }),
            ),
          ),
        ]),
      )
    Error(validation.CertificateMismatchFailure(condition)) ->
      Ok(
        obj([
          #("id", id),
          #("status", str("CertificateMismatch")),
          #("condition", str(condition)),
        ]),
      )
  }
}

pub fn run(line: String) -> String {
  let outcome =
    values.parse_wire(line)
    |> result.map_error(string.inspect)
    |> result.try(evaluate)
    |> result.try(fn(value) { encoded(value, values.encode_wire) })
  case outcome {
    Ok(output) -> output
    Error(reason) -> {
      let assert Ok(output) =
        values.encode_wire(obj([#("adapter_error", str(reason))]))
      output
    }
  }
}

pub fn main() {
  case read_line() {
    "" -> Nil
    line -> {
      io.println(run(line))
      main()
    }
  }
}
