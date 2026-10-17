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
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

@external(erlang, "necoherence_semantic_invariant_runner_ffi", "read_line")
fn read_line() -> String

fn field(value: json.JsonValue, key: String) -> Result(json.JsonValue, String) {
  case value {
    json.JsonValueObj(members) ->
      list.key_find(members, key)
      |> result.map_error(fn(_) { "field: " <> key })
    _ -> Error("object")
  }
}

fn text(value: json.JsonValue) -> Result(String, String) {
  case value {
    json.JsonValueStr(value) -> Ok(value)
    _ -> Error("text")
  }
}

fn array(value: json.JsonValue) -> Result(List(json.JsonValue), String) {
  case value {
    json.JsonValueArr(value) -> Ok(value)
    _ -> Error("array")
  }
}

fn boolean(value: json.JsonValue) -> Result(Bool, String) {
  case value {
    json.JsonValueBool(value) -> Ok(value)
    _ -> Error("boolean")
  }
}

fn decoded(value, decoder) {
  decoder(value) |> result.map_error(string.inspect)
}

fn element(value: json.JsonValue) -> Result(types.ElementContract, String) {
  use reference <- result.try(
    field(value, "type_ref")
    |> result.try(fn(value) { decoded(value, decode.decode_type_ref) }),
  )
  use nullable <- result.try(field(value, "nullable") |> result.try(boolean))
  Ok(types.ElementContract(reference, nullable))
}

fn occurrence(value: json.JsonValue) -> Result(types.OccurrenceRef, String) {
  use source <- result.try(
    field(value, "source")
    |> result.try(fn(value) { decoded(value, decode.decode_source_ref) }),
  )
  use pointer <- result.try(
    field(value, "pointer")
    |> result.try(array)
    |> result.try(fn(items) { list.try_map(items, text) }),
  )
  Ok(types.OccurrenceRef(source, pointer))
}

fn field_spec(value: json.JsonValue) -> Result(types.FieldSpec, String) {
  use name <- result.try(field(value, "wire_name") |> result.try(text))
  use slot <- result.try(
    field(value, "slot")
    |> result.try(fn(value) { decoded(value, decode.decode_slot_contract) }),
  )
  use origin <- result.try(field(value, "origin") |> result.try(occurrence))
  Ok(types.FieldSpec(name, slot, origin))
}

fn extras(value: json.JsonValue) -> Result(types.ExtraMembers, String) {
  use tag <- result.try(field(value, "tag") |> result.try(text))
  case tag {
    "Reject" -> Ok(types.RejectExtras)
    "Allow" -> {
      use fields <- result.try(field(value, "fields"))
      use key <- result.try(field(fields, "key_format"))
      use key <- result.try(case key {
        json.JsonValueNull -> Ok(None)
        _ -> decoded(key, decode.decode_format_use) |> result.map(Some)
      })
      use value <- result.try(field(fields, "value") |> result.try(element))
      Ok(types.AllowExtras(key, value))
    }
    _ -> Error("extras tag")
  }
}

fn branch(value: json.JsonValue) -> Result(types.UnionBranch, String) {
  use target <- result.try(
    field(value, "target")
    |> result.try(fn(value) { decoded(value, decode.decode_type_ref) }),
  )
  use tag <- result.try(field(value, "wire_tag") |> result.try(text))
  use selector <- result.try(
    field(value, "selector")
    |> result.try(fn(value) { field(value, "tag") })
    |> result.try(text),
  )
  use selector <- result.try(case selector {
    "InternalTag" -> Ok(types.InternalTag)
    "Otherwise" -> Ok(types.Otherwise)
    _ -> Error("selector")
  })
  use origin <- result.try(field(value, "origin") |> result.try(occurrence))
  Ok(types.UnionBranch(target, tag, selector, origin))
}

fn shape(value: json.JsonValue) -> Result(types.TypeShape, String) {
  use tag <- result.try(field(value, "tag") |> result.try(text))
  case tag {
    "Boolean" ->
      field(value, "value")
      |> result.try(fn(value) { decoded(value, decode.decode_boolean_spec) })
      |> result.map(types.BooleanShape)
    "Integer" ->
      field(value, "value")
      |> result.try(fn(value) { decoded(value, decode.decode_integer_spec) })
      |> result.map(types.IntegerShape)
    "String" ->
      field(value, "value")
      |> result.try(fn(value) { decoded(value, decode.decode_string_spec) })
      |> result.map(types.StringShape)
    "Array" ->
      field(value, "value")
      |> result.try(fn(value) { decoded(value, decode.decode_array_spec) })
      |> result.map(types.ArrayShape)
    "Product" -> {
      use value <- result.try(field(value, "value"))
      use fields <- result.try(
        field(value, "fields")
        |> result.try(array)
        |> result.try(fn(items) { list.try_map(items, field_spec) }),
      )
      use extras <- result.try(field(value, "extras") |> result.try(extras))
      Ok(types.ProductShape(types.ProductSpec(fields, extras)))
    }
    "Alias" -> {
      use value <- result.try(field(value, "fields"))
      use target <- result.try(
        field(value, "target")
        |> result.try(fn(value) { decoded(value, decode.decode_type_ref) }),
      )
      use reference_text <- result.try(
        field(value, "reference_text") |> result.try(text),
      )
      Ok(types.AliasShape(target, reference_text))
    }
    "TaggedUnion" ->
      field(value, "value")
      |> result.try(fn(value) { field(value, "branches") })
      |> result.try(array)
      |> result.try(fn(items) { list.try_map(items, branch) })
      |> result.map(fn(branches) {
        types.TaggedUnionShape(types.UnionSpec(branches))
      })
    "Unknown" -> {
      use kind <- result.try(
        field(value, "value")
        |> result.try(fn(value) { field(value, "tag") })
        |> result.try(text),
      )
      case kind {
        "Any" -> Ok(types.UnknownShape(types.AnyValue))
        "OrdinaryObject" -> Ok(types.UnknownShape(types.OrdinaryObject))
        _ -> Error("unknown kind")
      }
    }
    "Unit" -> Ok(types.UnitShape)
    "Never" -> Ok(types.Never)
    _ -> Error("type shape: " <> tag)
  }
}

fn node(value: json.JsonValue) -> Result(types.TypeNode, String) {
  use reference <- result.try(
    field(value, "reference")
    |> result.try(fn(value) { decoded(value, decode.decode_type_ref) }),
  )
  use shape <- result.try(field(value, "shape") |> result.try(shape))
  use description <- result.try(field(value, "description"))
  use description <- result.try(case description {
    json.JsonValueNull -> Ok(None)
    value -> text(value) |> result.map(Some)
  })
  use attributes <- result.try(
    field(value, "attributes")
    |> result.try(array)
    |> result.try(fn(items) { list.try_map(items, occurrence) }),
  )
  use extensions <- result.try(
    field(value, "extensions")
    |> result.try(array)
    |> result.try(fn(items) { list.try_map(items, occurrence) }),
  )
  Ok(types.TypeNode(reference, shape, description, attributes, extensions))
}

fn graph(value: json.JsonValue) -> Result(types.SemanticGraph, String) {
  use profile <- result.try(
    field(value, "profile")
    |> result.try(fn(value) { decoded(value, decode.decode_semantic_profile) }),
  )
  use nodes <- result.try(
    field(value, "nodes")
    |> result.try(array)
    |> result.try(fn(items) { list.try_map(items, node) }),
  )
  use sources <- result.try(
    field(value, "source_refs")
    |> result.try(array)
    |> result.try(fn(items) {
      list.try_map(items, fn(value) { decoded(value, decode.decode_source_ref) })
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
  use value <- result.try(decoded(application.value, values.encode_exact))
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

fn condition_name(condition: types.ValueCondition) -> String {
  case condition {
    types.MissingRequiredCondition -> "MissingRequired"
    types.NullNotAllowedCondition -> "NullNotAllowed"
    types.WrongValueKindCondition(expected) -> "WrongValueKind:" <> expected
    types.ConstMismatchCondition -> "ConstMismatch"
    types.EnumMismatchCondition -> "EnumMismatch"
    types.BelowMinimumCondition -> "BelowMinimum"
    types.AboveMaximumCondition -> "AboveMaximum"
    types.IntegerDomainCondition -> "IntegerDomain"
    types.StringLengthCondition -> "StringLength"
    types.ArrayLengthCondition -> "ArrayLength"
    types.BytesLengthCondition -> "BytesLength"
    types.FormatFailureCondition(name) -> "Format:" <> name
    types.InvalidBytesCondition -> "InvalidBytes"
    types.InvalidWrapperCondition(name) -> "InvalidWrapper:" <> name
    types.InvalidTagCondition -> "InvalidTag"
    types.ReservedFormCondition -> "ReservedForm"
    types.NoBranchSelectedCondition -> "NoBranchSelected"
    types.KeyFormatCondition(name) -> "KeyFormat:" <> name
    types.UninhabitedCondition -> "Uninhabited"
    types.DuplicateFieldCondition(name) -> "DuplicateField:" <> name
    types.UnexpectedFieldCondition(name) -> "UnexpectedField:" <> name
    types.InvalidDataModelCondition -> "InvalidDataModel"
    types.ReferenceCycleCondition -> "ReferenceCycle"
  }
}

fn evaluate(input: json.JsonValue) -> Result(json.JsonValue, String) {
  use id <- result.try(field(input, "id"))
  use graph <- result.try(field(input, "graph") |> result.try(graph))
  use reference <- result.try(
    field(input, "reference")
    |> result.try(fn(value) { decoded(value, decode.decode_type_ref) }),
  )
  use before <- result.try(
    field(input, "before")
    |> result.try(fn(value) { decoded(value, values.decode_exact) }),
  )
  use tamper <- result.try(field(input, "tamper") |> result.try(boolean))
  let materialized = case field(input, "wire") {
    Ok(wire) -> {
      use wire <- result.try(text(wire))
      Ok(
        values.parse_unique_wire(wire)
        |> result.map(fn(value) {
          validation.materialize_defaults(graph, reference, value)
        }),
      )
    }
    Error(_) ->
      Ok(Ok(validation.materialize_defaults(graph, reference, before)))
  }
  use materialized <- result.try(materialized)
  case materialized {
    Error(failure) -> {
      let classification = case failure {
        values.DuplicateField(_) -> "DuplicateField"
        values.InvalidSyntax | values.InvalidExactValue -> "Syntax"
      }
      Ok(
        obj([
          #("id", id),
          #("status", str("Wire")),
          #("classification", str(classification)),
        ]),
      )
    }
    Ok(Ok(defaulted)) -> {
      let value = validation.defaulted_value(defaulted)
      let applications = validation.defaulted_value_applications(defaulted)
      use second <- result.try(
        validation.materialize_defaults(graph, reference, value)
        |> result.map_error(string.inspect),
      )
      use after <- result.try(decoded(value, values.encode_exact))
      use apps_json <- result.try(applications_json(applications))
      use second_value <- result.try(decoded(
        validation.defaulted_value(second),
        values.encode_exact,
      ))
      use second_applications <- result.try(
        applications_json(validation.defaulted_value_applications(second)),
      )
      use before_json <- result.try(decoded(before, values.encode_exact))
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
                validation.check_default_applications(graph, before, value, [
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
    Ok(Error(validation.Rejected(failure))) ->
      Ok(
        obj([
          #("id", id),
          #("status", str("Rejected")),
          #("type_ref", ref_json(failure.type_ref)),
          #("origin", origin_json(failure.origin)),
          #("value_path", path_json(failure.value_path)),
          #("condition", str(condition_name(failure.condition))),
          #("reference_trace", arr(list.map(failure.reference_trace, ref_json))),
        ]),
      )
    Ok(Error(validation.Unresolved(obligations))) ->
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
                  #(
                    "origin",
                    origin_json(types.occurrence(obligation.type_ref)),
                  ),
                  #("value_path", path_json(obligation.value_path)),
                  #(
                    "profile",
                    obj([
                      #("identity", str(graph.profile.reference.identity)),
                      #("revision", str(graph.profile.reference.revision)),
                      #(
                        "content_digest",
                        str(graph.profile.reference.content_digest),
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
    Ok(Error(validation.CertificateMismatchFailure(condition))) ->
      Ok(
        obj([
          #("id", id),
          #("status", str("CertificateMismatch")),
          #("condition", str(condition)),
        ]),
      )
  }
}

pub fn main() {
  case read_line() {
    "" -> Nil
    line -> {
      let outcome =
        values.parse_wire(line)
        |> result.map_error(string.inspect)
        |> result.try(evaluate)
        |> result.try(fn(value) { decoded(value, values.encode_wire) })
      case outcome {
        Ok(output) -> io.println(output)
        Error(reason) -> {
          let assert Ok(output) =
            values.encode_wire(obj([#("adapter_error", str(reason))]))
          io.println(output)
        }
      }
      main()
    }
  }
}
