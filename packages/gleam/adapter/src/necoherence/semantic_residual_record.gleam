// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/result
import neco_quotient_encoding/canonical
import neco_quotient_encoding/failure as quotient_failure
import neco_quotient_encoding/json as quotient_json
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types

pub const semantic_residual_schema = "necoherence.semantic-residual.v1"

pub type ResidualFailure {
  Encoding(failure: quotient_failure.EncodingFailure)
  Wire(failure: signatures.Failure)
}

fn to_quotient(value: json.JsonValue) -> quotient_json.JsonValue {
  case value {
    json.JsonValueNull -> quotient_json.JsonNull
    json.JsonValueBool(flag) -> quotient_json.JsonBool(flag)
    json.JsonValueNum(number) -> quotient_json.JsonNumber(int.to_string(number))
    json.JsonValueDec(text) -> quotient_json.JsonNumber(text)
    json.JsonValueStr(text) -> quotient_json.JsonString(text)
    json.JsonValueArr(items) ->
      quotient_json.JsonArray(list.map(items, to_quotient))
    json.JsonValueObj(members) ->
      quotient_json.JsonObject(
        list.map(members, fn(member) { #(member.0, to_quotient(member.1)) }),
      )
  }
}

pub fn encode_semantic_residual(
  basis: signatures.GenerationRequirement,
  type_ref: types.TypeRef,
  value: types.JsonValue,
  obligations: List(types.SemanticObligation),
) -> Result(BitArray, ResidualFailure) {
  let basis_wire = to_quotient(signatures.encode_requirement_wire(basis))
  use type_ref_wire <- result.try(
    decode.encode_type_ref(type_ref)
    |> result.map_error(fn(failure) { Wire(signatures.Wire(failure)) }),
  )
  use value_wire <- result.try(
    values.encode_exact(value)
    |> result.map_error(fn(failure) { Wire(signatures.Json(failure)) }),
  )
  use obligation_wires <- result.try(
    list.try_map(obligations, decode.encode_semantic_obligation)
    |> result.map_error(fn(failure) { Wire(signatures.Wire(failure)) }),
  )
  use residuals <- result.try(
    canonical.normalize_residuals(list.map(obligation_wires, to_quotient))
    |> result.map_error(Encoding),
  )
  canonical.canonical_bytes(
    quotient_json.JsonObject([
      #("schema", quotient_json.JsonString(semantic_residual_schema)),
      #("basis", basis_wire),
      #(
        "input",
        quotient_json.JsonObject([
          #("type_ref", to_quotient(type_ref_wire)),
          #("value", to_quotient(value_wire)),
        ]),
      ),
      #("residuals", quotient_json.JsonArray(residuals)),
    ]),
  )
  |> result.map_error(Encoding)
}
