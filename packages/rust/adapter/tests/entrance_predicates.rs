// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::exact_json::JsonValue;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::{
    data_value_accepts, integer_value_for_domain, tag_value_accepts, wrapper_text_accepts,
};
use num_bigint::BigInt;

fn profile_ref() -> ProfileRef {
    ProfileRef {
        identity: "profile".into(),
        revision: "1".into(),
        content_digest: "digest".into(),
    }
}

fn profile(wrappers: Vec<Wrapper>) -> VersionedSemanticProfile {
    VersionedSemanticProfile {
        reference: profile_ref(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference: profile_ref(),
            range: IntegerDomain::Inclusive {
                minimum: BigInt::from(-10),
                maximum: BigInt::from(10),
            },
            forms: vec![IntegerForm::Number, IntegerForm::DecimalString],
        }],
        default_integer_domain: "integer".into(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![],
        bytes_policy: None,
        wrappers,
        tag: Some(TagModel {
            key: "kind".into(),
            format: None,
            sealed: vec![SealedForm {
                tag: "sealed".into(),
                fields: vec![],
                extras: SealedExtras::Reject,
            }],
        }),
    }
}

fn text_wrapper() -> Wrapper {
    Wrapper {
        name: "wrapped".into(),
        key: "$value".into(),
        payload: WrapperPayload::Text { format: None },
    }
}

#[test]
fn integer_value_reads_the_named_or_default_domain() {
    let profile = profile(vec![]);
    assert_eq!(
        integer_value_for_domain(&profile, None, &JsonValue::Num(BigInt::from(11))),
        Some(BigInt::from(11))
    );
    assert_eq!(
        integer_value_for_domain(&profile, Some("integer"), &JsonValue::Str("5".into())),
        Some(BigInt::from(5))
    );
    assert_eq!(
        integer_value_for_domain(&profile, Some("missing"), &JsonValue::Num(BigInt::from(1))),
        None
    );
    assert_eq!(
        integer_value_for_domain(&profile, None, &JsonValue::Bool(true)),
        None
    );
}

#[test]
fn tag_value_accepts_text_tags_without_a_format_and_rejects_other_kinds() {
    let profile = profile(vec![]);
    assert!(tag_value_accepts(
        &profile,
        &[("kind".into(), JsonValue::Str("sealed".into()))]
    ));
    assert!(tag_value_accepts(
        &profile,
        &[("kind".into(), JsonValue::Str("other".into()))]
    ));
    assert!(tag_value_accepts(
        &profile,
        &[("other".into(), JsonValue::Num(BigInt::from(1)))]
    ));
    assert!(!tag_value_accepts(
        &profile,
        &[("kind".into(), JsonValue::Num(BigInt::from(1)))]
    ));
}

#[test]
fn wrapper_text_accepts_only_the_text_payload_member() {
    let profile = profile(vec![text_wrapper()]);
    assert!(wrapper_text_accepts(
        &profile,
        &JsonValue::Obj(vec![("$value".into(), JsonValue::Str("text".into()))])
    ));
    assert!(!wrapper_text_accepts(
        &profile,
        &JsonValue::Obj(vec![("$value".into(), JsonValue::Num(BigInt::from(1)))])
    ));
    assert!(!wrapper_text_accepts(
        &profile,
        &JsonValue::Obj(vec![
            ("$value".into(), JsonValue::Str("text".into())),
            ("extra".into(), JsonValue::Null),
        ])
    ));
    assert!(!wrapper_text_accepts(
        &profile,
        &JsonValue::Str("text".into())
    ));
}

#[test]
fn wrapper_text_is_false_without_a_text_wrapper() {
    let profile = profile(vec![Wrapper {
        name: "bytes".into(),
        key: "$bytes".into(),
        payload: WrapperPayload::Bytes,
    }]);
    assert!(!wrapper_text_accepts(
        &profile,
        &JsonValue::Obj(vec![("$bytes".into(), JsonValue::Str("text".into()))])
    ));
}

#[test]
fn data_value_accepts_scalars_and_arrays_within_the_profile() {
    let profile = profile(vec![]);
    assert!(data_value_accepts(&profile, &JsonValue::Null));
    assert!(data_value_accepts(&profile, &JsonValue::Bool(true)));
    assert!(data_value_accepts(&profile, &JsonValue::Str("text".into())));
    assert!(data_value_accepts(
        &profile,
        &JsonValue::Num(BigInt::from(10))
    ));
    assert!(!data_value_accepts(
        &profile,
        &JsonValue::Num(BigInt::from(11))
    ));
    assert!(data_value_accepts(
        &profile,
        &JsonValue::Arr(vec![JsonValue::Num(BigInt::from(-10))])
    ));
    assert!(!data_value_accepts(
        &profile,
        &JsonValue::Arr(vec![JsonValue::Num(BigInt::from(11))])
    ));
}

#[test]
fn data_value_accepts_rejects_duplicate_keys_and_invalid_tags() {
    let profile = profile(vec![]);
    assert!(!data_value_accepts(
        &profile,
        &JsonValue::Obj(vec![
            ("a".into(), JsonValue::Null),
            ("a".into(), JsonValue::Null),
        ])
    ));
    assert!(!data_value_accepts(
        &profile,
        &JsonValue::Obj(vec![("kind".into(), JsonValue::Num(BigInt::from(1)))])
    ));
    assert!(data_value_accepts(
        &profile,
        &JsonValue::Obj(vec![
            ("kind".into(), JsonValue::Str("other".into())),
            ("a".into(), JsonValue::Num(BigInt::from(1))),
        ])
    ));
}

#[test]
fn data_value_accepts_sealed_forms_without_unknown_members() {
    let profile = profile(vec![]);
    assert!(data_value_accepts(
        &profile,
        &JsonValue::Obj(vec![("kind".into(), JsonValue::Str("sealed".into()))])
    ));
    assert!(!data_value_accepts(
        &profile,
        &JsonValue::Obj(vec![
            ("kind".into(), JsonValue::Str("sealed".into())),
            ("extra".into(), JsonValue::Null),
        ])
    ));
}

#[test]
fn data_value_accepts_wrapper_objects_by_their_text_payload() {
    let profile = profile(vec![text_wrapper()]);
    assert!(data_value_accepts(
        &profile,
        &JsonValue::Obj(vec![("$value".into(), JsonValue::Str("text".into()))])
    ));
    assert!(!data_value_accepts(
        &profile,
        &JsonValue::Obj(vec![("$value".into(), JsonValue::Num(BigInt::from(1)))])
    ));
    assert!(!data_value_accepts(
        &profile,
        &JsonValue::Arr(vec![JsonValue::Obj(vec![(
            "$value".into(),
            JsonValue::Num(BigInt::from(1))
        )])])
    ));
}
