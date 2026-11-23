// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]

use necoherence::typed_mapping::{
    apply_consumption, tokens_at, BindingMode, ColoredToken, InputBinding, Marking, TokenKind,
};
use necoherence::Nat;

fn nat(n: u64) -> Nat {
    Nat::from(n)
}

fn s(text: &str) -> String {
    text.to_string()
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

fn token_color_preserved(before: &[ColoredToken], after: &[ColoredToken]) -> bool {
    after.iter().all(|t| before.contains(t))
}

#[test]
fn consume_removes_only_selected_occurrences() {
    let marking = Marking {
        places: vec![(s("P-DUP"), vec![in_tok("job-d"), in_tok("job-d")])],
    };
    let bindings = vec![bind("T-D", "bd", "P-DUP", "job-d", BindingMode::Consume)];
    let after = apply_consumption(marking.clone(), &bindings);
    assert_eq!(tokens_at(&after, "P-DUP"), &[in_tok("job-d")]);
}

#[test]
fn consumption_preserves_the_token_colors_of_its_place() {
    let marking = Marking {
        places: vec![(s("P-DUP"), vec![in_tok("job-d"), in_tok("job-d")])],
    };
    let bindings = vec![bind("T-D", "bd", "P-DUP", "job-d", BindingMode::Consume)];
    let after = apply_consumption(marking.clone(), &bindings);
    assert!(token_color_preserved(
        tokens_at(&marking, "P-DUP"),
        tokens_at(&after, "P-DUP")
    ));
}
