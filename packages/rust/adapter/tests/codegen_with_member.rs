// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(
    clippy::expect_used,
    clippy::panic,
    clippy::result_large_err,
    clippy::unwrap_used
)]

use necoherence::exact_json::JsonValue;
use necoherence::semantic_codegen_runtime::{with_member, RuntimeFailure};

#[test]
fn with_member_replaces_the_existing_key_and_places_it_first() {
    let value = JsonValue::Obj(vec![
        ("kind".into(), JsonValue::Str("old".into())),
        ("x".into(), JsonValue::Bool(true)),
    ]);
    assert_eq!(
        with_member("kind", "sealed", value).unwrap(),
        JsonValue::Obj(vec![
            ("kind".into(), JsonValue::Str("sealed".into())),
            ("x".into(), JsonValue::Bool(true)),
        ])
    );
}

#[test]
fn with_member_rejects_non_object_members_as_representation_failure() {
    assert!(matches!(
        with_member("kind", "sealed", JsonValue::Str("text".into())),
        Err(RuntimeFailure::Representation(ref condition)) if condition == "object branch"
    ));
}
