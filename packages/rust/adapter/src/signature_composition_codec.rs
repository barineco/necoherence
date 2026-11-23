// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::exact_json::JsonValue as ExchangeJson;
use crate::semantic_composition::*;
use crate::semantic_exchange::{keys, syntax, CauseBinding, GenerationFailure, WireDecode};
use crate::semantic_types::{DefinitionRef, PathStep, SlotContract, SlotValue, TypeRef, ValuePath};
use crate::signature_admission::{
    check_type_signatures, signature_basis, signature_definition_ref, signature_type_ref,
    AdmissionFailure,
};
use crate::type_signatures::{OutcomeCause, SignatureGenerationBasis, TypeSignatureLibrary};
use crate::typed_mapping::BindingMode;
use num_bigint::BigUint;
use serde_json::Value;

pub type Decoded<T> = Result<T, GenerationFailure>;
type Members<'a> = &'a [(String, ExchangeJson)];

const PROBLEM_FIELDS: [&str; 12] = [
    "identity",
    "revision",
    "basis",
    "signatures",
    "initial_inputs",
    "initial_resources",
    "goal",
    "invocation_domain",
    "allowed_effects",
    "explicit_order",
    "selection_policy",
    "bounds",
];

pub fn field_path(path: &str, name: &str) -> String {
    format!("{path}.{name}")
}

fn admission(failure: AdmissionFailure) -> GenerationFailure {
    GenerationFailure::Admission(Box::new(failure))
}

pub fn to_exchange(value: &Value) -> Decoded<ExchangeJson> {
    crate::exact_json::parse_json_text(&value.to_string()).map_err(GenerationFailure::InvalidJson)
}

pub fn library_basis(library: &TypeSignatureLibrary) -> Decoded<SignatureGenerationBasis> {
    signature_basis(library, None, &[]).map_err(admission)
}

pub(crate) fn members<'a>(value: &'a ExchangeJson, path: &str) -> Decoded<Members<'a>> {
    match value {
        ExchangeJson::Obj(members) => Ok(members.as_slice()),
        _ => Err(syntax(path, "object expected")),
    }
}

pub fn member<'a>(members: Members<'a>, path: &str, name: &str) -> Decoded<&'a ExchangeJson> {
    members
        .iter()
        .find(|(key, _)| key.as_str() == name)
        .map(|(_, value)| value)
        .ok_or_else(|| {
            syntax(
                &field_path(path, name),
                &format!("property not found: {name}"),
            )
        })
}

pub fn read<T: WireDecode>(members: Members<'_>, path: &str, name: &str) -> Decoded<T> {
    T::decode_wire(member(members, path, name)?, &field_path(path, name))
}

pub fn read_with<T>(
    members: Members<'_>,
    path: &str,
    name: &str,
    decode: impl Fn(&ExchangeJson, &str) -> Decoded<T>,
) -> Decoded<T> {
    decode(member(members, path, name)?, &field_path(path, name))
}

pub fn array<'a>(value: &'a ExchangeJson, path: &str) -> Decoded<&'a [ExchangeJson]> {
    match value {
        ExchangeJson::Arr(items) => Ok(items.as_slice()),
        _ => Err(syntax(path, "array expected")),
    }
}

pub fn decode_all<T>(
    value: &ExchangeJson,
    path: &str,
    decode: impl Fn(&ExchangeJson, &str) -> Decoded<T>,
) -> Decoded<Vec<T>> {
    array(value, path)?
        .iter()
        .enumerate()
        .map(|(index, item)| decode(item, &format!("{path}[{index}]")))
        .collect()
}

pub fn decode_optional<T>(
    value: &ExchangeJson,
    path: &str,
    decode: impl Fn(&ExchangeJson, &str) -> Decoded<T>,
) -> Decoded<Option<T>> {
    match value {
        ExchangeJson::Null => Ok(None),
        value => decode(value, path).map(Some),
    }
}

pub fn decode_pair<A, B>(
    value: &ExchangeJson,
    path: &str,
    first: impl Fn(&ExchangeJson, &str) -> Decoded<A>,
    second: impl Fn(&ExchangeJson, &str) -> Decoded<B>,
) -> Decoded<(A, B)> {
    match array(value, path)? {
        [left, right] => Ok((first(left, path)?, second(right, path)?)),
        _ => Err(syntax(path, "pair size")),
    }
}

pub fn decode_identifier<T>(value: &ExchangeJson, path: &str, wrap: fn(String) -> T) -> Decoded<T> {
    String::decode_wire(value, path).map(wrap)
}

pub fn tag_of<'a>(value: &'a ExchangeJson, path: &str) -> Decoded<&'a str> {
    match member(members(value, path)?, path, "tag")? {
        ExchangeJson::Str(tag) => Ok(tag.as_str()),
        _ => Err(syntax(&field_path(path, "tag"), "String expected")),
    }
}

pub fn unknown_tag(path: &str, tag: &str) -> GenerationFailure {
    GenerationFailure::UnknownTag {
        path: field_path(path, "tag"),
        tag: tag.to_owned(),
    }
}

pub fn unit_variant<T>(value: &ExchangeJson, path: &str, variant: T) -> Decoded<T> {
    keys(value, path, &["tag"])?;
    Ok(variant)
}

pub fn payload_with<T>(
    value: &ExchangeJson,
    path: &str,
    decode: impl Fn(&ExchangeJson, &str) -> Decoded<T>,
) -> Decoded<T> {
    let row = keys(value, path, &["tag", "value"])?;
    decode(member(row, path, "value")?, &field_path(path, "value"))
}

pub fn tagged_fields<'a>(
    value: &'a ExchangeJson,
    path: &str,
    names: &[&str],
) -> Decoded<Members<'a>> {
    let row = keys(value, path, &["tag", "fields"])?;
    let fields_path = field_path(path, "fields");
    keys(member(row, path, "fields")?, &fields_path, names)
}

pub(crate) fn decode_type_ref(value: &ExchangeJson, path: &str) -> Decoded<TypeRef> {
    String::decode_wire(value, path).map(|id| signature_type_ref(&id))
}

fn decode_definition_ref(value: &ExchangeJson, path: &str) -> Decoded<DefinitionRef> {
    String::decode_wire(value, path).map(|name| signature_definition_ref(&name))
}

pub fn decode_function_ref(value: &ExchangeJson, path: &str) -> Decoded<FunctionRef> {
    let members = keys(value, path, &["identity", "revision", "content_digest"])?;
    Ok(FunctionRef {
        identity: read(members, path, "identity")?,
        revision: read(members, path, "revision")?,
        content_digest: read(members, path, "content_digest")?,
    })
}

pub fn decode_slot_contract(value: &ExchangeJson, path: &str) -> Decoded<SlotContract> {
    let members = keys(value, path, &["type_id", "required", "nullable"])?;
    Ok(SlotContract {
        type_ref: read_with(members, path, "type_id", decode_type_ref)?,
        required: read(members, path, "required")?,
        nullable: read(members, path, "nullable")?,
    })
}

fn decode_json_value(value: &ExchangeJson, path: &str) -> Decoded<ExchangeJson> {
    ExchangeJson::decode_wire(value, path)
}

pub fn decode_slot_value(value: &ExchangeJson, path: &str) -> Decoded<SlotValue> {
    match tag_of(value, path)? {
        "Absent" => unit_variant(value, path, SlotValue::Absent),
        "Null" => unit_variant(value, path, SlotValue::Null),
        "Present" => payload_with(value, path, |value, path| {
            decode_json_value(value, path).map(SlotValue::Present)
        }),
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_path_step(value: &ExchangeJson, path: &str) -> Decoded<PathStep> {
    match tag_of(value, path)? {
        "Field" => payload_with(value, path, |value, path| {
            String::decode_wire(value, path).map(PathStep::Field)
        }),
        "Index" => payload_with(value, path, |value, path| {
            BigUint::decode_wire(value, path).map(PathStep::Index)
        }),
        "Variant" => payload_with(value, path, |value, path| {
            String::decode_wire(value, path).map(PathStep::Variant)
        }),
        tag => Err(unknown_tag(path, tag)),
    }
}

pub(crate) fn decode_value_path(value: &ExchangeJson, path: &str) -> Decoded<ValuePath> {
    decode_all(value, path, decode_path_step)
}

fn decode_source_constraint(value: &ExchangeJson, path: &str) -> Decoded<SourceConstraint> {
    match tag_of(value, path)? {
        "AnyCompatible" => unit_variant(value, path, SourceConstraint::AnyCompatible),
        "InitialOnly" => {
            let row = tagged_fields(value, path, &["input", "path"])?;
            Ok(SourceConstraint::InitialOnly {
                input: read_with(row, path, "input", |value, path| {
                    decode_identifier(value, path, InputId)
                })?,
                path: read_with(row, path, "path", decode_value_path)?,
            })
        }
        "ProducedBy" => {
            let row = tagged_fields(value, path, &["site", "outcome", "port", "path"])?;
            Ok(SourceConstraint::ProducedBy {
                site: read_with(row, path, "site", |value, path| {
                    decode_identifier(value, path, SiteId)
                })?,
                outcome: read_with(row, path, "outcome", |value, path| {
                    decode_identifier(value, path, OutcomeId)
                })?,
                port: read_with(row, path, "port", |value, path| {
                    decode_identifier(value, path, PortId)
                })?,
                path: read_with(row, path, "path", decode_value_path)?,
            })
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

pub fn decode_resource_lot_ref(value: &ExchangeJson, path: &str) -> Decoded<ResourceLotRef> {
    match tag_of(value, path)? {
        "Initial" => payload_with(value, path, |value, path| {
            decode_identifier(value, path, LotId).map(ResourceLotRef::Initial)
        }),
        "Produced" => {
            let row = tagged_fields(value, path, &["site", "outcome", "production"])?;
            Ok(ResourceLotRef::Produced {
                site: read_with(row, path, "site", |value, path| {
                    decode_identifier(value, path, SiteId)
                })?,
                outcome: read_with(row, path, "outcome", |value, path| {
                    decode_identifier(value, path, OutcomeId)
                })?,
                production: read_with(row, path, "production", |value, path| {
                    decode_identifier(value, path, ProductionId)
                })?,
            })
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_resource_producer(value: &ExchangeJson, path: &str) -> Decoded<ResourceProducer> {
    match tag_of(value, path)? {
        "Initial" => {
            let row = tagged_fields(value, path, &["identity", "revision"])?;
            Ok(ResourceProducer::Initial {
                identity: read(row, path, "identity")?,
                revision: read(row, path, "revision")?,
            })
        }
        "InvocationOutcome" => {
            let row = tagged_fields(value, path, &["site", "outcome"])?;
            Ok(ResourceProducer::InvocationOutcome {
                site: read_with(row, path, "site", |value, path| {
                    decode_identifier(value, path, SiteId)
                })?,
                outcome: read_with(row, path, "outcome", |value, path| {
                    decode_identifier(value, path, OutcomeId)
                })?,
            })
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_resource_identity_constraint(
    value: &ExchangeJson,
    path: &str,
) -> Decoded<ResourceIdentityConstraint> {
    match tag_of(value, path)? {
        "Any" => unit_variant(value, path, ResourceIdentityConstraint::Any),
        "Exactly" => payload_with(value, path, decode_resource_producer)
            .map(ResourceIdentityConstraint::Exactly),
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_resource_lot(value: &ExchangeJson, path: &str) -> Decoded<ResourceLot> {
    let members = keys(
        value,
        path,
        &[
            "id",
            "token_type",
            "producer",
            "revision",
            "quantity",
            "provenance",
        ],
    )?;
    Ok(ResourceLot {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, LotId)
        })?,
        token_type: read_with(members, path, "token_type", decode_type_ref)?,
        producer: read_with(members, path, "producer", decode_resource_producer)?,
        revision: read(members, path, "revision")?,
        quantity: read(members, path, "quantity")?,
        provenance: read(members, path, "provenance")?,
    })
}

fn decode_binding_mode(value: &ExchangeJson, path: &str) -> Decoded<BindingMode> {
    match tag_of(value, path)? {
        "Read" => unit_variant(value, path, BindingMode::Read),
        "Consume" => unit_variant(value, path, BindingMode::Consume),
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_resource_requirement(value: &ExchangeJson, path: &str) -> Decoded<ResourceRequirement> {
    let members = keys(
        value,
        path,
        &[
            "id",
            "token_type",
            "mode",
            "multiplicity",
            "required_revision",
            "identity",
        ],
    )?;
    Ok(ResourceRequirement {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, RequirementId)
        })?,
        token_type: read_with(members, path, "token_type", decode_type_ref)?,
        mode: read_with(members, path, "mode", decode_binding_mode)?,
        multiplicity: read(members, path, "multiplicity")?,
        required_revision: read(members, path, "required_revision")?,
        identity: read_with(
            members,
            path,
            "identity",
            decode_resource_identity_constraint,
        )?,
    })
}

fn decode_resource_production(value: &ExchangeJson, path: &str) -> Decoded<ResourceProduction> {
    let members = keys(
        value,
        path,
        &["id", "token_type", "revision", "quantity", "provenance"],
    )?;
    Ok(ResourceProduction {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, ProductionId)
        })?,
        token_type: read_with(members, path, "token_type", decode_type_ref)?,
        revision: read(members, path, "revision")?,
        quantity: read(members, path, "quantity")?,
        provenance: read(members, path, "provenance")?,
    })
}

fn decode_initial_source(value: &ExchangeJson, path: &str) -> Decoded<InitialSource> {
    match tag_of(value, path)? {
        "Argument" => unit_variant(value, path, InitialSource::Argument),
        "SuppliedValue" => {
            payload_with(value, path, decode_slot_value).map(InitialSource::SuppliedValue)
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_initial_input(value: &ExchangeJson, path: &str) -> Decoded<InitialInput> {
    let members = keys(value, path, &["id", "contract", "source", "resource"])?;
    Ok(InitialInput {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, InputId)
        })?,
        contract: read_with(members, path, "contract", decode_slot_contract)?,
        source: read_with(members, path, "source", decode_initial_source)?,
        resource: read_with(members, path, "resource", |value, path| {
            decode_optional(value, path, |value, path| {
                decode_identifier(value, path, LotId)
            })
        })?,
    })
}

fn decode_input_port(value: &ExchangeJson, path: &str) -> Decoded<InputPort> {
    let members = keys(
        value,
        path,
        &[
            "id",
            "contract",
            "source_constraint",
            "resource_requirement",
        ],
    )?;
    Ok(InputPort {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, PortId)
        })?,
        contract: read_with(members, path, "contract", decode_slot_contract)?,
        source_constraint: read_with(members, path, "source_constraint", decode_source_constraint)?,
        resource_requirement: read_with(members, path, "resource_requirement", |value, path| {
            decode_optional(value, path, |value, path| {
                decode_identifier(value, path, RequirementId)
            })
        })?,
    })
}

fn decode_output_port(value: &ExchangeJson, path: &str) -> Decoded<OutputPort> {
    let members = keys(value, path, &["id", "contract", "resource_production"])?;
    Ok(OutputPort {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, PortId)
        })?,
        contract: read_with(members, path, "contract", decode_slot_contract)?,
        resource_production: read_with(members, path, "resource_production", |value, path| {
            decode_optional(value, path, |value, path| {
                decode_identifier(value, path, ProductionId)
            })
        })?,
    })
}

fn decode_outcome_form(value: &ExchangeJson, path: &str) -> Decoded<OutcomeForm> {
    match tag_of(value, path)? {
        "Success" => unit_variant(value, path, OutcomeForm::Success),
        "DeclaredFailure" => unit_variant(value, path, OutcomeForm::DeclaredFailure),
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_outcome_cause(value: &ExchangeJson, path: &str) -> Decoded<OutcomeCause> {
    OutcomeCause::decode_wire(value, path)
}

fn decode_outcome_contract(value: &ExchangeJson, path: &str) -> Decoded<OutcomeContract> {
    let members = keys(
        value,
        path,
        &["id", "form", "cause", "value_ports", "produced_resources"],
    )?;
    read_with(members, path, "cause", decode_outcome_cause)?;
    Ok(OutcomeContract {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, OutcomeId)
        })?,
        form: read_with(members, path, "form", decode_outcome_form)?,
        value_ports: read_with(members, path, "value_ports", |value, path| {
            decode_all(value, path, decode_output_port)
        })?,
        produced_resources: read_with(members, path, "produced_resources", |value, path| {
            decode_all(value, path, decode_resource_production)
        })?,
    })
}

fn decode_function_form(value: &ExchangeJson, path: &str) -> Decoded<FunctionForm> {
    match tag_of(value, path)? {
        "Pure" => unit_variant(value, path, FunctionForm::Pure),
        "DeclaredTransform" => unit_variant(value, path, FunctionForm::DeclaredTransform),
        "Operation" => {
            payload_with(value, path, decode_definition_ref).map(FunctionForm::Operation)
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_composition_effect(value: &ExchangeJson, path: &str) -> Decoded<CompositionEffect> {
    match tag_of(value, path)? {
        "PureFunction" => unit_variant(value, path, CompositionEffect::PureFunction),
        "HttpRequestResponse" => unit_variant(value, path, CompositionEffect::HttpRequestResponse),
        "DataOnly" => unit_variant(value, path, CompositionEffect::DataOnly),
        tag => Err(unknown_tag(path, tag)),
    }
}

pub fn decode_guard_arm(value: &ExchangeJson, path: &str) -> Decoded<GuardArm> {
    match tag_of(value, path)? {
        "Present" => unit_variant(value, path, GuardArm::Present),
        "Absent" => unit_variant(value, path, GuardArm::Absent),
        "Null" => unit_variant(value, path, GuardArm::Null),
        "UnknownVariant" => unit_variant(value, path, GuardArm::UnknownVariant),
        "Accepted" => unit_variant(value, path, GuardArm::Accepted),
        "Rejected" => unit_variant(value, path, GuardArm::Rejected),
        "Variant" => payload_with(value, path, String::decode_wire).map(GuardArm::Variant),
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_failure_origin(value: &ExchangeJson, path: &str) -> Decoded<FailureOrigin> {
    match tag_of(value, path)? {
        "Function" => {
            let row = tagged_fields(value, path, &["function", "outcome"])?;
            Ok(FailureOrigin::Function {
                function: read_with(row, path, "function", decode_function_ref)?,
                outcome: read_with(row, path, "outcome", |value, path| {
                    decode_identifier(value, path, OutcomeId)
                })?,
            })
        }
        "Guard" => {
            let row = tagged_fields(value, path, &["guard", "arm"])?;
            Ok(FailureOrigin::Guard {
                guard: read_with(row, path, "guard", |value, path| {
                    decode_identifier(value, path, GuardId)
                })?,
                arm: read_with(row, path, "arm", decode_guard_arm)?,
            })
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_function_signature(value: &ExchangeJson, path: &str) -> Decoded<FunctionSignature> {
    let members = keys(
        value,
        path,
        &[
            "reference",
            "form",
            "effect",
            "inputs",
            "outcomes",
            "resource_inputs",
            "assumption_ref",
            "handles_failure",
        ],
    )?;
    let reference = read_with(members, path, "reference", decode_function_ref)?;
    let form = read_with(members, path, "form", decode_function_form)?;
    let effect = read_with(members, path, "effect", decode_composition_effect)?;
    let inputs = read_with(members, path, "inputs", |value, path| {
        decode_all(value, path, decode_input_port)
    })?;
    let outcomes = read_with(members, path, "outcomes", |value, path| {
        decode_all(value, path, decode_outcome_contract)
    })?;
    let resource_inputs = read_with(members, path, "resource_inputs", |value, path| {
        decode_all(value, path, decode_resource_requirement)
    })?;
    let assumption_ref = read(members, path, "assumption_ref")?;
    let handles_failure = read_with(members, path, "handles_failure", |value, path| {
        decode_optional(value, path, decode_failure_origin)
    })?;
    Ok(FunctionSignature {
        reference,
        form,
        effect,
        inputs,
        outcomes,
        resource_inputs,
        assumption_ref,
        handles_failure,
    })
}

fn decode_invocation_site(value: &ExchangeJson, path: &str) -> Decoded<InvocationSite> {
    let members = keys(value, path, &["id", "function"])?;
    Ok(InvocationSite {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, SiteId)
        })?,
        function: read_with(members, path, "function", decode_function_ref)?,
    })
}

fn decode_permitted_projection(value: &ExchangeJson, path: &str) -> Decoded<PermittedProjection> {
    let members = keys(value, path, &["source_type", "path"])?;
    Ok(PermittedProjection {
        source_type: read_with(members, path, "source_type", decode_type_ref)?,
        path: read_with(members, path, "path", decode_value_path)?,
    })
}

fn decode_guard_kind(value: &ExchangeJson, path: &str) -> Decoded<GuardKind> {
    match tag_of(value, path)? {
        "Presence" => unit_variant(value, path, GuardKind::Presence),
        "Variants" => unit_variant(value, path, GuardKind::Variants),
        "Validate" => payload_with(value, path, decode_slot_contract).map(GuardKind::Validate),
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_declared_guard(value: &ExchangeJson, path: &str) -> Decoded<DeclaredGuard> {
    let members = keys(value, path, &["id", "source_type", "path", "kind"])?;
    Ok(DeclaredGuard {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, GuardId)
        })?,
        source_type: read_with(members, path, "source_type", decode_type_ref)?,
        path: read_with(members, path, "path", decode_value_path)?,
        kind: read_with(members, path, "kind", decode_guard_kind)?,
    })
}

fn decode_field_presence(value: &ExchangeJson, path: &str) -> Decoded<FieldPresence> {
    match tag_of(value, path)? {
        "Required" => unit_variant(value, path, FieldPresence::Required),
        "Optional" => unit_variant(value, path, FieldPresence::Optional),
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_field_constraint(value: &ExchangeJson, path: &str) -> Decoded<FieldConstraint> {
    let members = keys(value, path, &["field", "source", "presence"])?;
    Ok(FieldConstraint {
        field: read(members, path, "field")?,
        source: read_with(members, path, "source", decode_source_constraint)?,
        presence: read_with(members, path, "presence", decode_field_presence)?,
    })
}

fn decode_construction_rule(value: &ExchangeJson, path: &str) -> Decoded<ConstructionRule> {
    let members = keys(
        value,
        path,
        &["identity", "type_id", "nested_fields", "field_constraints"],
    )?;
    Ok(ConstructionRule {
        identity: read(members, path, "identity")?,
        type_ref: read_with(members, path, "type_id", decode_type_ref)?,
        nested_fields: read_with(members, path, "nested_fields", |value, path| {
            decode_all(value, path, |value, path| {
                decode_pair(value, path, String::decode_wire, String::decode_wire)
            })
        })?,
        field_constraints: read_with(members, path, "field_constraints", |value, path| {
            decode_all(value, path, decode_field_constraint)
        })?,
    })
}

fn decode_invocation_domain(value: &ExchangeJson, path: &str) -> Decoded<InvocationDomain> {
    let members = keys(
        value,
        path,
        &[
            "identity",
            "revision",
            "sites",
            "permitted_projections",
            "permitted_constructions",
            "permitted_transforms",
            "guards",
        ],
    )?;
    Ok(InvocationDomain {
        identity: read(members, path, "identity")?,
        revision: read(members, path, "revision")?,
        sites: read_with(members, path, "sites", |value, path| {
            decode_all(value, path, decode_invocation_site)
        })?,
        permitted_projections: read_with(members, path, "permitted_projections", |value, path| {
            decode_all(value, path, decode_permitted_projection)
        })?,
        permitted_constructions: read_with(
            members,
            path,
            "permitted_constructions",
            |value, path| decode_all(value, path, decode_construction_rule),
        )?,
        permitted_transforms: read_with(members, path, "permitted_transforms", |value, path| {
            decode_all(value, path, decode_function_ref)
        })?,
        guards: read_with(members, path, "guards", |value, path| {
            decode_all(value, path, decode_declared_guard)
        })?,
    })
}

fn decode_resource_goal(value: &ExchangeJson, path: &str) -> Decoded<ResourceGoal> {
    let members = keys(value, path, &["lot", "multiplicity", "revision"])?;
    Ok(ResourceGoal {
        lot: read_with(members, path, "lot", decode_resource_lot_ref)?,
        multiplicity: read(members, path, "multiplicity")?,
        revision: read(members, path, "revision")?,
    })
}

fn decode_goal_port(value: &ExchangeJson, path: &str) -> Decoded<GoalPort> {
    let members = keys(value, path, &["id", "contract", "source_constraint"])?;
    Ok(GoalPort {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, GoalPortId)
        })?,
        contract: read_with(members, path, "contract", decode_slot_contract)?,
        source_constraint: read_with(members, path, "source_constraint", decode_source_constraint)?,
    })
}

fn decode_failure_embedding(value: &ExchangeJson, path: &str) -> Decoded<FailureEmbedding> {
    let members = keys(
        value,
        path,
        &["id", "origin", "contract", "final_resources"],
    )?;
    Ok(FailureEmbedding {
        id: read_with(members, path, "id", |value, path| {
            decode_identifier(value, path, FailureEmbeddingId)
        })?,
        origin: read_with(members, path, "origin", decode_failure_origin)?,
        contract: read_with(members, path, "contract", decode_slot_contract)?,
        final_resources: read_with(members, path, "final_resources", |value, path| {
            decode_all(value, path, decode_resource_goal)
        })?,
    })
}

fn decode_goal_spec(value: &ExchangeJson, path: &str) -> Decoded<GoalSpec> {
    let members = keys(value, path, &["outputs", "failures", "final_resources"])?;
    Ok(GoalSpec {
        outputs: read_with(members, path, "outputs", |value, path| {
            decode_all(value, path, decode_goal_port)
        })?,
        failures: read_with(members, path, "failures", |value, path| {
            decode_all(value, path, decode_failure_embedding)
        })?,
        final_resources: read_with(members, path, "final_resources", |value, path| {
            decode_all(value, path, decode_resource_goal)
        })?,
    })
}

fn decode_selection_policy(value: &ExchangeJson, path: &str) -> Decoded<SelectionPolicy> {
    match tag_of(value, path)? {
        "RequireUnique" => unit_variant(value, path, SelectionPolicy::RequireUnique),
        "AnyFeasible" => unit_variant(value, path, SelectionPolicy::AnyFeasible),
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_resource_bounds(value: &ExchangeJson, path: &str) -> Decoded<ResourceBounds> {
    let members = keys(
        value,
        path,
        &["max_bindings", "max_search_steps", "max_tokens"],
    )?;
    Ok(ResourceBounds {
        max_bindings: read(members, path, "max_bindings")?,
        max_search_steps: read(members, path, "max_search_steps")?,
        max_tokens: read(members, path, "max_tokens")?,
    })
}

fn decode_search_bounds(value: &ExchangeJson, path: &str) -> Decoded<SearchBounds> {
    let members = keys(
        value,
        path,
        &[
            "max_expanded_states",
            "max_binding_candidates",
            "max_type_obligations",
            "max_branch_nodes",
            "resource_bounds",
            "max_sample_length",
        ],
    )?;
    Ok(SearchBounds {
        max_expanded_states: read(members, path, "max_expanded_states")?,
        max_binding_candidates: read(members, path, "max_binding_candidates")?,
        max_type_obligations: read(members, path, "max_type_obligations")?,
        max_branch_nodes: read(members, path, "max_branch_nodes")?,
        resource_bounds: read_with(members, path, "resource_bounds", |value, path| {
            decode_optional(value, path, decode_resource_bounds)
        })?,
        max_sample_length: read(members, path, "max_sample_length")?,
    })
}

fn cause_bindings(rows: &ExchangeJson, path: &str) -> Decoded<Vec<CauseBinding>> {
    let mut bindings = Vec::new();
    for (index, row) in array(rows, path)?.iter().enumerate() {
        let row_path = format!("{path}[{index}]");
        let row_members = members(row, &row_path)?;
        let function = read_with(row_members, &row_path, "reference", decode_function_ref)?;
        let outcomes_path = field_path(&row_path, "outcomes");
        let outcomes = member(row_members, &row_path, "outcomes")?;
        for outcome in array(outcomes, &outcomes_path)? {
            let outcome_members = members(outcome, &outcomes_path)?;
            let id = read_with(outcome_members, &outcomes_path, "id", |value, path| {
                decode_identifier(value, path, OutcomeId)
            })?;
            let cause = read_with(
                outcome_members,
                &outcomes_path,
                "cause",
                decode_outcome_cause,
            )?;
            bindings.push(CauseBinding {
                function: function.clone(),
                outcome: id,
                cause,
            });
        }
    }
    Ok(bindings)
}

pub fn decode_problem(
    library: &TypeSignatureLibrary,
    value: &Value,
    path: &str,
) -> Decoded<(CompositionInput, Vec<CauseBinding>)> {
    decode_problem_with_basis(library, &library_basis(library), value, path)
}

pub fn decode_problem_with_basis(
    library: &TypeSignatureLibrary,
    library_basis: &Decoded<SignatureGenerationBasis>,
    value: &Value,
    path: &str,
) -> Decoded<(CompositionInput, Vec<CauseBinding>)> {
    let root = to_exchange(value)?;
    let members = keys(&root, path, &PROBLEM_FIELDS)?;
    let supplied: SignatureGenerationBasis = read(members, path, "basis")?;
    if &supplied != library_basis.as_ref().map_err(Clone::clone)? {
        return Err(syntax(
            &field_path(path, "basis"),
            "composition signature basis mismatch",
        ));
    }
    let signature_rows = member(members, path, "signatures")?;
    let signatures_path = field_path(path, "signatures");
    let signatures = decode_all(signature_rows, &signatures_path, |row, row_path| {
        decode_function_signature(row, row_path)
    })?;
    let causes = cause_bindings(signature_rows, &signatures_path)?;
    let graph = check_type_signatures(library).map_err(admission)?;
    let problem = CompositionInput {
        identity: read(members, path, "identity")?,
        revision: read(members, path, "revision")?,
        basis: SemanticBasis::of(&graph),
        signatures,
        initial_inputs: read_with(members, path, "initial_inputs", |value, path| {
            decode_all(value, path, decode_initial_input)
        })?,
        initial_resources: read_with(members, path, "initial_resources", |value, path| {
            decode_all(value, path, decode_resource_lot)
        })?,
        goal: read_with(members, path, "goal", decode_goal_spec)?,
        invocation_domain: read_with(members, path, "invocation_domain", decode_invocation_domain)?,
        allowed_effects: read_with(members, path, "allowed_effects", |value, path| {
            decode_all(value, path, decode_composition_effect)
        })?,
        explicit_order: read_with(members, path, "explicit_order", |value, path| {
            decode_all(value, path, |value, path| {
                decode_pair(
                    value,
                    path,
                    |value, path| decode_identifier(value, path, SiteId),
                    |value, path| decode_identifier(value, path, SiteId),
                )
            })
        })?,
        selection_policy: read_with(members, path, "selection_policy", |value, path| {
            decode_optional(value, path, decode_selection_policy)
        })?,
        bounds: read_with(members, path, "bounds", decode_search_bounds)?,
    };
    Ok((problem, causes))
}
