//// Gleam comparison runner for the typed mapping solver: reads the shared
//// fixtures document, executes the four public operations and writes the
//// canonical result document to stdout as JSON; no solving itself.

// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import necoherence/typed_mapping as solver
import necoherence_tools/typed_mapping_solver as search

@external(erlang, "init", "get_plain_arguments")
fn plain_arguments() -> List(List(Int))

@external(erlang, "erlang", "list_to_binary")
fn charlist_to_string(chars: List(Int)) -> String

@external(erlang, "file", "read_file")
fn ffi_read_file(path: String) -> Result(String, Nil)

/// A JSON value, decoded for fixture input or built for result output.
pub type Json {
  JNull
  JBool(Bool)
  JNum(Int)
  JStr(String)
  JArr(List(Json))
  JObj(List(#(String, Json)))
}

type PResult =
  Result(#(Json, List(String)), String)

fn skip_ws(chars: List(String)) -> List(String) {
  case chars {
    [c, ..rest] ->
      case c == " " || c == "\t" || c == "\n" || c == "\r" {
        True -> skip_ws(rest)
        False -> chars
      }
    [] -> []
  }
}

fn parse_value(chars: List(String)) -> PResult {
  case skip_ws(chars) {
    [] -> Error("unexpected end of input")
    ["{", ..rest] -> parse_object(rest, [])
    ["[", ..rest] -> parse_array(rest, [])
    ["\"", ..rest] -> {
      use #(text, rest) <- result.try(parse_string(rest, ""))
      Ok(#(JStr(text), rest))
    }
    ["t", "r", "u", "e", ..rest] -> Ok(#(JBool(True), rest))
    ["f", "a", "l", "s", "e", ..rest] -> Ok(#(JBool(False), rest))
    ["n", "u", "l", "l", ..rest] -> Ok(#(JNull, rest))
    chars -> parse_number(chars)
  }
}

fn is_digit(c: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], c)
}

fn parse_number(chars: List(String)) -> PResult {
  let digits =
    list.fold(chars, #("", True), fn(acc, c) {
      case acc.1 && is_digit(c) {
        True -> #(acc.0 <> c, True)
        False -> #(acc.0, False)
      }
    }).0
  let consumed = string.length(digits)
  let rest = list.drop(chars, consumed)
  case int.parse(digits) {
    Ok(n) -> Ok(#(JNum(n), rest))
    Error(_) -> Error("bad number " <> digits)
  }
}

fn parse_string(
  chars: List(String),
  acc: String,
) -> Result(#(String, List(String)), String) {
  case chars {
    [] -> Error("unterminated string")
    ["\"", ..rest] -> Ok(#(acc, rest))
    ["\\", esc, ..rest] ->
      case esc {
        "\"" -> parse_string(rest, acc <> "\"")
        "\\" -> parse_string(rest, acc <> "\\")
        "/" -> parse_string(rest, acc <> "/")
        "n" -> parse_string(rest, acc <> "\n")
        "t" -> parse_string(rest, acc <> "\t")
        "r" -> parse_string(rest, acc <> "\r")
        "b" -> parse_string(rest, acc <> "\u{0008}")
        "f" -> parse_string(rest, acc <> "\u{000C}")
        _ -> Error("unsupported escape \\" <> esc)
      }
    [c, ..rest] -> parse_string(rest, acc <> c)
  }
}

fn parse_array(chars: List(String), acc: List(Json)) -> PResult {
  case skip_ws(chars) {
    ["]", ..rest] -> Ok(#(JArr(list.reverse(acc)), rest))
    chars -> {
      use #(value, rest) <- result.try(parse_value(chars))
      case skip_ws(rest) {
        [",", ..rest] -> parse_array(rest, [value, ..acc])
        ["]", ..rest] -> Ok(#(JArr(list.reverse([value, ..acc])), rest))
        _ -> Error("expected ',' or ']'")
      }
    }
  }
}

fn parse_object(chars: List(String), acc: List(#(String, Json))) -> PResult {
  case skip_ws(chars) {
    ["}", ..rest] -> Ok(#(JObj(list.reverse(acc)), rest))
    ["\"", ..rest] -> {
      use #(key, rest) <- result.try(parse_string(rest, ""))
      case skip_ws(rest) {
        [":", ..rest] -> {
          use #(value, rest) <- result.try(parse_value(rest))
          case skip_ws(rest) {
            [",", ..rest] -> parse_object(rest, [#(key, value), ..acc])
            ["}", ..rest] ->
              Ok(#(JObj(list.reverse([#(key, value), ..acc])), rest))
            _ -> Error("expected ',' or '}'")
          }
        }
        _ -> Error("expected ':'")
      }
    }
    _ -> Error("expected object key")
  }
}

fn parse_json(text: String) -> Result(Json, String) {
  use #(value, rest) <- result.try(parse_value(string.to_graphemes(text)))
  case skip_ws(rest) {
    [] -> Ok(value)
    _ -> Error("trailing input after JSON document")
  }
}

fn jfield(json: Json, key: String) -> Result(Json, String) {
  case json {
    JObj(fields) ->
      case list.find(fields, fn(f) { f.0 == key }) {
        Ok(#(_, v)) -> Ok(v)
        Error(_) -> Error("missing field " <> key)
      }
    _ -> Error("expected object for field " <> key)
  }
}

fn jstr(json: Json, key: String) -> Result(String, String) {
  use v <- result.try(jfield(json, key))
  case v {
    JStr(s) -> Ok(s)
    _ -> Error("field " <> key <> " is not a string")
  }
}

fn jnat(json: Json, key: String) -> Result(Int, String) {
  use v <- result.try(jfield(json, key))
  case v {
    JNum(n) -> Ok(n)
    _ -> Error("field " <> key <> " is not a number")
  }
}

fn jarr(json: Json, key: String) -> Result(List(Json), String) {
  use v <- result.try(jfield(json, key))
  case v {
    JArr(items) -> Ok(items)
    _ -> Error("field " <> key <> " is not an array")
  }
}

fn jstrs(json: Json, key: String) -> Result(List(String), String) {
  use items <- result.try(jarr(json, key))
  list.try_map(items, fn(item) {
    case item {
      JStr(s) -> Ok(s)
      _ -> Error("field " <> key <> " has a non-string item")
    }
  })
}

fn dec_token(j: Json) -> Result(solver.ColoredToken, String) {
  use kind_text <- result.try(jstr(j, "kind"))
  use kind <- result.try(case kind_text {
    "input" -> Ok(solver.TokenInput)
    "output" -> Ok(solver.TokenOutput)
    "failure" -> Ok(solver.TokenFailure)
    "effect" -> Ok(solver.TokenEffect)
    "observation" -> Ok(solver.TokenObservation)
    "accepted" -> Ok(solver.TokenAccepted)
    other -> Error("unknown token kind " <> other)
  })
  use target <- result.try(jstr(j, "target"))
  use index <- result.try(jnat(j, "index"))
  use revision <- result.try(jnat(j, "revision"))
  Ok(solver.ColoredToken(
    target: target,
    index: index,
    revision: revision,
    kind: kind,
  ))
}

fn dec_place(j: Json) -> Result(solver.TypedPlace, String) {
  use identity <- result.try(jstr(j, "identity"))
  use token_type <- result.try(jstr(j, "token_type"))
  use revision <- result.try(jnat(j, "revision"))
  Ok(solver.TypedPlace(
    identity: identity,
    token_type: token_type,
    revision: revision,
  ))
}

fn dec_transition(j: Json) -> Result(solver.TypedTransition, String) {
  use identity <- result.try(jstr(j, "identity"))
  use input_places <- result.try(jstrs(j, "input_places"))
  use output_places <- result.try(jstrs(j, "output_places"))
  use failure_places <- result.try(jstrs(j, "failure_places"))
  use revision <- result.try(jnat(j, "revision"))
  Ok(solver.TypedTransition(
    identity: identity,
    input_places: input_places,
    output_places: output_places,
    failure_places: failure_places,
    revision: revision,
  ))
}

fn dec_binding(j: Json) -> Result(solver.InputBinding, String) {
  use mode_text <- result.try(jstr(j, "mode"))
  use mode <- result.try(case mode_text {
    "read" -> Ok(solver.Read)
    "consume" -> Ok(solver.Consume)
    other -> Error("unknown binding mode " <> other)
  })
  use transition_id <- result.try(jstr(j, "transition_id"))
  use name <- result.try(jstr(j, "name"))
  use place <- result.try(jstr(j, "place"))
  use token_type <- result.try(jstr(j, "token_type"))
  use identity <- result.try(jstr(j, "identity"))
  use provenance <- result.try(jstr(j, "provenance"))
  use multiplicity <- result.try(jnat(j, "multiplicity"))
  use required_revision <- result.try(jnat(j, "required_revision"))
  Ok(solver.InputBinding(
    transition_id: transition_id,
    name: name,
    place: place,
    token_type: token_type,
    identity: identity,
    provenance: provenance,
    multiplicity: multiplicity,
    mode: mode,
    required_revision: required_revision,
  ))
}

fn dec_goal(j: Json) -> Result(solver.GoalPredicate, String) {
  use kind <- result.try(jstr(j, "kind"))
  case kind {
    "place_has_at_least" -> {
      use place <- result.try(jstr(j, "place"))
      use count <- result.try(jnat(j, "count"))
      Ok(solver.PlaceHasAtLeast(place: place, count: count))
    }
    "place_has_token" -> {
      use place <- result.try(jstr(j, "place"))
      use target <- result.try(jstr(j, "target"))
      use index <- result.try(jnat(j, "index"))
      use revision <- result.try(jnat(j, "revision"))
      Ok(solver.PlaceHasToken(
        place: place,
        target: target,
        index: index,
        revision: revision,
      ))
    }
    "and" -> {
      use a <- result.try(jfield(j, "a") |> result.try(dec_goal))
      use b <- result.try(jfield(j, "b") |> result.try(dec_goal))
      Ok(solver.GoalAnd(a: a, b: b))
    }
    "or" -> {
      use a <- result.try(jfield(j, "a") |> result.try(dec_goal))
      use b <- result.try(jfield(j, "b") |> result.try(dec_goal))
      Ok(solver.GoalOr(a: a, b: b))
    }
    "not" -> {
      use a <- result.try(jfield(j, "a") |> result.try(dec_goal))
      Ok(solver.GoalNot(a: a))
    }
    other -> Error("unknown goal kind " <> other)
  }
}

fn dec_marking(j: Json) -> Result(solver.Marking, String) {
  use entries <- result.try(jarr(j, "places"))
  use places <- result.try(
    list.try_map(entries, fn(entry) {
      use place <- result.try(jstr(entry, "place"))
      use token_json <- result.try(jarr(entry, "tokens"))
      use tokens <- result.try(list.try_map(token_json, dec_token))
      Ok(#(place, tokens))
    }),
  )
  Ok(solver.Marking(places: places))
}

fn dec_edge(j: Json) -> Result(#(String, String), String) {
  case j {
    JArr([JStr(a), JStr(b)]) -> Ok(#(a, b))
    _ -> Error("edge must be a two-element string array")
  }
}

fn dec_input(j: Json) -> Result(solver.SolverInput, String) {
  use place_json <- result.try(jarr(j, "places"))
  use places <- result.try(list.try_map(place_json, dec_place))
  use transition_json <- result.try(jarr(j, "transitions"))
  use transitions <- result.try(list.try_map(transition_json, dec_transition))
  use binding_json <- result.try(jarr(j, "bindings"))
  use bindings <- result.try(list.try_map(binding_json, dec_binding))
  use graph <- result.try(jfield(j, "graph"))
  use graph_places <- result.try(jstrs(graph, "places"))
  use graph_transitions <- result.try(jstrs(graph, "transitions"))
  use edge_json <- result.try(jarr(graph, "edges"))
  use edges <- result.try(list.try_map(edge_json, dec_edge))
  use graph_revision <- result.try(jnat(graph, "revision"))
  use goal <- result.try(jfield(j, "goal") |> result.try(dec_goal))
  use marking <- result.try(jfield(j, "marking") |> result.try(dec_marking))
  use bound <- result.try(jfield(j, "bound"))
  use target_identity <- result.try(jstr(bound, "target_identity"))
  use index <- result.try(jnat(bound, "index"))
  use revision <- result.try(jnat(bound, "revision"))
  use max_bindings <- result.try(jnat(bound, "max_bindings"))
  use max_search_steps <- result.try(jnat(bound, "max_search_steps"))
  Ok(solver.SolverInput(
    places: places,
    transitions: transitions,
    bindings: bindings,
    goal: goal,
    graph: solver.DeclarationGraph(
      places: graph_places,
      transitions: graph_transitions,
      edges: edges,
      revision: graph_revision,
    ),
    marking: marking,
    bound: solver.DomainBound(
      target_identity: target_identity,
      index: index,
      revision: revision,
      max_bindings: max_bindings,
      max_search_steps: max_search_steps,
    ),
  ))
}

fn esc(text: String) -> String {
  let body =
    text
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
    |> string.replace("\t", "\\t")
    |> string.replace("\r", "\\r")
  "\"" <> body <> "\""
}

fn emit(json: Json, out: String) -> String {
  case json {
    JNull -> out <> "null"
    JBool(True) -> out <> "true"
    JBool(False) -> out <> "false"
    JNum(n) -> out <> int.to_string(n)
    JStr(text) -> out <> esc(text)
    JArr(items) -> out <> "[" <> emit_items(items) <> "]"
    JObj(fields) -> out <> "{" <> emit_fields(fields) <> "}"
  }
}

fn emit_items(items: List(Json)) -> String {
  case items {
    [] -> ""
    [one] -> emit(one, "")
    [one, ..rest] -> emit(one, "") <> "," <> emit_items(rest)
  }
}

fn emit_fields(fields: List(#(String, Json))) -> String {
  case fields {
    [] -> ""
    [#(key, value)] -> esc(key) <> ":" <> emit(value, "")
    [#(key, value), ..rest] ->
      esc(key) <> ":" <> emit(value, "") <> "," <> emit_fields(rest)
  }
}

fn enc_token(token: solver.ColoredToken) -> Json {
  let kind = case token.kind {
    solver.TokenInput -> "input"
    solver.TokenOutput -> "output"
    solver.TokenFailure -> "failure"
    solver.TokenEffect -> "effect"
    solver.TokenObservation -> "observation"
    solver.TokenAccepted -> "accepted"
  }
  JObj([
    #("target", JStr(token.target)),
    #("index", JNum(token.index)),
    #("revision", JNum(token.revision)),
    #("kind", JStr(kind)),
  ])
}

fn enc_marking(marking: solver.Marking) -> Json {
  JObj([
    #(
      "places",
      JArr(
        list.map(marking.places, fn(entry) {
          JObj([
            #("place", JStr(entry.0)),
            #("tokens", JArr(list.map(entry.1, enc_token))),
          ])
        }),
      ),
    ),
  ])
}

fn enc_binding(binding: solver.InputBinding) -> Json {
  JObj([
    #("transition_id", JStr(binding.transition_id)),
    #("name", JStr(binding.name)),
    #("place", JStr(binding.place)),
    #("token_type", JStr(binding.token_type)),
    #("identity", JStr(binding.identity)),
    #("provenance", JStr(binding.provenance)),
    #("multiplicity", JNum(binding.multiplicity)),
    #(
      "mode",
      JStr(case binding.mode {
        solver.Read -> "read"
        solver.Consume -> "consume"
      }),
    ),
    #("required_revision", JNum(binding.required_revision)),
  ])
}

fn enc_invalid(reason: solver.InvalidReason) -> Json {
  case reason {
    solver.UnknownPlace(place) ->
      JObj([#("kind", JStr("unknown_place")), #("place", JStr(place))])
    solver.UnknownTransition(transition_id) ->
      JObj([
        #("kind", JStr("unknown_transition")),
        #("transition_id", JStr(transition_id)),
      ])
    solver.UnknownInputPlace(transition_id, place) ->
      JObj([
        #("kind", JStr("unknown_input_place")),
        #("transition_id", JStr(transition_id)),
        #("place", JStr(place)),
      ])
    solver.MissingInputBinding(transition_id, place) ->
      JObj([
        #("kind", JStr("missing_input_binding")),
        #("transition_id", JStr(transition_id)),
        #("place", JStr(place)),
      ])
    solver.DuplicateTransitionIdentity(identity) ->
      JObj([
        #("kind", JStr("duplicate_transition_identity")),
        #("identity", JStr(identity)),
      ])
    solver.TypeMismatch(place, expected, actual) ->
      JObj([
        #("kind", JStr("type_mismatch")),
        #("place", JStr(place)),
        #("expected", JStr(expected)),
        #("actual", JStr(actual)),
      ])
    solver.MultiplicityMismatch(transition_id, name, expected, actual) ->
      JObj([
        #("kind", JStr("multiplicity_mismatch")),
        #("transition_id", JStr(transition_id)),
        #("name", JStr(name)),
        #("expected", JNum(expected)),
        #("actual", JNum(actual)),
      ])
    solver.RevisionMismatch(transition_id, name, expected, actual) ->
      JObj([
        #("kind", JStr("revision_mismatch")),
        #("transition_id", JStr(transition_id)),
        #("name", JStr(name)),
        #("expected", JNum(expected)),
        #("actual", JNum(actual)),
      ])
    solver.IdentityMismatch(transition_id, name) ->
      JObj([
        #("kind", JStr("identity_mismatch")),
        #("transition_id", JStr(transition_id)),
        #("name", JStr(name)),
      ])
    solver.DependencyMismatch(transition_id, place) ->
      JObj([
        #("kind", JStr("dependency_mismatch")),
        #("transition_id", JStr(transition_id)),
        #("place", JStr(place)),
      ])
  }
}

fn enc_unknown(reason: solver.UnknownReason) -> Json {
  case reason {
    solver.BindingBoundExhausted(limit) ->
      JObj([
        #("kind", JStr("binding_bound_exhausted")),
        #("limit", JNum(limit)),
      ])
    solver.SearchStepBoundExhausted(limit) ->
      JObj([
        #("kind", JStr("search_step_bound_exhausted")),
        #("limit", JNum(limit)),
      ])
  }
}

fn enc_enabled_list(set: solver.EnabledSet) -> Json {
  JArr(
    list.map(set.enabled, fn(entry) {
      JObj([
        #("transition_id", JStr(entry.transition_id)),
        #("bindings", JArr(list.map(entry.bindings, enc_binding))),
      ])
    }),
  )
}

fn enc_acyclic_witness(w: solver.AcyclicWitness) -> Json {
  JObj([
    #("explored_markings", JArr(list.map(w.explored_markings, enc_marking))),
    #("steps", JNum(w.steps)),
    #("frontier", JArr(list.map(w.frontier, enc_marking))),
  ])
}

fn enc_cycle_witness(w: solver.CycleWitness) -> Json {
  JObj([
    #("prefix_path", JArr(list.map(w.prefix_path, JStr))),
    #("cycle_path", JArr(list.map(w.cycle_path, JStr))),
    #("cycle_start", enc_marking(w.cycle_start)),
    #("cycle_end", enc_marking(w.cycle_end)),
    #("measure_decreasing", JBool(w.measure_decreasing)),
  ])
}

fn enc_operations(input: solver.SolverInput) -> Result(Json, String) {
  use enabled <- result.try(
    solver.derive_enabled(input)
    |> result.map(fn(r) {
      case r {
        solver.Enabled(set) ->
          JObj([
            #("status", JStr("enabled_set")),
            #("enabled", enc_enabled_list(set)),
          ])
        solver.EnabledInvalid(reason) ->
          JObj([
            #("status", JStr("invalid")),
            #("reason", enc_invalid(reason)),
          ])
      }
    })
    |> result.map_error(fn(_) { "derive_enabled host failure" }),
  )
  use reachability <- result.try(
    search.check_reachability(input)
    |> result.map(fn(r) {
      case r {
        solver.ReachabilityInvalid(reason) ->
          JObj([
            #("status", JStr("invalid")),
            #("reason", enc_invalid(reason)),
          ])
        solver.Reachable(witness) ->
          JObj([
            #("status", JStr("reachable")),
            #("path", JArr(list.map(witness.path, JStr))),
            #("final_marking", enc_marking(witness.final_marking)),
          ])
        solver.ReachabilityUnknown(reason) ->
          JObj([
            #("status", JStr("unknown")),
            #("reason", enc_unknown(reason)),
          ])
        solver.Unreachable(witness) ->
          JObj([
            #("status", JStr("unreachable")),
            #(
              "closure_witness",
              JObj([
                #(
                  "explored_markings",
                  JArr(list.map(witness.explored_markings, enc_marking)),
                ),
                #("steps", JNum(witness.steps)),
                #("frontier", JArr(list.map(witness.frontier, enc_marking))),
              ]),
            ),
          ])
      }
    })
    |> result.map_error(fn(_) { "check_reachability host failure" }),
  )
  use deadlock <- result.try(
    search.check_deadlock(input)
    |> result.map(fn(r) {
      case r {
        solver.Deadlocked(witness) ->
          JObj([
            #("status", JStr("deadlocked")),
            #("marking", enc_marking(witness.marking)),
          ])
        solver.DeadlockInvalid(reason) ->
          JObj([
            #("status", JStr("invalid")),
            #("reason", enc_invalid(reason)),
          ])
        solver.NotDeadlocked(set) ->
          JObj([
            #("status", JStr("not_deadlocked")),
            #("enabled", enc_enabled_list(set)),
          ])
        solver.DeadlockUnknown(reason) ->
          JObj([
            #("status", JStr("unknown")),
            #("reason", enc_unknown(reason)),
          ])
      }
    })
    |> result.map_error(fn(_) { "check_deadlock host failure" }),
  )
  use well_foundedness <- result.try(
    search.check_well_foundedness(input)
    |> result.map(fn(r) {
      case r {
        solver.WellFoundednessInvalid(reason) ->
          JObj([
            #("status", JStr("invalid")),
            #("reason", enc_invalid(reason)),
          ])
        solver.NotWellFounded(witness) ->
          JObj([
            #("status", JStr("not_well_founded")),
            #("witness", enc_cycle_witness(witness)),
          ])
        solver.WellFoundednessUnknown(reason) ->
          JObj([
            #("status", JStr("unknown")),
            #("reason", enc_unknown(reason)),
          ])
        solver.WellFounded(witness) ->
          JObj([
            #("status", JStr("well_founded")),
            #("witness", enc_acyclic_witness(witness)),
          ])
      }
    })
    |> result.map_error(fn(_) { "check_well_foundedness host failure" }),
  )
  Ok(
    JObj([
      #("derive_enabled", enabled),
      #("check_reachability", reachability),
      #("check_deadlock", deadlock),
      #("check_well_foundedness", well_foundedness),
    ]),
  )
}

fn run() -> Result(String, String) {
  let path = case plain_arguments() {
    [first, ..] -> charlist_to_string(first)
    [] -> "../../comparison/typed_mapping_solver/fixtures.json"
  }
  use text <- result.try(
    ffi_read_file(path)
    |> result.map_error(fn(_) { "cannot read " <> path }),
  )
  use document <- result.try(parse_json(text))
  use cases <- result.try(jarr(document, "cases"))
  use results <- result.try(
    list.try_map(cases, fn(case_json) {
      use name <- result.try(jstr(case_json, "name"))
      use input_json <- result.try(jfield(case_json, "input"))
      use input <- result.try(dec_input(input_json))
      use operations <- result.try(enc_operations(input))
      Ok(JObj([#("case", JStr(name)), #("operations", operations)]))
    }),
  )
  Ok(emit(
    JObj([
      #("producer", JStr("gleam")),
      #("solver_module", JStr("necoherence_tools/typed_mapping_solver")),
      #("producer_kind", JStr("public-api")),
      #("results", JArr(results)),
    ]),
    "",
  ))
}

pub fn main() {
  case run() {
    Ok(text) -> io.println(text)
    Error(message) -> {
      io.println("{\"error\": " <> esc(message) <> "}")
      panic as "typed_mapping_solver_compare failed"
    }
  }
}
