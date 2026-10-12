// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/typed_mapping as solver

// Scenario A: one transition t1 consuming a res-a token at p1 and
// producing a token at `p2`; the goal asks for a token at `p2`.

fn place(identity: String) -> solver.TypedPlace {
  solver.TypedPlace(identity: identity, token_type: "tok", revision: 1)
}

fn transition(
  identity: String,
  input_places: List(String),
  output_places: List(String),
) -> solver.TypedTransition {
  solver.TypedTransition(
    identity: identity,
    input_places: input_places,
    output_places: output_places,
    failure_places: [],
    revision: 1,
  )
}

fn binding(
  transition_id: String,
  name: String,
  place: String,
  identity: String,
  mode: solver.BindingMode,
) -> solver.InputBinding {
  solver.InputBinding(
    transition_id: transition_id,
    name: name,
    place: place,
    token_type: "tok",
    identity: identity,
    provenance: "decl",
    multiplicity: 1,
    mode: mode,
    required_revision: 1,
  )
}

fn token(target: String, index: Int, revision: Int) -> solver.ColoredToken {
  solver.ColoredToken(
    target: target,
    index: index,
    revision: revision,
    kind: solver.TokenInput,
  )
}

fn scenario_a(
  marking: solver.Marking,
  goal: solver.GoalPredicate,
  max_search_steps: Int,
) -> solver.SolverInput {
  solver.SolverInput(
    places: [place("p1"), place("p2")],
    transitions: [transition("t1", ["p1"], ["p2"])],
    bindings: [binding("t1", "b1", "p1", "res-a", solver.Consume)],
    goal: goal,
    graph: solver.DeclarationGraph(
      places: ["p1", "p2"],
      transitions: ["t1"],
      edges: [#("p1", "t1"), #("t1", "p2")],
      revision: 1,
    ),
    marking: marking,
    bound: solver.DomainBound(
      target_identity: "res-a",
      index: 0,
      revision: 1,
      max_bindings: 4,
      max_search_steps: max_search_steps,
    ),
  )
}

fn initial_marking() -> solver.Marking {
  solver.Marking(places: [
    #("p1", [token("res-a", 0, 1)]),
    #("p2", []),
  ])
}

pub fn derive_enabled_reports_enabled_transition_test() {
  let input = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 8)
  let assert Ok(solver.Enabled(set)) = solver.derive_enabled(input)
  let assert [enabled] = set.enabled
  assert enabled.transition_id == "t1"
  assert enabled.bindings == input.bindings
}

/// Multiset atomicity is by occurrence count: removing one of two
/// identical tokens retains exactly one; removing every occurrence does
/// not satisfy the atomicity count for a single consumed token.
pub fn read_consume_atomicity_counts_occurrences_test() {
  let before = [token("res-a", 0, 1), token("res-a", 0, 1)]
  let consumed = [token("res-a", 0, 1)]
  assert solver.check_read_consume_atomicity(before, consumed, [
    token("res-a", 0, 1),
  ])
  assert !solver.check_read_consume_atomicity(before, consumed, [])
}
