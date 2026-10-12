// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/core_ops.{decode_basis, encode_basis}
import feature_check/decode_support.{type D, is_null, obj_val, str_field, try}
import feature_check/json_value.{type JsonValue, JNull, bool, object, string}
import necoherence/record

pub fn decode_call_record(
  value: JsonValue,
) -> D(record.CallRecord(JsonValue, JsonValue)) {
  use declaration <- try(str_field(value, "declaration"))
  use input <- try(obj_val(value, "input"))
  use product <- try(obj_val(value, "product"))
  use basis_json <- try(obj_val(value, "basis"))
  use basis <- try(case is_null(basis_json) {
    True -> Ok(record.NoBasis)
    False -> {
      use b <- try(decode_basis(basis_json))
      Ok(record.WithBasis(b))
    }
  })
  Ok(record.CallRecord(declaration, input, product, basis))
}

fn encode_basis_presence(presence: record.BasisPresence) -> JsonValue {
  case presence {
    record.NoBasis -> JNull
    record.WithBasis(b) -> encode_basis(b)
  }
}

fn encode_call_record(r: record.CallRecord(JsonValue, JsonValue)) -> JsonValue {
  object([
    #("declaration", string(r.declaration)),
    #("input", r.input),
    #("product", r.product),
    #("basis", encode_basis_presence(r.basis)),
  ])
}

pub fn op_record_record_of(input: JsonValue) -> D(JsonValue) {
  use declaration <- try(str_field(input, "declaration"))
  use ins <- try(obj_val(input, "input"))
  use product <- try(obj_val(input, "product"))
  Ok(encode_call_record(record.record_of(declaration, ins, product)))
}

pub fn op_record_record_on_basis(input: JsonValue) -> D(JsonValue) {
  use declaration <- try(str_field(input, "declaration"))
  use ins <- try(obj_val(input, "input"))
  use product <- try(obj_val(input, "product"))
  use basis_json <- try(obj_val(input, "basis"))
  use basis <- try(decode_basis(basis_json))
  Ok(
    encode_call_record(record.record_on_basis(declaration, ins, product, basis)),
  )
}

pub fn op_record_has_edge(input: JsonValue) -> D(JsonValue) {
  use earlier_json <- try(obj_val(input, "earlier"))
  use earlier <- try(decode_call_record(earlier_json))
  use later_json <- try(obj_val(input, "later"))
  use later <- try(decode_call_record(later_json))
  Ok(object([#("holds", bool(record.has_edge(earlier, later)))]))
}
