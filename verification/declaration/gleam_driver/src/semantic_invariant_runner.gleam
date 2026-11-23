// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import necoherence/admission_failure as admission
import necoherence/exact_json as j
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_generation_values as values
import necoherence/semantic_residual_record as residual_record
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import predicate_codes

@external(erlang, "semantic_invariant_runner_ffi", "read_line")
fn read_line() -> String

pub fn main() {
  case read_line() {
    "" -> Nil
    line -> {
      case string.trim(line) {
        "" -> Nil
        _ -> io.println(run(line))
      }
      main()
    }
  }
}

pub fn run(line: String) -> String {
  let output = case values.parse_wire(line) {
    Error(error) -> invalid("", string.inspect(error))
    Ok(input) -> {
      let id = result.unwrap(text_field(input, "id"), "")
      case evaluate(input, id) {
        Ok(output) -> output
        Error(reason) -> invalid(id, reason)
      }
    }
  }
  result.unwrap(
    values.encode_wire(output),
    "{\"error\":\"output encoding failed\"}",
  )
}

fn obj(fields: List(#(String, j.JsonValue))) -> j.JsonValue {
  j.JsonValueObj(fields)
}

fn str(value: String) -> j.JsonValue {
  j.JsonValueStr(value)
}

fn invalid(id: String, reason: String) -> j.JsonValue {
  obj([#("id", str(id)), #("error", str(reason))])
}

fn field(value: j.JsonValue, name: String) -> Result(j.JsonValue, String) {
  signatures.field(value, name) |> result.map_error(string.inspect)
}

fn text_field(value: j.JsonValue, name: String) -> Result(String, String) {
  use value <- result.try(field(value, name))
  case value {
    j.JsonValueStr(text) -> Ok(text)
    _ -> Error("string required: " <> name)
  }
}

fn evaluate(input: j.JsonValue, id: String) -> Result(j.JsonValue, String) {
  use kind <- result.try(text_field(input, "kind"))
  case kind {
    "wire" -> wire_roundtrip(input, id)
    "profile" -> profile_check(input, id)
    _ -> {
      use raw <- result.try(field(input, "library"))
      let decoded = signatures.decode_library_value(raw)
      case kind, decoded {
        "library", Ok(_) ->
          Ok(obj([#("id", str(id)), #("status", str("Accepted"))]))
        "library",
          Error(signatures.LibraryRejected(types.ProfileCheck(failure)))
        ->
          Ok(
            obj([
              #("id", str(id)),
              #("status", str("Rejected")),
              #("predicate", str(profile_predicate(failure.predicate))),
              #("path", string_array(failure.location)),
            ]),
          )
        "library",
          Error(signatures.LibraryRejected(types.LibraryCheck(failure)))
        ->
          Ok(
            obj([
              #("id", str(id)),
              #("status", str("Rejected")),
              #(
                "predicate",
                str(
                  string.uppercase(predicate_codes.library_predicate_code(
                    failure.predicate,
                  )),
                ),
              ),
              #("path", string_array(failure.location)),
            ]),
          )
        "library", Error(error) -> Error(string.inspect(error))
        "profile_admission", Error(_) ->
          Ok(
            obj([
              #("id", str(id)),
              #("status", str("Rejected")),
              #("rejection", str("InvalidProfile")),
            ]),
          )
        "profile_admission", Ok(library) ->
          case admission(library) {
            Ok(_) -> Ok(obj([#("id", str(id)), #("status", str("Accepted"))]))
            Error(_) ->
              Ok(
                obj([
                  #("id", str(id)),
                  #("status", str("Rejected")),
                  #("rejection", str("InvalidProfile")),
                ]),
              )
          }
        _, Error(error) -> Error(string.inspect(error))
        _, Ok(library) -> evaluate_admitted(input, id, kind, library)
      }
    }
  }
}

fn string_array(values: List(String)) -> j.JsonValue {
  j.JsonValueArr(list.map(values, str))
}

fn profile_predicate(predicate: types.ProfilePredicate) -> String {
  string.uppercase(predicate_codes.profile_predicate_code(predicate))
}

fn wire_roundtrip(
  input: j.JsonValue,
  id: String,
) -> Result(j.JsonValue, String) {
  use raw <- result.try(field(input, "value"))
  use basis_wire <- result.try(
    signatures.expected_generation_text(raw)
    |> result.map_error(string.inspect),
  )
  use input_wire <- result.try(
    values.encode_wire(raw)
    |> result.map_error(string.inspect),
  )
  case signatures.admit_generation(basis_wire, input_wire) {
    Error(admission.UnsupportedSchema(_)) ->
      Ok(wire_rejection(id, "UnsupportedSchema", ["$", "schema"]))
    Error(admission.Wire(decode.UnknownField(path, _))) ->
      Ok(wire_rejection(id, "UnknownField", path))
    Error(admission.Wire(decode.UnknownTag(path, _))) ->
      Ok(wire_rejection(id, "UnknownTag", path))
    Error(admission.Wire(decode.SyntaxFailure(path, _))) ->
      Ok(wire_rejection(id, "Syntax", path))
    Error(error) -> Error(string.inspect(error))
    Ok(checked) -> {
      use signatures_wire <- result.try(
        signatures.encode_library(signatures.checked_library(checked))
        |> result.map_error(string.inspect)
        |> result.try(fn(text) {
          values.parse_wire(text) |> result.map_error(string.inspect)
        }),
      )
      use basis_wire <- result.try(
        signatures.encode_basis(checked)
        |> result.map_error(string.inspect)
        |> result.try(fn(text) {
          values.parse_wire(text) |> result.map_error(string.inspect)
        }),
      )
      use entrypoints <- result.try(field(raw, "entrypoints"))
      let output =
        obj([
          #("schema", str("ncoh-checked-generation@5")),
          #("basis", basis_wire),
          #("signatures", signatures_wire),
          #("composition", j.JsonValueNull),
          #("entrypoints", entrypoints),
        ])
      Ok(
        obj([
          #("id", str(id)),
          #("status", str("Accepted")),
          #("encoded", output),
        ]),
      )
    }
  }
}

fn wire_rejection(
  id: String,
  classification: String,
  path: List(String),
) -> j.JsonValue {
  obj([
    #("id", str(id)),
    #("status", str("Rejected")),
    #("failure_kind", str("Wire")),
    #("classification", str(classification)),
    #("path", str(string.join(path, "."))),
  ])
}

fn profile_check(
  input: j.JsonValue,
  id: String,
) -> Result(j.JsonValue, String) {
  use library <- result.try(field(input, "library"))
  use raw <- result.try(field(library, "profile"))
  case decode.decode_semantic_profile(raw) {
    Error(decode.SyntaxFailure(path, reason)) ->
      Ok(
        obj([
          #("id", str(id)),
          #("status", str("Rejected")),
          #(
            "failure",
            obj([
              #("kind", str("Wire")),
              #("classification", str(reason)),
              #("path", string_array(path)),
            ]),
          ),
        ]),
      )
    Error(error) -> Error(string.inspect(error))
    Ok(profile) ->
      case validation.check_profile(profile) {
        Ok(_) -> Ok(obj([#("id", str(id)), #("status", str("Accepted"))]))
        Error(types.ProfileFailure(_, predicate, location)) ->
          Ok(
            obj([
              #("id", str(id)),
              #("status", str("Rejected")),
              #("predicate", str(profile_predicate(predicate))),
              #("path", string_array(location)),
            ]),
          )
      }
  }
}

fn evaluate_admitted(
  input: j.JsonValue,
  id: String,
  kind: String,
  library: signatures.AdmittedLibrary,
) -> Result(j.JsonValue, String) {
  case kind {
    "value" -> value(input, id, library)
    "residual_record" -> residual(input, id, library)
    _ -> Error("unknown kind: " <> kind)
  }
}

fn value(
  input: j.JsonValue,
  id: String,
  library: signatures.AdmittedLibrary,
) -> Result(j.JsonValue, String) {
  use type_id <- result.try(text_field(input, "type_id"))
  use value <- result.try(field(input, "value"))
  case signatures.validate_value(library, type_id, value) {
    Ok(_) -> Ok(obj([#("id", str(id)), #("status", str("Accepted"))]))
    Error(runtime.Constraint(validation.Rejected(failure))) -> {
      use details <- result.try(failure_fields(failure))
      Ok(obj([#("id", str(id)), #("status", str("Rejected")), ..details]))
    }
    Error(runtime.Constraint(validation.Unresolved(_))) ->
      Ok(obj([#("id", str(id)), #("status", str("Unresolved"))]))
    Error(error) -> Error(string.inspect(error))
  }
}

fn failure_fields(
  failure: types.ValueFailure,
) -> Result(List(#(String, j.JsonValue)), String) {
  use encoded <- result.try(
    decode.encode_value_condition(failure.condition)
    |> result.map_error(string.inspect),
  )
  use type_ref <- result.try(
    decode.encode_type_ref(failure.type_ref)
    |> result.map_error(string.inspect),
  )
  use tag <- result.try(text_field(encoded, "tag"))
  let condition = case field(encoded, "value") {
    Ok(j.JsonValueStr(value)) -> tag <> ":" <> value
    _ -> tag
  }
  Ok([
    #("type_ref", type_ref),
    #(
      "path",
      j.JsonValueArr(
        list.map(failure.value_path, fn(step) {
          case step {
            types.Field(name) -> str(name)
            types.Variant(tag) -> str("variant:" <> tag)
            types.Index(index) -> j.JsonValueNum(index)
          }
        }),
      ),
    ),
    #("condition", str(condition)),
    #(
      "trace",
      j.JsonValueArr(
        list.map(failure.reference_trace, fn(reference) {
          str(reference.definition_name)
        }),
      ),
    ),
  ])
}

fn admission(
  library: signatures.AdmittedLibrary,
) -> Result(signatures.CheckedGeneration, String) {
  use wire <- result.try(
    signatures.encode_library(library) |> result.map_error(string.inspect),
  )
  let entries =
    j.JsonValueArr(
      list.map(signatures.definitions(library), fn(definition) {
        obj([
          #("identity", str(definition.id)),
          #("definition", str(definition.id)),
        ])
      }),
    )
  use assembled <- result.try(
    signatures.assemble_generation(wire, j.JsonValueNull, entries)
    |> result.map_error(string.inspect),
  )
  signatures.admit_generation(assembled.0, assembled.1)
  |> result.map_error(string.inspect)
}

fn optional_text(
  value: j.JsonValue,
  name: String,
) -> Result(Option(String), String) {
  use member <- result.try(field(value, name))
  case member {
    j.JsonValueNull -> Ok(None)
    j.JsonValueStr(text) -> Ok(Some(text))
    _ -> Error("string or null required: " <> name)
  }
}

fn requirement(
  basis: j.JsonValue,
) -> Result(signatures.GenerationRequirement, String) {
  use signature_schema <- result.try(text_field(basis, "signature_schema"))
  use library_identity <- result.try(text_field(basis, "library_identity"))
  use library_revision <- result.try(text_field(basis, "library_revision"))
  use profile <- result.try(field(basis, "profile"))
  use profile <- result.try(
    decode.decode_profile_ref(profile) |> result.map_error(string.inspect),
  )
  use graph_sha256 <- result.try(text_field(basis, "graph_sha256"))
  use provenance_sha256 <- result.try(text_field(basis, "provenance_sha256"))
  use metadata_sha256 <- result.try(text_field(basis, "metadata_sha256"))
  use problem_sha256 <- result.try(optional_text(basis, "problem_sha256"))
  use observations_sha256 <- result.try(optional_text(
    basis,
    "observations_sha256",
  ))
  use entrypoints_sha256 <- result.try(text_field(basis, "entrypoints_sha256"))
  Ok(signatures.GenerationRequirement(
    signature_schema,
    library_identity,
    library_revision,
    profile,
    graph_sha256,
    provenance_sha256,
    metadata_sha256,
    problem_sha256,
    observations_sha256,
    entrypoints_sha256,
  ))
}

fn is_residual_reason(reason: types.SemanticReason) -> Bool {
  case reason {
    types.UnknownFormatReason(_)
    | types.MissingGraphemeRulesReason
    | types.MissingBytesPolicyReason
    | types.UnknownIntegerDomainReason(_)
    | types.UnknownWrapperReason(_)
    | types.UnknownSealedTagReason(_)
    | types.OpaqueTypeReason(_)
    | types.MissingTagModelReason
    | types.UninterpretedExtensionReason(_)
    | types.UnresolvedTypeReason
    | types.ProjectionUnavailableReason(_) -> True
    types.MembershipBoundReason
    | types.WrapperPayloadReason(_)
    | types.DecimalNotAdmittedReason
    | types.IntegerBoundReason
    | types.InvalidProfileReason(_)
    | types.CertificateMismatchReason(_) -> False
  }
}

fn hex(bytes: BitArray) -> String {
  case bytes {
    <<byte, rest:bits>> -> {
      let digits = string.lowercase(int.to_base16(byte))
      string.pad_start(digits, 2, "0") <> hex(rest)
    }
    _ -> ""
  }
}

fn residual(
  input: j.JsonValue,
  id: String,
  library: signatures.AdmittedLibrary,
) -> Result(j.JsonValue, String) {
  use type_id <- result.try(text_field(input, "type_id"))
  use value <- result.try(field(input, "value"))
  use basis <- result.try(field(input, "basis"))
  use basis <- result.try(requirement(basis))
  case signatures.validate_value(library, type_id, value) {
    Error(runtime.Constraint(validation.Unresolved(obligations))) ->
      case
        list.filter(obligations, fn(obligation) {
          is_residual_reason(obligation.reason)
        })
      {
        [] -> Ok(obj([#("id", str(id)), #("status", str("not-unresolved"))]))
        residuals ->
          case
            residual_record.encode_semantic_residual(
              basis,
              signatures.type_ref(library, type_id),
              value,
              residuals,
            )
          {
            Ok(bytes) ->
              Ok(
                obj([
                  #("id", str(id)),
                  #("status", str("encoded")),
                  #("bytes", str(hex(bytes))),
                ]),
              )
            Error(error) -> Error(string.inspect(error))
          }
      }
    Ok(_) | Error(runtime.Constraint(validation.Rejected(_))) ->
      Ok(obj([#("id", str(id)), #("status", str("not-unresolved"))]))
    Error(error) -> Error(string.inspect(error))
  }
}
