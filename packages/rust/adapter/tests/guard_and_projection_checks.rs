// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(
    clippy::indexing_slicing,
    clippy::panic,
    clippy::result_large_err,
    clippy::unwrap_used
)]
#[path = "semantic_value_samples.rs"]
mod semantic_value_samples;

use necoherence::exact_json_view::JsonValueView;
use necoherence::semantic_types::*;
use necoherence::signature_admission::check_type_signatures;
use num_bigint::BigUint;

fn untagged_profile() -> VersionedSemanticProfile {
    check_type_signatures(&semantic_value_samples::library())
        .unwrap()
        .profile
}

fn profile_with_tag(key: &str) -> VersionedSemanticProfile {
    let mut library = semantic_value_samples::library();
    library.nodes.clear();
    library.definitions.clear();
    library.profile.tag = Some(TagModel {
        key: key.into(),
        format: None,
        sealed: vec![],
    });
    check_type_signatures(&library).unwrap().profile
}

#[test]
fn project_value_view_matches_owned_projection_on_every_case() {
    use necoherence::semantic_composition::{project_owned, project_value_view};
    let profile = untagged_profile();
    let nested = JsonValue::Obj(vec![(
        "a".into(),
        JsonValue::Arr(vec![JsonValue::Obj(vec![("b".into(), JsonValue::Null)])]),
    )]);
    let paths: Vec<Vec<PathStep>> = vec![
        vec![],
        vec![
            PathStep::Field("a".into()),
            PathStep::Index(BigUint::from(0u8)),
            PathStep::Field("b".into()),
        ],
        vec![
            PathStep::Field("a".into()),
            PathStep::Index(BigUint::from(5u8)),
        ],
        vec![PathStep::Field("missing".into())],
        vec![PathStep::Variant("t".into()), PathStep::Field("a".into())],
    ];
    let roots = [
        SlotValue::Absent,
        SlotValue::Null,
        SlotValue::Present(nested.clone()),
        SlotValue::Present(JsonValue::Null),
    ];
    for root in &roots {
        for path in &paths {
            let owned = project_owned(&profile, root, path);
            let view = match root {
                SlotValue::Absent => SlotValue::Absent,
                SlotValue::Null => SlotValue::Null,
                SlotValue::Present(value) => SlotValue::Present(JsonValueView::from_json(value)),
            };
            let projected = match project_value_view(&profile, view, path) {
                SlotValue::Absent => SlotValue::Absent,
                SlotValue::Null => SlotValue::Null,
                SlotValue::Present(value) => SlotValue::Present(value.to_owned()),
            };
            assert_eq!(projected, owned, "{root:?} {path:?}");
        }
    }
    assert_eq!(
        project_owned(&profile, &SlotValue::Present(nested.clone()), &paths[1]),
        SlotValue::Null
    );
    assert_eq!(
        project_owned(&profile, &SlotValue::Present(nested), &paths[2]),
        SlotValue::Absent
    );
    assert_eq!(
        project_owned(&profile, &SlotValue::Present(JsonValue::Null), &[]),
        SlotValue::Present(JsonValue::Null)
    );
}

#[test]
fn owned_projection_follows_the_variant_tag_and_stops_at_a_null_like_lean() {
    use necoherence::semantic_composition::project_owned;
    let profile = profile_with_tag("kind");
    let object = |tag: &str| {
        JsonValue::Obj(vec![
            ("kind".into(), JsonValue::Str(tag.into())),
            ("x".into(), JsonValue::Num(1.into())),
        ])
    };
    let variant = [PathStep::Variant("a".into()), PathStep::Field("x".into())];
    assert_eq!(
        project_owned(&profile, &SlotValue::Present(object("b")), &variant),
        SlotValue::Absent
    );
    assert_eq!(
        project_owned(&profile, &SlotValue::Present(object("a")), &variant),
        SlotValue::Present(JsonValue::Num(1.into()))
    );
    let member_null = JsonValue::Obj(vec![("a".into(), JsonValue::Null)]);
    assert_eq!(
        project_owned(
            &profile,
            &SlotValue::Present(member_null),
            &[PathStep::Field("a".into()), PathStep::Field("b".into())]
        ),
        SlotValue::Null
    );
    assert_eq!(
        project_owned(
            &profile,
            &SlotValue::Present(JsonValue::Null),
            &[PathStep::Field("b".into())]
        ),
        SlotValue::Null
    );
}

fn assert_runtime_failure_fields(
    expected: &necoherence::semantic_codegen_runtime::RuntimeFailure,
    actual: necoherence::semantic_codegen_runtime::RuntimeFailure,
) {
    use necoherence::semantic_codegen_runtime::RuntimeFailure;
    use necoherence::semantic_validation::DefaultFailure;
    match (expected, &actual) {
        (RuntimeFailure::Json(expected), RuntimeFailure::Json(actual))
        | (RuntimeFailure::Representation(expected), RuntimeFailure::Representation(actual)) => {
            assert_eq!(actual, expected);
        }
        (RuntimeFailure::BranchSelection, RuntimeFailure::BranchSelection) => {}
        (RuntimeFailure::UndefinedType(expected), RuntimeFailure::UndefinedType(actual)) => {
            assert_eq!(actual, expected);
        }
        (RuntimeFailure::Validation(expected), RuntimeFailure::Validation(actual)) => {
            assert_eq!(actual, expected);
        }
        (
            RuntimeFailure::Defaults(DefaultFailure::Wire(expected)),
            RuntimeFailure::Defaults(DefaultFailure::Wire(actual)),
        ) => assert_eq!(actual, expected),
        _ => panic!("runtime cause changed: {expected:?} to {actual:?}"),
    }
}

#[test]
fn runtime_failure_view_round_trips_every_cause() {
    use necoherence::semantic_codegen_runtime::{RuntimeFailure, RuntimeFailureView};
    let make = || {
        vec![
            RuntimeFailure::Json("j".into()),
            RuntimeFailure::Representation("r".into()),
            RuntimeFailure::BranchSelection,
            RuntimeFailure::UndefinedType(semantic_value_samples::recursive_ref("Missing")),
            RuntimeFailure::Validation(
                necoherence::semantic_validation::ValidationFailure::CertificateMismatch(
                    "c".into(),
                ),
            ),
            RuntimeFailure::Defaults(necoherence::semantic_validation::DefaultFailure::Wire(
                necoherence::semantic_exchange::GenerationFailure::InvalidJson("w".into()),
            )),
        ]
    };
    for (cause, twin) in make().iter().zip(make()) {
        let borrowed: RuntimeFailureView<'_> = RuntimeFailureView::from(cause);
        assert_runtime_failure_fields(cause, borrowed.into_owned());
        let moved: RuntimeFailureView<'_> = RuntimeFailureView::from(twin);
        assert_runtime_failure_fields(cause, moved.into_owned());
    }
}
