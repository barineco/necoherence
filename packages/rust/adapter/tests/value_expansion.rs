// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
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
        bytes_policy: None,
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
fn rejected_condition(graph: &SemanticGraph, root: &str, value: &JsonValue) -> ValueCondition {
    match PreparedValidator::new(graph, FormatWorkspace::empty()).accepts_value(&named(root), value)
    {
        ValueDecision::Rejected(failure) => failure.condition,
        other => panic!("expected rejection, got {other:?}"),
    }
}
fn expanded_condition(graph: &SemanticGraph, root: &str, value: &JsonValue) -> ValueCondition {
    match PreparedValidator::new(graph, FormatWorkspace::empty()).expand_value(
        &named(root),
        &[],
        value,
    ) {
        Expansion::Rejected(failure) => failure.condition,
        other => panic!("expected rejection, got {other:?}"),
    }
}
fn kind(text: &str) -> ValueCondition {
    ValueCondition::WrongValueKind(text.into())
}
fn text(value: &str) -> JsonValue {
    JsonValue::Str(value.into())
}
fn number(value: i64) -> JsonValue {
    JsonValue::Num(BigInt::from(value))
}

#[test]
fn each_shape_rejects_with_the_declared_condition() {
    let decimal = TypeShape::Decimal(DecimalSpec {
        minimum: None,
        maximum: None,
    });
    let graph = graph_of(vec![
        (
            "flag",
            TypeShape::Boolean(BooleanSpec {
                const_value: Some(true),
                default_value: None,
            }),
        ),
        ("decimal", decimal),
        ("text", TypeShape::String(plain_string())),
        ("integer", TypeShape::Integer(integer_spec())),
        ("record", product(&[], ExtraMembers::Reject)),
        ("list", array("flag", Some(1))),
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
            "choice",
            TypeShape::TaggedUnion(UnionSpec {
                branches: vec![UnionBranch {
                    target: named("flag"),
                    wire_tag: "flag".into(),
                    selector: BranchSelector::Kind(ValueKind::Boolean),
                    origin: (&named("flag")).into(),
                }],
            }),
        ),
    ]);
    let cases = [
        ("flag", number(1), kind("boolean")),
        (
            "flag",
            JsonValue::Bool(false),
            ValueCondition::ConstMismatch,
        ),
        ("decimal", number(1), kind("decimal")),
        ("text", number(1), kind("string")),
        ("integer", text("x"), kind("integer")),
        ("integer", number(11), ValueCondition::IntegerDomain),
        ("record", number(1), kind("object")),
        ("list", number(1), kind("array")),
        ("list", JsonValue::Arr(vec![]), ValueCondition::ArrayLength),
        ("sealed", number(1), kind("sealed object")),
        ("unit", number(1), kind("unit")),
        ("never", JsonValue::Null, ValueCondition::InvalidDataModel),
        ("ordinary", number(1), kind("ordinary object")),
        ("raw", text("AQI="), ValueCondition::InvalidBytes),
        ("bytes", text("AQI="), ValueCondition::InvalidBytes),
        ("choice", number(1), ValueCondition::NoBranchSelected),
    ];
    for (root, value, condition) in cases {
        assert_eq!(
            expanded_condition(&graph, root, &value),
            condition,
            "{root}"
        );
    }
}

#[test]
fn object_members_are_checked_before_the_shape() {
    let graph = graph_of(vec![
        (
            "flag",
            TypeShape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        ),
        (
            "record",
            product(&[("flag", "flag", true, false)], ExtraMembers::Reject),
        ),
        (
            "sealed",
            TypeShape::Sealed {
                tag: "sealed".into(),
                refinements: vec![],
            },
        ),
        ("ordinary", TypeShape::Unknown(UnknownKind::OrdinaryObject)),
    ]);
    let flag = |value| ("flag".to_owned(), value);
    let cases = [
        (
            "record",
            JsonValue::Obj(vec![
                flag(JsonValue::Bool(true)),
                flag(JsonValue::Bool(true)),
            ]),
            ValueCondition::DuplicateField("flag".into()),
        ),
        (
            "record",
            JsonValue::Obj(vec![
                flag(JsonValue::Bool(true)),
                ("extra".into(), JsonValue::Null),
            ]),
            ValueCondition::UnexpectedField("extra".into()),
        ),
        (
            "record",
            JsonValue::Obj(vec![("$value".into(), text("x"))]),
            kind("plain data object"),
        ),
        (
            "record",
            JsonValue::Obj(vec![]),
            ValueCondition::MissingRequired,
        ),
        (
            "record",
            JsonValue::Obj(vec![flag(JsonValue::Null)]),
            ValueCondition::NullNotAllowed,
        ),
        (
            "sealed",
            JsonValue::Obj(vec![("kind".into(), number(1))]),
            ValueCondition::InvalidTag,
        ),
        (
            "sealed",
            JsonValue::Obj(vec![("$value".into(), text("x"))]),
            kind("sealed object"),
        ),
        (
            "sealed",
            JsonValue::Obj(vec![("kind".into(), text("sealed"))]),
            ValueCondition::MissingRequired,
        ),
        (
            "ordinary",
            JsonValue::Obj(vec![("$value".into(), text("x"))]),
            kind("ordinary object"),
        ),
        (
            "ordinary",
            JsonValue::Obj(vec![("big".into(), number(11))]),
            ValueCondition::IntegerDomain,
        ),
    ];
    for (root, value, condition) in cases {
        assert_eq!(
            rejected_condition(&graph, root, &value),
            condition,
            "{root} {value:?}"
        );
    }
}

#[test]
fn missing_and_opaque_types_are_unresolved_expansions() {
    let graph = graph_of(vec![(
        "hidden",
        TypeShape::Opaque {
            type_name: "external".into(),
        },
    )]);
    let missing = PreparedValidator::new(&graph, FormatWorkspace::empty()).expand_value(
        &named("absent"),
        &[],
        &JsonValue::Null,
    );
    assert!(matches!(
        &missing,
        Expansion::Unresolved(obligations)
            if matches!(obligations.as_slice(), [SemanticObligation { reason: SemanticReason::UnresolvedType, .. }])
    ));
    let opaque = PreparedValidator::new(&graph, FormatWorkspace::empty()).expand_value(
        &named("hidden"),
        &[],
        &JsonValue::Null,
    );
    assert!(matches!(
        &opaque,
        Expansion::Unresolved(obligations)
            if matches!(obligations.as_slice(), [SemanticObligation { reason: SemanticReason::OpaqueType(name), .. }] if name == "external")
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&named("hidden"), &JsonValue::Null),
        ValueDecision::Unresolved(_)
    ));
}

#[test]
fn decimal_text_follows_the_json_number_grammar() {
    let graph = graph_of(vec![(
        "decimal",
        TypeShape::Decimal(DecimalSpec {
            minimum: None,
            maximum: None,
        }),
    )]);
    for accepted in ["1.5", " 1.5 ", "-0", "1e5", "6.02E+23", "1e-3"] {
        assert_eq!(
            PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&named("decimal"), &JsonValue::Dec(accepted.into())),
            ValueDecision::Accepted,
            "{accepted}"
        );
    }
    for rejected in ["1.", ".5", "+1", "01", "1e", "abc", "", "1.5.2"] {
        assert_eq!(
            rejected_condition(&graph, "decimal", &JsonValue::Dec(rejected.into())),
            ValueCondition::InvalidDataModel,
            "{rejected}"
        );
    }
}

#[test]
fn integer_forms_and_domain_follow_the_binding() {
    let graph = graph_of(vec![("integer", TypeShape::Integer(integer_spec()))]);
    for accepted in [number(5), text("5"), text("-10")] {
        assert_eq!(
            PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&named("integer"), &accepted),
            ValueDecision::Accepted,
            "{accepted:?}"
        );
    }
    for (value, condition) in [
        (text("11"), ValueCondition::IntegerDomain),
        (text("1e3"), ValueCondition::IntegerDomain),
        (text(" 5"), kind("integer")),
        (text("+5"), kind("integer")),
        (text("5.5"), kind("integer")),
        (JsonValue::Dec("5".into()), kind("integer")),
    ] {
        assert_eq!(
            rejected_condition(&graph, "integer", &value),
            condition,
            "{value:?}"
        );
    }
}

#[test]
fn member_certificates_must_match_the_requirement_tree() {
    let graph = graph_of(vec![
        (
            "flag",
            TypeShape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        ),
        ("list", array("flag", None)),
    ]);
    let value = JsonValue::Arr(vec![JsonValue::Bool(true), JsonValue::Bool(false)]);
    let leaf = MemberProof::Node(vec![]);
    let derived = PreparedValidator::new(&graph, FormatWorkspace::empty())
        .validate_value(&named("list"), &value, None)
        .unwrap();
    assert_eq!(
        derived.proof(),
        &MemberProof::Node(vec![leaf.clone(), leaf.clone()])
    );
    assert!(PreparedValidator::new(&graph, FormatWorkspace::empty())
        .validate_value(&named("list"), &value, Some(derived.proof()))
        .is_ok());
    let cases = [
        (
            MemberProof::Node(vec![leaf.clone()]),
            "missing membership children",
        ),
        (
            MemberProof::Node(vec![leaf.clone(), leaf.clone(), leaf.clone()]),
            "extra membership children",
        ),
        (
            MemberProof::Node(vec![leaf.clone(), MemberProof::Node(vec![leaf.clone()])]),
            "extra membership children",
        ),
    ];
    for (proof, condition) in cases {
        assert_eq!(
            PreparedValidator::new(&graph, FormatWorkspace::empty())
                .validate_value(&named("list"), &value, Some(&proof))
                .unwrap_err(),
            ValidationFailure::CertificateMismatch(condition.into())
        );
    }
}

#[test]
fn slot_validation_reports_presence_and_records_the_certificate() {
    let graph = graph_of(vec![("text", TypeShape::String(plain_string()))]);
    let slot = |required, nullable| SlotContract {
        type_ref: named("text"),
        required,
        nullable,
    };
    let required = slot(true, false);
    let failure =
        |slot: &SlotContract, value| match PreparedValidator::new(&graph, FormatWorkspace::empty())
            .validate_slot(slot, value)
        {
            Err(ValidationFailure::Value(failure)) => failure,
            other => panic!("expected value failure, got {other:?}"),
        };
    let missing = failure(&required, SlotValue::Absent);
    assert_eq!(missing.condition, ValueCondition::MissingRequired);
    assert_eq!(missing.observed, SlotValue::Absent);
    assert_eq!(missing.value_path, vec![]);
    let null = failure(&required, SlotValue::Null);
    assert_eq!(null.condition, ValueCondition::NullNotAllowed);
    assert_eq!(null.observed, SlotValue::Null);
    let value = text("x");
    let checked = PreparedValidator::new(&graph, FormatWorkspace::empty())
        .validate_slot(&slot(false, true), SlotValue::Present(&value))
        .unwrap();
    let certificate = checked.certificate();
    assert_eq!(certificate.profile, profile_ref());
    assert_eq!(certificate.contract, slot(false, true));
    assert_eq!(certificate.value, SlotValue::Present(value.clone()));
    assert_eq!(certificate.proof, Some(MemberProof::Node(vec![])));
    for optional in [SlotValue::Absent, SlotValue::Null] {
        let checked = PreparedValidator::new(&graph, FormatWorkspace::empty())
            .validate_slot(&slot(false, true), optional)
            .unwrap();
        assert_eq!(checked.certificate().proof, None);
    }
    let undefined = graph_of(vec![(
        "text",
        TypeShape::Opaque {
            type_name: "external".into(),
        },
    )]);
    assert!(matches!(
        PreparedValidator::new(&undefined, FormatWorkspace::empty())
            .validate_slot(&required, SlotValue::Absent),
        Err(ValidationFailure::Unresolved(_))
    ));
}

fn expanded_failure(graph: &SemanticGraph, root: &str, value: &JsonValue) -> ValueFailure {
    match PreparedValidator::new(graph, FormatWorkspace::empty()).expand_value(
        &named(root),
        &[],
        value,
    ) {
        Expansion::Rejected(failure) => failure,
        other => panic!("expected rejection, got {other:?}"),
    }
}
fn decimal_graph(
    minimum: Option<(i64, u8, bool)>,
    maximum: Option<(i64, u8, bool)>,
) -> SemanticGraph {
    let bound = |(mantissa, scale, exclusive): (i64, u8, bool)| DecimalBound {
        mantissa: BigInt::from(mantissa),
        scale: BigUint::from(scale),
        exclusive,
    };
    graph_of(vec![(
        "decimal",
        TypeShape::Decimal(DecimalSpec {
            minimum: minimum.map(bound),
            maximum: maximum.map(bound),
        }),
    )])
}
fn decimal_decision(graph: &SemanticGraph, text: &str) -> Option<ValueCondition> {
    match PreparedValidator::new(graph, FormatWorkspace::empty()).expand_value(
        &named("decimal"),
        &[],
        &JsonValue::Dec(text.into()),
    ) {
        Expansion::Requirements(_) => None,
        Expansion::Rejected(failure) => Some(failure.condition),
        other => panic!("unexpected expansion {other:?}"),
    }
}

#[test]
fn decimal_bounds_compare_mathematical_values() {
    let below = Some(ValueCondition::BelowMinimum);
    let above = Some(ValueCondition::AboveMaximum);
    let graph = decimal_graph(Some((5, 0, false)), None);
    for (text, expected) in [
        ("1", below.clone()),
        ("4.9", below.clone()),
        ("0.4e1", below.clone()),
        ("-6", below.clone()),
        ("5", None),
        ("5.0", None),
        ("0.5e1", None),
        ("50", None),
        ("12e-1", below.clone()),
    ] {
        assert_eq!(decimal_decision(&graph, text), expected, "{text}");
    }
    let graph = decimal_graph(Some((5, 0, true)), None);
    assert_eq!(decimal_decision(&graph, "5"), below);
    assert_eq!(decimal_decision(&graph, "5.01"), None);
    let graph = decimal_graph(None, Some((5, 0, false)));
    for (text, expected) in [
        ("6", above.clone()),
        ("5.1", above.clone()),
        ("1e1", above.clone()),
        ("5", None),
        ("0.5e1", None),
        ("1", None),
        ("-6", None),
    ] {
        assert_eq!(decimal_decision(&graph, text), expected, "{text}");
    }
    let graph = decimal_graph(None, Some((5, 0, true)));
    assert_eq!(decimal_decision(&graph, "5"), above);
    let graph = decimal_graph(Some((15, 1, false)), Some((25, 1, false)));
    for (text, expected) in [
        ("1.4", below.clone()),
        ("1.5", None),
        ("2", None),
        ("2.6", above.clone()),
    ] {
        assert_eq!(decimal_decision(&graph, text), expected, "{text}");
    }
    let graph = decimal_graph(None, Some((25, 1, false)));
    assert_eq!(decimal_decision(&graph, "2.6"), above);
    assert_eq!(decimal_decision(&graph, "2.5"), None);
    let graph = decimal_graph(Some((-5, 0, false)), None);
    assert_eq!(decimal_decision(&graph, "-5"), None);
    assert_eq!(decimal_decision(&graph, "-5.5"), below);
    assert_eq!(decimal_decision(&graph, "0"), None);
}

#[test]
fn sealed_members_are_checked_after_the_declared_fields_and_before_refinements() {
    let sealed = |refinements| TypeShape::Sealed {
        tag: "sealed".into(),
        refinements,
    };
    let refinement = SealedRefinement {
        key: "extra".into(),
        leaf: SealedLeaf::String(plain_string()),
    };
    let mut graph = graph_of(vec![
        ("plain", sealed(vec![])),
        ("refined", sealed(vec![refinement])),
    ]);
    let member = |key: &str, value| (key.to_owned(), value);
    let object = |extra: Option<JsonValue>, name: bool| {
        let mut members = vec![member("kind", text("sealed"))];
        if name {
            members.push(member("name", text("x")));
        }
        if let Some(extra) = extra {
            members.push(member("extra", extra));
        }
        JsonValue::Obj(members)
    };
    let extra_path = vec![PathStep::Field("extra".into())];
    let failure = expanded_failure(&graph, "plain", &object(Some(number(1)), true));
    assert_eq!(
        failure.condition,
        ValueCondition::UnexpectedField("extra".into())
    );
    assert_eq!(failure.value_path, extra_path);
    assert_eq!(failure.observed, SlotValue::Present(number(1)));
    if let Some(tag) = graph.profile.tag.as_mut() {
        for form in &mut tag.sealed {
            form.extras = SealedExtras::Any;
        }
    }
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).expand_value(
            &named("plain"),
            &[],
            &object(Some(number(1)), true)
        ),
        Expansion::Requirements(_)
    ));
    let invalid = JsonValue::Dec("abc".into());
    for root in ["plain", "refined"] {
        let failure = expanded_failure(&graph, root, &object(Some(invalid.clone()), true));
        assert_eq!(
            failure.condition,
            ValueCondition::InvalidDataModel,
            "{root}"
        );
        assert_eq!(failure.value_path, extra_path);
        assert_eq!(failure.observed, SlotValue::Present(invalid.clone()));
    }
    let failure = expanded_failure(&graph, "refined", &object(Some(number(1)), true));
    assert_eq!(failure.condition, kind("string"));
    assert_eq!(failure.value_path, extra_path);
    let failure = expanded_failure(&graph, "plain", &object(Some(invalid.clone()), false));
    assert_eq!(failure.condition, ValueCondition::MissingRequired);
    assert_eq!(failure.value_path, vec![PathStep::Field("name".into())]);
}

#[test]
fn value_derivation_rejects_a_value_outside_the_contract() {
    let graph = graph_of(vec![
        ("text", TypeShape::String(plain_string())),
        ("list", array("text", None)),
    ]);
    let rejected = JsonValue::Arr(vec![number(1)]);
    let proof = MemberProof::Node(vec![MemberProof::Node(vec![])]);
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).validate_value(
            &named("list"),
            &rejected,
            Some(&proof)
        ),
        Err(ValidationFailure::Value(_))
    ));
}
