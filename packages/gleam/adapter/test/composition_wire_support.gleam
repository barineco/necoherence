// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{type Option, None, Some}
import necoherence/exact_json as json
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import simplifile

pub type Step {
  Key(String)
  Index(Int)
}

pub fn exchange_of(name: String) -> json.JsonValue {
  let assert Ok(text) =
    simplifile.read(
      "../../../verification/declaration/signature_admission/examples/"
      <> name
      <> ".request.json",
    )
  let assert Ok(request) = values.parse_wire(text)
  let assert json.JsonValueObj(members) = request
  let assert Ok(json.JsonValueStr(exchange)) =
    list.key_find(members, "exchange")
  let assert Ok(exchange) = values.parse_wire(exchange)
  exchange
}

pub fn member(value: json.JsonValue, key: String) -> json.JsonValue {
  let assert json.JsonValueObj(members) = value
  let assert Ok(found) = list.key_find(members, key)
  found
}

pub fn path_with_key(value: json.JsonValue, key: String) -> Option(List(Step)) {
  case value {
    json.JsonValueObj(members) ->
      case list.key_find(members, key) {
        Ok(_) -> Some([])
        Error(_) ->
          list.find_map(members, fn(entry) {
            case path_with_key(entry.1, key) {
              Some(path) -> Ok([Key(entry.0), ..path])
              None -> Error(Nil)
            }
          })
          |> option.from_result
      }
    json.JsonValueArr(items) ->
      list.index_map(items, fn(item, index) { #(item, index) })
      |> list.find_map(fn(entry) {
        case path_with_key(entry.0, key) {
          Some(path) -> Ok([Index(entry.1), ..path])
          None -> Error(Nil)
        }
      })
      |> option.from_result
    _ -> None
  }
}

pub fn update(
  value: json.JsonValue,
  path: List(Step),
  change: fn(json.JsonValue) -> json.JsonValue,
) -> json.JsonValue {
  case path, value {
    [], _ -> change(value)
    [Key(name), ..rest], json.JsonValueObj(members) ->
      json.JsonValueObj(
        list.map(members, fn(entry) {
          case entry.0 == name {
            True -> #(name, update(entry.1, rest, change))
            False -> entry
          }
        }),
      )
    [Index(position), ..rest], json.JsonValueArr(items) ->
      json.JsonValueArr(
        list.index_map(items, fn(item, index) {
          case index == position {
            True -> update(item, rest, change)
            False -> item
          }
        }),
      )
    _, _ -> panic as "path does not match the value"
  }
}

pub fn with_member(
  value: json.JsonValue,
  name: String,
  member: json.JsonValue,
) -> json.JsonValue {
  let assert json.JsonValueObj(members) = value
  json.JsonValueObj(list.append(members, [#(name, member)]))
}

pub fn with_extra_key(value: json.JsonValue) -> json.JsonValue {
  with_member(value, "extra", json.JsonValueNum(1))
}

pub fn without_member(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert json.JsonValueObj(members) = value
  json.JsonValueObj(list.filter(members, fn(entry) { entry.0 != name }))
}

pub fn admit_composition(
  exchange: json.JsonValue,
  composition: json.JsonValue,
) -> Result(signatures.CheckedGeneration, signatures.AdmissionFailure) {
  let assert Ok(library) = signatures.canonical(member(exchange, "signatures"))
  let assert Ok(#(expected, text)) =
    signatures.assemble_generation(
      library,
      composition,
      member(exchange, "entrypoints"),
    )
  signatures.admit_generation(expected, text)
}
