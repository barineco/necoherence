// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import necoherence/typed_mapping as tm

@external(erlang, "typed_mapping_core_compare_ffi", "read_stdin")
fn read_stdin() -> String

type Case {
  Case(name: String, input: tm.SolverInput, path: List(String))
}

pub fn main() {
  case json.parse(read_stdin(), using: cases_decoder()) {
    Ok(cases) ->
      io.println(
        json.to_string(
          json.object([
            #("producer", json.string("gleam")),
            #("results", json.array(cases, encode_case)),
          ]),
        ),
      )
    Error(error) -> io.println("invalid cases: " <> string.inspect(error))
  }
}

fn cases_decoder() -> decode.Decoder(List(Case)) {
  decode.field("cases", decode.list(case_decoder()), decode.success)
}

fn case_decoder() -> decode.Decoder(Case) {
  use name <- decode.field("name", decode.string)
  use input <- decode.field("input", input_decoder())
  use path <- decode.field("path", decode.list(decode.string))
  decode.success(Case(name, input, path))
}

fn strings(key: String) -> decode.Decoder(List(String)) {
  decode.at([key], decode.list(decode.string))
}

fn place_decoder() -> decode.Decoder(tm.TypedPlace) {
  use identity <- decode.field("identity", decode.string)
  use token_type <- decode.field("token_type", decode.string)
  use revision <- decode.field("revision", decode.int)
  decode.success(tm.TypedPlace(identity, token_type, revision))
}

fn transition_decoder() -> decode.Decoder(tm.TypedTransition) {
  use identity <- decode.field("identity", decode.string)
  use inputs <- decode.then(strings("input_places"))
  use outputs <- decode.then(strings("output_places"))
  use failures <- decode.then(strings("failure_places"))
  use revision <- decode.field("revision", decode.int)
  decode.success(tm.TypedTransition(
    identity,
    inputs,
    outputs,
    failures,
    revision,
  ))
}

fn mode_decoder() -> decode.Decoder(tm.BindingMode) {
  use text <- decode.then(decode.string)
  case text {
    "read" -> decode.success(tm.Read)
    "consume" -> decode.success(tm.Consume)
    _ -> decode.failure(tm.Read, expected: "BindingMode")
  }
}

fn binding_decoder() -> decode.Decoder(tm.InputBinding) {
  use transition_id <- decode.field("transition_id", decode.string)
  use name <- decode.field("name", decode.string)
  use place <- decode.field("place", decode.string)
  use token_type <- decode.field("token_type", decode.string)
  use identity <- decode.field("identity", decode.string)
  use provenance <- decode.field("provenance", decode.string)
  use multiplicity <- decode.field("multiplicity", decode.int)
  use mode <- decode.field("mode", mode_decoder())
  use required_revision <- decode.field("required_revision", decode.int)
  decode.success(tm.InputBinding(
    transition_id,
    name,
    place,
    token_type,
    identity,
    provenance,
    multiplicity,
    mode,
    required_revision,
  ))
}

fn kind_decoder() -> decode.Decoder(tm.TokenKind) {
  use text <- decode.then(decode.string)
  case text {
    "input" -> decode.success(tm.TokenInput)
    "output" -> decode.success(tm.TokenOutput)
    "failure" -> decode.success(tm.TokenFailure)
    "effect" -> decode.success(tm.TokenEffect)
    "observation" -> decode.success(tm.TokenObservation)
    "accepted" -> decode.success(tm.TokenAccepted)
    _ -> decode.failure(tm.TokenInput, expected: "TokenKind")
  }
}

fn token_decoder() -> decode.Decoder(tm.ColoredToken) {
  use target <- decode.field("target", decode.string)
  use index <- decode.field("index", decode.int)
  use revision <- decode.field("revision", decode.int)
  use kind <- decode.field("kind", kind_decoder())
  decode.success(tm.ColoredToken(target, index, revision, kind))
}

fn marking_decoder() -> decode.Decoder(tm.Marking) {
  use places <- decode.field("places", decode.list(marking_entry_decoder()))
  decode.success(tm.Marking(places))
}

fn marking_entry_decoder() -> decode.Decoder(#(String, List(tm.ColoredToken))) {
  use place <- decode.field("place", decode.string)
  use tokens <- decode.field("tokens", decode.list(token_decoder()))
  decode.success(#(place, tokens))
}

fn edge_decoder() -> decode.Decoder(#(String, String)) {
  decode.list(decode.string)
  |> decode.then(fn(pair) {
    case pair {
      [from, to] -> decode.success(#(from, to))
      _ -> decode.failure(#("", ""), expected: "edge")
    }
  })
}

fn graph_decoder() -> decode.Decoder(tm.DeclarationGraph) {
  use places <- decode.then(strings("places"))
  use transitions <- decode.then(strings("transitions"))
  use edges <- decode.field("edges", decode.list(edge_decoder()))
  use revision <- decode.field("revision", decode.int)
  decode.success(tm.DeclarationGraph(places, transitions, edges, revision))
}

fn bound_decoder() -> decode.Decoder(tm.DomainBound) {
  use target <- decode.field("target_identity", decode.string)
  use index <- decode.field("index", decode.int)
  use revision <- decode.field("revision", decode.int)
  use max_bindings <- decode.field("max_bindings", decode.int)
  use max_search_steps <- decode.field("max_search_steps", decode.int)
  decode.success(tm.DomainBound(
    target,
    index,
    revision,
    max_bindings,
    max_search_steps,
  ))
}

fn goal_decoder() -> decode.Decoder(tm.GoalPredicate) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "place_has_at_least" -> {
      use place <- decode.field("place", decode.string)
      use count <- decode.field("count", decode.int)
      decode.success(tm.PlaceHasAtLeast(place, count))
    }
    "place_has_token" -> {
      use place <- decode.field("place", decode.string)
      use target <- decode.field("target", decode.string)
      use index <- decode.field("index", decode.int)
      use revision <- decode.field("revision", decode.int)
      decode.success(tm.PlaceHasToken(place, target, index, revision))
    }
    "and" -> {
      use a <- decode.field("a", goal_decoder())
      use b <- decode.field("b", goal_decoder())
      decode.success(tm.GoalAnd(a, b))
    }
    "or" -> {
      use a <- decode.field("a", goal_decoder())
      use b <- decode.field("b", goal_decoder())
      decode.success(tm.GoalOr(a, b))
    }
    "not" -> {
      use a <- decode.field("a", goal_decoder())
      decode.success(tm.GoalNot(a))
    }
    _ -> decode.failure(tm.PlaceHasAtLeast("", 0), expected: "GoalPredicate")
  }
}

fn input_decoder() -> decode.Decoder(tm.SolverInput) {
  use places <- decode.field("places", decode.list(place_decoder()))
  use transitions <- decode.field(
    "transitions",
    decode.list(transition_decoder()),
  )
  use bindings <- decode.field("bindings", decode.list(binding_decoder()))
  use goal <- decode.field("goal", goal_decoder())
  use graph <- decode.field("graph", graph_decoder())
  use marking <- decode.field("marking", marking_decoder())
  use bound <- decode.field("bound", bound_decoder())
  decode.success(tm.SolverInput(
    places,
    transitions,
    bindings,
    goal,
    graph,
    marking,
    bound,
  ))
}

fn encode_case(value: Case) -> json.Json {
  let input = value.input
  json.object([
    #("case", json.string(value.name)),
    #(
      "operations",
      json.object([
        #("validate", encode_validate(tm.validate(input))),
        #("derive_enabled", encode_enabled(tm.derive_enabled_set(input))),
        #("binding_bound_exceeded", json.bool(tm.binding_bound_exceeded(input))),
        #(
          "path_replay",
          encode_marking_option(tm.path_replay(input, input.marking, value.path)),
        ),
        #(
          "step_at",
          json.array(value.path, fn(name) {
            encode_marking_option(tm.step_at(input, input.marking, name))
          }),
        ),
      ]),
    ),
  ])
}

fn encode_validate(result: Result(Nil, tm.InvalidReason)) -> json.Json {
  case result {
    Ok(Nil) -> json.object([#("status", json.string("valid"))])
    Error(reason) ->
      json.object([
        #("status", json.string("invalid")),
        #("reason", encode_invalid(reason)),
      ])
  }
}

fn kind(name: String, fields: List(#(String, json.Json))) -> json.Json {
  json.object([#("kind", json.string(name)), ..fields])
}

fn encode_invalid(reason: tm.InvalidReason) -> json.Json {
  case reason {
    tm.UnknownPlace(place) ->
      kind("unknown_place", [#("place", json.string(place))])
    tm.UnknownTransition(id) ->
      kind("unknown_transition", [#("transition_id", json.string(id))])
    tm.UnknownInputPlace(id, place) ->
      kind("unknown_input_place", [
        #("transition_id", json.string(id)),
        #("place", json.string(place)),
      ])
    tm.MissingInputBinding(id, place) ->
      kind("missing_input_binding", [
        #("transition_id", json.string(id)),
        #("place", json.string(place)),
      ])
    tm.DuplicateTransitionIdentity(identity) ->
      kind("duplicate_transition_identity", [
        #("identity", json.string(identity)),
      ])
    tm.TypeMismatch(place, expected, actual) ->
      kind("type_mismatch", [
        #("place", json.string(place)),
        #("expected", json.string(expected)),
        #("actual", json.string(actual)),
      ])
    tm.MultiplicityMismatch(id, name, expected, actual) ->
      kind("multiplicity_mismatch", [
        #("transition_id", json.string(id)),
        #("name", json.string(name)),
        #("expected", json.int(expected)),
        #("actual", json.int(actual)),
      ])
    tm.RevisionMismatch(id, name, expected, actual) ->
      kind("revision_mismatch", [
        #("transition_id", json.string(id)),
        #("name", json.string(name)),
        #("expected", json.int(expected)),
        #("actual", json.int(actual)),
      ])
    tm.IdentityMismatch(id, name) ->
      kind("identity_mismatch", [
        #("transition_id", json.string(id)),
        #("name", json.string(name)),
      ])
    tm.DependencyMismatch(id, place) ->
      kind("dependency_mismatch", [
        #("transition_id", json.string(id)),
        #("place", json.string(place)),
      ])
  }
}

fn encode_mode(mode: tm.BindingMode) -> json.Json {
  case mode {
    tm.Read -> json.string("read")
    tm.Consume -> json.string("consume")
  }
}

fn encode_binding(b: tm.InputBinding) -> json.Json {
  json.object([
    #("transition_id", json.string(b.transition_id)),
    #("name", json.string(b.name)),
    #("place", json.string(b.place)),
    #("token_type", json.string(b.token_type)),
    #("identity", json.string(b.identity)),
    #("provenance", json.string(b.provenance)),
    #("multiplicity", json.int(b.multiplicity)),
    #("mode", encode_mode(b.mode)),
    #("required_revision", json.int(b.required_revision)),
  ])
}

fn encode_enabled(result: tm.EnabledResult) -> json.Json {
  case result {
    tm.Enabled(tm.EnabledSet(enabled)) ->
      json.object([
        #("status", json.string("enabled_set")),
        #(
          "enabled",
          json.array(enabled, fn(e) {
            json.object([
              #("transition_id", json.string(e.transition_id)),
              #("bindings", json.array(e.bindings, encode_binding)),
            ])
          }),
        ),
      ])
    tm.EnabledInvalid(reason) ->
      json.object([
        #("status", json.string("invalid")),
        #("reason", encode_invalid(reason)),
      ])
  }
}

fn encode_kind(kind: tm.TokenKind) -> json.Json {
  json.string(case kind {
    tm.TokenInput -> "input"
    tm.TokenOutput -> "output"
    tm.TokenFailure -> "failure"
    tm.TokenEffect -> "effect"
    tm.TokenObservation -> "observation"
    tm.TokenAccepted -> "accepted"
  })
}

fn encode_marking_option(marking: Option(tm.Marking)) -> json.Json {
  case marking {
    None -> json.null()
    Some(tm.Marking(places)) ->
      json.object([
        #(
          "places",
          json.array(places, fn(entry) {
            json.object([
              #("place", json.string(entry.0)),
              #(
                "tokens",
                json.array(entry.1, fn(token) {
                  json.object([
                    #("target", json.string(token.target)),
                    #("index", json.int(token.index)),
                    #("revision", json.int(token.revision)),
                    #("kind", encode_kind(token.kind)),
                  ])
                }),
              ),
            ])
          }),
        ),
      ])
  }
}
