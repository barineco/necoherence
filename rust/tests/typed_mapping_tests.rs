// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]
//! Integration checks for `necoherence::typed_mapping`: only the
//! public module through the crate root, no copied solver logic.
//! Fixtures mirror the Lean typed mapping solver test.

use necoherence::typed_mapping::{
    apply_consumption, derive_enabled, tokens_at, BindingMode, ColoredToken, DeclarationGraph,
    DomainBound, EnabledResult, EnabledSet, EnabledTransition, GoalPredicate, InputBinding,
    Marking, SolverInput, TokenKind, TypedPlace, TypedTransition,
};
use necoherence::Nat;

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

/// `derive_enabled` reports `T-RUN` enabled at the ready marking.
#[test]
fn derive_enabled_reports_run_enabled() {
    let expected = EnabledResult::EnabledSet(EnabledSet {
        enabled: vec![EnabledTransition {
            transition_id: s("T-RUN"),
            bindings: vec![binding_run()],
        }],
    });
    assert_eq!(derive_enabled(&input_ready()), Ok(expected));
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

/// A `Consume` binding with multiplicity one removes exactly one
/// occurrence of a duplicated token, retaining the second.
#[test]
fn consume_removes_only_selected_occurrences() {
    let marking = Marking {
        places: vec![(s("P-DUP"), vec![in_tok("job-d"), in_tok("job-d")])],
    };
    let bindings = vec![bind("T-D", "bd", "P-DUP", "job-d", BindingMode::Consume)];
    let after = apply_consumption(&marking, &bindings);
    assert_eq!(tokens_at(&after, "P-DUP"), &[in_tok("job-d")]);
}
