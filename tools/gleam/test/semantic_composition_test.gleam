// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import necoherence/exact_json as json
import necoherence/semantic_composition as composition
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence_tools/composition_search as search
import semantic_tools_test_support as support
import simplifile

fn graph() -> types.SemanticGraph {
  let assert Ok(library) = signatures.decode_library_value(support.library())
  signatures.library_graph(library)
}

fn unit_ref(graph: types.SemanticGraph) -> types.TypeRef {
  let assert [node] = graph.nodes
  node.reference
}

fn problem(graph: types.SemanticGraph) -> composition.CompositionInput {
  let contract = types.SlotContract(unit_ref(graph), True, False)
  composition.CompositionInput(
    "test",
    "4",
    composition.semantic_basis(graph),
    [],
    [
      composition.InitialInput(
        composition.InputId("value"),
        contract,
        composition.Argument,
        None,
      ),
    ],
    [],
    composition.GoalSpec(
      [
        composition.GoalPort(
          composition.GoalPortId("result"),
          contract,
          composition.AnyCompatible,
        ),
      ],
      [],
      [],
    ),
    composition.InvocationDomain("test", "4", [], [], [], [], []),
    [],
    [],
    Some(composition.AnyFeasible),
    composition.default_search_bounds(),
  )
}

pub fn direct_initial_value_composition_is_derived_and_verified_test() {
  let graph = graph()
  let input = problem(graph)
  let assert Ok(prepared) =
    composition.prepare_composition(graph, input, fn(function) {
      composition.check_function(graph, input, function)
    })
  let assert Ok(composition.Solved(checked, _)) =
    search.derive_composition(prepared)
  let assert Ok(_) =
    composition.verify_composition(prepared, composition.checked_raw(checked))
}

fn bounds_wire(maximum: json.JsonValue) -> json.JsonValue {
  json.JsonValueObj([
    #("max_expanded_states", json.JsonValueStr("10000")),
    #("max_binding_candidates", json.JsonValueStr("100000")),
    #("max_type_obligations", json.JsonValueStr("10000")),
    #("max_branch_nodes", json.JsonValueStr("100000")),
    #("resource_bounds", json.JsonValueNull),
    #("max_sample_length", maximum),
  ])
}

pub fn public_sample_bound_is_mandatory_and_canonical_test() {
  let wire = bounds_wire(json.JsonValueStr("59"))
  let assert Ok(bounds) = decode.decode_search_bounds(wire)
  let assert 59 = bounds.max_sample_length
  let assert Ok(restored) = values.parse_wire(support.wire(wire))
  let assert Ok(restored) = decode.decode_search_bounds(restored)
  let assert True = restored == bounds
  list.each(
    [json.JsonValueNum(59), json.JsonValueStr("-1"), json.JsonValueStr("059")],
    fn(invalid) {
      let assert Error(_) = decode.decode_search_bounds(bounds_wire(invalid))
    },
  )
  let assert json.JsonValueObj(members) = wire
  let assert Error(_) =
    decode.decode_search_bounds(
      json.JsonValueObj(
        list.filter(members, fn(member) { member.0 != "max_sample_length" }),
      ),
    )
  let assert Error(_) =
    decode.decode_search_bounds(
      json.JsonValueObj([#("extra", json.JsonValueNull), ..members]),
    )
}

pub fn finite_composition_uses_caller_sample_length_test() {
  list.each([7, 17, 59], fn(length) {
    let text = string.repeat("x", length)
    let graph = graph()
    let assert [node] = graph.nodes
    let graph =
      types.SemanticGraph(..graph, nodes: [
        types.TypeNode(
          ..node,
          shape: types.StringShape(types.StringSpec(
            None,
            [],
            None,
            Some(text),
            None,
            [],
            None,
          )),
        ),
      ])
    let input = problem(graph)
    list.each([length - 1, length], fn(maximum) {
      let assert Ok(bounds) =
        decode.decode_search_bounds(
          bounds_wire(json.JsonValueStr(int.to_string(maximum))),
        )
      let input = composition.CompositionInput(..input, bounds: bounds)
      let assert [initial] = input.initial_inputs
      let sampled =
        composition.bounded_slot_samples(
          graph,
          initial.contract,
          bounds.max_type_obligations,
          bounds.max_sample_length,
        )
      let assert Ok(prepared) =
        composition.prepare_composition(graph, input, fn(function) {
          composition.check_function(graph, input, function)
        })
      case maximum < length {
        True -> {
          let assert [] = sampled.values
          let assert [composition.SampleBound] = sampled.obligations
          let assert Ok(composition.CompositionUnknown(_, _, _)) =
            search.derive_composition(prepared)
          Nil
        }
        False -> {
          let assert [types.Present(json.JsonValueStr(value))] = sampled.values
          let assert True = value == text
          let assert Ok(composition.Solved(checked, _)) =
            search.derive_composition(prepared)
          let assert Ok(_) =
            composition.verify_composition(
              prepared,
              composition.checked_raw(checked),
            )
          let assert True =
            composition.checked_raw(checked).witness.input_snapshot.bounds
            == bounds
          Nil
        }
      }
    })
  })
}

pub fn canonical_cid_samples_obey_32_58_59_bounds_test() {
  let assert Ok(wire) =
    simplifile.read("../../presets/atproto-data-model/profile.json")
  let assert Ok(profile) = values.parse_wire(wire)
  let assert Ok(profile) = decode.decode_semantic_profile(profile)
  let graph = graph()
  let assert [node] = graph.nodes
  let graph =
    types.SemanticGraph(..graph, profile: profile, nodes: [
      types.TypeNode(
        ..node,
        shape: types.StringShape(types.StringSpec(
          Some(types.NamedFormat("cid")),
          [],
          None,
          None,
          None,
          [],
          None,
        )),
      ),
    ])
  let contract = types.SlotContract(node.reference, True, False)
  list.each([32, 58, 59], fn(maximum) {
    let sampled =
      composition.bounded_slot_samples(graph, contract, 10_000, maximum)
    case maximum < 59 {
      True -> {
        let assert [] = sampled.values
        let assert [composition.SampleBound] = sampled.obligations
        Nil
      }
      False -> {
        let assert True = sampled.values != []
        list.each(sampled.values, fn(value) {
          let assert types.Present(json.JsonValueStr(text)) = value
          let assert 59 = string.length(text)
          let assert True = validation.accepts_slot(graph, contract, value)
        })
      }
    }
  })
}
