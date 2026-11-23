// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::semantic_types::*;
use crate::signature_admission::*;
use crate::type_signatures::*;

#[derive(Debug, Clone, PartialEq)]
pub struct AdditionalSemanticInformation {
    pub nodes: Vec<TypeNode>,
    pub profile: VersionedSemanticProfile,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SignatureEvaluation {
    source: neco_quotient_certificate::SourceRef<String, String>,
    basis: SignatureGenerationBasis,
    input: SemanticValueInput,
    certificate: SignatureGenerationInput,
    observations: VersionedSemanticGraph,
    outcome: SemanticEvaluation,
}

impl SignatureEvaluation {
    pub fn observations(&self) -> &VersionedSemanticGraph {
        &self.observations
    }
    pub fn outcome(&self) -> &SemanticEvaluation {
        &self.outcome
    }
    pub fn input(&self) -> &SemanticValueInput {
        &self.input
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SemanticEvaluationEvidence {
    observations: VersionedSemanticGraph,
    input: SemanticValueInput,
    outcome: SemanticEvaluation,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SemanticGraphExtension {
    information: AdditionalSemanticInformation,
}

pub type SignatureRefinement = neco_quotient_certificate::VerifiedRefinement<
    neco_quotient_certificate::SourceRef<String, String>,
    SignatureGenerationBasis,
    SemanticValueInput,
    SignatureGenerationInput,
    VersionedSemanticGraph,
    VersionedSemanticGraph,
    std::result::Result<SemanticJudgment, SemanticDecisionFailure>,
    SemanticObligation,
    Vec<SemanticObligation>,
    SemanticGraphExtension,
    SemanticEvaluationEvidence,
    SemanticEvaluationEvidence,
>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SemanticProfileDeclaration {
    DefaultIntegerDomain,
    Numbers,
    SourceRefs,
    IntegerDomains,
    FormatBindings,
    Wrappers,
    GraphemeRules,
    BytesPolicy,
    Tag,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SemanticGraphCondition {
    DistinctGraphRevision,
    UniqueAdditionalTypeReference(TypeRef),
    AdditionalNodeStructure(TypeRef),
    ExistingProfileDeclaration(SemanticProfileDeclaration),
    ObjectInterpretation,
    SealedLeafJudgment,
    ExistingTypeDeclaration(TypeRef),
}

#[derive(Debug, Clone, PartialEq)]
pub enum SemanticRefinementFailure {
    ObservationGraph {
        previous: VersionedSemanticGraph,
        information: AdditionalSemanticInformation,
        requested_revision: String,
        condition: SemanticGraphCondition,
    },
    Profile {
        previous: VersionedSemanticGraph,
        information: AdditionalSemanticInformation,
        requested_revision: String,
        failure: ProfileFailure,
    },
    Evidence {
        source: neco_quotient_certificate::SourceRef<String, String>,
        basis: SignatureGenerationBasis,
        input: SemanticValueInput,
        certificate: SignatureGenerationInput,
        previous: VersionedSemanticGraph,
        requested_revision: String,
        mismatch: neco_quotient_certificate::RefinementEvidenceMismatch,
    },
}

fn evaluate_signature_value(
    validator: &mut crate::semantic_validation::PreparedValidator<'_>,
    input: &SemanticValueInput,
) -> SemanticEvaluation {
    classify_value_decision(
        EvaluationProvenance {
            operation: "validate".into(),
            type_ref: input.type_ref.clone(),
            value_path: vec![],
        },
        validator.accepts_value(&input.type_ref, &input.value),
    )
}

fn refinement_evidence_outcome(
    outcome: &SemanticEvaluation,
) -> neco_quotient_certificate::RefinementOutcome<
    std::result::Result<SemanticJudgment, SemanticDecisionFailure>,
    SemanticObligation,
    Vec<SemanticObligation>,
> {
    use neco_quotient_certificate::RefinementOutcome;
    match outcome {
        Ok(RefinementOutcome::Resolved(value)) => RefinementOutcome::Resolved(Ok(value.clone())),
        Ok(RefinementOutcome::Residual { value, residuals }) => RefinementOutcome::Residual {
            value: Ok(value.clone()),
            residuals: residuals.clone(),
        },
        Ok(RefinementOutcome::Stopped {
            value,
            residuals,
            cause,
        }) => RefinementOutcome::Stopped {
            value: Ok(value.clone()),
            residuals: residuals.clone(),
            cause: cause.clone(),
        },
        Err(failure) => RefinementOutcome::Resolved(Err(failure.clone())),
    }
}

pub fn open_signature_evaluation(
    checked: &CheckedSignatureGeneration,
    input: SemanticValueInput,
    graph_revision: String,
) -> SignatureEvaluation {
    let observations = VersionedSemanticGraph {
        revision: graph_revision,
        graph: checked.graph().clone(),
    };
    let outcome = evaluate_signature_value(
        &mut crate::semantic_validation::PreparedValidator::new(
            &observations.graph,
            crate::semantic_validation::FormatWorkspace::empty(),
        ),
        &input,
    );
    SignatureEvaluation {
        source: source_of(&checked.input().basis),
        basis: checked.input().basis.clone(),
        input,
        certificate: checked.input().clone(),
        observations,
        outcome,
    }
}

pub fn refine_signature_evaluation(
    previous: &SignatureEvaluation,
    information: AdditionalSemanticInformation,
    graph_revision: String,
) -> std::result::Result<(SignatureEvaluation, SignatureRefinement), SemanticRefinementFailure> {
    use neco_quotient_certificate::{
        EvaluatedAt, ObservationRefines, RefinementOutcome, VerifiedRefinement,
    };
    let invalid = |condition: SemanticGraphCondition| SemanticRefinementFailure::ObservationGraph {
        previous: previous.observations.clone(),
        information: information.clone(),
        requested_revision: graph_revision.clone(),
        condition,
    };
    if graph_revision.is_empty() || graph_revision == previous.observations.revision {
        return Err(invalid(SemanticGraphCondition::DistinctGraphRevision));
    }
    let before_profile = &previous.observations.graph.profile;
    let after_profile = &information.profile;
    crate::semantic_validation::check_profile(after_profile).map_err(|failure| {
        SemanticRefinementFailure::Profile {
            previous: previous.observations.clone(),
            information: information.clone(),
            requested_revision: graph_revision.clone(),
            failure,
        }
    })?;
    let mut added = Vec::new();
    for node in &information.nodes {
        if added.contains(&node.reference) {
            return Err(invalid(
                SemanticGraphCondition::UniqueAdditionalTypeReference(node.reference.clone()),
            ));
        }
        if !crate::semantic_validation::semantic_node_structure_is_valid(after_profile, node) {
            return Err(invalid(SemanticGraphCondition::AdditionalNodeStructure(
                node.reference.clone(),
            )));
        }
        added.push(node.reference.clone());
    }
    let profile_failure =
        |field| invalid(SemanticGraphCondition::ExistingProfileDeclaration(field));
    if before_profile.default_integer_domain != after_profile.default_integer_domain {
        return Err(profile_failure(
            SemanticProfileDeclaration::DefaultIntegerDomain,
        ));
    }
    if before_profile.numbers != after_profile.numbers {
        return Err(profile_failure(SemanticProfileDeclaration::Numbers));
    }
    if !before_profile
        .source_refs
        .iter()
        .all(|item| after_profile.source_refs.contains(item))
    {
        return Err(profile_failure(SemanticProfileDeclaration::SourceRefs));
    }
    if !before_profile
        .integer_domains
        .iter()
        .all(|item| after_profile.integer_domains.contains(item))
    {
        return Err(profile_failure(SemanticProfileDeclaration::IntegerDomains));
    }
    if !before_profile
        .format_bindings
        .iter()
        .all(|item| after_profile.format_bindings.contains(item))
    {
        return Err(profile_failure(SemanticProfileDeclaration::FormatBindings));
    }
    if !before_profile
        .wrappers
        .iter()
        .all(|item| after_profile.wrappers.contains(item))
    {
        return Err(profile_failure(SemanticProfileDeclaration::Wrappers));
    }
    if before_profile.grapheme_rules.is_some()
        && before_profile.grapheme_rules != after_profile.grapheme_rules
    {
        return Err(profile_failure(SemanticProfileDeclaration::GraphemeRules));
    }
    if before_profile.bytes_policy.is_some()
        && before_profile.bytes_policy != after_profile.bytes_policy
    {
        return Err(profile_failure(SemanticProfileDeclaration::BytesPolicy));
    }
    if match (&before_profile.tag, &after_profile.tag) {
        (None, _) => false,
        (Some(before), Some(after)) => {
            before.key != after.key
                || before.format != after.format
                || !before.sealed.iter().all(|item| after.sealed.contains(item))
        }
        (Some(_), None) => true,
    } {
        return Err(profile_failure(SemanticProfileDeclaration::Tag));
    }
    let sealed_leaf_uses_graphemes = |leaf: &SealedLeaf| {
        matches!(
            leaf,
            SealedLeaf::String(spec)
                if spec
                    .lengths
                    .iter()
                    .any(|bound| bound.unit == StringLengthUnit::Graphemes)
        )
    };
    let has_bytes_wrapper = before_profile
        .wrappers
        .iter()
        .any(|wrapper| matches!(wrapper.payload, WrapperPayload::Bytes));
    let sealed_leaf_uses_bytes =
        |leaf: &SealedLeaf| has_bytes_wrapper && matches!(leaf, SealedLeaf::String(_));
    let sealed_leaf_is_string = |leaf: &SealedLeaf| matches!(leaf, SealedLeaf::String(_));
    let sealed_form_uses = |tag: Option<&str>, predicate: &dyn Fn(&SealedLeaf) -> bool| {
        before_profile.tag.as_ref().is_some_and(|model| {
            model.sealed.iter().any(|form| {
                tag.is_none_or(|tag| form.tag == tag)
                    && form.fields.iter().any(|field| predicate(&field.leaf))
            })
        })
    };
    let meaning_defined = |node: &TypeNode| {
        crate::semantic_validation::meaning_obligations(
            &previous.observations.graph,
            std::slice::from_ref(&node.reference),
        )
        .is_empty()
    };
    let wrappers_added = before_profile.wrappers != after_profile.wrappers;
    let tag_created = before_profile.tag.is_none() && after_profile.tag.is_some();
    let sealed_forms_added = match (&before_profile.tag, &after_profile.tag) {
        (Some(before), Some(after)) => before.sealed != after.sealed,
        _ => false,
    };
    let object_interpretation_changed = previous.observations.graph.nodes.iter().any(|node| {
        meaning_defined(node)
            && match &node.shape {
                TypeShape::Unknown(_) => wrappers_added || tag_created || sealed_forms_added,
                TypeShape::Product(_) => wrappers_added || tag_created || sealed_forms_added,
                TypeShape::TaggedUnion(_) => tag_created,
                TypeShape::Sealed { tag, refinements } => {
                    wrappers_added
                        && (sealed_form_uses(Some(tag), &sealed_leaf_is_string)
                            || refinements
                                .iter()
                                .any(|refinement| sealed_leaf_is_string(&refinement.leaf)))
                }
                _ => false,
            }
    });
    if object_interpretation_changed {
        return Err(invalid(SemanticGraphCondition::ObjectInterpretation));
    }
    let observes_new_grapheme_rules = before_profile.grapheme_rules.is_none()
        && after_profile.grapheme_rules.is_some()
        && previous.observations.graph.nodes.iter().any(|node| {
            crate::semantic_validation::meaning_obligations(
                &previous.observations.graph,
                std::slice::from_ref(&node.reference),
            )
            .is_empty()
                && match &node.shape {
                    TypeShape::Unknown(_) => sealed_form_uses(None, &sealed_leaf_uses_graphemes),
                    TypeShape::Sealed { tag, refinements } => {
                        sealed_form_uses(Some(tag), &sealed_leaf_uses_graphemes)
                            || refinements
                                .iter()
                                .any(|refinement| sealed_leaf_uses_graphemes(&refinement.leaf))
                    }
                    _ => false,
                }
        });
    let observes_new_bytes_policy = before_profile.bytes_policy.is_none()
        && after_profile.bytes_policy.is_some()
        && previous.observations.graph.nodes.iter().any(|node| {
            crate::semantic_validation::meaning_obligations(
                &previous.observations.graph,
                std::slice::from_ref(&node.reference),
            )
            .is_empty()
                && match &node.shape {
                    TypeShape::Unknown(_) => {
                        has_bytes_wrapper || sealed_form_uses(None, &sealed_leaf_uses_bytes)
                    }
                    TypeShape::Sealed { tag, refinements } => {
                        sealed_form_uses(Some(tag), &sealed_leaf_uses_bytes)
                            || refinements
                                .iter()
                                .any(|refinement| sealed_leaf_uses_bytes(&refinement.leaf))
                    }
                    _ => false,
                }
        });
    if observes_new_grapheme_rules || observes_new_bytes_policy {
        return Err(invalid(SemanticGraphCondition::SealedLeafJudgment));
    }
    let mut graph = previous.observations.graph.clone();
    graph.profile = information.profile.clone();
    for node in &information.nodes {
        if let Some(existing) = graph
            .nodes
            .iter_mut()
            .find(|existing| existing.reference == node.reference)
        {
            if existing != node {
                return Err(invalid(SemanticGraphCondition::ExistingTypeDeclaration(
                    node.reference.clone(),
                )));
            }
        } else {
            graph.nodes.push(node.clone());
        }
    }
    let observations = VersionedSemanticGraph {
        revision: graph_revision.clone(),
        graph,
    };
    let outcome = evaluate_signature_value(
        &mut crate::semantic_validation::PreparedValidator::new(
            &observations.graph,
            crate::semantic_validation::FormatWorkspace::empty(),
        ),
        &previous.input,
    );
    let before_evidence_outcome = refinement_evidence_outcome(&previous.outcome);
    let after_evidence_outcome = refinement_evidence_outcome(&outcome);
    let value = |outcome: &neco_quotient_certificate::RefinementOutcome<
        std::result::Result<SemanticJudgment, SemanticDecisionFailure>,
        SemanticObligation,
        Vec<SemanticObligation>,
    >| match outcome {
        RefinementOutcome::Resolved(value)
        | RefinementOutcome::Residual { value, .. }
        | RefinementOutcome::Stopped { value, .. } => value.clone(),
    };
    let evaluated_before = EvaluatedAt {
        source: previous.source.clone(),
        basis: previous.basis.clone(),
        input: previous.input.clone(),
        certificate: previous.certificate.clone(),
        observations: previous.observations.clone(),
        value: value(&before_evidence_outcome),
        evidence: SemanticEvaluationEvidence {
            observations: previous.observations.clone(),
            input: previous.input.clone(),
            outcome: previous.outcome.clone(),
        },
    };
    let evaluated_after = EvaluatedAt {
        source: previous.source.clone(),
        basis: previous.basis.clone(),
        input: previous.input.clone(),
        certificate: previous.certificate.clone(),
        observations: observations.clone(),
        value: value(&after_evidence_outcome),
        evidence: SemanticEvaluationEvidence {
            observations: observations.clone(),
            input: previous.input.clone(),
            outcome: outcome.clone(),
        },
    };
    let verified = VerifiedRefinement::new(
        previous.source.clone(),
        previous.basis.clone(),
        previous.input.clone(),
        previous.certificate.clone(),
        previous.observations.clone(),
        observations.clone(),
        before_evidence_outcome,
        after_evidence_outcome,
        ObservationRefines {
            before_observations: previous.observations.clone(),
            after_observations: observations.clone(),
            evidence: SemanticGraphExtension { information },
        },
        evaluated_before,
        evaluated_after,
    )
    .map_err(|mismatch| SemanticRefinementFailure::Evidence {
        source: previous.source.clone(),
        basis: previous.basis.clone(),
        input: previous.input.clone(),
        certificate: previous.certificate.clone(),
        previous: previous.observations.clone(),
        requested_revision: graph_revision,
        mismatch,
    })?;
    let next = SignatureEvaluation {
        observations,
        outcome,
        ..previous.clone()
    };
    Ok((next, verified))
}
