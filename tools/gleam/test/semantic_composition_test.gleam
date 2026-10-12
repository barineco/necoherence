// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/option.{None, Some}
import necoherence/semantic_composition as composition
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence_tools/composition_search as search
import semantic_tools_test_support as support

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
