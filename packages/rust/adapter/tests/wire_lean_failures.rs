// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::semantic_exchange::{
    decode_exact_value, decode_signature_generation, GenerationFailure,
};

fn syntax(path: &str, message: &str) -> GenerationFailure {
    GenerationFailure::Syntax {
        path: path.into(),
        message: message.into(),
    }
}

#[test]
fn unknown_member_reports_the_first_unknown_name_in_key_order() {
    assert_eq!(
        decode_exact_value(r#"{"tag":"Null","zeta":1,"alpha":2}"#),
        Err(GenerationFailure::UnknownField {
            path: "$.alpha".into(),
            field: "alpha".into(),
        })
    );
}

#[test]
fn unknown_member_path_names_the_member() {
    assert_eq!(
        decode_exact_value(r#"{"tag":"Null","x":1}"#),
        Err(GenerationFailure::UnknownField {
            path: "$.x".into(),
            field: "x".into(),
        })
    );
}

#[test]
fn missing_member_reports_the_missing_field_path() {
    assert_eq!(
        decode_exact_value(r#"{"tag":"Decimal"}"#),
        Err(syntax("$.text", "missing field"))
    );
}

#[test]
fn payload_failure_has_no_value_segment() {
    assert_eq!(
        decode_exact_value(r#"{"tag":"Bool","value":"x"}"#),
        Err(syntax("$", "Bool expected"))
    );
}

#[test]
fn list_element_failure_has_no_index_segment() {
    assert_eq!(
        decode_exact_value(r#"{"tag":"Array","items":[{"tag":"Bool","value":"x"}]}"#),
        Err(syntax("$", "Bool expected"))
    );
}

#[test]
fn non_object_tag_reports_the_tag_path_and_object_expected() {
    assert_eq!(
        decode_exact_value(r#""x""#),
        Err(syntax("$.tag", "object expected"))
    );
}

#[test]
fn missing_tag_reports_the_property_not_found_message() {
    assert_eq!(
        decode_exact_value(r#"{"value":1}"#),
        Err(syntax("$.tag", "property not found: tag"))
    );
}

#[test]
fn unknown_exact_json_tag_is_an_unknown_tag() {
    assert_eq!(
        decode_exact_value(r#"{"tag":"Other"}"#),
        Err(GenerationFailure::UnknownTag {
            path: "$.tag".into(),
            tag: "Other".into(),
        })
    );
}

#[test]
fn integer_text_spelling_failures_are_syntax_failures() {
    assert_eq!(
        decode_exact_value(r#"{"tag":"Integer","value":"x"}"#),
        Err(syntax("$", "expected canonical integer"))
    );
    assert_eq!(
        decode_exact_value(r#"{"tag":"Integer","value":"-0"}"#),
        Err(syntax("$", "noncanonical integer"))
    );
}

#[test]
fn integer_value_that_is_not_a_string_is_a_syntax_failure() {
    assert_eq!(
        decode_exact_value(r#"{"tag":"Integer","value":5}"#),
        Err(syntax("$", "String expected"))
    );
}

#[test]
fn decimal_with_whitespace_and_invalid_spelling_are_syntax_failures() {
    assert_eq!(
        decode_exact_value(r#"{"tag":"Decimal","text":" 1"}"#),
        Err(syntax("$.text", "decimal whitespace"))
    );
    assert_eq!(
        decode_exact_value(r#"{"tag":"Decimal","text":"01"}"#),
        Err(syntax("$.text", "invalid exact decimal"))
    );
}

#[test]
fn duplicate_object_key_is_rejected_at_parse() {
    assert!(matches!(
        decode_exact_value(r#"{"tag":"Null","tag":"Null"}"#),
        Err(GenerationFailure::InvalidJson(message)) if message.contains("duplicate object key: tag")
    ));
}

#[test]
fn schema_is_checked_after_the_keys() {
    assert_eq!(
        decode_signature_generation(r#"{"schema":"other@1"}"#),
        Err(syntax("$.basis", "missing field"))
    );
}

#[test]
fn unsupported_schema_reports_the_schema_path_after_the_keys() {
    let text = r#"{"schema":"other@1","basis":null,"signatures":null,"composition":null,"entrypoints":null}"#;
    assert_eq!(
        decode_signature_generation(text),
        Err(GenerationFailure::UnsupportedSchema {
            path: "$.schema".into(),
            observed: "other@1".into(),
        })
    );
}
