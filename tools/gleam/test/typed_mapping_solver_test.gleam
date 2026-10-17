// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/list
import necoherence/typed_mapping as solver
import necoherence_tools/typed_mapping_solver as search

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

pub fn check_reachability_reachable_with_witness_test() {
  let input = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 8)
  let assert Ok(solver.Reachable(witness)) = search.check_reachability(input)
  assert witness.path == ["t1"]
}

pub fn check_reachability_unreachable_carries_closure_witness_test() {
  let input = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 2), 8)
  let assert Ok(solver.Unreachable(witness)) = search.check_reachability(input)
  assert witness.steps == list.length(witness.explored_markings)
  assert witness.frontier == []
  assert witness.steps == 2
}

pub fn check_reachability_bound_exhausted_is_unknown_test() {
  let input = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 0)
  let assert Ok(solver.ReachabilityUnknown(reason)) =
    search.check_reachability(input)
  assert reason == solver.SearchStepBoundExhausted(0)
}

pub fn check_deadlock_not_deadlocked_when_enabled_test() {
  let input = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 8)
  let assert Ok(solver.NotDeadlocked(set)) = search.check_deadlock(input)
  assert list.length(set.enabled) == 1
}

pub fn check_deadlock_deadlocked_when_no_transition_enabled_test() {
  let marking = solver.Marking(places: [#("p1", []), #("p2", [])])
  let input = scenario_a(marking, solver.PlaceHasAtLeast("p2", 1), 8)
  let assert Ok(solver.Deadlocked(witness)) = search.check_deadlock(input)
  assert witness.marking == marking
}

pub fn check_deadlock_goal_satisfied_is_not_deadlocked_test() {
  let marking =
    solver.Marking(places: [
      #("p1", []),
      #("p2", [token("res-a", 0, 1)]),
    ])
  let input = scenario_a(marking, solver.PlaceHasAtLeast("p2", 1), 8)
  let assert Ok(solver.NotDeadlocked(_)) = search.check_deadlock(input)
}

fn scenario_b(max_search_steps: Int) -> solver.SolverInput {
  let marking = solver.Marking(places: [#("p2", [token("res-b", 0, 1)])])
  solver.SolverInput(
    places: [place("p2")],
    transitions: [
      solver.TypedTransition(
        identity: "t2",
        input_places: ["p2"],
        output_places: [],
        failure_places: [],
        revision: 1,
      ),
    ],
    bindings: [binding("t2", "b2", "p2", "res-b", solver.Read)],
    goal: solver.PlaceHasAtLeast("p2", 99),
    graph: solver.DeclarationGraph(
      places: ["p2"],
      transitions: ["t2"],
      edges: [#("p2", "t2")],
      revision: 1,
    ),
    marking: marking,
    bound: solver.DomainBound(
      target_identity: "res-b",
      index: 0,
      revision: 1,
      max_bindings: 4,
      max_search_steps: max_search_steps,
    ),
  )
}

pub fn check_well_foundedness_acyclic_closure_is_well_founded_test() {
  let input = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 2), 8)
  let assert Ok(solver.WellFounded(witness)) =
    search.check_well_foundedness(input)
  assert witness.explored_markings != []
  assert witness.steps == list.length(witness.explored_markings)
  assert witness.frontier == []
}

pub fn check_well_foundedness_non_decreasing_cycle_is_not_well_founded_test() {
  let input = scenario_b(8)
  let assert Ok(solver.NotWellFounded(witness)) =
    search.check_well_foundedness(input)
  assert witness.prefix_path == []
  assert witness.cycle_path == ["t2"]
  assert witness.cycle_start == witness.cycle_end
  assert !witness.measure_decreasing
}

pub fn check_well_foundedness_bound_exhausted_is_unknown_test() {
  let input = scenario_b(0)
  let assert Ok(solver.WellFoundednessUnknown(reason)) =
    search.check_well_foundedness(input)
  assert reason == solver.SearchStepBoundExhausted(0)
}

pub fn invalid_declaration_is_reported_by_every_operation_test() {
  let bad_binding =
    solver.InputBinding(
      transition_id: "t1",
      name: "bad",
      place: "p2",
      token_type: "tok",
      identity: "res-a",
      provenance: "decl",
      multiplicity: 1,
      mode: solver.Consume,
      required_revision: 1,
    )
  let input =
    solver.SolverInput(
      ..scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 8),
      bindings: [
        binding("t1", "b1", "p1", "res-a", solver.Consume),
        bad_binding,
      ],
    )
  let assert Ok(solver.EnabledInvalid(solver.DependencyMismatch("t1", "p2"))) =
    solver.derive_enabled(input)
  let assert Ok(solver.ReachabilityInvalid(solver.DependencyMismatch("t1", "p2"))) =
    search.check_reachability(input)
  let assert Ok(solver.DeadlockInvalid(solver.DependencyMismatch("t1", "p2"))) =
    search.check_deadlock(input)
  let assert Ok(solver.WellFoundednessInvalid(solver.DependencyMismatch(
    "t1",
    "p2",
  ))) = search.check_well_foundedness(input)
}

fn conv_transitions() -> List(solver.TypedTransition) {
  [
    solver.TypedTransition("T-A", ["P-SRC", "P-X", "P-S"], ["P-A"], [], 1),
    solver.TypedTransition("T-B", ["P-SRC", "P-X", "P-S"], ["P-B"], [], 1),
    solver.TypedTransition("T-AX", ["P-SRC", "P-X", "P-A"], [], [], 1),
    solver.TypedTransition("T-BC", ["P-SRC", "P-X", "P-B"], ["P-C"], [], 1),
    solver.TypedTransition("T-CX", ["P-SRC", "P-X", "P-C"], [], [], 1),
  ]
}

fn conv_bindings() -> List(solver.InputBinding) {
  [
    binding("T-A", "ba-src", "P-SRC", "job-1", solver.Read),
    binding("T-A", "ba-x", "P-X", "job-2", solver.Read),
    binding("T-A", "ba-s", "P-S", "job-3", solver.Consume),
    binding("T-B", "bb-src", "P-SRC", "job-1", solver.Read),
    binding("T-B", "bb-x", "P-X", "job-2", solver.Read),
    binding("T-B", "bb-s", "P-S", "job-3", solver.Consume),
    binding("T-AX", "bax-src", "P-SRC", "job-1", solver.Read),
    binding("T-AX", "bax-x", "P-X", "job-2", solver.Read),
    binding("T-AX", "bax-a", "P-A", "T-A", solver.Consume),
    binding("T-BC", "bbc-src", "P-SRC", "job-1", solver.Read),
    binding("T-BC", "bbc-x", "P-X", "job-2", solver.Read),
    binding("T-BC", "bbc-b", "P-B", "T-B", solver.Consume),
    binding("T-CX", "bcx-src", "P-SRC", "job-1", solver.Read),
    binding("T-CX", "bcx-x", "P-X", "job-2", solver.Read),
    binding("T-CX", "bcx-c", "P-C", "T-BC", solver.Consume),
  ]
}

fn conv_input() -> solver.SolverInput {
  solver.SolverInput(
    places: [
      place("P-SRC"),
      place("P-X"),
      place("P-S"),
      place("P-A"),
      place("P-B"),
      place("P-C"),
      place("P-Z"),
    ],
    transitions: conv_transitions(),
    bindings: conv_bindings(),
    goal: solver.PlaceHasAtLeast("P-Z", 1),
    graph: solver.DeclarationGraph(
      places: ["P-SRC", "P-X", "P-S", "P-A", "P-B", "P-C", "P-Z"],
      transitions: ["T-A", "T-B", "T-AX", "T-BC", "T-CX"],
      edges: [],
      revision: 1,
    ),
    marking: solver.Marking(places: [
      #("P-SRC", [token("job-1", 0, 1)]),
      #("P-X", [token("job-2", 0, 1)]),
      #("P-S", [token("job-3", 0, 1)]),
      #("P-A", []),
      #("P-B", []),
      #("P-C", []),
    ]),
    bound: solver.DomainBound(
      target_identity: "unit:typed-mapping-solver",
      index: 0,
      revision: 1,
      max_bindings: 20,
      max_search_steps: 20,
    ),
  )
}

pub fn convergent_dag_is_well_founded_test() {
  let assert Ok(solver.WellFounded(witness)) =
    search.check_well_foundedness(conv_input())
  assert witness.explored_markings != []
  assert witness.steps == list.length(witness.explored_markings)
  assert witness.frontier == []
}

pub fn closure_witness_records_distinct_markings_test() {
  let assert Ok(solver.Unreachable(witness)) =
    search.check_reachability(conv_input())
  assert witness.steps == 5
  assert list.length(witness.explored_markings) == 5
  assert list.unique(witness.explored_markings) == witness.explored_markings
}

pub fn consume_removes_only_selected_occurrences_test() {
  let marking =
    solver.Marking(places: [
      #("p1", [token("res-a", 0, 1), token("res-a", 0, 1)]),
      #("p2", []),
    ])
  let goal =
    solver.GoalAnd(
      solver.PlaceHasAtLeast("p1", 1),
      solver.PlaceHasAtLeast("p2", 1),
    )
  let input = scenario_a(marking, goal, 8)
  let assert Ok(solver.Reachable(witness)) = search.check_reachability(input)
  assert witness.path == ["t1"]
  let assert Ok(#(_, retained)) =
    list.find(witness.final_marking.places, fn(p) { p.0 == "p1" })
  assert retained == [token("res-a", 0, 1)]
}

pub fn binding_bound_exhaustion_reports_unknown_test() {
  let base = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 8)
  let input =
    solver.SolverInput(
      ..base,
      bound: solver.DomainBound(..base.bound, max_bindings: 0),
    )
  let assert Ok(solver.ReachabilityUnknown(solver.BindingBoundExhausted(0))) =
    search.check_reachability(input)
  let assert Ok(solver.DeadlockUnknown(solver.BindingBoundExhausted(0))) =
    search.check_deadlock(input)
  let assert Ok(solver.WellFoundednessUnknown(solver.BindingBoundExhausted(0))) =
    search.check_well_foundedness(input)
}

pub fn undeclared_output_place_is_invalid_test() {
  let base = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 8)
  let input =
    solver.SolverInput(
      ..base,
      transitions: [
        solver.TypedTransition("t-bad-out", [], ["p-ghost"], [], 1),
      ],
      bindings: [],
      graph: solver.DeclarationGraph(
        places: ["p1", "p2"],
        transitions: ["t-bad-out"],
        edges: [],
        revision: 1,
      ),
    )
  let assert Ok(solver.ReachabilityInvalid(solver.DependencyMismatch(
    "t-bad-out",
    "p-ghost",
  ))) = search.check_reachability(input)
}

pub fn undeclared_failure_place_is_invalid_test() {
  let base = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 8)
  let input =
    solver.SolverInput(
      ..base,
      transitions: [
        solver.TypedTransition("t-bad-fail", [], [], ["p-ghost-f"], 1),
      ],
      bindings: [],
      graph: solver.DeclarationGraph(
        places: ["p1", "p2"],
        transitions: ["t-bad-fail"],
        edges: [],
        revision: 1,
      ),
    )
  let assert Ok(solver.ReachabilityInvalid(solver.DependencyMismatch(
    "t-bad-fail",
    "p-ghost-f",
  ))) = search.check_reachability(input)
}

fn prefixed_cycle_input() -> solver.SolverInput {
  solver.SolverInput(
    places: [place("p0"), place("p1")],
    transitions: [
      solver.TypedTransition("prefix", ["p0"], ["p1"], [], 1),
      solver.TypedTransition("loop", ["p1"], [], [], 1),
    ],
    bindings: [
      binding("prefix", "source", "p0", "res-a", solver.Consume),
      binding("loop", "cycle", "p1", "prefix", solver.Read),
    ],
    goal: solver.PlaceHasAtLeast("p1", 99),
    graph: solver.DeclarationGraph(
      places: ["p0", "p1"],
      transitions: ["prefix", "loop"],
      edges: [],
      revision: 1,
    ),
    marking: solver.Marking(places: [
      #("p0", [token("res-a", 0, 1)]),
      #("p1", []),
    ]),
    bound: solver.DomainBound(
      target_identity: "res-a",
      index: 0,
      revision: 1,
      max_bindings: 4,
      max_search_steps: 8,
    ),
  )
}

fn decreasing_cycle_input() -> solver.SolverInput {
  solver.SolverInput(
    places: [place("p-a"), place("p-b")],
    transitions: [
      solver.TypedTransition("add", ["p-a"], ["p-b"], [], 1),
      solver.TypedTransition("consume", ["p-b"], [], [], 1),
    ],
    bindings: [
      binding("add", "source", "p-a", "seed", solver.Read),
      binding("consume", "added", "p-b", "add", solver.Consume),
    ],
    goal: solver.PlaceHasAtLeast("p-a", 5),
    graph: solver.DeclarationGraph(
      places: ["p-a", "p-b"],
      transitions: ["add", "consume"],
      edges: [],
      revision: 1,
    ),
    marking: solver.Marking(places: [
      #("p-a", [token("seed", 0, 1)]),
      #("p-b", []),
    ]),
    bound: solver.DomainBound(
      target_identity: "seed",
      index: 0,
      revision: 1,
      max_bindings: 4,
      max_search_steps: 8,
    ),
  )
}

pub fn decreasing_closing_edge_is_still_not_well_founded_test() {
  let assert Ok(solver.NotWellFounded(witness)) =
    search.check_well_foundedness(decreasing_cycle_input())
  assert witness.prefix_path == []
  assert witness.cycle_path == ["add", "consume"]
  assert witness.cycle_start == witness.cycle_end
  assert witness.measure_decreasing
}

pub fn well_foundedness_cycle_witness_has_exact_prefix_and_segment_test() {
  let assert Ok(solver.NotWellFounded(witness)) =
    search.check_well_foundedness(prefixed_cycle_input())
  assert witness.prefix_path == ["prefix"]
  assert witness.cycle_path == ["loop"]
  assert witness.cycle_start == witness.cycle_end
  assert !witness.measure_decreasing
}

pub fn input_place_membership_precedes_other_invalid_reasons_test() {
  let base = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 8)
  let input =
    solver.SolverInput(..base, transitions: [
      solver.TypedTransition("t1", ["p-ghost"], ["p2"], [], 1),
    ])
  let assert Ok(solver.EnabledInvalid(solver.UnknownInputPlace("t1", "p-ghost"))) =
    solver.derive_enabled(input)
  let assert Ok(solver.ReachabilityInvalid(solver.UnknownInputPlace(
    "t1",
    "p-ghost",
  ))) = search.check_reachability(input)
  let assert Ok(solver.DeadlockInvalid(solver.UnknownInputPlace("t1", "p-ghost"))) =
    search.check_deadlock(input)
  let assert Ok(solver.WellFoundednessInvalid(solver.UnknownInputPlace(
    "t1",
    "p-ghost",
  ))) = search.check_well_foundedness(input)
}

pub fn missing_input_binding_precedes_binding_validation_test() {
  let base = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 8)
  let input =
    solver.SolverInput(..base, transitions: [
      solver.TypedTransition("t1", ["p1", "p2"], ["p2"], [], 1),
    ])
  let assert Ok(solver.EnabledInvalid(solver.MissingInputBinding("t1", "p2"))) =
    solver.derive_enabled(input)
  let assert Ok(solver.ReachabilityInvalid(solver.MissingInputBinding(
    "t1",
    "p2",
  ))) = search.check_reachability(input)
}

pub fn duplicate_transition_identity_is_invalid_after_place_scan_test() {
  let base = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p2", 1), 8)
  let input =
    solver.SolverInput(..base, transitions: [
      solver.TypedTransition("t1", ["p1"], ["p2"], [], 1),
      solver.TypedTransition("t1", ["p1"], [], [], 1),
    ])
  let assert Ok(solver.EnabledInvalid(solver.DuplicateTransitionIdentity("t1"))) =
    solver.derive_enabled(input)
  let assert Ok(solver.ReachabilityInvalid(solver.DuplicateTransitionIdentity(
    "t1",
  ))) = search.check_reachability(input)
}

pub fn zero_input_source_transition_without_binding_is_valid_test() {
  let input =
    solver.SolverInput(
      places: [place("p1")],
      transitions: [
        solver.TypedTransition("source", [], ["p1"], [], 1),
      ],
      bindings: [],
      goal: solver.PlaceHasAtLeast("p1", 1),
      graph: solver.DeclarationGraph(
        places: ["p1"],
        transitions: ["source"],
        edges: [],
        revision: 1,
      ),
      marking: solver.Marking(places: [#("p1", [])]),
      bound: solver.DomainBound(
        target_identity: "res-a",
        index: 0,
        revision: 1,
        max_bindings: 0,
        max_search_steps: 1,
      ),
    )
  let assert Ok(solver.Enabled(set)) = solver.derive_enabled(input)
  let assert [enabled] = set.enabled
  assert enabled.transition_id == "source"
  let assert Ok(solver.Reachable(witness)) = search.check_reachability(input)
  assert witness.path == ["source"]
}

pub fn goal_satisfied_at_zero_search_steps_is_reachable_test() {
  let input = scenario_a(initial_marking(), solver.PlaceHasAtLeast("p1", 1), 0)
  let assert Ok(solver.Reachable(witness)) = search.check_reachability(input)
  assert witness.path == []
}
