// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(clippy::expect_used, clippy::unwrap_used)]
use necoherence::semantic_types::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use num_bigint::BigInt;

fn reference() -> ProfileRef {
    ProfileRef {
        identity: "p".into(),
        revision: "1".into(),
        content_digest: "a".repeat(64),
    }
}

fn profile() -> ValueSemanticProfile {
    ValueSemanticProfile {
        reference: reference(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference: reference(),
            range: IntegerDomain::Inclusive {
                minimum: BigInt::from(-10),
                maximum: BigInt::from(10),
            },
            forms: vec![IntegerForm::Number, IntegerForm::DecimalString],
        }],
        default_integer_domain: "integer".into(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![FormatBinding {
            name: "name".into(),
            reference: reference(),
            rule: FormatRule::Not(Box::new(FormatRule::Literal("bad".into()))),
        }],
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
                    leaf: SealedLeaf::String(StringSpec {
                        format: None,
                        lengths: vec![],
                        wrapper: None,
                        const_value: None,
                        enum_values: None,
                        examples: vec![],
                        default_value: None,
                    }),
                }],
                extras: SealedExtras::Reject,
            }],
        }),
        bytes_policy: None,
    }
}

#[test]
fn composition_classification_covers_every_obligation_and_nested_reason() {
    use necoherence::semantic_composition::{
        classify_unresolved_obligations, InputId, ProducerRef, TypeObligation,
        TypeObligationReason as T, UnresolvedObligation as O,
    };
    use necoherence_composition_solver::closure::{
        classify_terminal_assessment, TerminalAssessment,
    };
    let provenance = necoherence::semantic_composition::CompositionProvenance {
        operation: "composition".into(),
        input_identity: "input".into(),
        input_revision: "1".into(),
    };
    let reference = signature_type_ref("text");
    let is_residual = |obligation| {
        matches!(
            classify_unresolved_obligations(provenance.clone(), vec![obligation]),
            Ok(RefinementOutcome::Residual { .. })
        )
    };
    let is_stopped = |obligation| {
        matches!(
            classify_unresolved_obligations(provenance.clone(), vec![obligation]),
            Ok(RefinementOutcome::Stopped { .. })
        )
    };
    for reason in [
        T::ConstraintImplication,
        T::Presence,
        T::UnionRemainder,
        T::Inhabitation,
        T::ExtraField("extra".into()),
    ] {
        assert!(is_residual(O::Type {
            value: None,
            obligations: vec![TypeObligation {
                pair: necoherence::semantic_composition::TypePair {
                    source: necoherence::semantic_composition::present_contract(reference.clone()),
                    destination: necoherence::semantic_composition::present_contract(
                        reference.clone()
                    ),
                    source_tag: None,
                },
                path: vec![],
                reason
            }]
        }));
    }
    assert!(is_stopped(O::Type {
        value: None,
        obligations: vec![TypeObligation {
            pair: necoherence::semantic_composition::TypePair {
                source: necoherence::semantic_composition::present_contract(reference.clone()),
                destination: necoherence::semantic_composition::present_contract(reference.clone()),
                source_tag: None,
            },
            path: vec![],
            reason: T::ObligationBoundExhausted
        }]
    }));
    let semantic = |reason| SemanticObligation {
        type_ref: reference.clone(),
        origin: OccurrenceRef {
            source: reference.source.clone(),
            pointer: reference.pointer.clone(),
        },
        value_path: vec![],
        profile: profile().reference,
        reason,
    };
    let residual = semantic(SemanticReason::ProjectionUnavailable("projection".into()));
    let stop = semantic(SemanticReason::MembershipBound);
    let failure = semantic(SemanticReason::CertificateMismatch("certificate".into()));
    let mixed = O::Meaning(vec![residual.clone(), stop.clone(), failure]);
    let rejected =
        classify_unresolved_obligations(provenance.clone(), vec![mixed.clone()]).unwrap_err();
    assert_eq!(rejected.obligations, vec![mixed]);
    assert_eq!(
        rejected.residuals,
        ResidualSet::new([O::Meaning(vec![residual.clone()])])
    );
    assert!(is_stopped(O::Meaning(vec![stop.clone()])));
    assert!(is_residual(O::Meaning(vec![residual.clone()])));
    assert!(is_stopped(O::Type {
        value: None,
        obligations: vec![TypeObligation {
            pair: necoherence::semantic_composition::TypePair {
                source: necoherence::semantic_composition::present_contract(reference.clone()),
                destination: necoherence::semantic_composition::present_contract(reference.clone()),
                source_tag: None,
            },
            path: vec![],
            reason: T::Meaning(vec![residual, stop])
        }]
    }));
    assert!(is_residual(O::Inhabitation {
        producer: ProducerRef::Initial(InputId("input".into())),
        contract: SlotContract {
            type_ref: reference.clone(),
            required: true,
            nullable: false
        }
    }));
    assert!(is_residual(O::BranchInhabitation));
    assert!(is_residual(O::UnresolvedUniqueness));
    for obligation in [
        O::StateBoundExhausted,
        O::BindingBoundExhausted,
        O::BranchBoundExhausted,
        O::ResourceSolverUnknown(
            necoherence::typed_mapping::UnknownReason::BindingBoundExhausted(1u8.into()),
        ),
        O::ResourceCapacityBound {
            required: 2u8.into(),
            limit: 1u8.into(),
        },
    ] {
        assert!(is_stopped(obligation));
    }
    for obligations in [
        vec![],
        vec![O::Meaning(vec![])],
        vec![O::Meaning(vec![])],
        vec![O::Type {
            value: None,
            obligations: vec![],
        }],
        vec![O::Type {
            value: None,
            obligations: vec![TypeObligation {
                pair: necoherence::semantic_composition::TypePair {
                    source: necoherence::semantic_composition::present_contract(reference.clone()),
                    destination: necoherence::semantic_composition::present_contract(
                        reference.clone(),
                    ),
                    source_tag: None,
                },
                path: vec![],
                reason: T::Meaning(vec![]),
            }],
        }],
    ] {
        let failure =
            classify_unresolved_obligations(provenance.clone(), obligations.clone()).unwrap_err();
        assert_eq!(failure.obligations, obligations);
        assert_eq!(failure.provenance, provenance);
    }
    assert!(matches!(
        classify_terminal_assessment(provenance.clone(), TerminalAssessment::EmptyValues(vec![])),
        Ok(RefinementOutcome::Resolved(
            necoherence::semantic_composition::CompositionJudgment {
                value: TerminalAssessment::EmptyValues(_),
                ..
            }
        ))
    ));
    assert!(matches!(
        classify_terminal_assessment(
            provenance.clone(),
            TerminalAssessment::Unknown(vec![O::BranchBoundExhausted])
        ),
        Ok(RefinementOutcome::Stopped { .. })
    ));
    assert!(
        classify_terminal_assessment(provenance.clone(), TerminalAssessment::Unknown(vec![]))
            .is_err()
    );
}
