// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use necoherence::exact_json::{bounded_json_parse, decimal_spelling, JsonValue};

#[test]
fn a_decimal_text_is_read_with_the_canonical_text_that_drops_a_zero_fraction() {
    let value: JsonValue = bounded_json_parse("10.0").unwrap();
    assert_eq!(value, JsonValue::Dec("10".into()));
    let value: JsonValue = bounded_json_parse("0.0").unwrap();
    assert_eq!(value, JsonValue::Dec("0".into()));
}

#[test]
fn the_decimal_spelling_keeps_a_fraction_point_for_zero_and_integer_values() {
    let vectors = [
        ("0", "0.0"),
        ("0.0", "0.0"),
        ("-0.0", "0.0"),
        ("0e-100", "0.0"),
        ("10", "10.0"),
        ("10.0", "10.0"),
        ("1.0", "1.0"),
        ("-10.0", "-10.0"),
        ("1.50e1", "15.0"),
        ("100e-2", "1.0"),
        ("1.5", "1.5"),
        ("12345.6789e-2", "123.456789"),
        ("1e-100", "0.0000000001e-90"),
        ("1.5e-20", "0.00000000015e-10"),
    ];
    for (text, spelled) in vectors {
        assert_eq!(decimal_spelling(text).as_deref(), Some(spelled), "{text}");
    }
}

#[test]
fn a_decimal_serializes_with_its_spelling_and_an_integer_without_one() {
    assert_eq!(
        serde_json::to_string(&JsonValue::Dec("10".into())).unwrap(),
        "10.0"
    );
    assert_eq!(
        serde_json::to_string(&JsonValue::Dec("0".into())).unwrap(),
        "0.0"
    );
    assert_eq!(
        serde_json::to_string(&JsonValue::Dec("1.5".into())).unwrap(),
        "1.5"
    );
    assert_eq!(
        serde_json::to_string(&JsonValue::Num(10.into())).unwrap(),
        "10"
    );
}

#[test]
fn a_duplicate_key_at_any_depth_fails_the_text_entry() {
    assert!(bounded_json_parse(r#"{"ten":10.0,"ten":1.0}"#).is_err());
    assert!(bounded_json_parse(r#"{"child":{"flag":true,"flag":false}}"#).is_err());
    assert!(bounded_json_parse(r#"{"flag":true,"\u0066lag":false}"#).is_err());
    assert!(bounded_json_parse(r#"[{"y":1,"\u0079":2}]"#).is_err());
}

#[test]
fn members_whose_escaped_keys_differ_pass_the_text_entry() {
    let value = bounded_json_parse(r#"{"a":1,"\u0062":2}"#).unwrap();
    assert_eq!(
        value,
        JsonValue::Obj(vec![
            ("a".into(), JsonValue::Num(1.into())),
            ("b".into(), JsonValue::Num(2.into())),
        ])
    );
}

#[test]
fn an_admission_failure_is_reported_before_the_parse() {
    assert_eq!(
        bounded_json_parse("1e10000"),
        Err("exponent too large".to_owned())
    );
    assert_eq!(
        bounded_json_parse(r#""\ud800""#),
        Err("unpaired Unicode surrogate".to_owned())
    );
    assert!(bounded_json_parse("1e9999").is_ok());
}

#[test]
fn parsed_object_members_are_kept_in_key_order_as_the_lean_map_does() {
    assert_eq!(
        bounded_json_parse(r#"{"b":1,"a":2}"#),
        Ok(JsonValue::Obj(vec![
            ("a".into(), JsonValue::Num(2.into())),
            ("b".into(), JsonValue::Num(1.into())),
        ]))
    );
}

#[test]
fn object_members_compare_as_a_key_map_regardless_of_their_order() {
    assert_eq!(
        JsonValue::Obj(vec![
            ("a".into(), JsonValue::Num(1.into())),
            ("b".into(), JsonValue::Num(2.into())),
        ]),
        JsonValue::Obj(vec![
            ("b".into(), JsonValue::Num(2.into())),
            ("a".into(), JsonValue::Num(1.into())),
        ])
    );
    assert_ne!(
        JsonValue::Obj(vec![("a".into(), JsonValue::Num(1.into()))]),
        JsonValue::Obj(vec![("a".into(), JsonValue::Num(2.into()))])
    );
}

#[test]
fn number_key_text_is_an_ordinary_object() {
    let key = "$serde_json::private::Number";
    let value = bounded_json_parse(r#"{"$serde_json::private::Number":"1.5"}"#).unwrap();
    assert_eq!(
        value,
        JsonValue::Obj(vec![(key.to_owned(), JsonValue::Str("1.5".to_owned()))])
    );
    let value = bounded_json_parse(r#"{"$serde_json::private::Number":"x"}"#).unwrap();
    assert_eq!(
        value,
        JsonValue::Obj(vec![(key.to_owned(), JsonValue::Str("x".to_owned()))])
    );
    assert_eq!(
        bounded_json_parse("1.5").unwrap(),
        JsonValue::Dec("1.5".to_owned())
    );
}
