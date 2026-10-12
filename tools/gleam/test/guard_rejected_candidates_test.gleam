// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/option.{None, Some}
import necoherence/semantic_composition as composition
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence_tools/composition_search as search
import semantic_tools_test_support as support

pub fn rejected_guard_candidates_come_from_the_declared_source_type_test() {
  let assert Ok(library) = signatures.decode_library_value(support.library())
  let graph = signatures.library_graph(library)
  let assert [node] = graph.nodes
  let contract = types.SlotContract(node.reference, True, False)
  let input =
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
      composition.InvocationDomain("test", "4", [], [], [], [], [
        composition.DeclaredGuard(
          composition.GuardId("check"),
          node.reference,
          [],
          composition.Validate(contract),
        ),
      ]),
      [],
      [],
      Some(composition.AnyFeasible),
      composition.default_search_bounds(),
    )
  let assert Ok(prepared) =
    composition.prepare_composition(graph, input, fn(function) {
      composition.check_function(graph, input, function)
    })
  let fact =
    composition.BranchFact(
      composition.GuardId("check"),
      composition.ValueRef(
        composition.Initial(composition.InputId("value")),
        [],
      ),
      composition.GuardRejected,
      None,
      [],
      None,
    )
  let assert [] =
    search.fact_replacements(
      prepared,
      composition.initial_state(prepared),
      fact,
    )
}
