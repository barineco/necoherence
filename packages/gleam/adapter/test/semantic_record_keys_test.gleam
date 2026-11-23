// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import composition_wire_support.{
  type Step, Key, admit_composition, exchange_of, member, path_with_key, update,
  with_extra_key,
}
import gleam/list
import gleam/option.{Some}
import necoherence/admission_failure as admission
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode

fn inclusion_certificate_path(composition: json.JsonValue) -> List(Step) {
  let assert Some(path) = path_with_key(composition, "pairs")
  path
}

pub fn inclusion_basis_extra_key_is_an_unknown_field_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let path =
    list.append(inclusion_certificate_path(composition), [Key("basis")])
  let assert Error(admission.Wire(decode.UnknownField(_, "extra"))) =
    admit_composition(exchange, update(composition, path, with_extra_key))
}

pub fn inclusion_basis_profile_extra_key_is_an_unknown_field_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let path =
    list.append(inclusion_certificate_path(composition), [
      Key("basis"),
      Key("profile"),
    ])
  let assert Error(admission.Wire(decode.UnknownField(_, "extra"))) =
    admit_composition(exchange, update(composition, path, with_extra_key))
}
