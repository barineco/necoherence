// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

//! Searches a typed transition model, then checks the returned witnesses.

use std::io::Write;

use necoherence::resource_witness::verify_reachability_witness;
use necoherence::typed_mapping::{
    BindingMode, ColoredToken, DeclarationGraph, DomainBound, GoalPredicate, InputBinding, Marking,
    ReachabilityResult, SolverInput, TokenKind, TypedPlace, TypedTransition,
};
use necoherence::Nat;
use necoherence_composition_solver::composition_search::verify_closure_witness;
use necoherence_solver::typed_mapping_solver::check_reachability;

fn place(identity: &str) -> TypedPlace {
    TypedPlace {
        identity: identity.to_owned(),
        token_type: "job".to_owned(),
        revision: Nat::from(1u64),
    }
}

fn model(required_done: u64) -> SolverInput {
    SolverInput {
        places: vec![place("ready"), place("done")],
        transitions: vec![TypedTransition {
            identity: "run".to_owned(),
            input_places: vec!["ready".to_owned()],
            output_places: vec!["done".to_owned()],
            failure_places: vec![],
            revision: Nat::from(1u64),
        }],
        bindings: vec![InputBinding {
            transition_id: "run".to_owned(),
            name: "job".to_owned(),
            place: "ready".to_owned(),
            token_type: "job".to_owned(),
            identity: "job-1".to_owned(),
            provenance: "example".to_owned(),
            multiplicity: Nat::from(1u64),
            mode: BindingMode::Consume,
            required_revision: Nat::from(1u64),
        }],
        goal: GoalPredicate::PlaceHasAtLeast {
            place: "done".to_owned(),
            count: Nat::from(required_done),
        },
        graph: DeclarationGraph {
            places: vec!["ready".to_owned(), "done".to_owned()],
            transitions: vec!["run".to_owned()],
            edges: vec![("ready".to_owned(), "done".to_owned())],
            revision: Nat::from(1u64),
        },
        marking: Marking {
            places: vec![
                (
                    "ready".to_owned(),
                    vec![ColoredToken {
                        target: "job-1".to_owned(),
                        index: Nat::from(0u64),
                        revision: Nat::from(1u64),
                        kind: TokenKind::Input,
                    }],
                ),
                ("done".to_owned(), vec![]),
            ],
        },
        bound: DomainBound {
            target_identity: "example".to_owned(),
            index: Nat::from(0u64),
            revision: Nat::from(1u64),
            max_bindings: Nat::from(10u64),
            max_search_steps: Nat::from(10u64),
        },
    }
}

fn report(input: &SolverInput) -> Result<String, String> {
    match check_reachability(input).map_err(|failure| format!("{failure:?}"))? {
        ReachabilityResult::Reachable(witness) => verify_reachability_witness(input, &witness)
            .map(|_| format!("reachable by {:?}", witness.path))
            .map_err(|failure| format!("{failure:?}")),
        ReachabilityResult::Unreachable(witness) => verify_closure_witness(input, &witness)
            .map(|_| {
                format!(
                    "unreachable; closure of {} markings",
                    witness.explored_markings.len()
                )
            })
            .map_err(|failure| format!("{failure:?}")),
        other => Err(format!("{other:?}")),
    }
}

fn main() -> Result<(), String> {
    let text = format!("{}\n{}\n", report(&model(1))?, report(&model(2))?);
    std::io::stdout()
        .lock()
        .write_all(text.as_bytes())
        .map_err(|failure| failure.to_string())
}
