// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/core_ops.{
  decode_command, decode_resource_id, decode_revision, encode_resource_id,
  encode_revision, encode_world,
}
import feature_check/decode_support.{type D, as_arr, obj_val, try}
import feature_check/json_value.{type JsonValue, JNull, array, object, string}
import gleam/list
import necoherence/core
import necoherence/store

pub fn decode_store_entry(
  value: JsonValue,
) -> D(#(core.ResourceId, core.Revision, JsonValue)) {
  use resource_json <- try(obj_val(value, "resource"))
  use resource <- try(decode_resource_id(resource_json))
  use revision_json <- try(obj_val(value, "revision"))
  use revision <- try(decode_revision(revision_json))
  use payload <- try(obj_val(value, "payload"))
  Ok(#(resource, revision, payload))
}

pub fn decode_store(value: JsonValue) -> D(store.Store(JsonValue)) {
  use items <- try(as_arr(value))
  use entries <- try(decode_support.map_list(items, decode_store_entry))
  Ok(store.store_of(entries))
}

fn encode_store_entry(
  entry: #(core.ResourceId, core.Revision, JsonValue),
) -> JsonValue {
  object([
    #("resource", encode_resource_id(entry.0)),
    #("revision", encode_revision(entry.1)),
    #("payload", entry.2),
  ])
}

fn encode_store_entries(
  entries: List(#(core.ResourceId, core.Revision, JsonValue)),
) -> JsonValue {
  array(list.map(entries, encode_store_entry))
}

fn encode_store(s: store.Store(JsonValue)) -> JsonValue {
  encode_store_entries(store.store_entries(s))
}

fn encode_observe(value: store.Observe(JsonValue)) -> JsonValue {
  case value {
    store.ObserveFound(r, a) ->
      object([
        #("tag", string("found")),
        #("revision", encode_revision(r)),
        #("payload", a),
      ])
    store.ObserveUnknown(u) ->
      object([
        #("tag", string("unknown")),
        #("resource", encode_resource_id(u.resource)),
      ])
  }
}

fn encode_store_apply_outcome(
  value: core.Outcome(
    #(JsonValue, store.Store(JsonValue)),
    core.UnknownResource,
    core.StaleBasis,
    Nil,
  ),
) -> JsonValue {
  case value {
    core.Applied(#(intent, s)) ->
      object([
        #("tag", string("applied")),
        #("intent", intent),
        #("store", encode_store(s)),
      ])
    core.Rejected(u) ->
      object([
        #("tag", string("rejected")),
        #("resource", encode_resource_id(u.resource)),
      ])
    core.Conflicted(k) ->
      object([
        #("tag", string("conflicted")),
        #("expected", encode_revision(k.expected)),
        #("actual", encode_revision(k.actual)),
      ])
    core.BoundaryFailed(_) -> JNull
  }
}

pub fn op_store_store_of(input: JsonValue) -> D(JsonValue) {
  use s <- try(decode_store(input))
  Ok(encode_store(s))
}

pub fn op_store_store_entries(input: JsonValue) -> D(JsonValue) {
  use store_json <- try(obj_val(input, "store"))
  use s <- try(decode_store(store_json))
  Ok(encode_store_entries(store.store_entries(s)))
}

pub fn op_store_observe(input: JsonValue) -> D(JsonValue) {
  use store_json <- try(obj_val(input, "store"))
  use s <- try(decode_store(store_json))
  use resource_json <- try(obj_val(input, "resource"))
  use resource <- try(decode_resource_id(resource_json))
  Ok(encode_observe(store.observe(s, resource)))
}

pub fn op_store_apply(input: JsonValue) -> D(JsonValue) {
  use store_json <- try(obj_val(input, "store"))
  use s <- try(decode_store(store_json))
  use command_json <- try(obj_val(input, "command"))
  use command <- try(decode_command(command_json))
  Ok(encode_store_apply_outcome(store.apply(s, command)))
}

pub fn op_store_world_of(input: JsonValue) -> D(JsonValue) {
  use s <- try(decode_store(input))
  Ok(encode_world(store.world_of(s)))
}
