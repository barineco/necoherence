// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import necoherence/composition_plan
import necoherence/exact_json as kdl
import necoherence/inclusion
import necoherence/network_effect as network
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_generation_runtime_test as fixtures
import semantic_test_support as support

@external(erlang, "call_count_ffi", "count")
fn count_calls(
  patterns: List(#(String, String, Int)),
  run: fn() -> a,
) -> List(#(Int, Int))

const module_name = "necoherence@semantic_validation"

/// The functions that build the index, compute the meaning obligations, and build the programs and tables of the formats.
fn preparation_functions() -> List(#(String, String, Int)) {
  [
    #(module_name, "index_graph", 1),
    #(module_name, "declared_meaning_obligations", 3),
    #(module_name, "declared_reachable_types", 5),
    #(module_name, "computed_meaning_obligations", 2),
    #(module_name, "obligation_free_types", 1),
    #(module_name, "compile_format_program", 1),
    #(module_name, "compile_format_span", 2),
    #(module_name, "compile_format_node", 3),
    #(module_name, "dfa_transitions_by_state", 1),
    #(module_name, "grapheme_lookup", 1),
    #(module_name, "range_lookup", 3),
    #(module_name, "prepared_format_cache", 1),
    #(module_name, "graph_inline_rules", 1),
  ]
}

fn calls_of(counts: List(#(Int, Int))) -> Int {
  list.fold(counts, 0, fn(total, entry) { total + entry.1 })
}

fn every_function_traced(counts: List(#(Int, Int))) -> Bool {
  list.all(counts, fn(entry) { entry.0 == 1 })
}

fn grapheme_rules() -> types.GraphemeRules {
  types.GraphemeRules(
    support.profile_ref(),
    [types.GraphemeRange(0x0301, 0x0301, types.Extend)],
    [],
    [],
    types.GraphemeComponent("16.0.0", "45", "default"),
    string.repeat("c", 64),
    [],
  )
}

fn dfa() -> types.FormatRule {
  types.AsciiDfa(
    types.DfaSpec(2, 0, [1], [
      types.DfaTransition(0, 97, 122, 1),
      types.DfaTransition(1, 97, 122, 1),
    ]),
  )
}

fn graph() -> types.SemanticGraph {
  let base = support.profile()
  let profile =
    types.SemanticProfile(
      ..base,
      grapheme_rules: Some(grapheme_rules()),
      format_bindings: [
        types.FormatBinding("lower", support.profile_ref(), dfa()),
        types.FormatBinding(
          "short",
          support.profile_ref(),
          types.Bounded(types.Graphemes, 4, types.Text),
        ),
        ..base.format_bindings
      ],
    )
  let string_node = fn(name, format, lengths) {
    support.node(
      name,
      types.StringShape(types.StringSpec(
        format,
        lengths,
        None,
        None,
        None,
        [],
        None,
      )),
    )
  }
  let nodes = [
    support.node("flag", types.BooleanShape(types.BooleanSpec(None, None))),
    string_node("named", Some(types.NamedFormat("lower")), []),
    string_node("graphemes", Some(types.NamedFormat("short")), [
      types.LengthBound(types.Graphemes, None, Some(4)),
    ]),
    string_node(
      "inline",
      Some(
        types.InlineFormat(
          types.Sequence([types.Literal("k"), types.Optional(dfa())]),
        ),
      ),
      [],
    ),
    support.node("opaque", types.OpaqueShape("unknown")),
    support.node(
      "broken",
      types.ProductShape(types.ProductSpec(
        [support.field("o", "opaque", True, False)],
        types.RejectExtras,
      )),
    ),
    support.node(
      "list",
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(support.reference("named"), False),
        None,
        None,
      )),
    ),
    support.node("alias", types.AliasShape(support.reference("list"), "list")),
    support.node(
      "record",
      types.ProductShape(types.ProductSpec(
        [
          support.field("f", "flag", True, False),
          support.field("n", "named", True, False),
          support.field("g", "graphemes", False, True),
          support.field("i", "inline", True, False),
          support.field("l", "alias", True, False),
        ],
        types.AllowExtras(
          Some(types.NamedFormat("key-x")),
          types.ElementContract(support.reference("flag"), False),
        ),
      )),
    ),
  ]
  types.SemanticGraph(profile, nodes, [support.source()])
}

fn accepted_record() -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("f", kdl.JsonValueBool(True)),
    #("n", kdl.JsonValueStr("abc")),
    #("g", kdl.JsonValueStr("abc")),
    #("i", kdl.JsonValueStr("kab")),
    #("l", kdl.JsonValueArr([kdl.JsonValueStr("a"), kdl.JsonValueStr("bc")])),
    #("x", kdl.JsonValueBool(False)),
  ])
}

fn rejected_record() -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("f", kdl.JsonValueBool(True)),
    #("n", kdl.JsonValueStr("ABC")),
    #("i", kdl.JsonValueStr("kab")),
    #("l", kdl.JsonValueArr([])),
  ])
}

fn record_slot() -> types.SlotContract {
  types.SlotContract(support.reference("record"), True, False)
}

fn validate_repeatedly(prepared: validation.PreparedGraph, times: Int) -> Nil {
  list.each(list.repeat(Nil, times), fn(_) {
    let assert Ok(_) =
      validation.validate_value(
        prepared,
        support.reference("record"),
        accepted_record(),
        None,
      )
    let assert Error(validation.Rejected(_)) =
      validation.validate_value(
        prepared,
        support.reference("record"),
        rejected_record(),
        None,
      )
    let assert Ok(_) =
      validation.validate_slot(
        prepared,
        record_slot(),
        types.Present(accepted_record()),
      )
    let assert types.AcceptedValue =
      validation.accepts_value(
        prepared,
        support.reference("record"),
        accepted_record(),
      )
    let assert types.RejectedValue(_) =
      validation.accepts_slot(
        prepared,
        record_slot(),
        types.Present(rejected_record()),
      )
    Nil
  })
}

pub fn preparation_builds_the_index_the_obligations_and_the_formats_test() {
  let graph = graph()
  let counts =
    count_calls(preparation_functions(), fn() { validation.prepare(graph) })
  let assert True = every_function_traced(counts)
  let assert True = calls_of(counts) > 0
  let assert [#(_, indexed), #(_, declared), ..] = counts
  let assert True = indexed >= 1
  let assert True = declared >= list.length(graph.nodes)
}

pub fn repeated_validation_on_one_prepared_graph_builds_nothing_test() {
  let prepared = validation.prepare(graph())
  let counts =
    count_calls(preparation_functions(), fn() {
      validate_repeatedly(prepared, 25)
    })
  let assert True = every_function_traced(counts)
  let assert [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] =
    list.map(counts, fn(entry) { entry.1 })
}

fn query_repeatedly(prepared: validation.PreparedGraph, times: Int) -> Nil {
  list.each(list.repeat(Nil, times), fn(_) {
    let _ = validation.project_slot(prepared, record_slot(), [], [])
    let _ =
      validation.expand_value(
        prepared,
        support.reference("record"),
        [],
        accepted_record(),
      )
    let _ =
      validation.check_default_applications(
        prepared,
        accepted_record(),
        accepted_record(),
        [],
      )
    let _ =
      validation.meaning_obligations(prepared, [support.reference("record")])
    let _ = inclusion.empty_types(prepared)
    let _ = inclusion.verify_empty_types(prepared, [])
    let _ =
      inclusion.check_assignable(prepared, record_slot(), record_slot(), 64)
    Nil
  })
}

pub fn repeated_queries_on_one_prepared_graph_build_no_index_test() {
  let prepared = validation.prepare(graph())
  let counts =
    count_calls(preparation_functions(), fn() { query_repeatedly(prepared, 25) })
  let assert True = every_function_traced(counts)
  let assert [indexed, ..] = list.map(counts, fn(entry) { entry.1 })
  let assert 0 = indexed
}

pub fn a_type_with_remaining_obligations_still_reports_them_test() {
  let prepared = validation.prepare(graph())
  let assert Error(validation.Unresolved(obligations)) =
    validation.validate_value(
      prepared,
      support.reference("broken"),
      kdl.JsonValueObj([#("o", kdl.JsonValueNull)]),
      None,
    )
  let assert [
    types.SemanticObligation(
      reference,
      _,
      types.OpaqueTypeReason("unknown"),
      _,
      _,
    ),
  ] = obligations
  let assert True = reference == support.reference("opaque")
  let assert types.UnresolvedValue([_]) =
    validation.accepts_value(
      prepared,
      support.reference("broken"),
      kdl.JsonValueNull,
    )
  let assert types.UnresolvedValue([_]) =
    validation.accepts_value(
      prepared,
      support.reference("missing"),
      kdl.JsonValueNull,
    )
}

pub fn the_prepared_graph_reads_back_its_graph_test() {
  let graph = graph()
  let assert True =
    validation.prepared_graph(validation.prepare(graph)) == graph
}

fn admission_functions() -> List(#(String, String, Int)) {
  [#(module_name, "prepare", 1), #(module_name, "index_graph", 1)]
}

fn run_repeatedly(checked: composition_plan.CheckedComposition, times: Int) {
  list.each(list.repeat(Nil, times), fn(_) {
    let assert Ok(runtime.Completed(runtime.Success(_), _)) =
      runtime.start_composition(checked, [], [], network.empty_state())
    Nil
  })
}

fn assert_run_prepares_nothing(
  build: fn() -> composition_plan.CheckedComposition,
) {
  let built = count_calls(admission_functions(), build)
  let assert True = every_function_traced(built)
  let assert [prepared, indexed] = list.map(built, fn(entry) { entry.1 })
  let assert True = prepared > 0
  let assert True = indexed > 0
  let checked = build()
  let counts =
    count_calls(admission_functions(), fn() { run_repeatedly(checked, 20) })
  let assert True = every_function_traced(counts)
  let assert [0, 0] = list.map(counts, fn(entry) { entry.1 })
}

pub fn repeated_runs_through_a_presence_guard_prepare_nothing_test() {
  assert_run_prepares_nothing(fixtures.guard_checked)
}

pub fn repeated_runs_through_a_variant_guard_prepare_nothing_test() {
  assert_run_prepares_nothing(fixtures.variant_checked)
}
