// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::semantic_composition::*;
use crate::typed_mapping as resource;

macro_rules! wire_identifier {
    ($($type:ty),* $(,)?) => { $(
        impl WireEncode for $type {
            fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_newtype_struct(stringify!($type), &self.0)
            }
        }
        impl WireDecode for $type {
            fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
                String::decode_wire(value, path).map(Self)
            }
        }
    )* };
}

impl WireEncode for TypeObligation {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut record = serializer.serialize_struct("TypeObligation", 3)?;
        record.serialize_field("source", &Wire(&self.pair.source.type_ref))?;
        record.serialize_field("destination", &Wire(&self.pair.destination.type_ref))?;
        record.serialize_field("reason", &Wire(&self.reason))?;
        record.end()
    }
}
impl WireDecode for TypeObligation {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        let members = keys(value, path, &["source", "destination", "reason"])?;
        let source =
            TypeRef::decode_wire(field(members, path, "source")?, &field_path(path, "source"))?;
        let destination = TypeRef::decode_wire(
            field(members, path, "destination")?,
            &field_path(path, "destination"),
        )?;
        let reason = TypeObligationReason::decode_wire(
            field(members, path, "reason")?,
            &field_path(path, "reason"),
        )?;
        Ok(Self {
            pair: TypePair {
                source: present_contract(source),
                destination: present_contract(destination),
                source_tag: None,
            },
            path: vec![],
            reason,
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct GenerationComposition {
    pub problem: CompositionInput,
    pub plan: CompositionPlan,
    pub causes: Vec<CauseBinding>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CauseBinding {
    pub function: FunctionRef,
    pub outcome: OutcomeId,
    pub cause: OutcomeCause,
}
fn signature_contract(
    causes: &[CauseBinding],
    function: &FunctionSignature,
) -> Result<OperationContract, SignatureContractFailure> {
    let outcomes = function
        .outcomes
        .iter()
        .map(|outcome| {
            let cause = causes
                .iter()
                .find(|binding| {
                    binding.function == function.reference && binding.outcome == outcome.id
                })
                .ok_or_else(|| SignatureContractFailure::MissingOutcomeCause {
                    function: function.reference.clone(),
                    outcome: outcome.id.clone(),
                })?
                .cause
                .clone();
            Ok(SignatureOutcome {
                id: outcome.id.0.clone(),
                form: match outcome.form {
                    crate::semantic_composition::OutcomeForm::Success => {
                        crate::type_signatures::OutcomeForm::Success
                    }
                    crate::semantic_composition::OutcomeForm::DeclaredFailure => {
                        crate::type_signatures::OutcomeForm::DeclaredFailure
                    }
                },
                cause,
                value_ports: outcome
                    .value_ports
                    .iter()
                    .map(|port| SignaturePort {
                        id: port.id.0.clone(),
                        contract: SignatureSlot {
                            type_id: port.contract.type_ref.definition_name.to_string(),
                            required: port.contract.required,
                            nullable: port.contract.nullable,
                        },
                    })
                    .collect(),
                produced_resources: outcome
                    .produced_resources
                    .iter()
                    .map(|production| SignatureResourceProduction {
                        id: production.id.0.clone(),
                        token_type: production.token_type.definition_name.to_string(),
                        revision: production.revision.clone(),
                        quantity: production.quantity.clone(),
                        provenance: production.provenance.clone(),
                    })
                    .collect(),
            })
        })
        .collect::<Result<Vec<_>, SignatureContractFailure>>()?;
    Ok(OperationContract {
        effect: match function.effect {
            CompositionEffect::HttpRequestResponse => EffectPoint::HttpRequestResponse,
            _ => EffectPoint::DataOnly,
        },
        inputs: function
            .inputs
            .iter()
            .map(|port| SignaturePort {
                id: port.id.0.clone(),
                contract: SignatureSlot {
                    type_id: port.contract.type_ref.definition_name.to_string(),
                    required: port.contract.required,
                    nullable: port.contract.nullable,
                },
            })
            .collect(),
        outcomes,
    })
}
pub fn prepare_signature_composition<'g>(
    library: &'g TypeSignatureLibrary,
    graph_digest: &'g str,
    graph: &'g SemanticGraph,
    input: CompositionInput,
    causes: &'g [CauseBinding],
) -> Result<PreparedCompositionInput<'g>, CompositionInputFailure> {
    crate::type_signatures::check_library(library)
        .map_err(CompositionInputFailure::InvalidLibrary)?;
    for function in &input.signatures {
        let contract = signature_contract(causes, function).map_err(|reason| {
            CompositionInputFailure::InvalidSignature {
                function: function.reference.clone(),
                reason: InvalidSignatureReason::Contract(reason),
            }
        })?;
        if !contract
            .outcomes
            .iter()
            .all(|outcome| crate::type_signatures::outcome_valid(library, outcome))
        {
            return Err(CompositionInputFailure::InvalidSignature {
                function: function.reference.clone(),
                reason: InvalidSignatureReason::OutcomeCauseOrExternalFailureValue,
            });
        }
    }
    let operation_checker: OperationChecker<'g> = Arc::new(move |function, reference| {
        let invalid = |reason: InvalidSignatureReason| CompositionInputFailure::InvalidSignature {
            function: function.reference.clone(),
            reason,
        };
        let definition = library
            .definitions
            .iter()
            .find(|definition| definition.id.as_str() == reference.name.as_ref())
            .ok_or_else(|| invalid(InvalidSignatureReason::UnresolvedOperationIdentity))?;
        let SignatureDefinitionShape::Operation(base) = &definition.shape else {
            return Err(invalid(InvalidSignatureReason::DefinitionIsNotAnOperation));
        };
        if function.reference.identity != definition.wire_identity
            || function.reference.revision != library.revision
            || function.reference.content_digest != graph_digest
        {
            return Err(invalid(InvalidSignatureReason::OperationIdentityBasis));
        }
        let extended = signature_contract(causes, function).map_err(|reason| {
            invalid(InvalidSignatureReason::Contract(reason))
        })?;
        let expected = match base.effect {
            EffectPoint::HttpRequestResponse => CompositionEffect::HttpRequestResponse,
            EffectPoint::DataOnly => CompositionEffect::DataOnly,
        };
        if function.effect != expected {
            return Err(invalid(InvalidSignatureReason::OperationEffect));
        }
        if crate::type_signatures::operation_extension_valid(base, &extended, library) {
            Ok(())
        } else {
            Err(invalid(
                InvalidSignatureReason::BaseOutcomePreservationOrExternalSupplement,
            ))
        }
    });
    let operation_meaning: OperationMeaning<'g> =
        crate::semantic_composition::operation_meaning_of(graph);
    prepare_direct_composition(graph, input, operation_checker, operation_meaning)
}




pub fn decode_signature_problem(
    library: &TypeSignatureLibrary,
    value: &serde_json::Value,
) -> Result<CompositionInput, crate::signature_admission::AdmissionFailure> {
    use crate::signature_admission::AdmissionFailure;
    let (problem, causes) = crate::signature_composition_codec::decode_problem(
        library,
        value,
        "$.composition.problem",
    )
    .map_err(AdmissionFailure::Wire)?;
    let graph = crate::signature_admission::check_type_signatures(library)?;
    let graph_digest = crate::signature_admission::canonical_digest(library)?;
    prepare_signature_composition(library, &graph_digest, &graph, problem.clone(), &causes)
        .map_err(AdmissionFailure::CompositionInput)?;
    Ok(problem)
}
pub enum SignatureCompositionAdmissionFailure {
    Wire(GenerationFailure),
    CompositionInput(CompositionInputFailure),
    Composition(WitnessFailure),
}
pub fn composition_or_wire(failure: GenerationFailure) -> SignatureCompositionAdmissionFailure {
    match failure {
        GenerationFailure::Composition(failure) => {
            SignatureCompositionAdmissionFailure::Composition(failure)
        }
        failure => SignatureCompositionAdmissionFailure::Wire(failure),
    }
}
pub fn composition_members(
    composition: &serde_json::Value,
) -> Result<(&serde_json::Value, &serde_json::Value), GenerationFailure> {
    let serde_json::Value::Object(members) = composition else {
        return Err(syntax("$", "object expected"));
    };
    keys(
        &crate::signature_composition_codec::to_exchange(composition)?,
        "$",
        &["problem", "derivation"],
    )?;
    let member = |name: &str| {
        members
            .get(name)
            .ok_or_else(|| syntax(&format!("$.{name}"), "missing field"))
    };
    Ok((member("problem")?, member("derivation")?))
}
pub(crate) fn decode_signature_composition_wire(
    input: &SignatureGenerationInput,
    graph: &SemanticGraph,
) -> Result<Option<GenerationComposition>, SignatureCompositionAdmissionFailure> {
    let Some(composition) = &input.composition else {
        return Ok(None);
    };
    let (problem_value, derivation_value) = composition_members(composition)
        .map_err(SignatureCompositionAdmissionFailure::Wire)?;
    let library_basis = crate::signature_composition_codec::library_basis(&input.signatures);
    let (problem, causes) = crate::signature_composition_codec::decode_problem_with_basis(
        &input.signatures,
        &library_basis,
        problem_value,
        "$.composition.problem",
    )
    .map_err(SignatureCompositionAdmissionFailure::Wire)?;
    let graph_digest = crate::signature_admission::canonical_digest(&input.signatures).map_err(|failure| {
        SignatureCompositionAdmissionFailure::Wire(GenerationFailure::Admission(Box::new(failure)))
    })?;
    let prepared = prepare_signature_composition(
        &input.signatures,
        &graph_digest,
        graph,
        problem.clone(),
        &causes,
    )
    .map_err(SignatureCompositionAdmissionFailure::CompositionInput)?;
    let problem_json = crate::signature_composition_codec::to_exchange(problem_value)
        .map_err(SignatureCompositionAdmissionFailure::Wire)?;
    let derivation_json = crate::signature_composition_codec::to_exchange(derivation_value)
        .map_err(SignatureCompositionAdmissionFailure::Wire)?;
    let plan = crate::signature_derivation_codec::decode_plan(
        &input.signatures,
        &library_basis,
        graph,
        &prepared,
        &problem,
        &problem_json,
        &derivation_json,
    )
    .map_err(composition_or_wire)?;
    drop(prepared);
    Ok(Some(GenerationComposition {
        problem,
        plan,
        causes,
    }))
}
pub fn signature_generation_context(
    expected: &crate::type_signatures::ExpectedSignatureBasis,
    text: &str,
) -> Decoded<crate::signature_admission::CheckedSignatureGeneration> {
    let input = decode_signature_generation(text)?;
    crate::signature_admission::admit_signature_generation(expected, input)
        .map_err(|failure| GenerationFailure::Admission(Box::new(failure)))
}
