// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::semantic_types::*;
use crate::type_signatures::*;
use neco_quotient_certificate::{
    DigestScope, DuplicateRule, Mismatch, ProjectionDigest, ProjectionDigests, Rule, RuleTable,
};
use sha2::{Digest, Sha256};
use std::sync::{Arc, OnceLock};

pub type Result<T> = std::result::Result<T, AdmissionFailure>;
#[derive(Debug, Clone, PartialEq)]
pub enum AdmissionFailure {
    UnsupportedSchema(String),
    EntrypointsEmpty,
    EntrypointIdentityEmpty,
    EntrypointDuplicate(String),
    EntrypointUnresolved {
        identity: String,
        definition: DefinitionId,
    },
    Library(LibraryCheckFailure),
    Certificate(Mismatch<String>),
    Wire(crate::semantic_exchange::GenerationFailure),
    CompositionInput(crate::semantic_composition::CompositionInputFailure),
    Composition(crate::semantic_composition::WitnessFailure),
    Generation(crate::semantic_exchange::GenerationFailure),
    RuleTable(DuplicateRule),
}
impl std::fmt::Display for AdmissionFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for AdmissionFailure {}
fn lean_string(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len() + 2);
    escaped.push('"');
    for character in text.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            control if u32::from(control) < 0x20 => {
                escaped.push_str(&format!("\\u{:04x}", u32::from(control)));
            }
            other => escaped.push(other),
        }
    }
    escaped.push('"');
    escaped
}
fn canonical_json(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::Object(members) => {
            let mut entries: Vec<_> = members.iter().collect();
            entries.sort_by(|left, right| left.0.cmp(right.0));
            let fields = entries
                .into_iter()
                .map(|(key, value)| format!("{}:{}", lean_string(key), canonical_json(value)))
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
        serde_json::Value::String(text) => lean_string(text),
        serde_json::Value::Number(number) => {
            let text = number.to_string();
            crate::exact_json::LeanNumber::parse(&text)
                .map_or(text, |number| number.canonical_text())
        }
        value => value.to_string(),
    }
}
fn hash(value: &serde_json::Value) -> String {
    format!("{:x}", Sha256::digest(canonical_json(value).as_bytes()))
}
#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod canonical_json_tests {
    use super::canonical_json;

    #[test]
    fn control_characters_are_escaped_in_lean_form() {
        let value = serde_json::json!({"b": "x\ty", "a": "\u{8}\u{c}\u{1b}\"\\\n\r"});
        assert_eq!(
            canonical_json(&value),
            r#"{"a":"\u0008\u000c\u001b\"\\\n\r","b":"x\u0009y"}"#
        );
    }

    #[test]
    fn numbers_are_printed_in_lean_json_compress_form() {
        let value: serde_json::Value =
            serde_json::from_str(r#"{"a":[1.50,1e2,1.0,10e-1,0.0,-0.0,1e-20]}"#).unwrap();
        assert_eq!(
            canonical_json(&value),
            r#"{"a":[1.5,100,1,1,0,0,0.0000000001e-10]}"#
        );
    }
}
fn wire_value<T: crate::semantic_exchange::WireEncode + ?Sized>(
    value: &T,
) -> Result<serde_json::Value> {
    crate::semantic_exchange::wire_value(value).map_err(AdmissionFailure::Generation)
}
fn shape_failure(path: &str, message: &str) -> AdmissionFailure {
    AdmissionFailure::Wire(crate::semantic_exchange::syntax(path, message))
}
fn required<'a>(
    value: &'a serde_json::Value,
    path: &str,
    key: &str,
) -> Result<&'a serde_json::Value> {
    value
        .as_object()
        .and_then(|members| members.get(key))
        .ok_or_else(|| shape_failure(&format!("{path}.{key}"), "required field"))
}
fn required_string<'a>(value: &'a serde_json::Value, path: &str, key: &str) -> Result<&'a str> {
    required(value, path, key)?
        .as_str()
        .ok_or_else(|| shape_failure(&format!("{path}.{key}"), "String expected"))
}
fn required_array(
    value: &serde_json::Value,
    path: &str,
    key: &str,
) -> Result<Vec<serde_json::Value>> {
    value
        .as_object()
        .and_then(|members| members.get(key))
        .and_then(serde_json::Value::as_array)
        .cloned()
        .ok_or_else(|| shape_failure(&format!("{path}.{key}"), "array"))
}
fn root_object(encoded: &serde_json::Value) -> Result<()> {
    if encoded.is_object() {
        Ok(())
    } else {
        Err(shape_failure("$", "object"))
    }
}
fn sorted_by_keys(
    items: Vec<serde_json::Value>,
    path: &str,
    keys: &[&str],
) -> Result<Vec<serde_json::Value>> {
    let mut keyed = items
        .into_iter()
        .map(|item| {
            let key = keys
                .iter()
                .map(|key| required_string(&item, path, key).map(str::to_owned))
                .collect::<Result<Vec<_>>>()?;
            Ok((key, item))
        })
        .collect::<Result<Vec<_>>>()?;
    keyed.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(keyed.into_iter().map(|(_, item)| item).collect())
}
fn graph_projection(library: &TypeSignatureLibrary) -> Result<serde_json::Value> {
    graph_projection_of(&wire_value(library)?)
}
fn graph_projection_of(encoded: &serde_json::Value) -> Result<serde_json::Value> {
    root_object(encoded)?;
    let profile = encoded
        .get("profile")
        .cloned()
        .ok_or_else(|| shape_failure("$.profile", "required field"))?;
    let nodes = sorted_by_keys(required_array(encoded, "$", "nodes")?, "$.nodes", &["id"])?;
    let mut definitions = sorted_by_keys(
        required_array(encoded, "$", "definitions")?,
        "$.definitions",
        &["id"],
    )?;
    for definition in &mut definitions {
        let shape = definition
            .as_object_mut()
            .and_then(|definition| definition.get_mut("shape"))
            .ok_or_else(|| shape_failure("$.definitions.shape", "required field"))?;
        if shape.get("tag").and_then(serde_json::Value::as_str) != Some("Operation") {
            continue;
        }
        let outcomes = shape
            .get_mut("value")
            .and_then(|operation| operation.get_mut("outcomes"))
            .and_then(serde_json::Value::as_array_mut)
            .ok_or_else(|| shape_failure("$.definitions.shape.value.outcomes", "array"))?;
        for outcome in outcomes {
            let cause = outcome
                .as_object_mut()
                .and_then(|outcome| outcome.get_mut("cause"))
                .ok_or_else(|| {
                    shape_failure("$.definitions.shape.value.outcomes.cause", "required field")
                })?;
            let tag = required_string(cause, "$.definitions.shape.value.outcomes.cause", "tag")?
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
    provenance_projection_of(&wire_value(library)?)
}
fn provenance_projection_of(encoded: &serde_json::Value) -> Result<serde_json::Value> {
    root_object(encoded)?;
    let sources = sorted_by_keys(
        required_array(encoded, "$", "sources")?,
        "$.sources",
        &["repository", "revision", "path", "content_digest"],
    )?;
    let mut provenance_keyed = required_array(encoded, "$", "provenance")?
        .into_iter()
        .map(|binding| {
            let target = canonical_json(required(&binding, "$.provenance", "target")?);
            Ok((target, binding))
        })
        .collect::<Result<Vec<_>>>()?;
    provenance_keyed.sort_by(|left, right| left.0.cmp(&right.0));
    let mut provenance: Vec<serde_json::Value> = provenance_keyed
        .into_iter()
        .map(|(_, binding)| binding)
        .collect();
    for binding in &mut provenance {
        let origins = binding
            .as_object_mut()
            .and_then(|members| members.get_mut("origins"))
            .and_then(serde_json::Value::as_array_mut)
            .ok_or_else(|| shape_failure("$.provenance.origins", "array"))?;
        origins.sort_by_key(canonical_json);
    }
    let definitions = sorted_by_keys(
        required_array(encoded, "$", "definitions")?,
        "$.definitions",
        &["id"],
    )?;
    let mut outcome_origins = Vec::new();
    for definition in definitions {
        let definition_id = required_string(&definition, "$.definitions", "id")?.to_owned();
        let shape = required(&definition, "$.definitions", "shape")?;
        if shape.get("tag").and_then(serde_json::Value::as_str) != Some("Operation") {
            continue;
        }
        let operation = required(shape, "$.definitions.shape", "value")?;
        let outcomes = sorted_by_keys(
            required_array(operation, "$.definitions.shape.value", "outcomes")?,
            "$.definitions.shape.value.outcomes",
            &["id"],
        )?;
        for outcome in outcomes {
            let outcome_path = "$.definitions.shape.value.outcomes";
            let outcome_id = required_string(&outcome, outcome_path, "id")?.to_owned();
            let cause = required(&outcome, outcome_path, "cause")?.clone();
            outcome_origins.push(serde_json::json!({
                "definition": definition_id.clone(),
                "outcome": outcome_id,
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
    metadata_projection_of(&wire_value(library)?)
}
fn metadata_projection_of(encoded: &serde_json::Value) -> Result<serde_json::Value> {
    root_object(encoded)?;
    let mut groups = sorted_by_keys(required_array(encoded, "$", "groups")?, "$.groups", &["id"])?;
    for group in &mut groups {
        let group_members = group
            .as_object_mut()
            .and_then(|members| members.get_mut("members"))
            .and_then(serde_json::Value::as_array_mut)
            .ok_or_else(|| shape_failure("$.groups.members", "array"))?;
        let mut names = group_members
            .iter()
            .map(|member| {
                member
                    .as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| shape_failure("$.groups.members", "String expected"))
            })
            .collect::<Result<Vec<_>>>()?;
        names.sort();
        *group_members = names.into_iter().map(serde_json::Value::String).collect();
    }
    let mut annotations_keyed = required_array(encoded, "$", "annotations")?
        .into_iter()
        .map(|annotation| {
            let path = "$.annotations";
            let target = canonical_json(required(&annotation, path, "target")?);
            let key = required_string(&annotation, path, "key")?.to_owned();
            let value = canonical_json(required(&annotation, path, "value")?);
            Ok(((target, key, value), annotation))
        })
        .collect::<Result<Vec<_>>>()?;
    annotations_keyed.sort_by(|left, right| left.0.cmp(&right.0));
    let annotations: Vec<serde_json::Value> = annotations_keyed
        .into_iter()
        .map(|(_, annotation)| annotation)
        .collect();
    Ok(serde_json::json!({
        "groups": groups,
        "annotations": annotations
    }))
}
pub fn canonical_digest(library: &TypeSignatureLibrary) -> Result<String> {
    graph_projection(library).map(|projection| hash(&projection))
}
fn source() -> Arc<SourceRef> {
    Arc::new(SourceRef {
        repository: "ncoh-type-signatures".into(),
        revision: "1".into(),
        path: String::new(),
        content_digest: String::new(),
        document_id: String::new(),
        declared_revision: None,
    })
}
pub fn signature_type_ref(id: &str) -> TypeRef {
    TypeRef::new(source(), id, Vec::<String>::new())
}
pub fn signature_definition_ref(id: &str) -> DefinitionRef {
    DefinitionRef {
        source: source(),
        name: Arc::from(id),
    }
}
fn occurrence(r: &TypeRef) -> OccurrenceRef {
    r.into()
}
pub fn check_type_signatures(l: &TypeSignatureLibrary) -> Result<SemanticGraph> {
    let checked = check_library(l).map_err(AdmissionFailure::Library)?;
    let tr = |id: &str| signature_type_ref(id);
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
                    reference_text: String::new(),
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
        profile: checked.into_profile(),
        nodes,
        source_refs: vec![],
    };
    Ok(graph)
}
type Observations = Option<crate::goal_observations::GoalObservations>;
pub type GenerationAdmission = neco_quotient_certificate::Checked<
    'static,
    String,
    String,
    GenerationCoordinate,
    Observations,
    (),
    GenerationEvidence,
>;
#[derive(Debug)]
pub struct CheckedSignatureGeneration {
    pub(crate) input: SignatureGenerationInput,
    pub(crate) graph: SemanticGraph,
    pub(crate) composition: Option<crate::semantic_exchange::GenerationComposition>,
    pub(crate) admission: GenerationAdmission,
}
impl CheckedSignatureGeneration {
    pub fn admission(&self) -> &GenerationAdmission {
        &self.admission
    }
    pub fn graph(&self) -> &SemanticGraph {
        &self.graph
    }
    pub fn input(&self) -> &SignatureGenerationInput {
        &self.input
    }
    pub fn composition(&self) -> Option<&crate::semantic_exchange::GenerationComposition> {
        self.composition.as_ref()
    }
    pub fn prepare_admission(
        &self,
    ) -> std::result::Result<
        Option<PreparedAdmission<'_>>,
        crate::semantic_composition::CompositionInputFailure,
    > {
        let Some(composition) = &self.composition else {
            return Ok(None);
        };
        let prepared = crate::semantic_composition::prepare_direct_composition(
            &self.graph,
            composition.problem.clone(),
            crate::semantic_composition::operation_checker_without_library(),
            crate::semantic_composition::operation_meaning_of(&self.graph),
        )?;
        Ok(Some(PreparedAdmission {
            prepared,
            plan: &composition.plan,
        }))
    }
}
pub struct PreparedAdmission<'g> {
    prepared: crate::semantic_composition::PreparedCompositionInput<'g>,
    plan: &'g crate::semantic_composition::CompositionPlan,
}
impl<'g> PreparedAdmission<'g> {
    pub fn prepared(&self) -> &crate::semantic_composition::PreparedCompositionInput<'g> {
        &self.prepared
    }
    pub fn admitted(&self) -> crate::semantic_composition::AdmittedComposition<'_, 'g> {
        crate::semantic_composition::AdmittedComposition::from_admission(&self.prepared, self.plan)
    }
}
const GENERATION_RULE: &str = "ncoh-checked-generation@5";
const CERTIFICATE_OPERATION: &str = "admit_signature_generation";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryMetadata {
    signature_schema: String,
    library_identity: String,
    library_revision: String,
    profile: ProfileRef,
}

impl LibraryMetadata {
    fn from_basis(basis: &SignatureGenerationBasis) -> Self {
        Self {
            signature_schema: basis.signature_schema.clone(),
            library_identity: basis.library_identity.clone(),
            library_revision: basis.library_revision.clone(),
            profile: basis.profile.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerationCoordinate {
    signature_schema: String,
    profile: ProfileRef,
    graph_sha256: String,
    provenance_sha256: String,
    metadata_sha256: String,
    problem_sha256: Option<String>,
    observations_sha256: Option<String>,
    entrypoints_sha256: String,
    actual_library_metadata: LibraryMetadata,
}

impl GenerationCoordinate {
    fn new(basis: &SignatureGenerationBasis, actual_library_metadata: LibraryMetadata) -> Self {
        Self {
            signature_schema: basis.signature_schema.clone(),
            profile: basis.profile.clone(),
            graph_sha256: basis.graph_sha256.clone(),
            provenance_sha256: basis.provenance_sha256.clone(),
            metadata_sha256: basis.metadata_sha256.clone(),
            problem_sha256: basis.problem_sha256.clone(),
            observations_sha256: basis.observations_sha256.clone(),
            entrypoints_sha256: basis.entrypoints_sha256.clone(),
            actual_library_metadata,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerationEvidence {
    graph: serde_json::Value,
    provenance: serde_json::Value,
    metadata: serde_json::Value,
    entrypoints: serde_json::Value,
    composition: Option<serde_json::Value>,
}

struct GenerationComponents {
    graph: SemanticGraph,
    actual_library_metadata: LibraryMetadata,
    evidence: GenerationEvidence,
}

fn generation_components(
    library: &TypeSignatureLibrary,
    composition: Option<&serde_json::Value>,
    entrypoints: &[SignatureEntrypoint],
) -> Result<GenerationComponents> {
    let graph = check_type_signatures(library)?;
    let actual_library_metadata = LibraryMetadata {
        signature_schema: library.schema.clone(),
        library_identity: library.identity.clone(),
        library_revision: library.revision.clone(),
        profile: graph.profile.reference.clone(),
    };
    let graph_value = graph_projection(library)?;
    let provenance = provenance_projection(library)?;
    let metadata = metadata_projection(library)?;
    let mut ordered_entrypoints = entrypoints.to_vec();
    ordered_entrypoints.sort_by(|left, right| left.identity.cmp(&right.identity));
    let entrypoints_value = wire_value(&ordered_entrypoints)?;
    let composition_value = composition.cloned();
    Ok(GenerationComponents {
        graph,
        actual_library_metadata,
        evidence: GenerationEvidence {
            graph: graph_value,
            provenance,
            metadata,
            entrypoints: entrypoints_value,
            composition: composition_value,
        },
    })
}

fn prepare_generation(input: &SignatureGenerationInput) -> Result<GenerationComponents> {
    generation_components(
        &input.signatures,
        input.composition.as_ref(),
        &input.entrypoints,
    )
}

fn scoped_digest(digest: String) -> ProjectionDigest {
    ProjectionDigest {
        digest,
        scope: DigestScope::CrossLanguage("sha256".to_owned()),
    }
}

fn projection_digests(
    entrypoints: String,
    graph: String,
    metadata: String,
    problem: Option<String>,
    observations: Option<String>,
    provenance: String,
) -> ProjectionDigests {
    let mut digests = ProjectionDigests::new();
    digests.insert("entrypoints".to_owned(), scoped_digest(entrypoints));
    digests.insert("graph".to_owned(), scoped_digest(graph));
    digests.insert("metadata".to_owned(), scoped_digest(metadata));
    if let Some(problem) = problem {
        digests.insert("problem".to_owned(), scoped_digest(problem));
    }
    if let Some(observations) = observations {
        digests.insert("observations".to_owned(), scoped_digest(observations));
    }
    digests.insert("provenance".to_owned(), scoped_digest(provenance));
    digests
}

fn certified_digests(basis: &SignatureGenerationBasis) -> ProjectionDigests {
    projection_digests(
        basis.entrypoints_sha256.clone(),
        basis.graph_sha256.clone(),
        basis.metadata_sha256.clone(),
        basis.problem_sha256.clone(),
        basis.observations_sha256.clone(),
        basis.provenance_sha256.clone(),
    )
}

type CompositionDecoding = std::result::Result<
    Option<crate::semantic_exchange::GenerationComposition>,
    crate::semantic_exchange::SignatureCompositionAdmissionFailure,
>;

fn certificate_observations(
    input: &SignatureGenerationInput,
    decoding: &CompositionDecoding,
) -> Observations {
    let composition = input.composition.as_ref()?;
    Some(if decoding.is_ok() {
        crate::goal_observations::GoalObservations::of_plan(composition)
    } else {
        crate::goal_observations::GoalObservations::of_composition(composition)
    })
}

fn observations_of(composition: Option<&serde_json::Value>) -> Observations {
    composition.map(crate::goal_observations::GoalObservations::of_composition)
}

pub fn source_of(
    basis: &SignatureGenerationBasis,
) -> neco_quotient_certificate::SourceRef<String, String> {
    neco_quotient_certificate::SourceRef {
        identity: basis.library_identity.clone(),
        revision: basis.library_revision.clone(),
    }
}

struct GenerationRule;

impl Rule<String, String, GenerationCoordinate, Observations, GenerationEvidence>
    for GenerationRule
{
    fn recompute(
        &self,
        _source: &neco_quotient_certificate::SourceRef<String, String>,
        _coordinate: &GenerationCoordinate,
        _observations: &Observations,
        evidence: &GenerationEvidence,
    ) -> ProjectionDigests {
        projection_digests(
            hash(&evidence.entrypoints),
            hash(&evidence.graph),
            hash(&evidence.metadata),
            evidence.composition.as_ref().map(hash),
            observations_of(evidence.composition.as_ref())
                .map(|observations| hash(observations.value())),
            hash(&evidence.provenance),
        )
    }
}

type GenerationTable =
    RuleTable<String, String, GenerationCoordinate, Observations, GenerationEvidence>;

static GENERATION_TABLE: OnceLock<GenerationTable> = OnceLock::new();

fn generation_table() -> std::result::Result<&'static GenerationTable, DuplicateRule> {
    if let Some(table) = GENERATION_TABLE.get() {
        return Ok(table);
    }
    let rule: Box<
        dyn Rule<String, String, GenerationCoordinate, Observations, GenerationEvidence>
            + Send
            + Sync,
    > = Box::new(GenerationRule);
    let table = RuleTable::new(vec![(GENERATION_RULE.to_owned(), rule)])?;
    Ok(GENERATION_TABLE.get_or_init(|| table))
}

pub fn admit_signature_generation(
    expected: &ExpectedSignatureBasis,
    input: SignatureGenerationInput,
) -> Result<CheckedSignatureGeneration> {
    if input.schema != GENERATION_RULE {
        return Err(AdmissionFailure::UnsupportedSchema(input.schema));
    }
    if input.entrypoints.is_empty() && input.composition.is_none() {
        return Err(AdmissionFailure::EntrypointsEmpty);
    }
    if input
        .entrypoints
        .iter()
        .any(|entrypoint| entrypoint.identity.is_empty())
    {
        return Err(AdmissionFailure::EntrypointIdentityEmpty);
    }
    let mut identities = std::collections::HashSet::new();
    if let Some(entrypoint) = input
        .entrypoints
        .iter()
        .find(|entrypoint| !identities.insert(&entrypoint.identity))
    {
        return Err(AdmissionFailure::EntrypointDuplicate(
            entrypoint.identity.clone(),
        ));
    }
    if let Some(entrypoint) = input.entrypoints.iter().find(|entrypoint| {
        !input
            .signatures
            .definitions
            .iter()
            .any(|definition| definition.id == entrypoint.definition)
    }) {
        return Err(AdmissionFailure::EntrypointUnresolved {
            identity: entrypoint.identity.clone(),
            definition: entrypoint.definition.clone(),
        });
    }
    let GenerationComponents {
        graph,
        actual_library_metadata,
        evidence,
    } = prepare_generation(&input)?;
    let decoding = crate::semantic_exchange::decode_signature_composition_wire(&input, &graph);
    let certificate = neco_quotient_certificate::Certificate {
        rule_revision: input.schema.clone(),
        source: source_of(&input.basis),
        coordinate: GenerationCoordinate::new(&input.basis, actual_library_metadata),
        digests: certified_digests(&input.basis),
        residuals: neco_quotient_certificate::ResidualSet::<()>::new([]),
        observations: certificate_observations(&input, &decoding),
        evidence,
    };
    let expectation = neco_quotient_certificate::Expected {
        rule_revision: GENERATION_RULE.to_owned(),
        source: source_of(&expected.basis),
        coordinate: GenerationCoordinate::new(
            &expected.basis,
            LibraryMetadata::from_basis(&input.basis),
        ),
        observations: expected.observations.clone(),
        residuals: neco_quotient_certificate::ResidualSet::<()>::new([]),
    };
    let table = generation_table().map_err(AdmissionFailure::RuleTable)?;
    let admission = neco_quotient_certificate::admit(
        table,
        certificate,
        expectation,
        CERTIFICATE_OPERATION.to_owned(),
    )
    .map_err(AdmissionFailure::Certificate)?;
    let composition = decoding.map_err(|failure| match failure {
        crate::semantic_exchange::SignatureCompositionAdmissionFailure::Wire(failure) => {
            AdmissionFailure::Wire(failure)
        }
        crate::semantic_exchange::SignatureCompositionAdmissionFailure::CompositionInput(
            failure,
        ) => AdmissionFailure::CompositionInput(failure),
        crate::semantic_exchange::SignatureCompositionAdmissionFailure::Composition(failure) => {
            AdmissionFailure::Composition(failure)
        }
    })?;
    Ok(CheckedSignatureGeneration {
        input,
        graph,
        composition,
        admission,
    })
}

pub fn signature_basis(
    library: &TypeSignatureLibrary,
    composition: Option<&serde_json::Value>,
    entrypoints: &[SignatureEntrypoint],
) -> Result<SignatureGenerationBasis> {
    let GenerationComponents {
        actual_library_metadata,
        evidence,
        ..
    } = generation_components(library, composition, entrypoints)?;
    let LibraryMetadata {
        signature_schema,
        library_identity,
        library_revision,
        profile,
    } = actual_library_metadata;
    Ok(SignatureGenerationBasis {
        signature_schema,
        library_identity,
        library_revision,
        profile,
        graph_sha256: hash(&evidence.graph),
        provenance_sha256: hash(&evidence.provenance),
        metadata_sha256: hash(&evidence.metadata),
        problem_sha256: evidence.composition.as_ref().map(hash),
        observations_sha256: observations_of(evidence.composition.as_ref())
            .map(|observations| hash(observations.value())),
        entrypoints_sha256: hash(&evidence.entrypoints),
    })
}
pub fn assemble_signature_generation(
    signatures: TypeSignatureLibrary,
    composition: Option<serde_json::Value>,
    entrypoints: Vec<SignatureEntrypoint>,
) -> Result<SignatureGenerationInput> {
    let signatures = Arc::new(signatures);
    let basis = signature_basis(&signatures, composition.as_ref(), &entrypoints)?;
    Ok(SignatureGenerationInput {
        schema: GENERATION_RULE.into(),
        basis,
        signatures,
        composition,
        entrypoints,
    })
}

#[derive(Debug, Clone, PartialEq)]
pub struct VersionedSemanticGraph {
    pub revision: String,
    pub graph: SemanticGraph,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SemanticValueInput {
    pub type_ref: TypeRef,
    pub value: JsonValue,
}

#[cfg(test)]
mod tests {
    use super::projection_digests;
    use super::scoped_digest;
    use neco_quotient_certificate::ProjectionDigests;

    #[test]
    fn projection_names_track_composition_presence() {
        let without_composition = projection_digests(
            "entrypoints".into(),
            "graph".into(),
            "metadata".into(),
            None,
            None,
            "provenance".into(),
        );
        let with_composition = projection_digests(
            "entrypoints".into(),
            "graph".into(),
            "metadata".into(),
            Some("problem".into()),
            Some("observations".into()),
            "provenance".into(),
        );

        assert_eq!(
            without_composition,
            ProjectionDigests::from([
                (
                    "entrypoints".to_owned(),
                    scoped_digest("entrypoints".to_owned())
                ),
                ("graph".to_owned(), scoped_digest("graph".to_owned())),
                ("metadata".to_owned(), scoped_digest("metadata".to_owned())),
                (
                    "provenance".to_owned(),
                    scoped_digest("provenance".to_owned())
                ),
            ])
        );
        assert_eq!(
            with_composition,
            ProjectionDigests::from([
                (
                    "entrypoints".to_owned(),
                    scoped_digest("entrypoints".to_owned())
                ),
                ("graph".to_owned(), scoped_digest("graph".to_owned())),
                ("metadata".to_owned(), scoped_digest("metadata".to_owned())),
                ("problem".to_owned(), scoped_digest("problem".to_owned())),
                (
                    "observations".to_owned(),
                    scoped_digest("observations".to_owned())
                ),
                (
                    "provenance".to_owned(),
                    scoped_digest("provenance".to_owned())
                ),
            ])
        );
    }
}

#[cfg(test)]
mod library_shape_tests {
    use super::*;
    use crate::semantic_exchange::GenerationFailure;

    fn shape(path: &str, message: &str) -> AdmissionFailure {
        AdmissionFailure::Wire(GenerationFailure::Syntax {
            path: path.into(),
            message: message.into(),
        })
    }

    #[test]
    fn graph_projection_reports_missing_members_as_wire_shapes() {
        assert_eq!(
            graph_projection_of(&serde_json::json!(null)),
            Err(shape("$", "object"))
        );
        assert_eq!(
            graph_projection_of(&serde_json::json!({"nodes": [], "definitions": []})),
            Err(shape("$.profile", "required field"))
        );
        assert_eq!(
            graph_projection_of(&serde_json::json!({"profile": {}, "definitions": []})),
            Err(shape("$.nodes", "array"))
        );
        assert_eq!(
            graph_projection_of(&serde_json::json!({"profile": {}, "nodes": []})),
            Err(shape("$.definitions", "array"))
        );
    }

    #[test]
    fn provenance_projection_reports_missing_members_as_wire_shapes() {
        assert_eq!(
            provenance_projection_of(&serde_json::json!(null)),
            Err(shape("$", "object"))
        );
        assert_eq!(
            provenance_projection_of(&serde_json::json!({"provenance": [], "definitions": []})),
            Err(shape("$.sources", "array"))
        );
        assert_eq!(
            provenance_projection_of(&serde_json::json!({"sources": [], "definitions": []})),
            Err(shape("$.provenance", "array"))
        );
        assert_eq!(
            provenance_projection_of(&serde_json::json!({"sources": [], "provenance": []})),
            Err(shape("$.definitions", "array"))
        );
    }

    #[test]
    fn graph_projection_rejects_a_node_without_identity() {
        assert_eq!(
            graph_projection_of(&serde_json::json!({
                "profile": {},
                "nodes": [{"shape": {}}],
                "definitions": []
            })),
            Err(shape("$.nodes.id", "required field"))
        );
    }

    #[test]
    fn graph_projection_rejects_an_operation_cause_without_tag() {
        assert_eq!(
            graph_projection_of(&serde_json::json!({
                "profile": {},
                "nodes": [],
                "definitions": [{
                    "id": "operation",
                    "shape": {
                        "tag": "Operation",
                        "value": {"outcomes": [{"id": "done", "cause": {}}]}
                    }
                }]
            })),
            Err(shape(
                "$.definitions.shape.value.outcomes.cause.tag",
                "required field"
            ))
        );
    }

    #[test]
    fn provenance_projection_rejects_a_source_without_repository() {
        assert_eq!(
            provenance_projection_of(&serde_json::json!({
                "sources": [{"revision": "1", "path": "p", "content_digest": "d"}],
                "provenance": [],
                "definitions": []
            })),
            Err(shape("$.sources.repository", "required field"))
        );
    }

    #[test]
    fn metadata_projection_reports_missing_members_as_wire_shapes() {
        assert_eq!(
            metadata_projection_of(&serde_json::json!(null)),
            Err(shape("$", "object"))
        );
        assert_eq!(
            metadata_projection_of(&serde_json::json!({"annotations": []})),
            Err(shape("$.groups", "array"))
        );
        assert_eq!(
            metadata_projection_of(&serde_json::json!({"groups": []})),
            Err(shape("$.annotations", "array"))
        );
    }
}
