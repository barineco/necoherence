// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic,
    clippy::indexing_slicing
)]

use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
use num_bigint::{BigInt, BigUint};
use std::sync::Arc;

const NAMES: &[&str] = &[
    "flag", "decimal", "text", "integer", "record", "list", "sealed", "unit", "never", "ordinary",
    "any", "raw", "bytes", "hidden", "partial",
];

fn profile_ref() -> ProfileRef {
    ProfileRef {
        identity: "profile".into(),
        revision: "1".into(),
        content_digest: "a".repeat(64),
    }
}

fn source() -> Arc<SourceRef> {
    Arc::new(SourceRef {
        repository: "repo".into(),
        revision: "rev".into(),
        path: "types.json".into(),
        content_digest: "b".repeat(64),
        document_id: "values".into(),
        declared_revision: None,
    })
}

fn named(name: &str) -> TypeRef {
    TypeRef::new(source(), name, vec![])
}

fn plain_string() -> StringSpec {
    StringSpec {
        format: None,
        lengths: vec![],
        wrapper: None,
        const_value: None,
        enum_values: None,
        examples: vec![],
        default_value: None,
    }
}

fn integer_spec() -> IntegerSpec {
    IntegerSpec {
        domain: None,
        minimum: None,
        maximum: None,
        const_value: None,
        enum_values: None,
        default_value: None,
    }
}

fn profile() -> VersionedSemanticProfile {
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
        wrappers: vec![],
        tag: Some(TagModel {
            key: "kind".into(),
            format: None,
            sealed: vec![SealedForm {
                tag: "sealed".into(),
                fields: vec![SealedField {
                    key: "name".into(),
                    required: true,
                    leaf: SealedLeaf::String(plain_string()),
                }],
                extras: SealedExtras::Reject,
            }],
        }),
    }
}

fn graph() -> SemanticGraph {
    let nodes = vec![
        (
            "flag",
            TypeShape::Boolean(BooleanSpec {
                const_value: Some(true),
                default_value: None,
            }),
        ),
        (
            "decimal",
            TypeShape::Decimal(DecimalSpec {
                minimum: None,
                maximum: None,
            }),
        ),
        ("text", TypeShape::String(plain_string())),
        ("integer", TypeShape::Integer(integer_spec())),
        (
            "record",
            product(
                &[("flag", "flag", true, false), ("text", "text", false, true)],
                ExtraMembers::Reject,
            ),
        ),
        (
            "list",
            TypeShape::Array(ArraySpec {
                item: ElementContract {
                    type_ref: named("flag"),
                    nullable: false,
                },
                min_length: Some(BigUint::from(1u8)),
                max_length: None,
            }),
        ),
        (
            "sealed",
            TypeShape::Sealed {
                tag: "sealed".into(),
                refinements: vec![],
            },
        ),
        ("unit", TypeShape::Unit),
        ("never", TypeShape::Never),
        ("ordinary", TypeShape::Unknown(UnknownKind::OrdinaryObject)),
        ("any", TypeShape::Unknown(UnknownKind::Any)),
        (
            "raw",
            TypeShape::RawBody {
                encoding: "base64".into(),
            },
        ),
        (
            "bytes",
            TypeShape::Bytes(LengthSpec {
                minimum: None,
                maximum: None,
            }),
        ),
        (
            "hidden",
            TypeShape::Opaque {
                type_name: "external".into(),
            },
        ),
        (
            "partial",
            product(&[("missing", "absent", true, false)], ExtraMembers::Reject),
        ),
    ];
    SemanticGraph {
        profile: profile(),
        nodes: nodes
            .into_iter()
            .map(|(name, shape)| TypeNode {
                reference: named(name),
                shape,
                description: None,
                attributes: vec![],
                extensions: vec![],
            })
            .collect(),
        source_refs: vec![],
    }
}

fn product(fields: &[(&str, &str, bool, bool)], extras: ExtraMembers) -> TypeShape {
    TypeShape::Product(ProductSpec {
        fields: fields
            .iter()
            .map(|(name, target, required, nullable)| FieldSpec {
                wire_name: (*name).into(),
                slot: SlotContract {
                    type_ref: named(target),
                    required: *required,
                    nullable: *nullable,
                },
                origin: (&named(target)).into(),
            })
            .collect(),
        extras,
    })
}

fn samples() -> Vec<JsonValue> {
    vec![
        JsonValue::Null,
        JsonValue::Bool(true),
        JsonValue::Bool(false),
        JsonValue::Num(BigInt::from(-11)),
        JsonValue::Num(BigInt::from(0)),
        JsonValue::Num(BigInt::from(10)),
        JsonValue::Dec("1.5".into()),
        JsonValue::Str(String::new()),
        JsonValue::Str("x".into()),
        JsonValue::Arr(vec![]),
        JsonValue::Arr(vec![JsonValue::Bool(true), JsonValue::Null]),
        JsonValue::Obj(vec![]),
        JsonValue::Obj(vec![("flag".into(), JsonValue::Bool(true))]),
        JsonValue::Obj(vec![
            ("flag".into(), JsonValue::Bool(false)),
            ("text".into(), JsonValue::Str("x".into())),
        ]),
        JsonValue::Obj(vec![("a".into(), JsonValue::Num(BigInt::from(0)))]),
        JsonValue::Obj(vec![
            ("name".into(), JsonValue::Str("x".into())),
            ("kind".into(), JsonValue::Str("sealed".into())),
        ]),
        JsonValue::Obj(vec![
            ("flag".into(), JsonValue::Null),
            ("missing".into(), JsonValue::Bool(true)),
        ]),
    ]
}

#[test]
fn expansion_and_validation_are_deterministic_and_agree_on_acceptance() {
    let graph = graph();
    for name in NAMES {
        let reference = named(name);
        for value in samples() {
            let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
            let decision = validator.accepts_value(&reference, &value);
            let decision_again = validator.accepts_value(&reference, &value);
            assert_eq!(decision, decision_again, "{name} {value:?}");

            let expanded = validator.expand_value(&reference, &[], &value);
            let expanded_again = validator.expand_value(&reference, &[], &value);
            assert_eq!(expanded, expanded_again, "{name} {value:?}");

            let validated = validator.validate_value(&reference, &value, None);
            let validated_again = validator.validate_value(&reference, &value, None);
            assert_eq!(
                validated.as_ref().map(|_| ()),
                validated_again.as_ref().map(|_| ()),
                "{name} {value:?}"
            );

            match (&decision, &validated) {
                (ValueDecision::Accepted, Ok(_)) => {}
                (ValueDecision::Rejected(expected), Err(ValidationFailure::Value(actual))) => {
                    assert_eq!(actual, expected, "{name} {value:?}");
                }
                (
                    ValueDecision::Unresolved(expected),
                    Err(ValidationFailure::Unresolved(actual)),
                ) => {
                    assert_eq!(actual, expected, "{name} {value:?}");
                }
                _ => panic!("accepts_value ({decision:?}) disagrees with validate_value ({validated:?}) for {name} {value:?}"),
            }

            match (&expanded, &decision) {
                (Expansion::Requirements(requirements), ValueDecision::Accepted) => {
                    for requirement in requirements {
                        assert_eq!(
                            validator.accepts_value(&requirement.type_ref, &requirement.value),
                            ValueDecision::Accepted,
                            "accepted value {name} {value:?} had rejected requirement {requirement:?}"
                        );
                    }
                }
                (Expansion::Requirements(requirements), ValueDecision::Rejected(_)) => {
                    assert!(
                        requirements.iter().any(|requirement| {
                            !matches!(
                                validator.accepts_value(&requirement.type_ref, &requirement.value),
                                ValueDecision::Accepted
                            )
                        }),
                        "rejected value {name} {value:?} had all requirements accepted"
                    );
                }
                (Expansion::Requirements(requirements), ValueDecision::Unresolved(_)) => {
                    assert!(
                        requirements.iter().any(|requirement| {
                            matches!(
                                validator.accepts_value(&requirement.type_ref, &requirement.value),
                                ValueDecision::Unresolved(_)
                            )
                        }),
                        "unresolved value {name} {value:?} had no unresolved requirement"
                    );
                }
                (Expansion::Rejected(expected), ValueDecision::Rejected(actual)) => {
                    assert_eq!(actual, expected, "{name} {value:?}");
                }
                (Expansion::Rejected(_), ValueDecision::Unresolved(_)) => {}
                (Expansion::Unresolved(expected), ValueDecision::Unresolved(actual)) => {
                    assert_eq!(actual, expected, "{name} {value:?}");
                }
                _ => panic!("expand_value ({expanded:?}) disagrees with accepts_value ({decision:?}) for {name} {value:?}"),
            }
        }
    }
}

#[test]
fn required_non_nullable_slots_are_deterministic_and_reject_absent_or_null_unless_unresolved() {
    let graph = graph();
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    for name in NAMES {
        let slot = SlotContract {
            type_ref: named(name),
            required: true,
            nullable: false,
        };
        let absent = validator.accepts_slot(&slot, SlotValue::Absent);
        assert_eq!(
            absent,
            validator.accepts_slot(&slot, SlotValue::Absent),
            "{name} absent"
        );
        assert!(
            matches!(
                absent,
                ValueDecision::Rejected(ValueFailure {
                    condition: ValueCondition::MissingRequired,
                    ..
                }) | ValueDecision::Unresolved(_)
            ),
            "{name} absent: {absent:?}"
        );
        let null_decision = validator.accepts_slot(&slot, SlotValue::Null);
        assert_eq!(
            null_decision,
            validator.accepts_slot(&slot, SlotValue::Null),
            "{name} null"
        );
        assert!(
            matches!(
                null_decision,
                ValueDecision::Rejected(ValueFailure {
                    condition: ValueCondition::NullNotAllowed,
                    ..
                }) | ValueDecision::Unresolved(_)
            ),
            "{name} null: {null_decision:?}"
        );
    }
}
