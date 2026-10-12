// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/core_ops.{
  decode_basis, decode_resource_id, decode_revision, decode_world,
  encode_resource_id, encode_revision,
}
import feature_check/decode_support.{
  type D, arr_field, fail_shape, is_null, nat_field, nat_to_json, obj_val,
  str_field, try,
}
import feature_check/json_value.{type JsonValue, bool, object, string}
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import necoherence/core
import necoherence/reconcile

fn resource_id_compare(a: core.ResourceId, b: core.ResourceId) -> order.Order {
  case string.compare(a.kind, b.kind) {
    order.Eq -> string.compare(a.name, b.name)
    other -> other
  }
}

fn divergence_resource(value: reconcile.Divergence) -> core.ResourceId {
  case value {
    reconcile.WorldAhead(r, _, _) -> r
    reconcile.WorldBehind(r, _, _) -> r
    reconcile.UnknownToWorld(r, _) -> r
  }
}

fn encode_divergence(value: reconcile.Divergence) -> JsonValue {
  case value {
    reconcile.WorldAhead(r, recorded, actual) ->
      object([
        #("tag", string("world_ahead")),
        #("resource", encode_resource_id(r)),
        #("recorded", encode_revision(recorded)),
        #("actual", encode_revision(actual)),
      ])
    reconcile.WorldBehind(r, recorded, actual) ->
      object([
        #("tag", string("world_behind")),
        #("resource", encode_resource_id(r)),
        #("recorded", encode_revision(recorded)),
        #("actual", encode_revision(actual)),
      ])
    reconcile.UnknownToWorld(r, recorded) ->
      object([
        #("tag", string("unknown_to_world")),
        #("resource", encode_resource_id(r)),
        #("recorded", encode_revision(recorded)),
      ])
  }
}

fn encode_reconciliation(r: reconcile.Reconciliation) -> JsonValue {
  let sorted =
    list.sort(r.divergences, fn(a, b) {
      resource_id_compare(divergence_resource(a), divergence_resource(b))
    })
  object([
    #("divergences", json_value.array(list.map(sorted, encode_divergence))),
    #("unbased", nat_to_json(r.unbased)),
    #("dropped", nat_to_json(r.dropped)),
  ])
}

fn decode_option_basis(value: JsonValue) -> D(option.Option(core.Basis)) {
  case is_null(value) {
    True -> Ok(None)
    False -> {
      use b <- try(decode_basis(value))
      Ok(Some(b))
    }
  }
}

pub fn op_reconcile_reconcile(input: JsonValue) -> D(JsonValue) {
  use bases_arr <- try(arr_field(input, "bases"))
  use bases <- try(decode_support.map_list(bases_arr, decode_option_basis))
  use world_json <- try(obj_val(input, "world"))
  use world <- try(decode_world(world_json))
  use dropped <- try(nat_field(input, "dropped"))
  Ok(encode_reconciliation(reconcile.reconcile(bases, world, dropped)))
}

fn decode_divergence(value: JsonValue) -> D(reconcile.Divergence) {
  use tag <- try(str_field(value, "tag"))
  case tag {
    "world_ahead" -> {
      use resource_json <- try(obj_val(value, "resource"))
      use resource <- try(decode_resource_id(resource_json))
      use recorded_json <- try(obj_val(value, "recorded"))
      use recorded <- try(decode_revision(recorded_json))
      use actual_json <- try(obj_val(value, "actual"))
      use actual <- try(decode_revision(actual_json))
      Ok(reconcile.WorldAhead(resource, recorded, actual))
    }
    "world_behind" -> {
      use resource_json <- try(obj_val(value, "resource"))
      use resource <- try(decode_resource_id(resource_json))
      use recorded_json <- try(obj_val(value, "recorded"))
      use recorded <- try(decode_revision(recorded_json))
      use actual_json <- try(obj_val(value, "actual"))
      use actual <- try(decode_revision(actual_json))
      Ok(reconcile.WorldBehind(resource, recorded, actual))
    }
    "unknown_to_world" -> {
      use resource_json <- try(obj_val(value, "resource"))
      use resource <- try(decode_resource_id(resource_json))
      use recorded_json <- try(obj_val(value, "recorded"))
      use recorded <- try(decode_revision(recorded_json))
      Ok(reconcile.UnknownToWorld(resource, recorded))
    }
    other -> Error(fail_shape("unknown divergence tag " <> other))
  }
}

pub fn op_reconcile_coherent(input: JsonValue) -> D(JsonValue) {
  use divergences_arr <- try(arr_field(input, "divergences"))
  use divergences <- try(decode_support.map_list(
    divergences_arr,
    decode_divergence,
  ))
  use unbased <- try(nat_field(input, "unbased"))
  use dropped <- try(nat_field(input, "dropped"))
  let r = reconcile.Reconciliation(divergences, unbased, dropped)
  Ok(object([#("coherent", bool(reconcile.coherent(r)))]))
}
