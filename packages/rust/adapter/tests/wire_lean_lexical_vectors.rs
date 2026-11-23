// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::unwrap_used)]

use necoherence::exact_json::{bounded_json_parse, text_admission_failure, JsonValue};
use necoherence::semantic_exchange::{
    decode_exact_value, decode_value_profile, GenerationFailure, WireDecode,
};

fn syntax(path: &str, message: &str) -> GenerationFailure {
    GenerationFailure::Syntax {
        path: path.into(),
        message: message.into(),
    }
}

#[test]
fn lone_high_surrogate_escape_is_a_typed_syntax_failure() {
    assert_eq!(
        decode_exact_value(r#""\ud800""#),
        Err(syntax("$", "unpaired Unicode surrogate"))
    );
}

#[test]
fn lone_low_surrogate_escape_is_a_typed_syntax_failure() {
    assert_eq!(
        decode_exact_value(r#""\udc00""#),
        Err(syntax("$", "unpaired Unicode surrogate"))
    );
}

#[test]
fn high_surrogate_followed_by_a_non_low_escape_is_a_typed_syntax_failure() {
    assert_eq!(
        text_admission_failure(r#""\ud83d\u0041""#),
        Some("unpaired Unicode surrogate")
    );
}

#[test]
fn surrogate_pair_escape_is_admitted_and_read_as_one_character() {
    assert_eq!(text_admission_failure(r#""\ud83d\ude00""#), None);
    assert_eq!(
        bounded_json_parse(r#""\ud83d\ude00""#).unwrap(),
        JsonValue::Str("\u{1F600}".into())
    );
}

#[test]
fn exponent_below_the_limit_is_admitted() {
    assert_eq!(text_admission_failure("[1e42]"), None);
    assert_eq!(text_admission_failure("[1e9999]"), None);
    assert!(bounded_json_parse("1e9999").is_ok());
}

#[test]
fn negative_exponent_below_the_limit_is_admitted() {
    for text in ["1e-42", "1e-9999"] {
        assert_eq!(text_admission_failure(&format!("[{text}]")), None, "{text}");
        assert!(bounded_json_parse(text).is_ok(), "{text}");
    }
}

#[test]
fn exponent_magnitude_is_compared_by_value_with_leading_zeros() {
    let zeros = "0".repeat(5000);
    for text in [
        format!("1e-{zeros}5"),
        format!("1e+{zeros}5"),
        format!("1e-{zeros}9999"),
    ] {
        assert_eq!(text_admission_failure(&format!("[{text}]")), None);
    }
    for text in [format!("1e-{zeros}10000"), format!("1e{zeros}10000")] {
        assert_eq!(
            text_admission_failure(&format!("[{text}]")),
            Some("exponent too large")
        );
    }
}

#[test]
fn exponent_at_the_limit_is_a_typed_syntax_failure_in_both_signs() {
    for text in [
        "1e10000",
        "1E+10000",
        "1e4294967295",
        "1e4294967296",
        "1e-10000",
        "1E-10000",
        "1e-4294967296",
        "1e99999999999999999999",
        "1e-99999999999999999999",
    ] {
        assert_eq!(
            decode_exact_value(text),
            Err(syntax("$", "exponent too large")),
            "{text}"
        );
        assert_eq!(
            text_admission_failure(&format!("[{text}]")),
            Some("exponent too large"),
            "{text}"
        );
    }
}

#[test]
fn zero_and_integer_decimals_keep_the_lean_spelling() {
    let value: JsonValue = bounded_json_parse("[0.0,-0.00e5,1.0]").unwrap();
    assert_eq!(serde_json::to_string(&value).unwrap(), "[0.0,0,1.0]");
}

#[test]
fn array_element_decode_failures_carry_the_element_index() {
    let items = JsonValue::Arr(vec![JsonValue::Str("a".into()), JsonValue::Num(1.into())]);
    assert_eq!(
        <Vec<String> as WireDecode>::decode_wire(&items, "$.items"),
        Err(syntax("$.items[1]", "String expected"))
    );
}

#[test]
fn decimal_text_is_read_by_the_number_reader_with_the_exponent_limit() {
    for text in [
        "1e10000",
        "1e-10000",
        "0e-10000",
        "1.5e10000",
        "1e4294967296",
        "-1e-10000",
    ] {
        let exchange = format!(r#"{{"tag":"Decimal","text":"{text}"}}"#);
        assert_eq!(
            decode_exact_value(&exchange),
            Err(syntax("$.text", "invalid exact decimal")),
            "{text}"
        );
    }
    for text in ["1e9999", "1e-9999", "1.5e42"] {
        let exchange = format!(r#"{{"tag":"Decimal","text":"{text}"}}"#);
        assert!(decode_exact_value(&exchange).is_ok(), "{text}");
    }
}

#[test]
fn zero_numbers_follow_the_fromjson_exponent_rule() {
    for text in ["0e-100", "0.000e-100", "0.0", "-0.0"] {
        assert_eq!(
            bounded_json_parse(text).unwrap(),
            JsonValue::Dec("0".into()),
            "{text}"
        );
    }
    for text in ["0", "0e11", "0e5", "0.00e3"] {
        assert_eq!(
            bounded_json_parse(text).unwrap(),
            JsonValue::Num(0.into()),
            "{text}"
        );
    }
    assert_eq!(
        bounded_json_parse("1.5").unwrap(),
        JsonValue::Dec("1.5".into())
    );
}

#[test]
fn exchange_documents_reject_raw_json_numbers_where_strings_are_required() {
    assert_eq!(
        decode_exact_value(r#"{"tag":"Decimal","text":0.0}"#),
        Err(syntax("$.text", "String expected"))
    );
    assert_eq!(
        decode_exact_value(r#"{"tag":"Integer","value":0}"#),
        Err(syntax("$", "String expected"))
    );
    assert_eq!(
        decode_exact_value(r#"{"tag":"Integer","value":0.0}"#),
        Err(syntax("$", "String expected"))
    );
}

#[test]
fn decimal_values_at_the_exponent_limit_are_not_encoded() {
    for text in ["1e10000", "1e-10000", "0e-10000"] {
        assert!(
            serde_json::to_string(&JsonValue::Dec(text.into())).is_err(),
            "{text}"
        );
    }
    assert!(serde_json::to_string(&JsonValue::Dec("1e9999".into())).is_ok());
}

#[test]
fn exponent_text_inside_a_string_is_not_an_exponent() {
    assert_eq!(text_admission_failure(r#""1e10000""#), None);
    assert_eq!(
        bounded_json_parse(r#""1e10000""#).unwrap(),
        JsonValue::Str("1e10000".into())
    );
}

#[test]
fn profile_text_at_the_exponent_limit_is_a_typed_syntax_failure() {
    assert_eq!(
        decode_value_profile("1e10000").map(|_| ()),
        Err(syntax("$", "exponent too large"))
    );
}

#[test]
fn profile_text_with_negative_exponent_at_the_limit_is_a_typed_syntax_failure() {
    for text in ["1e-10000", "[1e-10000]"] {
        assert_eq!(
            decode_value_profile(text).map(|_| ()),
            Err(syntax("$", "exponent too large")),
            "{text}"
        );
    }
}

#[test]
fn profile_text_with_unpaired_surrogate_is_a_typed_syntax_failure() {
    for text in [
        r#""\ud800""#,
        r#""\udc00""#,
        r#""\ud83d""#,
        r#"{"x":"\udc00"}"#,
    ] {
        assert_eq!(
            decode_value_profile(text).map(|_| ()),
            Err(syntax("$", "unpaired Unicode surrogate")),
            "{text}"
        );
    }
}

#[test]
fn profile_text_with_surrogate_pair_is_admitted_before_the_profile_decode() {
    assert_eq!(
        decode_value_profile(r#""\ud83d\ude00""#).map(|_| ()),
        Err(syntax("$", "object expected"))
    );
}

#[test]
fn profile_text_exponent_below_the_limit_is_admitted_before_the_profile_decode() {
    for text in ["1e9999", "1e-9999", r#""1e10000""#] {
        assert_eq!(
            decode_value_profile(text).map(|_| ()),
            Err(syntax("$", "object expected")),
            "{text}"
        );
    }
}

#[test]
fn profile_text_reports_the_first_admission_failure_in_text_order() {
    assert_eq!(
        decode_value_profile(r#"[1e10000,"\udc00"]"#).map(|_| ()),
        Err(syntax("$", "exponent too large"))
    );
    assert_eq!(
        decode_value_profile(r#"["\udc00",1e10000]"#).map(|_| ()),
        Err(syntax("$", "unpaired Unicode surrogate"))
    );
}
