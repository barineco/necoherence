// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/decode_support.{
  type D, as_arr, as_str, nat_field, nat_of_str, nat_to_json, obj_val, str_field,
  try,
}
import feature_check/json_value.{type JsonValue, JNull, array, object, string}
import gleam/list
import necoherence/core

pub fn decode_resource_id(value: JsonValue) -> D(core.ResourceId) {
  use kind <- try(str_field(value, "kind"))
  use name <- try(str_field(value, "name"))
  Ok(core.resource(kind, name))
}

pub fn encode_resource_id(r: core.ResourceId) -> JsonValue {
  object([#("kind", string(r.kind)), #("name", string(r.name))])
}

pub fn decode_revision(value: JsonValue) -> D(core.Revision) {
  use s <- try(as_str(value))
  use v <- try(nat_of_str(s))
  Ok(core.revision(v))
}

pub fn encode_revision(r: core.Revision) -> JsonValue {
  nat_to_json(core.revision_value(r))
}

pub fn decode_basis(value: JsonValue) -> D(core.Basis) {
  use resource_json <- try(obj_val(value, "resource"))
  use resource <- try(decode_resource_id(resource_json))
  use revision_json <- try(obj_val(value, "revision"))
  use revision <- try(decode_revision(revision_json))
  Ok(core.Basis(resource, revision))
}

pub fn encode_basis(b: core.Basis) -> JsonValue {
  object([
    #("resource", encode_resource_id(b.resource)),
    #("revision", encode_revision(b.revision)),
  ])
}

pub fn decode_world_entry(
  value: JsonValue,
) -> D(#(core.ResourceId, core.Revision)) {
  use resource_json <- try(obj_val(value, "resource"))
  use resource <- try(decode_resource_id(resource_json))
  use revision_json <- try(obj_val(value, "revision"))
  use revision <- try(decode_revision(revision_json))
  Ok(#(resource, revision))
}

pub fn decode_world(value: JsonValue) -> D(core.World) {
  use items <- try(as_arr(value))
  use entries <- try(decode_support.map_list(items, decode_world_entry))
  Ok(core.world(entries))
}

pub fn encode_world_entry(
  entry: #(core.ResourceId, core.Revision),
) -> JsonValue {
  object([
    #("resource", encode_resource_id(entry.0)),
    #("revision", encode_revision(entry.1)),
  ])
}

pub fn encode_world(w: core.World) -> JsonValue {
  array(list.map(core.world_entries(w), encode_world_entry))
}

pub fn encode_lookup(value: core.Lookup) -> JsonValue {
  case value {
    core.Found(r) ->
      object([#("tag", string("found")), #("revision", encode_revision(r))])
    core.Unknown(u) ->
      object([
        #("tag", string("unknown")),
        #("resource", encode_resource_id(u.resource)),
      ])
  }
}

pub fn decode_command(value: JsonValue) -> D(core.Command(JsonValue)) {
  use intent <- try(obj_val(value, "intent"))
  use basis_json <- try(obj_val(value, "basis"))
  use basis <- try(decode_basis(basis_json))
  Ok(core.Command(intent, basis))
}

pub fn encode_command(c: core.Command(JsonValue)) -> JsonValue {
  object([#("intent", c.intent), #("basis", encode_basis(c.basis))])
}

pub fn encode_apply_outcome(
  value: core.Outcome(
    #(JsonValue, core.World),
    core.UnknownResource,
    core.StaleBasis,
    Nil,
  ),
) -> JsonValue {
  case value {
    core.Applied(#(intent, world)) ->
      object([
        #("tag", string("applied")),
        #("intent", intent),
        #("world", encode_world(world)),
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

pub fn op_core_lookup(input: JsonValue) -> D(JsonValue) {
  use world_json <- try(obj_val(input, "world"))
  use world <- try(decode_world(world_json))
  use resource_json <- try(obj_val(input, "resource"))
  use resource <- try(decode_resource_id(resource_json))
  Ok(encode_lookup(core.lookup(world, resource)))
}

pub fn op_core_bump(input: JsonValue) -> D(JsonValue) {
  use world_json <- try(obj_val(input, "world"))
  use world <- try(decode_world(world_json))
  use resource_json <- try(obj_val(input, "resource"))
  use resource <- try(decode_resource_id(resource_json))
  Ok(encode_world(core.bump(world, resource)))
}

pub fn op_core_command_of(input: JsonValue) -> D(JsonValue) {
  use obs_json <- try(obj_val(input, "observation"))
  use payload <- try(obj_val(obs_json, "payload"))
  use basis_json <- try(obj_val(obs_json, "basis"))
  use basis <- try(decode_basis(basis_json))
  use observed_at <- try(nat_field(obs_json, "observedAt"))
  let observation = core.Observation(payload, basis, observed_at)
  use x <- try(obj_val(input, "payload"))
  Ok(encode_command(core.command_of(observation, x)))
}

pub fn op_core_apply(input: JsonValue) -> D(JsonValue) {
  use world_json <- try(obj_val(input, "world"))
  use world <- try(decode_world(world_json))
  use command_json <- try(obj_val(input, "command"))
  use command <- try(decode_command(command_json))
  Ok(encode_apply_outcome(core.apply(world, command)))
}
