// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import necoherence/exact_json as j
import necoherence/semantic_composition as composition
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence_tools/composition_search
import necoherence_tools/renderer

@external(erlang, "necoherence_semantic_invariant_runner_ffi", "read_line")
fn read_line() -> String

@external(erlang, "necoherence_semantic_invariant_runner_ffi", "codec")
fn compiled_codec(
  source: String,
  name: String,
  checked: signatures.CheckedGeneration,
  wire: String,
) -> Result(String, runtime.ValueFailure)

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
        "library", Error(signatures.Invalid(predicate)) ->
          Ok(
            obj([
              #("id", str(id)),
              #("status", str("Rejected")),
              #("predicate", str(predicate)),
              #("path", j.JsonValueArr([str("library")])),
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
  case predicate {
    types.Pr01 -> "PR01"
    types.Pr02 -> "PR02"
    types.Pr03 -> "PR03"
    types.Pr04 -> "PR04"
    types.Pr05 -> "PR05"
    types.Pr06 -> "PR06"
    types.Pr07 -> "PR07"
    types.Pr08 -> "PR08"
    types.Pr09 -> "PR09"
    types.Pr10 -> "PR10"
    types.Pr11 -> "PR11"
    types.Pr12 -> "PR12"
    types.Pr13 -> "PR13"
    types.Pr14 -> "PR14"
    types.Pr15 -> "PR15"
    types.Pr16 -> "PR16"
  }
}

fn wire_roundtrip(
  input: j.JsonValue,
  id: String,
) -> Result(j.JsonValue, String) {
  use raw <- result.try(field(input, "value"))
  use basis <- result.try(field(raw, "basis"))
  use basis_wire <- result.try(
    values.encode_wire(basis)
    |> result.map_error(string.inspect),
  )
  use input_wire <- result.try(
    values.encode_wire(raw)
    |> result.map_error(string.inspect),
  )
  use checked <- result.try(
    signatures.admit_generation(basis_wire, input_wire)
    |> result.map_error(string.inspect),
  )
  use encoded <- result.try(
    signatures.encode_checked(checked)
    |> result.map_error(string.inspect),
  )
  use output <- result.try(
    values.parse_wire(encoded)
    |> result.map_error(string.inspect),
  )
  Ok(
    obj([
      #("id", str(id)),
      #("status", str("Accepted")),
      #("encoded", output),
    ]),
  )
}

fn profile_check(
  input: j.JsonValue,
  id: String,
) -> Result(j.JsonValue, String) {
  use library <- result.try(field(input, "library"))
  use raw <- result.try(field(library, "profile"))
  case decode.decode_semantic_profile(raw) {
    Error(decode.DecodeFailure(path, reason)) ->
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
        Error(types.ProfileFailure(reference, predicate, location)) ->
          Ok(
            obj([
              #("id", str(id)),
              #("status", str("Rejected")),
              #(
                "failure",
                obj([
                  #("kind", str("Declaration")),
                  #("predicate", str(profile_predicate(predicate))),
                  #("location", string_array(location)),
                  #("reference", str(reference.identity)),
                ]),
              ),
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
    "grapheme" -> grapheme(input, id, library)
    "construction_solver" -> solve(input, id, library)
    "construction_witness" -> witness(input, id)
    "value" -> value(input, id, library)
    "samples" -> samples(input, id, library)
    "inclusion" -> inclusion(input, id, library)
    "projection" -> projection(input, id, library)
    "codec" -> codec(input, id, library)
    "library_invariant" -> library_invariant(input, id, library)
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

fn grapheme(
  input: j.JsonValue,
  id: String,
  library: signatures.AdmittedLibrary,
) -> Result(j.JsonValue, String) {
  use text <- result.try(text_field(input, "text"))
  case signatures.library_graph(library).profile.grapheme_rules {
    None -> Error("grapheme rules required")
    Some(rules) ->
      Ok(
        obj([
          #("id", str(id)),
          #(
            "boundaries",
            j.JsonValueArr(list.map(
              validation.grapheme_boundaries(rules, text),
              j.JsonValueNum,
            )),
          ),
          #("count", j.JsonValueNum(validation.grapheme_count(rules, text))),
        ]),
      )
  }
}

fn solve(
  input: j.JsonValue,
  id: String,
  library: signatures.AdmittedLibrary,
) -> Result(j.JsonValue, String) {
  use problem <- result.try(field(input, "problem"))
  use translated <- result.try(
    signatures.translate_composition(library, problem)
    |> result.map_error(string.inspect),
  )
  use decoded <- result.try(
    decode.decode_composition_input(translated)
    |> result.map_error(string.inspect),
  )
  use prepared <- result.try(
    signatures.prepare_composition(library, decoded, [])
    |> result.map_error(string.inspect),
  )
  use decision <- result.try(
    composition_search.derive_composition(prepared)
    |> result.map_error(string.inspect),
  )
  let #(classification, bindings) = case decision {
    composition.Solved(checked, _) -> #(
      "Solved",
      plan_bindings(composition.checked_plan(checked).root),
    )
    composition.Unreachable(_) -> #("Unreachable", [])
    composition.Ambiguous(_, _) -> #("Ambiguous", [])
    composition.CompositionUnknown(_, _, _) -> #("Unknown", [])
  }
  let bindings =
    list.sort(bindings, fn(a, b) {
      string.compare(
        result.unwrap(values.encode_wire(a), ""),
        result.unwrap(values.encode_wire(b), ""),
      )
    })
  Ok(
    obj([
      #("id", str(id)),
      #("classification", str(classification)),
      #("bindings", j.JsonValueArr(bindings)),
    ]),
  )
}

fn path_strings(path: types.ValuePath) -> j.JsonValue {
  j.JsonValueArr(
    list.map(path, fn(step) {
      str(case step {
        types.Field(name) -> "field:" <> name
        types.Index(index) -> "index:" <> int.to_string(index)
        types.Variant(tag) -> "variant:" <> tag
      })
    }),
  )
}

fn binding(
  destination: String,
  expression: composition.BindingExpr,
) -> List(j.JsonValue) {
  case expression {
    composition.Source(value, _, _) -> {
      let producer = case value.producer {
        composition.Initial(id) -> ["initial", id.value]
        composition.InvocationOutcome(site, outcome, port) -> [
          "outcome",
          site.value,
          outcome.value,
          port.value,
        ]
      }
      [
        obj([
          #("destination", str(destination)),
          #("producer", j.JsonValueArr(list.map(producer, str))),
          #("path", path_strings(value.path)),
        ]),
      ]
    }
    composition.Product(id, _, fields) -> [
      obj([
        #("destination", str(destination)),
        #("producer", j.JsonValueArr([str("construction"), str(id)])),
        #("path", j.JsonValueArr([])),
      ]),
      ..list.flat_map(fields, fn(field) {
        binding("construction:" <> id <> ":" <> field.0, field.1)
      })
    ]
  }
}

fn plan_bindings(tree: composition.PlanTree) -> List(j.JsonValue) {
  case tree.node {
    composition.Return(composition.ReturnSuccess(outputs)) ->
      list.flat_map(outputs, fn(output) {
        binding("goal:" <> output.0.value, output.1)
      })
    composition.Return(composition.ReturnFailure(id, value)) ->
      binding("failure:" <> id.value, value)
    composition.Invoke(invocation, arms, _) ->
      list.append(
        list.flat_map(invocation.bindings, fn(input) {
          binding(
            "invocation:" <> invocation.site.value <> ":" <> input.0.value,
            input.1,
          )
        }),
        list.flat_map(arms, fn(arm) { plan_bindings(arm.1) }),
      )
    composition.Guard(_, _, arms) ->
      list.flat_map(arms, fn(arm) { plan_bindings(arm.1) })
  }
}

fn witness(input: j.JsonValue, id: String) -> Result(j.JsonValue, String) {
  use basis <- result.try(field(input, "expected_basis"))
  use exchange <- result.try(field(input, "exchange"))
  use basis <- result.try(
    values.encode_wire(basis) |> result.map_error(string.inspect),
  )
  use exchange <- result.try(
    values.encode_wire(exchange) |> result.map_error(string.inspect),
  )
  case signatures.admit_generation(basis, exchange) {
    Ok(_) -> Ok(obj([#("id", str(id)), #("status", str("Accepted"))]))
    Error(signatures.Witness(_)) ->
      Ok(
        obj([
          #("id", str(id)),
          #("status", str("Rejected")),
          #("rejection", str("Witness")),
        ]),
      )
    Error(error) -> Error(string.inspect(error))
  }
}

fn slot(
  input: j.JsonValue,
  name: String,
  library: signatures.AdmittedLibrary,
) -> Result(types.SlotContract, String) {
  use raw <- result.try(field(input, name))
  use id <- result.try(text_field(raw, "type_id"))
  use required <- result.try(field(raw, "required"))
  use nullable <- result.try(field(raw, "nullable"))
  case required, nullable {
    j.JsonValueBool(required), j.JsonValueBool(nullable) ->
      Ok(types.SlotContract(
        signatures.type_ref(library, id),
        required,
        nullable,
      ))
    _, _ -> Error("slot boolean required")
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
            types.Field(name) | types.Variant(name) -> str(name)
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

fn samples(
  input: j.JsonValue,
  id: String,
  library: signatures.AdmittedLibrary,
) -> Result(j.JsonValue, String) {
  use type_id <- result.try(text_field(input, "type_id"))
  let maximum = case text_field(input, "max_type_obligations") {
    Ok(value) -> result.unwrap(int.parse(value), 64)
    Error(_) -> 64
  }
  let values =
    composition.samples(
      signatures.library_graph(library),
      signatures.type_ref(library, type_id),
      [],
      maximum,
    )
  Ok(
    obj([
      #("id", str(id)),
      #("status", str("Accepted")),
      #("sample_count", j.JsonValueNum(list.length(values))),
      #("sample_bound", j.JsonValueBool(False)),
    ]),
  )
}

fn counterexample(
  graph: types.SemanticGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  candidates: List(j.JsonValue),
) -> Option(#(j.JsonValue, types.ValueFailure)) {
  case candidates {
    [] -> None
    [value, ..rest] ->
      case
        validation.validate_slot(graph, source, types.Present(value)),
        validation.validate_slot(graph, destination, types.Present(value))
      {
        Ok(_), Error(validation.Rejected(failure)) -> Some(#(value, failure))
        _, _ -> counterexample(graph, source, destination, rest)
      }
  }
}

fn inclusion(
  input: j.JsonValue,
  id: String,
  library: signatures.AdmittedLibrary,
) -> Result(j.JsonValue, String) {
  use source <- result.try(slot(input, "source", library))
  use destination <- result.try(slot(input, "destination", library))
  use candidates <- result.try(field(input, "candidates"))
  use candidates <- result.try(case candidates {
    j.JsonValueArr(items) -> Ok(items)
    _ -> Error("candidates array required")
  })
  let graph = signatures.library_graph(library)
  case counterexample(graph, source, destination, candidates) {
    Some(#(value, failure)) -> {
      use details <- result.try(failure_fields(failure))
      Ok(
        obj([
          #("id", str(id)),
          #("classification", str("Incompatible")),
          #("value", obj([#("tag", str("Present")), #("value", value)])),
          ..details
        ]),
      )
    }
    None ->
      case composition.check_assignable(graph, source, destination, 10_000) {
        composition.Compatible(_) ->
          Ok(obj([#("id", str(id)), #("classification", str("Compatible"))]))
        composition.CompatibilityUnknown(_) ->
          Ok(obj([#("id", str(id)), #("classification", str("Unknown"))]))
        composition.Incompatible(certificate) -> {
          use details <- result.try(failure_fields(
            certificate.destination_failure,
          ))
          let value = case certificate.value {
            types.Absent -> obj([#("tag", str("Absent"))])
            types.Null -> obj([#("tag", str("Null"))])
            types.Present(value) ->
              obj([#("tag", str("Present")), #("value", value)])
          }
          Ok(
            obj([
              #("id", str(id)),
              #("classification", str("Incompatible")),
              #("value", value),
              ..details
            ]),
          )
        }
      }
  }
}

fn projection(
  input: j.JsonValue,
  id: String,
  library: signatures.AdmittedLibrary,
) -> Result(j.JsonValue, String) {
  use source <- result.try(slot(input, "source", library))
  use destination <- result.try(slot(input, "destination", library))
  use raw <- result.try(field(input, "path"))
  use path <- result.try(case raw {
    j.JsonValueArr(items) ->
      list.try_map(items, decode.decode_path_step)
      |> result.map_error(string.inspect)
    _ -> Error("path array required")
  })
  use producer <- result.try(field(input, "producer"))
  use raw_candidates <- result.try(field(input, "candidate_slots"))
  use candidates <- result.try(case raw_candidates {
    j.JsonValueArr(items) -> list.try_map(items, slot_value)
    _ -> Error("candidate_slots array required")
  })
  let graph = signatures.library_graph(library)
  let reject = fn(reason) {
    Ok(
      obj([
        #("id", str(id)),
        #("status", str("Rejected")),
        #("rejection", str(reason)),
      ]),
    )
  }
  case validation.project_slot(graph, source, path, []) {
    Error(failure) ->
      reject(case failure {
        validation.WrongShape(_, _) -> "WrongShape"
        validation.MissingField(_, _) -> "MissingField"
        validation.MissingVariant(_, _) -> "MissingVariant"
        validation.BranchAssumptionRequired(_, _) -> "BranchAssumptionRequired"
        validation.ProjectionUnresolved(_) -> "ProjectionUnresolved"
        validation.CertificateMismatch(_) -> "CertificateMismatch"
      })
    Ok(certificate) -> {
      case
        list.any(candidates, fn(value) {
          validation.accepts_slot(graph, certificate.destination, value)
          && !validation.accepts_slot(graph, destination, value)
        })
      {
        True -> reject("Incompatible")
        False ->
          case
            composition.check_assignable(
              graph,
              certificate.destination,
              destination,
              10_000,
            )
          {
            composition.Incompatible(_) -> reject("Incompatible")
            composition.CompatibilityUnknown(_) -> reject("Unknown")
            composition.Compatible(_) ->
              Ok(
                obj([
                  #("id", str(id)),
                  #("status", str("Accepted")),
                  #(
                    "binding",
                    obj([
                      #("producer", producer),
                      #("path", path_strings(path)),
                      #("compatibility", str("Compatible")),
                    ]),
                  ),
                ]),
              )
          }
      }
    }
  }
}

fn codec(
  input: j.JsonValue,
  id: String,
  library: signatures.AdmittedLibrary,
) -> Result(j.JsonValue, String) {
  use type_id <- result.try(text_field(input, "type_id"))
  use raw <- result.try(field(input, "value"))
  use checked <- result.try(admission(library))
  use source <- result.try(
    renderer.render_signatures(checked) |> result.map_error(string.inspect),
  )
  let nodes =
    list.sort(signatures.library_graph(library).nodes, fn(a, b) {
      string.compare(a.reference.definition_name, b.reference.definition_name)
    })
  use node <- result.try(
    list.find(nodes, fn(node) { node.reference.definition_name == type_id })
    |> result.map_error(fn(_) { "codec type missing" }),
  )
  use wire <- result.try(
    values.encode_wire(raw) |> result.map_error(string.inspect),
  )
  case
    compiled_codec(
      source,
      renderer.type_codec_identifier(node.reference),
      checked,
      wire,
    )
  {
    Ok(encoded) -> {
      use encoded <- result.try(
        values.parse_wire(encoded) |> result.map_error(string.inspect),
      )
      Ok(
        obj([
          #("id", str(id)),
          #("status", str("Accepted")),
          #("encoded", encoded),
        ]),
      )
    }
    Error(runtime.Constraint(validation.Rejected(failure))) -> {
      use details <- result.try(failure_fields(failure))
      Ok(obj([#("id", str(id)), #("status", str("Rejected")), ..details]))
    }
    Error(error) -> Error(string.inspect(error))
  }
}

fn slot_value(
  raw: j.JsonValue,
) -> Result(types.SlotValue(j.JsonValue), String) {
  use tag <- result.try(text_field(raw, "tag"))
  case tag {
    "Absent" -> Ok(types.Absent)
    "Null" -> Ok(types.Null)
    "Present" -> field(raw, "value") |> result.map(types.Present)
    _ -> Error("slot tag required")
  }
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

fn library_invariant(
  input: j.JsonValue,
  id: String,
  library: signatures.AdmittedLibrary,
) -> Result(j.JsonValue, String) {
  use changed <- result.try(field(input, "changed_library"))
  use changed <- result.try(
    signatures.decode_library_value(changed) |> result.map_error(string.inspect),
  )
  use _ <- result.try(admission(library))
  use _ <- result.try(admission(changed))
  use before <- result.try(
    signatures.signature_digests(library) |> result.map_error(string.inspect),
  )
  use after <- result.try(
    signatures.signature_digests(changed) |> result.map_error(string.inspect),
  )
  use type_id <- result.try(text_field(input, "type_id"))
  use value <- result.try(field(input, "value"))
  let status = fn(library) {
    case signatures.validate_value(library, type_id, value) {
      Ok(_) -> str("Accepted")
      Error(_) -> str("Rejected")
    }
  }
  Ok(
    obj([
      #("id", str(id)),
      #("graph_equal", j.JsonValueBool(before.0 == after.0)),
      #("provenance_equal", j.JsonValueBool(before.1 == after.1)),
      #("metadata_equal", j.JsonValueBool(before.2 == after.2)),
      #("before", status(library)),
      #("after", status(changed)),
    ]),
  )
}
