// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/dict
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import neco_quotient_certificate/digest as quotient_digest
import neco_quotient_certificate/failure as quotient
import necoherence/admission_failure as admission
import necoherence/composition_plan
import necoherence/exact_json as json
import necoherence/resource_witness
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types

@external(erlang, "signature_admission_entry_ffi", "read_stdin")
fn read_stdin() -> String

@external(erlang, "signature_admission_entry_ffi", "batch_requested")
fn batch_requested() -> Bool

@external(erlang, "signature_admission_entry_ffi", "guarded")
fn guarded(run: fn() -> String) -> Result(String, String)

pub fn main() {
  case batch_requested() {
    True -> list.each(run_batch(read_stdin()), io.println)
    False -> io.println(run(read_stdin()))
  }
}

pub fn run_batch(input: String) -> List(String) {
  list.map(request_lines(input), run_guarded)
}

fn request_lines(input: String) -> List(String) {
  let lines = string.split(input, "\n")
  case list.reverse(lines) {
    ["", ..rest] -> list.reverse(rest)
    _ -> lines
  }
}

fn run_guarded(line: String) -> String {
  case guarded(fn() { run(line) }) {
    Ok(output) -> output
    Error(message) -> encode(obj([#("error", str(message))]))
  }
}

pub fn run(input: String) -> String {
  case values.parse_wire(input) {
    Error(_) -> failed_with("request", "request_json")
    Ok(request) ->
      case field(request, "exchange") {
        Ok(json.JsonValueStr(exchange)) ->
          case field(request, "expected_basis") {
            Error(_) -> failed_with("request", "request_expected_basis")
            Ok(expected_json) ->
              case signatures.expected_basis_text(expected_json) {
                Error(failure) ->
                  failed_with("request", "expected_basis." <> wire_tag(failure))
                Ok(expected) -> mode_output(request, exchange, expected)
              }
          }
        _ -> failed_with("request", "request_exchange")
      }
  }
}

fn failed_with(kind: String, reason: String) -> String {
  encode(
    obj([
      #("result", str("failed")),
      #("failure", obj([#("kind", str(kind)), #("reason", str(reason))])),
    ]),
  )
}

fn wire_tag(failure: signatures.Failure) -> String {
  case failure {
    signatures.Wire(value) -> wire_reason(value)
    _ -> "syntax"
  }
}

fn exchange_reason(failure: signatures.Failure) -> String {
  case failure {
    signatures.Json(_) -> "exchange_json"
    _ -> "exchange." <> wire_tag(failure)
  }
}

fn admit(exchange: String, expected: String) -> String {
  case signatures.admit_generation(expected, exchange) {
    Ok(checked) ->
      case accepted(checked, exchange) {
        Ok(output) -> output
        Error(reason) -> failed_with("decode", reason)
      }
    Error(failure) -> encode(failed(failure))
  }
}

fn mode_output(
  request: json.JsonValue,
  exchange: String,
  expected: String,
) -> String {
  case field(request, "mode") {
    Error(_) -> admit(exchange, expected)
    Ok(json.JsonValueStr("admission")) -> admit(exchange, expected)
    Ok(_) -> failed_with("request", "request_mode")
  }
}

fn accepted(
  checked: signatures.CheckedGeneration,
  exchange: String,
) -> Result(String, String) {
  use basis <- result.try(
    signatures.encode_basis(checked)
    |> result.replace_error("basis")
    |> result.try(fn(text) {
      values.parse_wire(text) |> result.replace_error("basis")
    }),
  )
  use exchange_value <- result.try(
    values.parse_wire(exchange) |> result.replace_error("exchange"),
  )
  use library <- result.try(field(exchange_value, "signatures"))
  use identity <- result.try(text_field(library, "identity"))
  use revision <- result.try(text_field(library, "revision"))
  use entries <- result.try(entrypoint_entries(exchange_value))
  use composition <- result.try(case field(exchange_value, "composition") {
    Ok(json.JsonValueNull) -> Ok(json.JsonValueNull)
    Ok(_) ->
      field(basis, "problem_sha256")
      |> result.replace_error("problem_sha256")
      |> result.map(fn(digest) { obj([#("problem_sha256", digest)]) })
    Error(_) -> Error("composition")
  })
  encode(
    obj([
      #("result", str("accepted")),
      #(
        "checked",
        obj([
          #("basis", basis),
          #(
            "library",
            obj([#("identity", str(identity)), #("revision", str(revision))]),
          ),
          #("entrypoints", json.JsonValueArr(entries)),
          #("composition", composition),
        ]),
      ),
    ]),
  )
  |> Ok
}

fn entrypoint_entries(
  exchange: json.JsonValue,
) -> Result(List(json.JsonValue), String) {
  use items <- result.try(case field(exchange, "entrypoints") {
    Ok(json.JsonValueArr(items)) -> Ok(items)
    _ -> Error("entrypoints")
  })
  use entries <- result.try(
    list.try_map(items, fn(item) {
      use identity <- result.try(text_field(item, "identity"))
      use definition <- result.try(text_field(item, "definition"))
      Ok(#(identity, definition))
    }),
  )
  entries
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.map(fn(entry) {
    obj([#("identity", str(entry.0)), #("definition", str(entry.1))])
  })
  |> Ok
}

fn failed(failure: signatures.AdmissionFailure) -> json.JsonValue {
  obj([
    #("result", str("failed")),
    #("failure", failure_value(failure)),
  ])
}

fn failure_value(failure: signatures.AdmissionFailure) -> json.JsonValue {
  case failure {
    admission.UnsupportedSchema(schema) ->
      obj([#("kind", str("schema")), #("actual", str(schema))])
    admission.EntrypointsEmpty -> obj([#("kind", str("entrypoints_empty"))])
    admission.EntrypointIdentityEmpty ->
      obj([#("kind", str("entrypoint_identity_empty"))])
    admission.EntrypointDuplicate(identity) ->
      obj([#("kind", str("entrypoint_duplicate")), #("identity", str(identity))])
    admission.EntrypointUnresolved(identity, definition) ->
      obj([
        #("kind", str("entrypoint_unresolved")),
        #("identity", str(identity)),
        #("definition", str(definition)),
      ])
    admission.Library(library) ->
      obj([
        #("kind", str("declaration")),
        #("reason", str(library_reason(library))),
      ])
    admission.Certificate(mismatch) -> certificate_value(mismatch)
    admission.Wire(value) ->
      obj([
        #("kind", str("composition")),
        #("reason", str(wire_reason(value))),
      ])
    admission.CompositionInput(value) ->
      obj([
        #("kind", str("composition")),
        #("reason", str(composition_input_reason(value))),
      ])
    admission.Composition(value) ->
      obj([
        #("kind", str("composition")),
        #("reason", str(witness_reason(value))),
      ])
    admission.Generation(value) ->
      obj([#("kind", str("decode")), #("reason", str(exchange_reason(value)))])
  }
}

fn wire_reason(failure: decode.DecodeFailure) -> String {
  case failure {
    decode.UnknownField(_, _) -> "unknownField"
    decode.UnknownTag(_, _) -> "unknownTag"
    decode.SyntaxFailure(_, _) | decode.ProfileFailure(_) -> "syntax"
    decode.CompositionFailure(value) -> witness_reason(value)
  }
}

fn composition_input_reason(
  failure: composition_plan.CompositionInputFailure,
) -> String {
  case failure {
    composition_plan.InputBasisMismatch -> "basisMismatch"
    composition_plan.DuplicateIdentity(_, _) -> "duplicateIdentity"
    composition_plan.UnresolvedType(_) -> "unresolvedType"
    composition_plan.UnresolvedFunction(_) -> "unresolvedFunction"
    composition_plan.InvalidSignature(_, _) -> "invalidSignature"
    composition_plan.InvalidInitialValue(_, _) -> "invalidInitialValue"
    composition_plan.SiteEffectNotPermitted(_, _) -> "siteEffectNotPermitted"
    composition_plan.TransformNotPermitted(_) -> "transformNotPermitted"
    composition_plan.EmptyGoal -> "emptyGoal"
    composition_plan.GoalSourceConstraintUndefined(_, _) ->
      "goalSourceConstraintUndefined"
    composition_plan.FailureEmbeddingOriginUndefined(_, _) ->
      "failureEmbeddingOriginUndefined"
    composition_plan.ConstructionNotProduct(_, _) -> "constructionNotProduct"
    composition_plan.FieldConstraintUnknownField(_, _) ->
      "fieldConstraintUnknownField"
    composition_plan.ConstrainedNestedField(_, _) -> "constrainedNestedField"
    composition_plan.ConstructionFieldSourceUndefined(_, _) ->
      "constructionFieldSourceUndefined"
    composition_plan.NestedFieldUndeclared(_, _) -> "nestedFieldUndeclared"
    composition_plan.NestedConstructionMismatch(_, _, _, _) ->
      "nestedConstructionMismatch"
    composition_plan.CyclicConstruction(_) -> "cyclicConstruction"
    composition_plan.ExplicitSiteOrderInvalid(_, _) ->
      "explicitSiteOrderInvalid"
    composition_plan.InvalidEmptyTypeClosure(_) -> "invalidEmptyTypeClosure"
    composition_plan.InvalidResourceDeclaration(_) ->
      "invalidResourceDeclaration"
    composition_plan.InvalidLibrary(_) -> "invalidLibrary"
  }
}

fn witness_reason(failure: resource_witness.WitnessFailure) -> String {
  case failure {
    resource_witness.InputRevisionMismatch -> "inputRevisionMismatch"
    resource_witness.InitialMembership(_) -> "initialMembership"
    resource_witness.ProducerMismatch(_) -> "producerMismatch"
    resource_witness.ProjectionMismatch(_) -> "projectionMismatch"
    resource_witness.SourceConstraintMismatch(_) -> "sourceConstraintMismatch"
    resource_witness.InclusionMismatch(_) -> "inclusion"
    resource_witness.SuppliedValueMismatch(_) -> "suppliedValueMismatch"
    resource_witness.ConstructionMismatch(_) -> "constructionMismatch"
    resource_witness.MissingBinding(_) -> "missingBinding"
    resource_witness.SignatureMismatch(_) -> "signatureMismatch"
    resource_witness.GuardNotDominating(_) -> "guardNotDominating"
    resource_witness.IncompleteBranchCoverage(_) -> "incompleteBranchCoverage"
    resource_witness.FailureEmbeddingMismatch(_) -> "failureEmbeddingMismatch"
    resource_witness.GoalMismatch -> "goalMismatch"
    resource_witness.RankViolation -> "rankViolation"
    resource_witness.ResourceLoweringMismatch(_) -> "resourceLoweringMismatch"
    resource_witness.ResourceReplayMismatch(_) -> "resourceReplayMismatch"
    resource_witness.ForgedClosure(_) -> "forgedClosure"
    resource_witness.ForgedAcyclicity(_) -> "forgedAcyclicity"
    resource_witness.MissingEvidence(_) -> "missingEvidence"
  }
}

fn library_reason(failure: types.LibraryCheckFailure) -> String {
  case failure {
    types.ProfileCheck(profile) -> profile_predicate_code(profile.predicate)
    types.LibraryCheck(library) -> library_predicate_code(library.predicate)
  }
}

fn certificate_value(mismatch: quotient.Mismatch(String)) -> json.JsonValue {
  let checks = quotient.mismatch_checks(mismatch)
  let origin = quotient.mismatch_origin(mismatch)
  obj([
    #("kind", str("certificate")),
    #(
      "conditions",
      obj(
        list.map(quotient.all_conditions, fn(condition) {
          #(
            quotient.condition_name(condition),
            str(status_text(quotient.mismatch_status_at(mismatch, condition))),
          )
        }),
      ),
    ),
    #("failures", json.JsonValueArr(condition_failures(checks))),
    #("digests", digests_value(checks.decode)),
    #(
      "origin",
      obj([
        #("rule_revision", str(origin.rule_revision)),
        #("source_identity", str(origin.source_identity)),
        #("source_revision", str(origin.source_revision)),
      ]),
    ),
    #("provenance", str(quotient.mismatch_provenance(mismatch))),
  ])
}

fn digests_value(
  decode: quotient.Prerequisite(failure, quotient_digest.DigestChecks),
) -> json.JsonValue {
  case decode {
    quotient.Failed(_) -> json.JsonValueNull
    quotient.Established(checks) ->
      obj(
        checks
        |> dict.to_list
        |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
        |> list.map(fn(entry) { #(entry.0, str(projection_text(entry.1))) }),
      )
  }
}

fn projection_text(result: quotient_digest.ProjectionResult) -> String {
  case result {
    quotient_digest.Matched(_) -> "matched"
    quotient_digest.CertificateOnly(_) -> "certificateOnly"
    quotient_digest.RecomputedOnly(_) -> "recomputedOnly"
    quotient_digest.Different(_, _) -> "different"
  }
}

fn condition_failures(
  checks: quotient.AdmissionChecks(String),
) -> List(json.JsonValue) {
  let decode = case checks.decode {
    quotient.Failed(failure) -> [condition_entry(failure)]
    quotient.Established(_) -> []
  }
  let source = case checks.source {
    quotient.Failed(failure) -> [condition_entry(failure)]
    quotient.Established(source) ->
      list.flatten([
        result_entries(source.coordinate),
        result_entries(source.observations),
        result_entries(source.residual),
      ])
  }
  list.flatten([decode, source])
}

fn result_entries(
  result: quotient.CheckResult(quotient.ConditionFailure(stage, String)),
) -> List(json.JsonValue) {
  case result {
    quotient.CheckMatched -> []
    quotient.CheckMismatched(failure) -> [condition_entry(failure)]
  }
}

fn condition_entry(
  failure: quotient.ConditionFailure(stage, String),
) -> json.JsonValue {
  obj([
    #("condition", str(quotient.condition_name(failure.condition))),
    #("operation", str(failure.operation)),
  ])
}

fn status_text(status: quotient.Status(p)) -> String {
  case status {
    quotient.Matched -> "Matched"
    quotient.Mismatched -> "Mismatched"
    quotient.UncheckedByDecode(_) -> "UncheckedByDecode"
    quotient.UncheckedBySource(_) -> "UncheckedBySource"
  }
}

fn field(
  value: json.JsonValue,
  name: String,
) -> Result(json.JsonValue, String) {
  case value {
    json.JsonValueObj(members) ->
      list.key_find(members, name) |> result.replace_error(name)
    _ -> Error(name)
  }
}

fn text_field(value: json.JsonValue, name: String) -> Result(String, String) {
  case field(value, name) {
    Ok(json.JsonValueStr(text)) -> Ok(text)
    _ -> Error(name)
  }
}

fn obj(members: List(#(String, json.JsonValue))) -> json.JsonValue {
  json.JsonValueObj(
    list.sort(members, fn(left, right) { string.compare(left.0, right.0) }),
  )
}

fn str(text: String) -> json.JsonValue {
  json.JsonValueStr(text)
}

fn encode(value: json.JsonValue) -> String {
  case values.encode_wire(value) {
    Ok(text) -> text
    Error(_) -> "{\"result\":\"failed\",\"failure\":{\"kind\":\"encoding\"}}"
  }
}

fn profile_predicate_code(predicate: types.ProfilePredicate) -> String {
  case predicate {
    types.Pr01 -> "pr01"
    types.Pr02 -> "pr02"
    types.Pr03 -> "pr03"
    types.Pr04 -> "pr04"
    types.Pr05 -> "pr05"
    types.Pr06 -> "pr06"
    types.Pr07 -> "pr07"
    types.Pr08 -> "pr08"
    types.Pr09 -> "pr09"
    types.Pr10 -> "pr10"
    types.Pr11 -> "pr11"
    types.Pr12 -> "pr12"
    types.Pr13 -> "pr13"
    types.Pr14 -> "pr14"
    types.Pr15 -> "pr15"
    types.Pr16 -> "pr16"
  }
}

fn library_predicate_code(predicate: types.LibraryPredicate) -> String {
  case predicate {
    types.Lb01 -> "lb01"
    types.Lb02 -> "lb02"
    types.Lb03 -> "lb03"
    types.Lb04 -> "lb04"
    types.Lb05 -> "lb05"
    types.Lb06 -> "lb06"
    types.Lb07 -> "lb07"
    types.Lb08 -> "lb08"
    types.Lb09 -> "lb09"
    types.Lb10 -> "lb10"
    types.Lb11 -> "lb11"
    types.Lb12 -> "lb12"
    types.Lb13 -> "lb13"
    types.Lb14 -> "lb14"
    types.Lb15 -> "lb15"
    types.Lb16 -> "lb16"
    types.Lb17 -> "lb17"
    types.Lb18 -> "lb18"
    types.Lb19 -> "lb19"
  }
}
