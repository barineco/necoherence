// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(clippy::panic)]

use necoherence::semantic_composition::WitnessFailure;
use necoherence::typed_mapping::{
    BindingMode, ClosureWitness, ColoredToken, DeclarationGraph, DomainBound, GoalPredicate,
    InputBinding, Marking, SolverInput, TokenKind, TypedPlace, TypedTransition,
};
use necoherence::Nat;
use necoherence_composition_solver::composition_search::verify_closure_witness;

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

fn forged_closure(reason: &str) -> WitnessFailure {
    WitnessFailure::ForgedClosure(reason.to_owned())
}

fn closure(
    input: &SolverInput,
    markings: Vec<Marking>,
    steps: u64,
    frontier: Vec<Marking>,
) -> Option<WitnessFailure> {
    verify_closure_witness(
        input,
        &ClosureWitness {
            explored_markings: markings,
            steps: nat(steps),
            frontier,
        },
    )
    .err()
}

#[test]
fn closure_checks_follow_the_lean_order() {
    let input = run_input(5);
    assert_eq!(closure(&input, vec![ready(), done()], 2, vec![]), None);
    assert_eq!(
        closure(&input, vec![ready(), done()], 2, vec![done()]),
        Some(forged_closure("frontier, steps, or resource bound"))
    );
    assert_eq!(
        closure(&input, vec![ready(), done()], 1, vec![]),
        Some(forged_closure("frontier, steps, or resource bound"))
    );
    assert_eq!(
        closure(&input, vec![done()], 1, vec![]),
        Some(forged_closure("initial marking omitted"))
    );
    assert_eq!(
        closure(&input, vec![ready(), ready()], 2, vec![]),
        Some(forged_closure("duplicated explored marking"))
    );
    assert_eq!(
        closure(&input, vec![ready()], 1, vec![]),
        Some(forged_closure("enabled successor omitted"))
    );
    assert_eq!(
        closure(&run_input(1), vec![ready(), done()], 2, vec![]),
        Some(forged_closure("closed marking satisfies the goal"))
    );

    let mut bounded = run_input(5);
    bounded.bound.max_search_steps = nat(1);
    assert_eq!(
        closure(&bounded, vec![ready(), done()], 2, vec![]),
        Some(forged_closure("frontier, steps, or resource bound"))
    );

    let mut crowded = run_input(5);
    crowded.bound.max_bindings = nat(0);
    assert_eq!(
        closure(&crowded, vec![ready(), done()], 2, vec![]),
        Some(forged_closure("resource binding bound"))
    );

    let mut invalid = run_input(5);
    invalid.graph.places.push("P-UNDECLARED".to_owned());
    assert_eq!(
        closure(&invalid, vec![ready(), done()], 2, vec![]),
        Some(forged_closure("invalid resource declaration"))
    );
}
