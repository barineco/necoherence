// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::expect_used, clippy::unwrap_used)]

use necoherence::exact_json::JsonValue;
use necoherence::semantic_exchange::WireDecode;
use necoherence::semantic_types::{CodepointRange, DfaTransition, GraphemeRange, IndicRange};

fn exchange(text: &str) -> JsonValue {
    necoherence::exact_json::bounded_json_parse(text).expect("exchange JSON")
}

#[test]
fn codepoint_ranges_are_read_without_an_upper_bound() {
    let value = exchange(r#"{"first":"4294967296","last":"18446744073709551616"}"#);
    let range = CodepointRange::decode_wire(&value, "$").expect("decoded");
    assert_eq!(range.first.to_string(), "4294967296");
    assert_eq!(range.last.to_string(), "18446744073709551616");
}

#[test]
fn grapheme_and_indic_ranges_are_read_without_an_upper_bound() {
    let grapheme = exchange(
        r#"{"first":"4294967296","last":"18446744073709551616","property":{"tag":"Other"}}"#,
    );
    assert!(GraphemeRange::decode_wire(&grapheme, "$").is_ok());
    let indic = exchange(
        r#"{"first":"4294967296","last":"18446744073709551616","property":{"tag":"Other"}}"#,
    );
    assert!(IndicRange::decode_wire(&indic, "$").is_ok());
}

#[test]
fn dfa_transition_bytes_are_read_without_an_upper_bound() {
    let value = exchange(r#"{"from_state":"0","first":"256","last":"65536","to_state":"0"}"#);
    let transition = DfaTransition::decode_wire(&value, "$").expect("decoded");
    assert_eq!(transition.first.to_string(), "256");
    assert_eq!(transition.last.to_string(), "65536");
}
