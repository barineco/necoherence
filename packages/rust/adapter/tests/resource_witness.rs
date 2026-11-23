// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]

use necoherence::resource_witness::{
    verify_acyclic_witness, verify_finite_closure, verify_reachability_witness,
};
use necoherence::semantic_composition::WitnessFailure;
use necoherence::typed_mapping::{
    path_replay, step_at, AcyclicWitness, BindingMode, ColoredToken, DeclarationGraph, DomainBound,
    GoalPredicate, InputBinding, Marking, ReachabilityWitness, SolverInput, TokenKind, TypedPlace,
    TypedTransition,
};
use necoherence::Nat;

fn nat(value: u64) -> Nat {
    Nat::from(value)
}

fn token(target: &str) -> ColoredToken {
    ColoredToken {
        target: target.to_owned(),
        index: nat(0),
        revision: nat(1),
        kind: TokenKind::Input,
    }
}

fn ready() -> Marking {
    Marking {
        places: vec![
            ("P-READY".to_owned(), vec![token("job-1")]),
            ("P-DONE".to_owned(), vec![]),
        ],
    }
}

fn done() -> Marking {
    Marking {
        places: vec![
            ("P-READY".to_owned(), vec![]),
            (
                "P-DONE".to_owned(),
                vec![ColoredToken {
                    target: "T-RUN".to_owned(),
                    index: nat(0),
                    revision: nat(1),
                    kind: TokenKind::Output,
                }],
            ),
        ],
    }
}

fn empty() -> Marking {
    Marking {
        places: vec![
            ("P-READY".to_owned(), vec![]),
            ("P-DONE".to_owned(), vec![]),
        ],
    }
}

fn run_input(goal: u64) -> SolverInput {
    SolverInput {
        places: vec![
            TypedPlace {
                identity: "P-READY".to_owned(),
                token_type: "T-JOB".to_owned(),
                revision: nat(1),
            },
            TypedPlace {
                identity: "P-DONE".to_owned(),
                token_type: "T-JOB".to_owned(),
                revision: nat(1),
            },
        ],
        transitions: vec![TypedTransition {
            identity: "T-RUN".to_owned(),
            input_places: vec!["P-READY".to_owned()],
            output_places: vec!["P-DONE".to_owned()],
            failure_places: vec![],
            revision: nat(1),
        }],
        bindings: vec![InputBinding {
            transition_id: "T-RUN".to_owned(),
            name: "job".to_owned(),
            place: "P-READY".to_owned(),
            token_type: "T-JOB".to_owned(),
            identity: "job-1".to_owned(),
            provenance: "test".to_owned(),
            multiplicity: nat(1),
            mode: BindingMode::Consume,
            required_revision: nat(1),
        }],
        goal: GoalPredicate::PlaceHasAtLeast {
            place: "P-DONE".to_owned(),
            count: nat(goal),
        },
        graph: DeclarationGraph {
            places: vec!["P-READY".to_owned(), "P-DONE".to_owned()],
            transitions: vec!["T-RUN".to_owned()],
            edges: vec![("P-READY".to_owned(), "P-DONE".to_owned())],
            revision: nat(1),
        },
        marking: ready(),
        bound: DomainBound {
            target_identity: "unit".to_owned(),
            index: nat(0),
            revision: nat(1),
            max_bindings: nat(10),
            max_search_steps: nat(10),
        },
    }
}

fn loop_input() -> SolverInput {
    let marking = Marking {
        places: vec![("P".to_owned(), vec![token("token")])],
    };
    SolverInput {
        places: vec![TypedPlace {
            identity: "P".to_owned(),
            token_type: "T".to_owned(),
            revision: nat(1),
        }],
        transitions: vec![TypedTransition {
            identity: "LOOP".to_owned(),
            input_places: vec!["P".to_owned()],
            output_places: vec![],
            failure_places: vec![],
            revision: nat(1),
        }],
        bindings: vec![InputBinding {
            transition_id: "LOOP".to_owned(),
            name: "read".to_owned(),
            place: "P".to_owned(),
            token_type: "T".to_owned(),
            identity: "token".to_owned(),
            provenance: "test".to_owned(),
            multiplicity: nat(1),
            mode: BindingMode::Read,
            required_revision: nat(1),
        }],
        goal: GoalPredicate::PlaceHasAtLeast {
            place: "P".to_owned(),
            count: nat(2),
        },
        graph: DeclarationGraph {
            places: vec!["P".to_owned()],
            transitions: vec!["LOOP".to_owned()],
            edges: vec![
                ("P".to_owned(), "LOOP".to_owned()),
                ("LOOP".to_owned(), "P".to_owned()),
            ],
            revision: nat(1),
        },
        marking,
        bound: DomainBound {
            target_identity: "unit".to_owned(),
            index: nat(0),
            revision: nat(1),
            max_bindings: nat(10),
            max_search_steps: nat(10),
        },
    }
}

fn replay_mismatch(reason: &str) -> WitnessFailure {
    WitnessFailure::ResourceReplayMismatch(reason.to_owned())
}

fn forged_closure(reason: &str) -> WitnessFailure {
    WitnessFailure::ForgedClosure(reason.to_owned())
}

fn path_of(identity: &str) -> Vec<String> {
    vec![identity.to_owned()]
}

fn reachability(
    input: &SolverInput,
    path: Vec<String>,
    final_marking: Marking,
) -> Option<WitnessFailure> {
    verify_reachability_witness(
        input,
        &ReachabilityWitness {
            path,
            final_marking,
        },
    )
    .err()
}

fn acyclic(
    input: &SolverInput,
    markings: Vec<Marking>,
    steps: u64,
    frontier: Vec<Marking>,
) -> Option<WitnessFailure> {
    verify_acyclic_witness(
        input,
        &AcyclicWitness {
            explored_markings: markings,
            steps: nat(steps),
            frontier,
        },
    )
    .err()
}

#[test]
fn step_at_and_path_replay_follow_declared_transitions() {
    let input = run_input(1);
    assert_eq!(step_at(&input, &ready(), "T-RUN"), Some(done()));
    assert_eq!(step_at(&input, &done(), "T-RUN"), None);
    assert_eq!(step_at(&input, &ready(), "T-OTHER"), None);
    assert_eq!(path_replay(&input, &ready(), &[]), Some(ready()));
    assert_eq!(
        path_replay(&input, &ready(), &path_of("T-RUN")),
        Some(done())
    );
    assert_eq!(
        path_replay(&input, &ready(), &["T-RUN".to_owned(), "T-RUN".to_owned()]),
        None
    );
}

#[test]
fn reachability_checks_follow_the_lean_order() {
    let input = run_input(1);
    assert_eq!(reachability(&input, path_of("T-RUN"), done()), None);
    assert_eq!(
        reachability(&input, path_of("T-RUN"), ready()),
        Some(replay_mismatch("enabled path or final marking"))
    );
    assert_eq!(
        reachability(&input, path_of("T-OTHER"), done()),
        Some(replay_mismatch("enabled path or final marking"))
    );
    assert_eq!(
        reachability(&run_input(2), path_of("T-RUN"), done()),
        Some(replay_mismatch("terminal resource goal"))
    );

    let mut bounded = run_input(1);
    bounded.bound.max_search_steps = nat(0);
    assert_eq!(
        reachability(&bounded, path_of("T-RUN"), done()),
        Some(replay_mismatch("path step bound"))
    );

    let mut crowded = run_input(1);
    crowded.bound.max_bindings = nat(0);
    crowded.bound.max_search_steps = nat(0);
    assert_eq!(
        reachability(&crowded, path_of("T-RUN"), done()),
        Some(replay_mismatch("binding bound"))
    );

    let mut invalid = run_input(1);
    invalid.bound.max_bindings = nat(0);
    invalid.graph.places.push("P-UNDECLARED".to_owned());
    assert_eq!(
        reachability(&invalid, path_of("T-RUN"), done()),
        Some(replay_mismatch("invalid resource declaration"))
    );
}

#[test]
fn acyclic_witness_rejects_a_marking_that_reaches_itself() {
    let input = run_input(5);
    assert_eq!(acyclic(&input, vec![ready(), done()], 2, vec![]), None);
    assert_eq!(acyclic(&input, vec![done(), ready()], 2, vec![]), None);
    assert_eq!(
        acyclic(&input, vec![ready()], 1, vec![]),
        Some(forged_closure("enabled successor omitted"))
    );

    let looping = loop_input();
    let marking = looping.marking.clone();
    assert_eq!(
        acyclic(&looping, vec![marking], 1, vec![]),
        Some(WitnessFailure::ForgedAcyclicity(
            "closed resource graph contains a cycle".to_owned()
        ))
    );
}

#[test]
fn finite_closure_admits_a_marking_unreachable_from_the_initial_one() {
    let input = run_input(1);
    let markings = vec![ready(), done(), empty()];
    assert_eq!(
        verify_finite_closure(&input, &markings, &nat(3), &[]).err(),
        None
    );
    assert_eq!(
        verify_finite_closure(&input, &[ready(), empty()], &nat(2), &[]).err(),
        Some(forged_closure("enabled successor omitted"))
    );
}
