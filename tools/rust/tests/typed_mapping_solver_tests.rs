// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(clippy::panic)]

use necoherence::typed_mapping::{
    derive_enabled, BindingMode, ColoredToken, DeadlockResult, DeadlockWitness, DeclarationGraph,
    DomainBound, EnabledResult, EnabledSet, EnabledTransition, GoalPredicate, InputBinding,
    InvalidReason, Marking, ReachabilityResult, ReachabilityWitness, SolverInput, TokenKind,
    TypedPlace, TypedTransition, UnknownReason, WellFoundednessResult,
};
use necoherence::Nat;
use necoherence_tools::typed_mapping_solver::{
    check_deadlock, check_reachability, check_well_foundedness,
};

fn nat(n: u64) -> Nat {
    Nat::from(n)
}

fn s(text: &str) -> String {
    text.to_string()
}

fn place_ready() -> TypedPlace {
    TypedPlace {
        identity: s("P-READY"),
        token_type: s("T-JOB"),
        revision: nat(1),
    }
}

fn place_done() -> TypedPlace {
    TypedPlace {
        identity: s("P-DONE"),
        token_type: s("T-JOB"),
        revision: nat(1),
    }
}

fn t_run() -> TypedTransition {
    TypedTransition {
        identity: s("T-RUN"),
        input_places: vec![s("P-READY")],
        output_places: vec![s("P-DONE")],
        failure_places: vec![],
        revision: nat(1),
    }
}

fn binding_run() -> InputBinding {
    InputBinding {
        transition_id: s("T-RUN"),
        name: s("job"),
        place: s("P-READY"),
        token_type: s("T-JOB"),
        identity: s("job-1"),
        provenance: s("test"),
        multiplicity: nat(1),
        mode: BindingMode::Consume,
        required_revision: nat(1),
    }
}

fn tok_job() -> ColoredToken {
    ColoredToken {
        target: s("job-1"),
        index: nat(0),
        revision: nat(1),
        kind: TokenKind::Input,
    }
}

fn marking_ready() -> Marking {
    Marking {
        places: vec![(s("P-READY"), vec![tok_job()]), (s("P-DONE"), vec![])],
    }
}

fn bound_small() -> DomainBound {
    DomainBound {
        target_identity: s("unit:typed-mapping-solver"),
        index: nat(0),
        revision: nat(1),
        max_bindings: nat(10),
        max_search_steps: nat(10),
    }
}

fn graph_simple() -> DeclarationGraph {
    DeclarationGraph {
        places: vec![s("P-READY"), s("P-DONE")],
        transitions: vec![s("T-RUN")],
        edges: vec![(s("P-READY"), s("P-DONE"))],
        revision: nat(1),
    }
}

fn input_ready() -> SolverInput {
    SolverInput {
        places: vec![place_ready(), place_done()],
        transitions: vec![t_run()],
        bindings: vec![binding_run()],
        goal: GoalPredicate::PlaceHasAtLeast {
            place: s("P-DONE"),
            count: nat(1),
        },
        graph: graph_simple(),
        marking: marking_ready(),
        bound: bound_small(),
    }
}

#[test]
fn check_reachability_finds_goal_by_firing_run() {
    let produced = ColoredToken {
        target: s("T-RUN"),
        index: nat(0),
        revision: nat(1),
        kind: TokenKind::Output,
    };
    let expected = ReachabilityResult::Reachable(ReachabilityWitness {
        path: vec![s("T-RUN")],
        final_marking: Marking {
            places: vec![(s("P-READY"), vec![]), (s("P-DONE"), vec![produced])],
        },
    });
    assert_eq!(check_reachability(&input_ready()), Ok(expected));
}

#[test]
fn check_deadlock_reports_deadlocked_on_empty_marking() {
    let mut input = input_ready();
    input.marking = Marking {
        places: vec![(s("P-READY"), vec![]), (s("P-DONE"), vec![])],
    };
    let expected = DeadlockResult::Deadlocked(DeadlockWitness {
        marking: input.marking.clone(),
    });
    assert_eq!(check_deadlock(&input), Ok(expected));
}

#[test]
fn check_well_foundedness_reports_acyclic_graph_well_founded() {
    match check_well_foundedness(&input_ready()) {
        Ok(WellFoundednessResult::WellFounded(witness)) => {
            assert_eq!(witness.explored_markings.len(), 2);
            assert_eq!(witness.steps, nat(2));
            assert!(witness.frontier.is_empty());
        }
        other => panic!("expected acyclic witness, got {other:?}"),
    }
}

#[test]
fn invalid_binding_reports_invalid_result() {
    let mut input = input_ready();
    input.bindings = vec![InputBinding {
        token_type: s("T-OTHER"),
        ..binding_run()
    }];
    let expected = EnabledResult::Invalid(InvalidReason::TypeMismatch {
        place: s("P-READY"),
        expected: s("T-OTHER"),
        actual: s("T-JOB"),
    });
    assert_eq!(derive_enabled(&input), Ok(expected));
    assert_eq!(
        check_reachability(&input),
        Ok(ReachabilityResult::Invalid(InvalidReason::TypeMismatch {
            place: s("P-READY"),
            expected: s("T-OTHER"),
            actual: s("T-JOB"),
        }))
    );
}

#[test]
fn unreachable_goal_carries_closure_witness() {
    let mut input = input_ready();
    input.goal = GoalPredicate::PlaceHasAtLeast {
        place: s("P-DONE"),
        count: nat(2),
    };
    match check_reachability(&input) {
        Ok(ReachabilityResult::Unreachable(witness)) => {
            assert_eq!(witness.steps, nat(2));
            assert_eq!(witness.explored_markings.len(), 2);
        }
        other => panic!("expected unreachable, got {other:?}"),
    }
}

#[test]
fn bound_exhaustion_reports_unknown() {
    let mut input = input_ready();
    input.bound.max_search_steps = nat(0);
    assert_eq!(
        check_reachability(&input),
        Ok(ReachabilityResult::Unknown(
            UnknownReason::SearchStepBoundExhausted(nat(0))
        ))
    );
    assert_eq!(
        check_well_foundedness(&input),
        Ok(WellFoundednessResult::Unknown(
            UnknownReason::SearchStepBoundExhausted(nat(0))
        ))
    );
}

#[test]
fn non_decreasing_cycle_reports_not_well_founded() {
    let p_a = TypedPlace {
        identity: s("P-A"),
        token_type: s("T-JOB"),
        revision: nat(1),
    };
    let p_b = TypedPlace {
        identity: s("P-B"),
        token_type: s("T-JOB"),
        revision: nat(1),
    };
    let t1 = TypedTransition {
        identity: s("T-1"),
        input_places: vec![s("P-A")],
        output_places: vec![s("P-B")],
        failure_places: vec![],
        revision: nat(1),
    };
    let t2 = TypedTransition {
        identity: s("T-2"),
        input_places: vec![s("P-B")],
        output_places: vec![s("P-A")],
        failure_places: vec![],
        revision: nat(1),
    };
    let b1 = InputBinding {
        transition_id: s("T-1"),
        name: s("in"),
        place: s("P-A"),
        token_type: s("T-JOB"),
        identity: s("T-2"),
        provenance: s("test"),
        multiplicity: nat(1),
        mode: BindingMode::Consume,
        required_revision: nat(1),
    };
    let b2 = InputBinding {
        transition_id: s("T-2"),
        name: s("in"),
        place: s("P-B"),
        token_type: s("T-JOB"),
        identity: s("T-1"),
        provenance: s("test"),
        multiplicity: nat(1),
        mode: BindingMode::Consume,
        required_revision: nat(1),
    };
    let seed = ColoredToken {
        target: s("T-2"),
        index: nat(0),
        revision: nat(1),
        kind: TokenKind::Output,
    };
    let input = SolverInput {
        places: vec![p_a, p_b],
        transitions: vec![t1, t2],
        bindings: vec![b1, b2],
        goal: GoalPredicate::PlaceHasAtLeast {
            place: s("P-B"),
            count: nat(5),
        },
        graph: DeclarationGraph {
            places: vec![s("P-A"), s("P-B")],
            transitions: vec![s("T-1"), s("T-2")],
            edges: vec![
                (s("P-A"), s("T-1")),
                (s("T-1"), s("P-B")),
                (s("P-B"), s("T-2")),
                (s("T-2"), s("P-A")),
            ],
            revision: nat(1),
        },
        marking: Marking {
            places: vec![(s("P-A"), vec![seed]), (s("P-B"), vec![])],
        },
        bound: bound_small(),
    };
    match check_well_foundedness(&input) {
        Ok(WellFoundednessResult::NotWellFounded(witness)) => {
            assert!(witness.prefix_path.is_empty());
            assert_eq!(witness.cycle_path, vec![s("T-1"), s("T-2")]);
            assert_eq!(witness.cycle_start, witness.cycle_end);
            assert!(!witness.measure_decreasing);
        }
        other => panic!("expected cycle witness, got {other:?}"),
    }
}

fn place_of(id: &str) -> TypedPlace {
    TypedPlace {
        identity: s(id),
        token_type: s("T-JOB"),
        revision: nat(1),
    }
}

fn in_tok(target: &str) -> ColoredToken {
    ColoredToken {
        target: s(target),
        index: nat(0),
        revision: nat(1),
        kind: TokenKind::Input,
    }
}

fn bind(tid: &str, name: &str, place: &str, ident: &str, mode: BindingMode) -> InputBinding {
    InputBinding {
        transition_id: s(tid),
        name: s(name),
        place: s(place),
        token_type: s("T-JOB"),
        identity: s(ident),
        provenance: s("test"),
        multiplicity: nat(1),
        mode,
        required_revision: nat(1),
    }
}

fn conv_transitions() -> Vec<TypedTransition> {
    vec![
        TypedTransition {
            identity: s("T-A"),
            input_places: vec![s("P-SRC"), s("P-X"), s("P-S")],
            output_places: vec![s("P-A")],
            failure_places: vec![],
            revision: nat(1),
        },
        TypedTransition {
            identity: s("T-B"),
            input_places: vec![s("P-SRC"), s("P-X"), s("P-S")],
            output_places: vec![s("P-B")],
            failure_places: vec![],
            revision: nat(1),
        },
        TypedTransition {
            identity: s("T-AX"),
            input_places: vec![s("P-SRC"), s("P-X"), s("P-A")],
            output_places: vec![],
            failure_places: vec![],
            revision: nat(1),
        },
        TypedTransition {
            identity: s("T-BC"),
            input_places: vec![s("P-SRC"), s("P-X"), s("P-B")],
            output_places: vec![s("P-C")],
            failure_places: vec![],
            revision: nat(1),
        },
        TypedTransition {
            identity: s("T-CX"),
            input_places: vec![s("P-SRC"), s("P-X"), s("P-C")],
            output_places: vec![],
            failure_places: vec![],
            revision: nat(1),
        },
    ]
}

fn conv_bindings() -> Vec<InputBinding> {
    vec![
        bind("T-A", "ba-src", "P-SRC", "job-1", BindingMode::Read),
        bind("T-A", "ba-x", "P-X", "job-2", BindingMode::Read),
        bind("T-A", "ba-s", "P-S", "job-3", BindingMode::Consume),
        bind("T-B", "bb-src", "P-SRC", "job-1", BindingMode::Read),
        bind("T-B", "bb-x", "P-X", "job-2", BindingMode::Read),
        bind("T-B", "bb-s", "P-S", "job-3", BindingMode::Consume),
        bind("T-AX", "bax-src", "P-SRC", "job-1", BindingMode::Read),
        bind("T-AX", "bax-x", "P-X", "job-2", BindingMode::Read),
        bind("T-AX", "bax-a", "P-A", "T-A", BindingMode::Consume),
        bind("T-BC", "bbc-src", "P-SRC", "job-1", BindingMode::Read),
        bind("T-BC", "bbc-x", "P-X", "job-2", BindingMode::Read),
        bind("T-BC", "bbc-b", "P-B", "T-B", BindingMode::Consume),
        bind("T-CX", "bcx-src", "P-SRC", "job-1", BindingMode::Read),
        bind("T-CX", "bcx-x", "P-X", "job-2", BindingMode::Read),
        bind("T-CX", "bcx-c", "P-C", "T-BC", BindingMode::Consume),
    ]
}

fn conv_marking() -> Marking {
    Marking {
        places: vec![
            (s("P-SRC"), vec![in_tok("job-1")]),
            (s("P-X"), vec![in_tok("job-2")]),
            (s("P-S"), vec![in_tok("job-3")]),
            (s("P-A"), vec![]),
            (s("P-B"), vec![]),
            (s("P-C"), vec![]),
        ],
    }
}

fn input_conv() -> SolverInput {
    SolverInput {
        places: ["P-SRC", "P-X", "P-S", "P-A", "P-B", "P-C", "P-Z"]
            .into_iter()
            .map(place_of)
            .collect(),
        transitions: conv_transitions(),
        bindings: conv_bindings(),
        goal: GoalPredicate::PlaceHasAtLeast {
            place: s("P-Z"),
            count: nat(1),
        },
        graph: DeclarationGraph {
            places: vec![
                s("P-SRC"),
                s("P-X"),
                s("P-S"),
                s("P-A"),
                s("P-B"),
                s("P-C"),
                s("P-Z"),
            ],
            transitions: vec![s("T-A"), s("T-B"), s("T-AX"), s("T-BC"), s("T-CX")],
            edges: vec![],
            revision: nat(1),
        },
        marking: conv_marking(),
        bound: DomainBound {
            target_identity: s("unit:typed-mapping-solver"),
            index: nat(0),
            revision: nat(1),
            max_bindings: nat(20),
            max_search_steps: nat(20),
        },
    }
}

#[test]
fn convergent_dag_is_well_founded() {
    match check_well_foundedness(&input_conv()) {
        Ok(WellFoundednessResult::WellFounded(witness)) => {
            assert_eq!(witness.explored_markings.len(), 5);
            assert_eq!(witness.steps, nat(5));
            assert!(witness.frontier.is_empty());
        }
        other => panic!("expected acyclic witness, got {other:?}"),
    }
}

#[test]
fn closure_witness_records_distinct_markings() {
    match check_reachability(&input_conv()) {
        Ok(ReachabilityResult::Unreachable(witness)) => {
            assert_eq!(witness.explored_markings.len(), 5);
            assert_eq!(witness.steps, nat(5));
            assert!(witness.frontier.is_empty());
            let mut seen: Vec<Marking> = Vec::new();
            for m in &witness.explored_markings {
                assert!(
                    !seen.contains(m),
                    "duplicate marking in closure witness: {m:?}"
                );
                seen.push(m.clone());
            }
        }
        other => panic!("expected unreachable, got {other:?}"),
    }
}

#[test]
fn binding_bound_exhaustion_reports_unknown() {
    let mut input = input_ready();
    input.bound.max_bindings = nat(0);
    assert_eq!(
        check_reachability(&input),
        Ok(ReachabilityResult::Unknown(
            UnknownReason::BindingBoundExhausted(nat(0))
        ))
    );
    assert_eq!(
        check_deadlock(&input),
        Ok(DeadlockResult::Unknown(
            UnknownReason::BindingBoundExhausted(nat(0))
        ))
    );
    assert_eq!(
        check_well_foundedness(&input),
        Ok(WellFoundednessResult::Unknown(
            UnknownReason::BindingBoundExhausted(nat(0))
        ))
    );
}

#[test]
fn undeclared_output_place_is_invalid() {
    let mut input = input_ready();
    input.transitions = vec![TypedTransition {
        identity: s("T-BAD-OUT"),
        input_places: vec![],
        output_places: vec![s("P-GHOST")],
        failure_places: vec![],
        revision: nat(1),
    }];
    input.bindings = vec![];
    input.graph = DeclarationGraph {
        places: vec![s("P-READY"), s("P-DONE")],
        transitions: vec![s("T-BAD-OUT")],
        edges: vec![],
        revision: nat(1),
    };
    assert_eq!(
        check_reachability(&input),
        Ok(ReachabilityResult::Invalid(
            InvalidReason::DependencyMismatch {
                transition_id: s("T-BAD-OUT"),
                place: s("P-GHOST"),
            }
        ))
    );
}

#[test]
fn undeclared_failure_place_is_invalid() {
    let mut input = input_ready();
    input.transitions = vec![TypedTransition {
        identity: s("T-BAD-FAIL"),
        input_places: vec![],
        output_places: vec![],
        failure_places: vec![s("P-GHOST-F")],
        revision: nat(1),
    }];
    input.bindings = vec![];
    input.graph = DeclarationGraph {
        places: vec![s("P-READY"), s("P-DONE")],
        transitions: vec![s("T-BAD-FAIL")],
        edges: vec![],
        revision: nat(1),
    };
    assert_eq!(
        check_reachability(&input),
        Ok(ReachabilityResult::Invalid(
            InvalidReason::DependencyMismatch {
                transition_id: s("T-BAD-FAIL"),
                place: s("P-GHOST-F"),
            }
        ))
    );
}

#[test]
fn unknown_input_place_invalidates_every_operation() {
    let mut input = input_ready();
    let mut transition = t_run();
    transition.input_places = vec![s("P-GHOST")];
    input.transitions = vec![transition];
    let reason = InvalidReason::UnknownInputPlace {
        transition_id: s("T-RUN"),
        place: s("P-GHOST"),
    };
    assert_eq!(
        derive_enabled(&input),
        Ok(EnabledResult::Invalid(reason.clone()))
    );
    assert_eq!(
        check_reachability(&input),
        Ok(ReachabilityResult::Invalid(reason.clone()))
    );
    assert_eq!(
        check_deadlock(&input),
        Ok(DeadlockResult::Invalid(reason.clone()))
    );
    assert_eq!(
        check_well_foundedness(&input),
        Ok(WellFoundednessResult::Invalid(reason))
    );
}

#[test]
fn missing_input_binding_invalidates_every_operation() {
    let mut input = input_ready();
    input.bindings.clear();
    let reason = InvalidReason::MissingInputBinding {
        transition_id: s("T-RUN"),
        place: s("P-READY"),
    };
    assert_eq!(
        derive_enabled(&input),
        Ok(EnabledResult::Invalid(reason.clone()))
    );
    assert_eq!(
        check_reachability(&input),
        Ok(ReachabilityResult::Invalid(reason.clone()))
    );
    assert_eq!(
        check_deadlock(&input),
        Ok(DeadlockResult::Invalid(reason.clone()))
    );
    assert_eq!(
        check_well_foundedness(&input),
        Ok(WellFoundednessResult::Invalid(reason))
    );
}

#[test]
fn duplicate_transition_identity_invalidates_every_operation() {
    let mut input = input_ready();
    input.transitions.push(t_run());
    let reason = InvalidReason::DuplicateTransitionIdentity(s("T-RUN"));
    assert_eq!(
        derive_enabled(&input),
        Ok(EnabledResult::Invalid(reason.clone()))
    );
    assert_eq!(
        check_reachability(&input),
        Ok(ReachabilityResult::Invalid(reason.clone()))
    );
    assert_eq!(
        check_deadlock(&input),
        Ok(DeadlockResult::Invalid(reason.clone()))
    );
    assert_eq!(
        check_well_foundedness(&input),
        Ok(WellFoundednessResult::Invalid(reason))
    );
}

#[test]
fn zero_input_source_transition_remains_valid() {
    let mut input = input_ready();
    input.transitions = vec![TypedTransition {
        identity: s("T-SOURCE"),
        input_places: vec![],
        output_places: vec![s("P-DONE")],
        failure_places: vec![],
        revision: nat(1),
    }];
    input.bindings.clear();
    input.graph = DeclarationGraph {
        places: vec![s("P-READY"), s("P-DONE")],
        transitions: vec![s("T-SOURCE")],
        edges: vec![],
        revision: nat(1),
    };
    assert_eq!(
        derive_enabled(&input),
        Ok(EnabledResult::EnabledSet(EnabledSet {
            enabled: vec![EnabledTransition {
                transition_id: s("T-SOURCE"),
                bindings: vec![],
            }],
        }))
    );
    assert!(matches!(
        check_reachability(&input),
        Ok(ReachabilityResult::Reachable(ReachabilityWitness { path, .. }))
            if path == vec![s("T-SOURCE")]
    ));
}

#[test]
fn initial_goal_is_reachable_with_zero_search_steps() {
    let mut input = input_ready();
    input.goal = GoalPredicate::PlaceHasAtLeast {
        place: s("P-READY"),
        count: nat(1),
    };
    input.bound.max_search_steps = nat(0);
    assert_eq!(
        check_reachability(&input),
        Ok(ReachabilityResult::Reachable(ReachabilityWitness {
            path: vec![],
            final_marking: input.marking.clone(),
        }))
    );
}

#[test]
fn additive_then_consuming_cycle_is_not_well_founded_even_when_closing_measure_decreases() {
    let p_a = place_of("P-A");
    let p_b = place_of("P-B");
    let transitions = vec![
        TypedTransition {
            identity: s("T-A"),
            input_places: vec![s("P-A")],
            output_places: vec![s("P-B")],
            failure_places: vec![],
            revision: nat(1),
        },
        TypedTransition {
            identity: s("T-B"),
            input_places: vec![s("P-B")],
            output_places: vec![],
            failure_places: vec![],
            revision: nat(1),
        },
    ];
    let input = SolverInput {
        places: vec![p_a, p_b],
        transitions,
        bindings: vec![
            bind("T-A", "source", "P-A", "seed", BindingMode::Read),
            bind("T-B", "added", "P-B", "T-A", BindingMode::Consume),
        ],
        goal: GoalPredicate::PlaceHasAtLeast {
            place: s("P-A"),
            count: nat(5),
        },
        graph: DeclarationGraph {
            places: vec![s("P-A"), s("P-B")],
            transitions: vec![s("T-A"), s("T-B")],
            edges: vec![],
            revision: nat(1),
        },
        marking: Marking {
            places: vec![(s("P-A"), vec![in_tok("seed")]), (s("P-B"), vec![])],
        },
        bound: bound_small(),
    };
    match check_well_foundedness(&input) {
        Ok(WellFoundednessResult::NotWellFounded(witness)) => {
            assert_eq!(witness.prefix_path, Vec::<String>::new());
            assert_eq!(witness.cycle_path, vec![s("T-A"), s("T-B")]);
            assert_eq!(witness.cycle_start, witness.cycle_end);
            assert!(witness.measure_decreasing);
        }
        other => panic!("expected decreasing-closing cycle, got {other:?}"),
    }
}
