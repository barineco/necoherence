// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
use necoherence::semantic_composition::{
    format_use_samples, sample_value_candidates_fuel, sample_value_fuel, sample_within_bound,
    slot_samples, SampleObligation, SearchBounds,
};
use necoherence::semantic_types::*;
use num_bigint::{BigInt, BigUint};
use std::sync::Arc;

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
        bytes_policy: Some(BytesPolicy {
            reference: profile_ref(),
            padding_optional: true,
            alphabet: BytesAlphabet::Standard,
            strict_pad_bits: true,
            wrapper: None,
        }),
        wrappers: vec![Wrapper {
            name: "wrapped".into(),
            key: "$value".into(),
            payload: WrapperPayload::Text { format: None },
        }],
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
fn graph_of(nodes: Vec<(&str, TypeShape)>) -> SemanticGraph {
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
fn array(target: &str, minimum: Option<u8>) -> TypeShape {
    TypeShape::Array(ArraySpec {
        item: ElementContract {
            type_ref: named(target),
            nullable: false,
        },
        min_length: minimum.map(BigUint::from),
        max_length: None,
    })
}

fn candidates(graph: &SemanticGraph, root: &str) -> Vec<JsonValue> {
    sample_value_candidates_fuel(graph, graph.nodes.len() + 1, &[], &named(root))
}
fn text(value: &str) -> JsonValue {
    JsonValue::Str(value.into())
}
fn boolean() -> TypeShape {
    TypeShape::Boolean(BooleanSpec {
        const_value: None,
        default_value: None,
    })
}
fn flag(value: bool) -> JsonValue {
    JsonValue::Bool(value)
}
fn obj(members: Vec<(&str, JsonValue)>) -> JsonValue {
    JsonValue::Obj(
        members
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v))
            .collect(),
    )
}

#[test]
fn boolean_and_integer_candidates_follow_the_declared_forms() {
    let graph = graph_of(vec![
        ("any", boolean()),
        (
            "constant",
            TypeShape::Boolean(BooleanSpec {
                const_value: Some(true),
                default_value: None,
            }),
        ),
        (
            "bounded",
            TypeShape::Integer(IntegerSpec {
                minimum: Some(BigInt::from(3)),
                maximum: Some(BigInt::from(5)),
                ..integer_spec()
            }),
        ),
        ("unit", TypeShape::Unit),
        ("never", TypeShape::Never),
        (
            "alias",
            TypeShape::Alias {
                target: named("any"),
                reference_text: "any".into(),
            },
        ),
    ]);
    assert_eq!(candidates(&graph, "any"), vec![flag(false), flag(true)]);
    assert_eq!(candidates(&graph, "constant"), vec![flag(true)]);
    assert_eq!(
        candidates(&graph, "bounded"),
        vec![
            JsonValue::Num(BigInt::from(3)),
            JsonValue::Num(BigInt::from(5)),
            text("3"),
            text("5"),
        ]
    );
    assert_eq!(candidates(&graph, "unit"), vec![JsonValue::Null]);
    assert_eq!(candidates(&graph, "never"), Vec::<JsonValue>::new());
    assert_eq!(candidates(&graph, "alias"), vec![flag(false), flag(true)]);
}

#[test]
fn decimal_string_and_bytes_candidates_follow_the_profile() {
    let graph = graph_of(vec![
        (
            "decimal",
            TypeShape::Decimal(DecimalSpec {
                minimum: Some(DecimalBound {
                    mantissa: BigInt::from(15),
                    scale: BigUint::from(1u8),
                    exclusive: false,
                }),
                maximum: None,
            }),
        ),
        ("plain", TypeShape::String(plain_string())),
        (
            "wrapped",
            TypeShape::String(StringSpec {
                wrapper: Some("wrapped".into()),
                ..plain_string()
            }),
        ),
        (
            "bytes",
            TypeShape::Bytes(LengthSpec {
                minimum: Some(BigUint::from(3u8)),
                maximum: None,
            }),
        ),
        (
            "free-bytes",
            TypeShape::Bytes(LengthSpec {
                minimum: None,
                maximum: None,
            }),
        ),
        (
            "raw",
            TypeShape::RawBody {
                encoding: "base64".into(),
            },
        ),
    ]);
    assert_eq!(
        candidates(&graph, "decimal"),
        vec![JsonValue::Dec("15e-1".into())]
    );
    assert_eq!(
        candidates(&graph, "plain"),
        vec![text("x"), text(""), text("a")]
    );
    assert_eq!(
        candidates(&graph, "wrapped"),
        vec![
            obj(vec![("$value", text("x"))]),
            obj(vec![("$value", text(""))]),
            obj(vec![("$value", text("a"))]),
        ]
    );
    assert_eq!(candidates(&graph, "bytes"), vec![text("////")]);
    assert_eq!(
        candidates(&graph, "free-bytes"),
        vec![text(""), text("/w==")]
    );
    assert_eq!(candidates(&graph, "raw"), vec![text(""), text("/w==")]);
}

#[test]
fn composite_candidates_are_bounded_by_the_fuel() {
    let graph = graph_of(vec![
        ("flag", boolean()),
        ("pair", array("flag", Some(2))),
        (
            "record",
            product(
                &[("a", "flag", true, false), ("b", "flag", false, false)],
                ExtraMembers::Reject,
            ),
        ),
        (
            "open",
            product(
                &[],
                ExtraMembers::Allow {
                    key_format: None,
                    value: ElementContract {
                        type_ref: named("flag"),
                        nullable: false,
                    },
                },
            ),
        ),
        ("unknown", TypeShape::Unknown(UnknownKind::Any)),
    ]);
    assert_eq!(
        candidates(&graph, "pair"),
        vec![
            JsonValue::Arr(vec![flag(false), flag(false)]),
            JsonValue::Arr(vec![flag(true), flag(true)]),
        ]
    );
    assert_eq!(
        sample_value_candidates_fuel(&graph, 3, &[], &named("record")),
        vec![
            obj(vec![("a", flag(false))]),
            obj(vec![("a", flag(false)), ("b", flag(false))]),
            obj(vec![("a", flag(false)), ("b", flag(true))]),
        ]
    );
    assert_eq!(
        candidates(&graph, "open"),
        vec![obj(vec![]), obj(vec![("x", flag(false))])]
    );
    assert_eq!(candidates(&graph, "unknown").len(), 6);
    assert!(sample_value_candidates_fuel(&graph, 0, &[], &named("flag")).is_empty());
    assert!(sample_value_candidates_fuel(&graph, 3, &[named("flag")], &named("flag")).is_empty());
}

#[test]
fn union_and_sealed_candidates_shape_the_selected_branch() {
    let branch = |target: &str, tag: &str, selector: BranchSelector| UnionBranch {
        target: named(target),
        wire_tag: tag.into(),
        selector,
        origin: (&named(target)).into(),
    };
    let graph = graph_of(vec![
        ("flag", boolean()),
        ("empty", product(&[], ExtraMembers::Reject)),
        (
            "optional",
            product(&[("m", "flag", false, false)], ExtraMembers::Reject),
        ),
        (
            "tagged",
            TypeShape::TaggedUnion(UnionSpec {
                branches: vec![branch("empty", "k", BranchSelector::InternalTag)],
            }),
        ),
        (
            "kinded",
            TypeShape::TaggedUnion(UnionSpec {
                branches: vec![branch(
                    "flag",
                    "f",
                    BranchSelector::Kind(ValueKind::Boolean),
                )],
            }),
        ),
        (
            "shaped",
            TypeShape::TaggedUnion(UnionSpec {
                branches: vec![branch(
                    "optional",
                    "o",
                    BranchSelector::MemberShape(vec![("m".into(), MemberTest::Absent)]),
                )],
            }),
        ),
        (
            "sealed",
            TypeShape::Sealed {
                tag: "sealed".into(),
                refinements: vec![],
            },
        ),
    ]);
    assert_eq!(
        candidates(&graph, "tagged"),
        vec![obj(vec![("kind", text("k"))])]
    );
    assert_eq!(candidates(&graph, "kinded"), vec![flag(false), flag(true)]);
    assert_eq!(
        candidates(&graph, "shaped"),
        vec![obj(vec![]), obj(vec![]), obj(vec![])]
    );
    assert_eq!(
        candidates(&graph, "sealed"),
        vec![obj(vec![("kind", text("sealed")), ("name", text("x"))])]
    );
}

#[test]
fn format_samples_follow_each_rule() {
    let profile = profile();
    let samples =
        |rule: FormatRule| format_use_samples(&profile, &Some(FormatUse::Inline(rule)), 5);
    let literal = |value: &str| FormatRule::Literal(value.into());
    assert_eq!(samples(literal("ab")), vec!["ab".to_owned()]);
    assert_eq!(
        samples(FormatRule::Text),
        vec![String::new(), "a".to_owned()]
    );
    assert_eq!(
        samples(FormatRule::Optional(Box::new(literal("a")))),
        vec![String::new(), "a".to_owned()]
    );
    assert_eq!(
        samples(FormatRule::Choice(vec![literal("a"), literal("b")])),
        vec!["a".to_owned(), "b".to_owned()]
    );
    assert_eq!(
        samples(FormatRule::Sequence(vec![
            literal("a"),
            FormatRule::Choice(vec![literal("b"), literal("c")]),
        ])),
        vec!["ab".to_owned(), "ac".to_owned()]
    );
    assert_eq!(
        samples(FormatRule::Not(Box::new(literal("bad")))),
        vec![
            String::new(),
            "a".to_owned(),
            "aa".to_owned(),
            "badx".to_owned()
        ]
    );
    assert_eq!(
        samples(FormatRule::Labels {
            separator: ".".into(),
            min_count: BigUint::from(2u8),
            max_count: None,
            total_max: None,
            rule: Box::new(literal("a")),
        }),
        vec!["a.a".to_owned()]
    );
    assert_eq!(
        samples(FormatRule::AsciiDfa(DfaSpec {
            state_count: BigUint::from(2u8),
            initial_state: BigUint::from(0u8),
            accepting_states: vec![BigUint::from(1u8)],
            transitions: vec![DfaTransition {
                from_state: BigUint::from(0u8),
                first: BigUint::from(b'q'),
                last: BigUint::from(b'q'),
                to_state: BigUint::from(1u8),
            }],
        })),
        vec!["q".to_owned()]
    );
    assert_eq!(
        samples(FormatRule::Timestamp(CalendarRule {
            allow_second_60: false,
            minimum_year: BigUint::from(2000u16),
            maximum_year: BigUint::from(2100u16),
            reject_utc_year_outside_range: false,
        })),
        vec!["2000-01-01T00:00:00Z".to_owned()]
    );
    assert_eq!(
        samples(FormatRule::LanguageTag {
            grandfathered: vec![]
        }),
        vec!["aa".to_owned()]
    );
    assert_eq!(
        samples(FormatRule::Identifier {
            first_alphabet: "ab".into(),
            rest_alphabet: "cd".into(),
            exact_length: None,
            min_length: BigUint::from(2u8),
            max_length: None,
            forbidden: vec![],
        }),
        vec!["ac".to_owned()]
    );
    assert_eq!(format_use_samples(&profile, &None, 5), vec!["x".to_owned()]);
    assert_eq!(
        samples(FormatRule::Sequence(vec![literal("a"), literal("b")])),
        vec!["ab".to_owned()]
    );
}

#[test]
fn sample_results_record_the_bound_and_the_slot_presence() {
    let graph = graph_of(vec![
        ("flag", boolean()),
        (
            "long",
            TypeShape::String(StringSpec {
                const_value: Some("abcd".into()),
                ..plain_string()
            }),
        ),
    ]);
    let bounds = SearchBounds {
        max_sample_length: BigUint::from(2u32),
        ..SearchBounds::default()
    };
    let bounded = sample_value_fuel(&graph, &bounds, 3, &[], &named("long"));
    assert!(bounded.values.is_empty());
    assert_eq!(bounded.obligations, vec![SampleObligation::SampleBound]);
    let unbounded = sample_value_fuel(&graph, &SearchBounds::default(), 3, &[], &named("long"));
    assert_eq!(unbounded.values, vec![text("abcd")]);
    assert!(unbounded.obligations.is_empty());
    assert!(sample_within_bound(2, &text("ab")));
    assert!(!sample_within_bound(2, &text("abc")));
    assert!(!sample_within_bound(
        1,
        &JsonValue::Arr(vec![flag(true), flag(true)])
    ));
    assert!(!sample_within_bound(
        1,
        &obj(vec![("a", flag(true)), ("b", flag(true))])
    ));
    assert!(sample_within_bound(0, &flag(true)));
    let slot = |required, nullable| SlotContract {
        type_ref: named("flag"),
        required,
        nullable,
    };
    assert_eq!(
        slot_samples(&graph, &SearchBounds::default(), &slot(false, true)).values,
        vec![
            SlotValue::Absent,
            SlotValue::Null,
            SlotValue::Present(flag(false)),
            SlotValue::Present(flag(true)),
        ]
    );
    assert_eq!(
        slot_samples(&graph, &SearchBounds::default(), &slot(true, false)).values,
        vec![
            SlotValue::Present(flag(false)),
            SlotValue::Present(flag(true))
        ]
    );
}
