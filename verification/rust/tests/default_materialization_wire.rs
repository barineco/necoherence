// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use necoherence::exact_json::JsonValue;
use necoherence_verification::default_materialization_wire::{check_wire_text, WireTextFailure};

fn dec(text: &str) -> JsonValue {
    JsonValue::Dec(text.into())
}

fn object(members: Vec<(&str, JsonValue)>) -> JsonValue {
    JsonValue::Obj(
        members
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

#[test]
fn a_wire_decimal_spells_the_same_as_the_exact_decimal_of_another_text() {
    let before = object(vec![("ten", dec("10.0")), ("one", dec("1.0"))]);
    assert_eq!(
        check_wire_text(&before, r#"{"ten":10.0,"one":1.0}"#),
        Ok(())
    );
    let short = object(vec![("ten", dec("10"))]);
    assert_eq!(check_wire_text(&short, r#"{"ten":10.0}"#), Ok(()));
}

#[test]
fn a_wire_integer_does_not_spell_an_exact_decimal() {
    let before = object(vec![("ten", dec("10.0"))]);
    assert_eq!(
        check_wire_text(&before, r#"{"ten":10}"#),
        Err(WireTextFailure::Differs)
    );
}

#[test]
fn the_order_of_wire_members_does_not_matter() {
    let before = object(vec![
        ("a", JsonValue::Num(2.into())),
        ("b", JsonValue::Num(1.into())),
    ]);
    assert_eq!(check_wire_text(&before, r#"{"b":1,"a":2}"#), Ok(()));
}

#[test]
fn a_duplicate_key_in_the_wire_text_is_a_syntax_failure() {
    let before = object(vec![]);
    assert_eq!(
        check_wire_text(&before, r#"{"ten":10.0,"ten":1.0}"#),
        Err(WireTextFailure::Syntax)
    );
    assert_eq!(
        check_wire_text(&before, r#"{"child":{"flag":true,"flag":false}}"#),
        Err(WireTextFailure::Syntax)
    );
    assert_eq!(
        check_wire_text(&before, r#"{"flag":true,"\u0066lag":false}"#),
        Err(WireTextFailure::Syntax)
    );
}

#[test]
fn a_duplicate_key_in_the_exact_input_is_a_duplicate_field_before_the_wire_text_is_read() {
    let before = object(vec![
        ("flag", JsonValue::Bool(false)),
        ("flag", JsonValue::Bool(true)),
    ]);
    assert_eq!(
        check_wire_text(&before, "{"),
        Err(WireTextFailure::DuplicateField)
    );
}

#[test]
fn an_unadmitted_wire_text_is_a_syntax_failure() {
    let before = JsonValue::Null;
    assert_eq!(check_wire_text(&before, "{"), Err(WireTextFailure::Syntax));
    assert_eq!(
        check_wire_text(&before, "1e10000"),
        Err(WireTextFailure::Syntax)
    );
    assert_eq!(
        check_wire_text(&before, r#""\ud800""#),
        Err(WireTextFailure::Syntax)
    );
}
