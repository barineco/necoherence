// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::semantic_types::*;
use crate::type_signatures::*;
use sha2::{Digest, Sha256};
use std::sync::Arc;

pub type Result<T> = std::result::Result<T, AdmissionFailure>;
#[derive(Debug, Clone, PartialEq)]
pub enum AdmissionFailure {
    Library(LibraryCheckFailure),
    Basis(String),
    Meaning(MeaningFailure),
    Composition(String),
}
impl std::fmt::Display for AdmissionFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for AdmissionFailure {}
fn canonical_json(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::Object(members) => {
            let mut entries: Vec<_> = members.iter().collect();
            entries.sort_by(|left, right| left.0.cmp(right.0));
            let fields = entries
                .into_iter()
                .map(|(key, value)| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(key).unwrap_or_default(),
                        canonical_json(value)
                    )
                })
                .collect::<Vec<_>>()
                .join(",");
            format!("{{{fields}}}")
        }
        serde_json::Value::Array(values) => {
            format!(
                "[{}]",
                values
                    .iter()
                    .map(canonical_json)
                    .collect::<Vec<_>>()
                    .join(",")
            )
        }
        value => serde_json::to_string(value).unwrap_or_default(),
    }
}
fn hash(value: &serde_json::Value) -> String {
    format!("{:x}", Sha256::digest(canonical_json(value).as_bytes()))
}
fn wire_value<T: crate::semantic_exchange::WireEncode + ?Sized>(
    value: &T,
) -> Result<serde_json::Value> {
    crate::semantic_exchange::wire_value(value)
        .map_err(|failure| AdmissionFailure::Basis(failure.to_string()))
}
fn string_member<'a>(value: &'a serde_json::Value, key: &str) -> &'a str {
    value
        .as_object()
        .and_then(|members| members.get(key))
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
}
fn graph_projection(library: &TypeSignatureLibrary) -> Result<serde_json::Value> {
    let encoded = wire_value(library)?;
    let members = encoded
        .as_object()
        .ok_or_else(|| AdmissionFailure::Basis("library wire object".into()))?;
    let profile = members
        .get("profile")
        .cloned()
        .ok_or_else(|| AdmissionFailure::Basis("library profile".into()))?;
    let mut nodes = members
        .get("nodes")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .ok_or_else(|| AdmissionFailure::Basis("library nodes".into()))?;
    nodes.sort_by(|left, right| string_member(left, "id").cmp(string_member(right, "id")));
    let mut definitions = members
        .get("definitions")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .ok_or_else(|| AdmissionFailure::Basis("library definitions".into()))?;
    definitions.sort_by(|left, right| string_member(left, "id").cmp(string_member(right, "id")));
    for definition in &mut definitions {
        let Some(shape) = definition
            .as_object_mut()
            .and_then(|definition| definition.get_mut("shape"))
            .and_then(serde_json::Value::as_object_mut)
        else {
            continue;
        };
        if shape.get("tag").and_then(serde_json::Value::as_str) != Some("Operation") {
            continue;
        }
        let Some(outcomes) = shape
            .get_mut("value")
            .and_then(serde_json::Value::as_object_mut)
            .and_then(|operation| operation.get_mut("outcomes"))
            .and_then(serde_json::Value::as_array_mut)
        else {
            continue;
        };
        for outcome in outcomes {
            let Some(cause) = outcome
                .as_object_mut()
                .and_then(|outcome| outcome.get_mut("cause"))
            else {
                continue;
            };
            let tag = cause
                .as_object()
                .and_then(|members| members.get("tag"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_owned();
            *cause = serde_json::json!({"tag": tag});
        }
    }
    Ok(serde_json::json!({
        "profile": profile,
        "nodes": nodes,
        "definitions": definitions
    }))
}
fn provenance_projection(library: &TypeSignatureLibrary) -> Result<serde_json::Value> {
    let encoded = wire_value(library)?;
    let members = encoded
        .as_object()
        .ok_or_else(|| AdmissionFailure::Basis("library wire object".into()))?;
    let mut sources = members
        .get("sources")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .ok_or_else(|| AdmissionFailure::Basis("library sources".into()))?;
    sources.sort_by(|left, right| {
        ["repository", "revision", "path", "content_digest"]
            .map(|key| string_member(left, key))
            .cmp(
                &["repository", "revision", "path", "content_digest"]
                    .map(|key| string_member(right, key)),
            )
    });
    let mut provenance = members
        .get("provenance")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .ok_or_else(|| AdmissionFailure::Basis("library provenance".into()))?;
    provenance.sort_by(|left, right| {
        let target = |value: &serde_json::Value| {
            value
                .as_object()
                .and_then(|members| members.get("target"))
                .map(canonical_json)
                .unwrap_or_default()
        };
        target(left).cmp(&target(right))
    });
    for binding in &mut provenance {
        if let Some(origins) = binding
            .as_object_mut()
            .and_then(|members| members.get_mut("origins"))
            .and_then(serde_json::Value::as_array_mut)
        {
            origins.sort_by_key(canonical_json);
        }
    }
    let mut definitions = members
        .get("definitions")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .ok_or_else(|| AdmissionFailure::Basis("library definitions".into()))?;
    definitions.sort_by(|left, right| string_member(left, "id").cmp(string_member(right, "id")));
    let mut outcome_origins = Vec::new();
    for definition in definitions {
        let definition_id = string_member(&definition, "id").to_owned();
        let Some(shape) = definition
            .as_object()
            .and_then(|members| members.get("shape"))
            .and_then(serde_json::Value::as_object)
        else {
            continue;
        };
        if shape.get("tag").and_then(serde_json::Value::as_str) != Some("Operation") {
            continue;
        }
        let mut outcomes = shape
            .get("value")
            .and_then(serde_json::Value::as_object)
            .and_then(|operation| operation.get("outcomes"))
            .and_then(serde_json::Value::as_array)
            .cloned()
            .unwrap_or_default();
        outcomes.sort_by(|left, right| string_member(left, "id").cmp(string_member(right, "id")));
        for outcome in outcomes {
            let Some(cause) = outcome
                .as_object()
                .and_then(|members| members.get("cause"))
                .cloned()
            else {
                continue;
            };
            outcome_origins.push(serde_json::json!({
                "definition": definition_id,
                "outcome": string_member(&outcome, "id"),
                "cause": cause
            }));
        }
    }
    Ok(serde_json::json!({
        "sources": sources,
        "provenance": provenance,
        "outcome_origins": outcome_origins
    }))
}
fn metadata_projection(library: &TypeSignatureLibrary) -> Result<serde_json::Value> {
    let encoded = wire_value(library)?;
    let members = encoded
        .as_object()
        .ok_or_else(|| AdmissionFailure::Basis("library wire object".into()))?;
    let mut groups = members
        .get("groups")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .ok_or_else(|| AdmissionFailure::Basis("library groups".into()))?;
    groups.sort_by(|left, right| string_member(left, "id").cmp(string_member(right, "id")));
    for group in &mut groups {
        if let Some(group_members) = group
            .as_object_mut()
            .and_then(|members| members.get_mut("members"))
            .and_then(serde_json::Value::as_array_mut)
        {
            group_members.sort_by(|left, right| {
                left.as_str()
                    .unwrap_or_default()
                    .cmp(right.as_str().unwrap_or_default())
            });
        }
    }
    let mut annotations = members
        .get("annotations")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .ok_or_else(|| AdmissionFailure::Basis("library annotations".into()))?;
    annotations.sort_by(|left, right| {
        let key = |value: &serde_json::Value| {
            let target = value
                .as_object()
                .and_then(|members| members.get("target"))
                .map(canonical_json)
                .unwrap_or_default();
            let annotation_key = string_member(value, "key").to_owned();
            let annotation_value = value
                .as_object()
                .and_then(|members| members.get("value"))
                .map(canonical_json)
                .unwrap_or_default();
            (target, annotation_key, annotation_value)
        };
        key(left).cmp(&key(right))
    });
    Ok(serde_json::json!({
        "groups": groups,
        "annotations": annotations
    }))
}
pub fn canonical_digest(library: &TypeSignatureLibrary) -> String {
    graph_projection(library)
        .map(|projection| hash(&projection))
        .unwrap_or_default()
}
fn source(_library: &TypeSignatureLibrary, _digest: &str) -> Arc<SourceRef> {
    Arc::new(SourceRef {
        repository: "ncoh-type-signatures".into(),
        revision: "1".into(),
        path: String::new(),
        content_digest: String::new(),
        document_id: String::new(),
        declared_revision: None,
    })
}
pub fn signature_type_ref(l: &TypeSignatureLibrary, digest: &str, id: &str) -> TypeRef {
    TypeRef::new(source(l, digest), id, Vec::<String>::new())
}
pub fn signature_definition_ref(l: &TypeSignatureLibrary, digest: &str, id: &str) -> DefinitionRef {
    DefinitionRef {
        source: source(l, digest),
        name: Arc::from(id),
    }
}
fn occurrence(r: &TypeRef) -> OccurrenceRef {
    r.into()
}
pub fn check_type_signatures(l: &TypeSignatureLibrary) -> Result<SemanticGraph> {
    let checked = check_library(l).map_err(AdmissionFailure::Library)?;
    let digest = canonical_digest(l);
    let tr = |id: &str| signature_type_ref(l, &digest, id);
    let nodes = l
        .nodes
        .iter()
        .map(|n| {
            let reference = tr(&n.id);
            let o = occurrence(&reference);
            let shape = match &n.shape {
                Shape::Unknown(k) => TypeShape::Unknown(*k),
                Shape::Unit => TypeShape::Unit,
                Shape::Boolean(s) => TypeShape::Boolean(s.clone()),
                Shape::Integer(s) => TypeShape::Integer(s.clone()),
                Shape::Decimal(s) => TypeShape::Decimal(s.clone()),
                Shape::String(s) => TypeShape::String(s.clone()),
                Shape::Bytes(s) => TypeShape::Bytes(s.clone()),
                Shape::Product(p) => TypeShape::Product(ProductSpec {
                    fields: p
                        .fields
                        .iter()
                        .map(|f| FieldSpec {
                            wire_name: f.wire_name.clone(),
                            slot: SlotContract {
                                type_ref: tr(&f.slot.type_id),
                                required: f.slot.required,
                                nullable: f.slot.nullable,
                            },
                            origin: o.clone(),
                        })
                        .collect(),
                    extras: match &p.extras {
                        SignatureExtraMembers::Reject => ExtraMembers::Reject,
                        SignatureExtraMembers::Allow { key_format, value } => ExtraMembers::Allow {
                            key_format: key_format.clone(),
                            value: ElementContract {
                                type_ref: tr(&value.type_id),
                                nullable: value.nullable,
                            },
                        },
                    },
                }),
                Shape::Array(a) => TypeShape::Array(ArraySpec {
                    item: ElementContract {
                        type_ref: tr(&a.item.type_id),
                        nullable: a.item.nullable,
                    },
                    min_length: a.minimum.clone(),
                    max_length: a.maximum.clone(),
                }),
                Shape::TaggedUnion(u) => TypeShape::TaggedUnion(UnionSpec {
                    branches: u
                        .branches
                        .iter()
                        .map(|b| UnionBranch {
                            target: tr(&b.target),
                            wire_tag: b.wire_tag.clone(),
                            selector: b.selector.clone(),
                            origin: o.clone(),
                        })
                        .collect(),
                }),
                Shape::Sealed { tag, refinements } => TypeShape::Sealed {
                    tag: tag.clone(),
                    refinements: refinements.clone(),
                },
                Shape::Never => TypeShape::Never,
                Shape::Alias { target } => TypeShape::Alias {
                    target: tr(target),
                    reference_text: target.clone(),
                },
                Shape::RawBody { encoding } => TypeShape::RawBody {
                    encoding: encoding.clone(),
                },
                Shape::Opaque { type_name } => TypeShape::Opaque {
                    type_name: type_name.clone(),
                },
            };
            TypeNode {
                reference,
                shape,
                description: None,
                attributes: vec![],
                extensions: vec![],
            }
        })
        .collect();
    let graph = SemanticGraph {
        profile: checked.profile.profile,
        nodes,
        source_refs: l
            .sources
            .iter()
            .map(|s| SourceRef {
                repository: s.repository.clone(),
                revision: s.revision.clone(),
                path: s.path.clone(),
                content_digest: s.content_digest.clone(),
                document_id: String::new(),
                declared_revision: None,
            })
            .collect(),
    };
    Ok(graph)
}
fn check_shared_type_signatures(signatures: Arc<TypeSignatureLibrary>) -> Result<SemanticGraph> {
    check_type_signatures(&signatures)
}

pub fn check_signature_operation(
    library: &TypeSignatureLibrary,
    operation: &OperationContract,
) -> std::result::Result<(), String> {
    let unique = |values: Vec<&str>| {
        let mut seen = std::collections::HashSet::new();
        if values
            .into_iter()
            .any(|value| value.is_empty() || !seen.insert(value))
        {
            Err("operation identities are not unique".to_owned())
        } else {
            Ok(())
        }
    };
    unique(
        operation
            .inputs
            .iter()
            .map(|port| port.id.as_str())
            .collect(),
    )?;
    unique(
        operation
            .outcomes
            .iter()
            .map(|outcome| outcome.id.as_str())
            .collect(),
    )?;
    if !operation
        .outcomes
        .iter()
        .any(|outcome| outcome.form == OutcomeForm::Success)
    {
        return Err("operation has no success outcome".into());
    }
    let type_exists = |id: &str| library.nodes.iter().any(|node| node.id == id);
    if operation
        .inputs
        .iter()
        .any(|port| !type_exists(&port.contract.type_id))
    {
        return Err("operation input type is unresolved".into());
    }
    for outcome in &operation.outcomes {
        unique(
            outcome
                .value_ports
                .iter()
                .map(|port| port.id.as_str())
                .collect(),
        )?;
        unique(
            outcome
                .produced_resources
                .iter()
                .map(|production| production.id.as_str())
                .collect(),
        )?;
        if outcome
            .value_ports
            .iter()
            .any(|port| !type_exists(&port.contract.type_id))
            || outcome
                .produced_resources
                .iter()
                .any(|production| !type_exists(&production.token_type))
        {
            return Err("operation outcome type is unresolved".into());
        }
        if matches!(outcome.cause, OutcomeCause::ExternalCondition { .. })
            && (outcome.form != OutcomeForm::DeclaredFailure || outcome.value_ports.is_empty())
        {
            return Err("external condition is not a typed declared failure".into());
        }
    }
    Ok(())
}

pub fn check_operation_extension(
    library: &TypeSignatureLibrary,
    base: &OperationContract,
    supplied: &OperationContract,
) -> std::result::Result<(), String> {
    check_library(library).map_err(|failure| format!("{failure:?}"))?;
    check_signature_operation(library, supplied)?;
    if base.effect != supplied.effect || base.inputs != supplied.inputs {
        return Err("operation effect or inputs changed".into());
    }
    if base
        .outcomes
        .iter()
        .any(|outcome| !supplied.outcomes.contains(outcome))
    {
        return Err("base operation outcome changed".into());
    }
    if supplied.outcomes.iter().any(|outcome| {
        !base.outcomes.iter().any(|base| base.id == outcome.id)
            && !matches!(outcome.cause, OutcomeCause::ExternalCondition { .. })
    }) {
        return Err("operation supplement lacks an external condition".into());
    }
    Ok(())
}

pub fn internal_outcome(
    library: &TypeSignatureLibrary,
    digest: &str,
    outcome: &SignatureOutcome,
) -> crate::semantic_composition::OutcomeContract {
    use crate::semantic_composition::{
        OutcomeContract, OutcomeForm as NativeOutcomeForm, OutcomeId, OutputPort, PortId,
        ProductionId, ResourceProduction,
    };
    let slot = |slot: &SignatureSlot| SlotContract {
        type_ref: signature_type_ref(library, digest, &slot.type_id),
        required: slot.required,
        nullable: slot.nullable,
    };
    OutcomeContract {
        id: OutcomeId(outcome.id.clone()),
        form: match outcome.form {
            OutcomeForm::Success => NativeOutcomeForm::Success,
            OutcomeForm::DeclaredFailure => NativeOutcomeForm::DeclaredFailure,
        },
        value_ports: outcome
            .value_ports
            .iter()
            .map(|port| OutputPort {
                id: PortId(port.id.clone()),
                contract: slot(&port.contract),
                resource_production: None,
            })
            .collect(),
        produced_resources: outcome
            .produced_resources
            .iter()
            .map(|production| ResourceProduction {
                id: ProductionId(production.id.clone()),
                token_type: signature_type_ref(library, digest, &production.token_type),
                revision: production.revision.clone(),
                quantity: production.quantity.clone(),
                provenance: production.provenance.clone(),
            })
            .collect(),
    }
}
#[derive(Debug, Clone, PartialEq)]
pub struct CheckedSignatureGeneration {
    pub(crate) input: SignatureGenerationInput,
    pub(crate) graph: SemanticGraph,
}
impl CheckedSignatureGeneration {
    pub fn graph(&self) -> &SemanticGraph {
        &self.graph
    }
    pub fn input(&self) -> &SignatureGenerationInput {
        &self.input
    }
}
pub fn admit_signature_generation(
    expected: &SignatureGenerationBasis,
    input: SignatureGenerationInput,
) -> Result<CheckedSignatureGeneration> {
    if input.schema != "ncoh-checked-generation@4" || &input.basis != expected {
        return Err(AdmissionFailure::Basis("generation basis".into()));
    }
    let recomputed = signature_basis(
        &input.signatures,
        input.composition.as_ref(),
        &input.entrypoints,
    )?;
    if recomputed != input.basis {
        return Err(AdmissionFailure::Basis("generation digest".into()));
    }
    let mut identities = std::collections::HashSet::new();
    if input.entrypoints.iter().any(|entrypoint| {
        entrypoint.identity.is_empty()
            || !identities.insert(&entrypoint.identity)
            || !input
                .signatures
                .definitions
                .iter()
                .any(|definition| definition.id == entrypoint.definition)
    }) {
        return Err(AdmissionFailure::Basis("generation entrypoint".into()));
    }
    let graph = check_shared_type_signatures(input.signatures.clone())?;
    crate::semantic_exchange::decode_signature_composition(&input, &graph)
        .map_err(|failure| AdmissionFailure::Composition(failure.to_string()))?;
    Ok(CheckedSignatureGeneration { input, graph })
}
pub fn signature_basis(
    library: &TypeSignatureLibrary,
    composition: Option<&SignatureComposition>,
    entrypoints: &[SignatureEntrypoint],
) -> Result<SignatureGenerationBasis> {
    let graph = check_type_signatures(library)?;
    let graph_projection = graph_projection(library)?;
    let provenance_projection = provenance_projection(library)?;
    let metadata_projection = metadata_projection(library)?;
    let problem_sha256 = composition.map(wire_value).transpose()?.as_ref().map(hash);
    let mut ordered_entrypoints = entrypoints.to_vec();
    ordered_entrypoints.sort_by(|left, right| left.identity.cmp(&right.identity));
    let encoded_entrypoints = wire_value(&ordered_entrypoints)?;
    Ok(SignatureGenerationBasis {
        signature_schema: library.schema.clone(),
        library_identity: library.identity.clone(),
        library_revision: library.revision.clone(),
        profile: graph.profile.reference.clone(),
        graph_sha256: hash(&graph_projection),
        provenance_sha256: hash(&provenance_projection),
        metadata_sha256: hash(&metadata_projection),
        problem_sha256,
        entrypoints_sha256: hash(&encoded_entrypoints),
    })
}
pub fn assemble_signature_generation(
    signatures: TypeSignatureLibrary,
    composition: Option<SignatureComposition>,
    entrypoints: Vec<SignatureEntrypoint>,
) -> Result<SignatureGenerationInput> {
    let signatures = Arc::new(signatures);
    check_shared_type_signatures(signatures.clone())?;
    let basis = signature_basis(&signatures, composition.as_ref(), &entrypoints)?;
    Ok(SignatureGenerationInput {
        schema: "ncoh-checked-generation@4".into(),
        basis,
        signatures,
        composition,
        entrypoints,
    })
}
