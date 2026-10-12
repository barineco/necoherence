// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/core_ops.{
  decode_basis, decode_world, encode_basis, encode_resource_id, encode_revision,
  encode_world,
}
import feature_check/decode_support.{
  type D, arr_field, as_arr, as_str, fail_shape, nat_field, nat_of_str,
  nat_to_json, obj_val, try,
}
import feature_check/json_value.{type JsonValue, array, bool, object, string}
import gleam/list
import necoherence/core
import necoherence/file_effect as files

fn decode_normalized_path(value: JsonValue) -> D(files.NormalizedPath) {
  use root_json <- try(obj_val(value, "root"))
  use root <- try(decode_support.as_bool(root_json))
  use segments_arr <- try(arr_field(value, "segments"))
  use segments <- try(decode_support.map_list(segments_arr, as_str))
  Ok(files.NormalizedPath(root, segments))
}

fn encode_normalized_path(p: files.NormalizedPath) -> JsonValue {
  object([
    #("root", bool(p.root)),
    #("segments", array(list.map(p.segments, string))),
  ])
}

fn decode_content_digest(value: JsonValue) -> D(files.ContentDigest) {
  use s <- try(as_str(value))
  Ok(files.ContentDigest(s))
}

fn encode_content_digest(d: files.ContentDigest) -> JsonValue {
  string(d.value)
}

fn decode_byte(value: JsonValue) -> D(Int) {
  use s <- try(as_str(value))
  use n <- try(nat_of_str(s))
  case n < 256 {
    True -> Ok(n)
    False -> Error(fail_shape("byte out of range"))
  }
}

fn encode_byte(b: Int) -> JsonValue {
  nat_to_json(b)
}

fn decode_bytes(value: JsonValue) -> D(List(Int)) {
  use arr <- try(as_arr(value))
  decode_support.map_list(arr, decode_byte)
}

fn encode_bytes(bs: List(Int)) -> JsonValue {
  array(list.map(bs, encode_byte))
}

fn decode_file_record(value: JsonValue) -> D(files.FileRecord) {
  use digest_json <- try(obj_val(value, "digest"))
  use digest <- try(decode_content_digest(digest_json))
  use bytes_json <- try(obj_val(value, "bytes"))
  use bytes <- try(decode_bytes(bytes_json))
  Ok(files.FileRecord(digest, bytes))
}

fn encode_file_record(r: files.FileRecord) -> JsonValue {
  object([
    #("digest", encode_content_digest(r.digest)),
    #("bytes", encode_bytes(r.bytes)),
  ])
}

fn decode_external_file_state(value: JsonValue) -> D(files.ExternalFileState) {
  use files_arr <- try(arr_field(value, "files"))
  use file_entries <- try(
    decode_support.map_list(files_arr, fn(e) {
      use path_json <- try(obj_val(e, "path"))
      use path <- try(decode_normalized_path(path_json))
      use record_json <- try(obj_val(e, "record"))
      use record <- try(decode_file_record(record_json))
      Ok(#(path, record))
    }),
  )
  use read_failures_arr <- try(arr_field(value, "readFailures"))
  use read_failures <- try(decode_support.map_list(
    read_failures_arr,
    decode_normalized_path,
  ))
  use write_failures_arr <- try(arr_field(value, "writeFailures"))
  use write_failures <- try(decode_support.map_list(
    write_failures_arr,
    decode_normalized_path,
  ))
  Ok(files.ExternalFileState(file_entries, read_failures, write_failures))
}

fn encode_external_file_state(s: files.ExternalFileState) -> JsonValue {
  object([
    #(
      "files",
      array(
        list.map(s.files, fn(e) {
          object([
            #("path", encode_normalized_path(e.0)),
            #("record", encode_file_record(e.1)),
          ])
        }),
      ),
    ),
    #("readFailures", array(list.map(s.read_failures, encode_normalized_path))),
    #(
      "writeFailures",
      array(list.map(s.write_failures, encode_normalized_path)),
    ),
  ])
}

fn decode_digests(value: JsonValue) -> D(files.Digests) {
  use arr <- try(as_arr(value))
  use entries <- try(
    decode_support.map_list(arr, fn(e) {
      use resource_json <- try(obj_val(e, "resource"))
      use resource <- try(core_ops.decode_resource_id(resource_json))
      use digest_json <- try(obj_val(e, "digest"))
      use digest <- try(decode_content_digest(digest_json))
      Ok(#(resource, digest))
    }),
  )
  Ok(files.Digests(entries))
}

fn encode_digests(d: files.Digests) -> JsonValue {
  array(
    list.map(d.entries, fn(e) {
      object([
        #("resource", encode_resource_id(e.0)),
        #("digest", encode_content_digest(e.1)),
      ])
    }),
  )
}

fn encode_digest_lookup(value: files.DigestLookup) -> JsonValue {
  case value {
    files.DigestFound(d) ->
      object([#("tag", string("found")), #("digest", encode_content_digest(d))])
    files.DigestUnobserved(u) ->
      object([
        #("tag", string("unobserved")),
        #("resource", encode_resource_id(u.resource)),
      ])
  }
}

fn encode_observation(
  encode_payload: fn(a) -> JsonValue,
  o: core.Observation(a),
) -> JsonValue {
  object([
    #("payload", encode_payload(o.payload)),
    #("basis", encode_basis(o.basis)),
    #("observedAt", nat_to_json(o.observed_at)),
  ])
}

fn encode_file_snapshot(s: files.FileSnapshot) -> JsonValue {
  object([
    #("path", encode_normalized_path(s.path)),
    #("contents", encode_bytes(s.contents)),
    #("digest", encode_content_digest(s.digest)),
  ])
}

fn encode_track_result(
  value: core.Outcome(files.Tracked, Nil, Nil, Nil),
) -> JsonValue {
  case value {
    core.Applied(t) ->
      object([
        #("tag", string("applied")),
        #("observation", encode_observation(encode_revision, t.observation)),
        #("world", encode_world(t.world)),
      ])
    _ -> json_value.JNull
  }
}

fn encode_read_result(
  value: core.Outcome(files.Read, core.UnknownResource, Nil, files.ReadFailure),
) -> JsonValue {
  case value {
    core.Applied(r) ->
      object([
        #("tag", string("applied")),
        #(
          "observation",
          encode_observation(encode_file_snapshot, r.observation),
        ),
        #("world", encode_world(r.world)),
        #("digests", encode_digests(r.digests)),
      ])
    core.Rejected(u) ->
      object([
        #("tag", string("rejected")),
        #("resource", encode_resource_id(u.resource)),
      ])
    core.Conflicted(_) -> json_value.JNull
    core.BoundaryFailed(f) ->
      object([
        #("tag", string("boundaryFailed")),
        #("path", encode_normalized_path(f.path)),
      ])
  }
}

fn decode_replace_contents(value: JsonValue) -> D(files.ReplaceContents) {
  use new_contents_json <- try(obj_val(value, "newContents"))
  use new_contents <- try(decode_bytes(new_contents_json))
  use new_digest_json <- try(obj_val(value, "newDigest"))
  use new_digest <- try(decode_content_digest(new_digest_json))
  Ok(files.ReplaceContents(new_contents, new_digest))
}

fn encode_replace_rejection(value: files.ReplaceRejection) -> JsonValue {
  case value {
    files.RejectMismatch(m) ->
      object([
        #("tag", string("resourcePathMismatch")),
        #("resource", encode_resource_id(m.resource)),
        #("path", encode_normalized_path(m.path)),
      ])
    files.RejectUnknownResource(u) ->
      object([
        #("tag", string("unknownResource")),
        #("resource", encode_resource_id(u.resource)),
      ])
    files.RejectUnobservedContents(u) ->
      object([
        #("tag", string("unobservedContents")),
        #("resource", encode_resource_id(u.resource)),
      ])
  }
}

fn encode_replace_conflict(value: files.ReplaceConflict) -> JsonValue {
  case value {
    files.ConflictStaleBasis(s) ->
      object([
        #("tag", string("staleBasis")),
        #("expected", encode_revision(s.expected)),
        #("actual", encode_revision(s.actual)),
      ])
    files.ConflictExternalMutation(m) ->
      object([
        #("tag", string("externalMutation")),
        #("expected", encode_content_digest(m.expected)),
        #("actual", encode_content_digest(m.actual)),
      ])
  }
}

fn encode_replace_result(
  value: core.Outcome(
    files.Replaced,
    files.ReplaceRejection,
    files.ReplaceConflict,
    files.WriteFailure,
  ),
) -> JsonValue {
  case value {
    core.Applied(r) ->
      object([
        #("tag", string("applied")),
        #(
          "observation",
          encode_observation(encode_file_snapshot, r.observation),
        ),
        #("world", encode_world(r.world)),
        #("digests", encode_digests(r.digests)),
        #("state", encode_external_file_state(r.state)),
      ])
    core.Rejected(r) ->
      object([
        #("tag", string("rejected")),
        #("rejection", encode_replace_rejection(r)),
      ])
    core.Conflicted(c) ->
      object([
        #("tag", string("conflicted")),
        #("conflict", encode_replace_conflict(c)),
      ])
    core.BoundaryFailed(f) ->
      object([
        #("tag", string("boundaryFailed")),
        #("path", encode_normalized_path(f.path)),
      ])
  }
}

pub fn op_file_effect_normalize_path(input: JsonValue) -> D(JsonValue) {
  use root_json <- try(obj_val(input, "root"))
  use root <- try(decode_support.as_bool(root_json))
  use raw_arr <- try(arr_field(input, "raw"))
  use raw <- try(decode_support.map_list(raw_arr, as_str))
  Ok(encode_normalized_path(files.normalize_path(root, raw)))
}

pub fn op_file_effect_lookup_digest(input: JsonValue) -> D(JsonValue) {
  use digests_json <- try(obj_val(input, "digests"))
  use digests <- try(decode_digests(digests_json))
  use resource_json <- try(obj_val(input, "resource"))
  use resource <- try(core_ops.decode_resource_id(resource_json))
  Ok(encode_digest_lookup(files.lookup_digest(digests, resource)))
}

pub fn op_file_effect_set_digest(input: JsonValue) -> D(JsonValue) {
  use digests_json <- try(obj_val(input, "digests"))
  use digests <- try(decode_digests(digests_json))
  use resource_json <- try(obj_val(input, "resource"))
  use resource <- try(core_ops.decode_resource_id(resource_json))
  use digest_json <- try(obj_val(input, "digest"))
  use digest <- try(decode_content_digest(digest_json))
  Ok(encode_digests(files.set_digest(digests, resource, digest)))
}

pub fn op_file_effect_track(input: JsonValue) -> D(JsonValue) {
  use path_json <- try(obj_val(input, "path"))
  use path <- try(decode_normalized_path(path_json))
  use world_json <- try(obj_val(input, "world"))
  use world <- try(decode_world(world_json))
  use observed_at <- try(nat_field(input, "observedAt"))
  Ok(encode_track_result(files.track(files.TrackReq(path, world, observed_at))))
}

pub fn op_file_effect_read(input: JsonValue) -> D(JsonValue) {
  use path_json <- try(obj_val(input, "path"))
  use path <- try(decode_normalized_path(path_json))
  use world_json <- try(obj_val(input, "world"))
  use world <- try(decode_world(world_json))
  use digests_json <- try(obj_val(input, "digests"))
  use digests <- try(decode_digests(digests_json))
  use state_json <- try(obj_val(input, "state"))
  use state <- try(decode_external_file_state(state_json))
  use observed_at <- try(nat_field(input, "observedAt"))
  Ok(
    encode_read_result(
      files.read(files.ReadReq(path, world, digests, state, observed_at)),
    ),
  )
}

pub fn op_file_effect_replace(input: JsonValue) -> D(JsonValue) {
  use intent_json <- try(obj_val(input, "intent"))
  use intent <- try(decode_replace_contents(intent_json))
  use basis_json <- try(obj_val(input, "basis"))
  use basis <- try(decode_basis(basis_json))
  let command = core.Command(intent, basis)
  use path_json <- try(obj_val(input, "path"))
  use path <- try(decode_normalized_path(path_json))
  use world_json <- try(obj_val(input, "world"))
  use world <- try(decode_world(world_json))
  use digests_json <- try(obj_val(input, "digests"))
  use digests <- try(decode_digests(digests_json))
  use state_json <- try(obj_val(input, "state"))
  use state <- try(decode_external_file_state(state_json))
  use observed_at <- try(nat_field(input, "observedAt"))
  Ok(
    encode_replace_result(
      files.replace(files.ReplaceReq(
        command,
        path,
        world,
        digests,
        state,
        observed_at,
      )),
    ),
  )
}
